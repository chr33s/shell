#if os(macOS)
import Foundation
import NIOCore
import NIOPosix

/// A loopback sshd launched from a local OpenSSH build, for the live interoperability tests.
///
/// Point `OPENSSH_INTEROP_BINARIES` at a built openssh-portable directory to enable those tests;
/// they skip when it is unset. Keys, certificates and the config live in a temporary directory
/// that `stop()` removes, and the server only ever listens on 127.0.0.1.
final class OpenSSHTestServer {
    struct Configuration {
        var cipher = "aes256-gcm@openssh.com"
        var mac = "hmac-sha2-256-etm@openssh.com"
        /// Restricts sshd's KexAlgorithms, e.g. curve25519-sha256 to force a SHA-256 exchange hash.
        var kex: String?
        var rekeyLimit = "16K"

        init(cipher: String = "aes256-gcm@openssh.com", mac: String = "hmac-sha2-256-etm@openssh.com", kex: String? = nil, rekeyLimit: String = "16K") {
            self.cipher = cipher
            self.mac = mac
            self.kex = kex
            self.rekeyLimit = rekeyLimit
        }
    }

    enum StartError: Error, CustomStringConvertible {
        case toolFailed(String, String)
        case unsupported(String)
        case didNotStart(String)

        var description: String {
            switch self {
            case .toolFailed(let tool, let output): return "\(tool) failed: \(output)"
            case .unsupported(let what): return "This OpenSSH build does not support \(what)"
            case .didNotStart(let reason): return "sshd did not start: \(reason)"
            }
        }
    }

    /// The OpenSSH build directory, when the environment enables the live tests.
    static var binaries: URL? {
        ProcessInfo.processInfo.environment["OPENSSH_INTEROP_BINARIES"].map { URL(fileURLWithPath: $0) }
    }

    let fixtures: URL
    let port: Int
    /// True when the build predates the canonical `ssh-mldsa44-ed25519` names.
    let usesLegacyHybridNames: Bool

    private let process: Process
    private let logURL: URL

    /// Everything sshd has logged so far. It runs at DEBUG3, which is what reports strict KEX.
    var diagnostics: String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    static func start(_ configuration: Configuration = .init()) throws -> OpenSSHTestServer {
        let binaries = try XCTUnwrapBinaries()
        let fixtures = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("citadel-openssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

        guard try query(binaries, "cipher").contains(configuration.cipher) else {
            throw StartError.unsupported(configuration.cipher)
        }
        let keyTypes = try query(binaries, "key")
        let legacy = !keyTypes.contains("ssh-mldsa44-ed25519")
        let algorithm = legacy ? "ssh-mldsa44-ed25519@openssh.com" : "ssh-mldsa44-ed25519"
        let certificate = legacy ? "ssh-mldsa44-ed25519-cert-v01@openssh.com" : "ssh-mldsa44-ed25519-cert"
        guard keyTypes.contains(algorithm) else {
            throw StartError.unsupported("hybrid ML-DSA-44 + Ed25519")
        }

        try generateFixtures(binaries: binaries, fixtures: fixtures)

        let port = try reserveLoopbackPort()
        let config = fixtures.appendingPathComponent("sshd_config")
        try sshdConfig(configuration, binaries: binaries, fixtures: fixtures, port: port,
                       algorithm: algorithm, certificate: certificate)
            .write(to: config, atomically: true, encoding: .utf8)

        let logURL = fixtures.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = binaries.appendingPathComponent("sshd")
        process.arguments = ["-D", "-e", "-f", config.path]
        process.standardOutput = log
        process.standardError = log
        try process.run()

        let server = OpenSSHTestServer(fixtures: fixtures, port: port, usesLegacyHybridNames: legacy,
                                       process: process, logURL: logURL)
        do {
            try server.waitUntilListening()
        } catch {
            server.stop()
            throw error
        }
        return server
    }

    private init(fixtures: URL, port: Int, usesLegacyHybridNames: Bool, process: Process, logURL: URL) {
        self.fixtures = fixtures
        self.port = port
        self.usesLegacyHybridNames = usesLegacyHybridNames
        self.process = process
        self.logURL = logURL
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: fixtures)
    }

    /// Reads a fixture file, e.g. `""` for the private key or `"-user-cert.pub"` for the user certificate.
    func fixture(_ suffix: String = "") throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent("key" + suffix), encoding: .utf8)
    }

    func path(_ name: String) -> String {
        fixtures.appendingPathComponent(name).path
    }

    // MARK: Setup

    private static func XCTUnwrapBinaries() throws -> URL {
        guard let binaries = Self.binaries else {
            throw StartError.didNotStart("OPENSSH_INTEROP_BINARIES is not set")
        }
        return binaries
    }

    private static func generateFixtures(binaries: URL, fixtures: URL) throws {
        let key = fixtures.appendingPathComponent("key").path
        let ca = fixtures.appendingPathComponent("ca").path
        try keygen(binaries, ["-t", "mldsa44-ed25519", "-N", "", "-f", key])
        try keygen(binaries, ["-t", "ed25519", "-N", "", "-f", ca])
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("ca.pub"),
                                         to: fixtures.appendingPathComponent("key-ca.pub"))

        // The user certificate first, then the host certificate, which overwrites key-cert.pub.
        try keygen(binaries, ["-s", ca, "-I", "test-user", "-n", NSUserName(), "-V", "-1h:+1h", key + ".pub"])
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("key-cert.pub"),
                                         to: fixtures.appendingPathComponent("key-user-cert.pub"))
        try keygen(binaries, ["-s", ca, "-I", "test-host", "-h", "-n", "localhost", "-V", "-1h:+1h", key + ".pub"])
    }

    private static func sshdConfig(_ configuration: Configuration, binaries: URL, fixtures: URL, port: Int,
                                   algorithm: String, certificate: String) -> String {
        var lines = [
            "ListenAddress 127.0.0.1",
            "Port \(port)",
            "HostKey \(fixtures.path)/key",
            "HostCertificate \(fixtures.path)/key-cert.pub",
            "HostKeyAlgorithms \(certificate),\(algorithm)",
            "PubkeyAcceptedAlgorithms \(certificate),\(algorithm)",
            "AuthorizedKeysFile \(fixtures.path)/key.pub",
            "TrustedUserCAKeys \(fixtures.path)/ca.pub",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "UsePAM no",
            "StrictModes no",
            "PidFile \(fixtures.path)/sshd.pid",
            "SshdAuthPath \(binaries.path)/sshd-auth",
            "SshdSessionPath \(binaries.path)/sshd-session",
            "Subsystem sftp \(binaries.path)/sftp-server",
            "Ciphers \(configuration.cipher)",
            "MACs \(configuration.mac)",
            "RekeyLimit \(configuration.rekeyLimit)",
            "LogLevel DEBUG3",
        ]
        if let kex = configuration.kex {
            lines.append("KexAlgorithms \(kex)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func waitUntilListening() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard process.isRunning else {
                throw StartError.didNotStart(diagnostics)
            }
            if Self.canConnect(port: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw StartError.didNotStart("timed out waiting for port \(port)")
    }

    // MARK: Running the OpenSSH tools

    @discardableResult
    private static func keygen(_ binaries: URL, _ arguments: [String]) throws -> String {
        try run(binaries.appendingPathComponent("ssh-keygen"), ["-q"] + arguments)
    }

    private static func query(_ binaries: URL, _ what: String) throws -> [String] {
        try run(binaries.appendingPathComponent("ssh"), ["-Q", what])
            .split(separator: "\n").map(String.init)
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw StartError.toolFailed(executable.lastPathComponent, text)
        }
        return text
    }

    // MARK: Loopback sockets

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        address.sin_port = UInt16(port).bigEndian
        return address
    }

    /// Binds port 0 and reports what the kernel assigned, then releases it for sshd.
    private static func reserveLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.didNotStart("could not create a socket") }
        defer { close(descriptor) }

        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw StartError.didNotStart("could not bind a loopback port") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw StartError.didNotStart("could not read the bound port") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = loopbackAddress(port: port)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

/// Relays to sshd after emitting a text line of its own, so the client sees the pre-banner lines
/// RFC 4253 §4.2 permits. There is no sshd option for this: `Banner` is a user-auth message.
final class PreBannerProxy {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    var port: Int { channel.localAddress?.port ?? 0 }

    init(forwardingTo targetPort: Int, banner: String = "Welcome to the jungle\r\n") throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        do {
            self.channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 8)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(PreBannerRelay(targetPort: targetPort, banner: banner))
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// Accepted-side handler: writes the banner, dials sshd, then pipes both ways.
private final class PreBannerRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let targetPort: Int
    private let banner: String
    private var upstream: Channel?
    private var pending: [ByteBuffer] = []

    init(targetPort: Int, banner: String) {
        self.targetPort = targetPort
        self.banner = banner
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: banner.utf8.count)
        buffer.writeString(banner)
        context.writeAndFlush(NIOAny(buffer), promise: nil)

        let downstream = context.channel
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(PeerRelay(peer: downstream))
            }
            .connect(host: "127.0.0.1", port: targetPort)
            .whenComplete { [weak self] result in
                switch result {
                case .success(let channel):
                    guard let self = self else {
                        channel.close(promise: nil)
                        return
                    }
                    self.upstream = channel
                    for buffer in self.pending {
                        channel.write(NIOAny(buffer), promise: nil)
                    }
                    if !self.pending.isEmpty {
                        channel.flush()
                    }
                    self.pending = []
                case .failure:
                    downstream.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if let upstream = upstream {
            upstream.writeAndFlush(NIOAny(buffer), promise: nil)
        } else {
            pending.append(buffer)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
    }
}

/// Upstream-side handler: everything sshd sends goes back to the accepted connection.
private final class PeerRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(NIOAny(self.unwrapInboundIn(data)), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }
}
#endif
