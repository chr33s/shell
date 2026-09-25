import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlHostRuntime

/// A probe with scripted answers; nothing leaves the process.
struct StubProbe: HostHTTPProbe {
    let answer: @Sendable (URL) throws -> (status: Int, body: Data)
    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) { try answer(url) }

    static let silent = StubProbe { _ in throw URLError(.cannotConnectToHost) }
}

enum HostTestSupport {
    static func temporaryDirectory() throws -> URL {
        // Short: sun_path is 104 bytes on Darwin.
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("sch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Int32 in
                guard bind(fd, raw, length) == 0 else { return -1 }
                return getsockname(fd, raw, &length)
            }
        }
        guard bound == 0 else { throw URLError(.cannotConnectToHost) }
        return UInt16(bigEndian: address.sin_port)
    }

    static func runtime(
        root: URL,
        port: UInt16,
        legacyProbe: StubProbe = .silent,
        standaloneDirectory: URL? = nil,
        routeProbe: any HostHTTPProbe = StubProbe.silent
    ) -> HostRuntime {
        HostRuntime(configuration: HostRuntime.Configuration(
            layout: HostStorageLayout(developmentRoot: root),
            hostBuild: "test",
            legacyDetector: LegacyInstallationDetector(probe: legacyProbe, standaloneStateDirectory: standaloneDirectory),
            routeVerifier: TailscaleRouteVerifier(probe: routeProbe),
            heartbeatInterval: 60,
            brokerPortOverride: port
        ))
    }

    /// Polls a condition without busy-waiting the test thread.
    static func eventually(timeout: TimeInterval = 10, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }
}

final class HostRuntimeTests: XCTestCase {
    func testStartsBrokerAndAdapterIngressAndReportsReady() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try HostTestSupport.freePort()
        let runtime = HostTestSupport.runtime(root: root, port: port)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }

        let status = await runtime.status()
        XCTAssertEqual(status.phase, .ready)
        XCTAssertTrue(status.acceptingWork)
        XCTAssertEqual(status.brokerPort, Int(port))
        XCTAssertEqual(status.route.state, .notConfigured)
        XCTAssertNotNil(status.originFingerprint)
        let layout = HostStorageLayout(developmentRoot: root)
        XCTAssertEqual(status.adapterSocketPath, layout.adapterSocketPath)
        XCTAssertTrue(UnixSocketServer(path: layout.adapterSocketPath).isServedByLiveInstance())

        // The loopback broker is this host's, not a standalone one.
        let (body, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
        var reader = try JSONReader(try JSONValue.parse(body))
        XCTAssertEqual(try reader.string("service_identity", maxLength: 200), "shell-control-host")

        // An adapter registers a run through the composed daemon, which
        // authenticates to the in-process broker with the host's origin.
        let hello = try UnixSocketClient(path: layout.adapterSocketPath).exchange(IPCRequest(
            messageID: .random(), type: .hello, runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "host-test",
                "job_label": "host runtime test",
                "capabilities": JSONValue(strings: [ControlFeature.consume]),
                "operation_schemas": JSONValue(strings: [ExecOperation.schema])
            ])
        ), timeout: 10)
        XCTAssertTrue(hello.ok, "\(hello.errorCode ?? "") \(hello.errorMessage ?? "")")

        // Private state is owner-only.
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.privateDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let keyMode = try FileManager.default.attributesOfItem(atPath: layout.originKeyURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(keyMode?.intValue, 0o600)
    }

    func testJournalRecoveryCompletesBeforeReadinessWithBoundedRetry() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostStorageLayout(developmentRoot: root)
        try layout.prepare()
        // An unreadable journal stops discovery; the host must neither exit
        // nor open adapter ingress until recovery succeeds.
        FileManager.default.createFile(atPath: layout.journalURL.path, contents: Data(), attributes: [.posixPermissions: 0o000])
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        let starting = Task { try await runtime.start() }
        let recovering = await HostTestSupport.eventually { await runtime.currentPhase == .recovering }
        XCTAssertTrue(recovering)
        let early = await runtime.status()
        XCTAssertFalse(early.acceptingWork)
        XCTAssertNil(early.adapterSocketPath)
        XCTAssertFalse(UnixSocketServer(path: layout.adapterSocketPath).isServedByLiveInstance())

        chmod(layout.journalURL.path, 0o600)
        try await starting.value
        let ready = await HostTestSupport.eventually { await runtime.currentPhase == .ready }
        XCTAssertTrue(ready)
        XCTAssertTrue(UnixSocketServer(path: layout.adapterSocketPath).isServedByLiveInstance())
        await runtime.shutdown()
    }

    func testCorruptJournalIsQuarantinedBeforeReadiness() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostStorageLayout(developmentRoot: root)
        try layout.prepare()
        try Data("not a journal record\n".utf8).write(to: layout.journalURL)
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        try await runtime.start()
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .ready)
        XCTAssertTrue(status.journalQuarantined)
        await runtime.shutdown()
    }

    func testSecondInstanceIsRefused() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        try await first.acquireOwnership()
        let second = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        do {
            try await second.start()
            XCTFail("a second host must not start against the same ledger")
        } catch let error as HostRuntime.OwnershipError {
            guard case .duplicateInstance = error else { return XCTFail("\(error)") }
        }
        await first.shutdown()
        // Once released, a new instance may own it.
        try await second.acquireOwnership()
        await second.shutdown()
    }

    func testIdentitySurvivesRestartAndMissingKeyIsNeverRegenerated() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostStorageLayout(developmentRoot: root)
        try layout.prepare()
        let first = try HostIdentity.loadOrCreate(layout: layout)
        let again = try HostIdentity.loadOrCreate(layout: layout)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.origin.fingerprint, again.origin.fingerprint)

        try FileManager.default.removeItem(at: layout.originKeyURL)
        XCTAssertThrowsError(try HostIdentity.loadOrCreate(layout: layout)) { error in
            XCTAssertEqual(error as? HostIdentity.LoadError, .originKeyMissing)
        }
        // The host reports it instead of minting a new origin.
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        try await runtime.start()
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .degraded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.originKeyURL.path))
        await runtime.shutdown()
    }

    func testStopAndResumeAcceptingWorkPersistsIntent() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try HostTestSupport.freePort()
        let layout = HostStorageLayout(developmentRoot: root)
        let runtime = HostTestSupport.runtime(root: root, port: port)
        try await runtime.start()
        try await runtime.stopAcceptingWork()
        var status = await runtime.status()
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertFalse(status.acceptingWork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.adapterSocketPath))
        XCTAssertFalse(try HostSettings.load(layout.settingsURL).acceptingWork)
        await runtime.shutdown()

        // A launchd restart before unregistration completes stays stopped.
        let restarted = HostTestSupport.runtime(root: root, port: port)
        try await restarted.start()
        status = await restarted.status()
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertFalse(UnixSocketServer(path: layout.adapterSocketPath).isServedByLiveInstance())

        try await restarted.resumeAcceptingWork()
        status = await restarted.status()
        XCTAssertEqual(status.phase, .ready)
        XCTAssertTrue(UnixSocketServer(path: layout.adapterSocketPath).isServedByLiveInstance())
        await restarted.shutdown()
    }

    func testPairingNeedsAVerifiedRouteAndPinsThisOrigin() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try HostTestSupport.freePort()
        // The real verifier against the host's own loopback broker: the same
        // proof check a Tailscale route gets, minus the tailnet.
        let runtime = HostTestSupport.runtime(root: root, port: port, routeProbe: URLSessionHostProbe())
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }

        do {
            _ = try await runtime.mintPairingInvitation()
            XCTFail("no invitation without a verified route")
        } catch let error as HostOperationError {
            XCTAssertEqual(error.code, .routeUnavailable)
        }
        let route = try await runtime.setRoute("http://127.0.0.1:\(port)")
        XCTAssertEqual(route.state, .verified, route.detail ?? "")
        let invitation = try await runtime.mintPairingInvitation()
        let parsed = try PairingInvitation(scanned: invitation.link)
        let status = await runtime.status()
        XCTAssertEqual(parsed.origin.fingerprint, status.originFingerprint)
        XCTAssertEqual(parsed.route.url.absoluteString, "http://127.0.0.1:\(port)")
        let devices = try await runtime.listDevices()
        XCTAssertEqual(devices, [])
        let pending = try await runtime.listPendingPairings()
        XCTAssertEqual(pending, [])
        let unknown = await HostXPCService.dispatch(
            ControlHostRequest(.setAgentGrants, deviceID: ControlID.random().rawValue, enabled: true), runtime: runtime
        )
        XCTAssertEqual(unknown.errorCode, ControlHostErrorCode.notFound.rawValue)
        do {
            try await runtime.revokeDevice("not-a-uuid")
            XCTFail("invalid id")
        } catch let error as HostOperationError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }
}

final class LegacyConflictTests: XCTestCase {
    func testStandaloneBrokerOnThePortBlocksAuthority() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try HostTestSupport.freePort()
        let legacy = StubProbe { url in
            XCTAssertEqual(url.path, "/v1/capabilities")
            return (200, Data(#"{"service_identity":"shell-control:0b0a2f5e-0000-4000-8000-000000000000"}"#.utf8))
        }
        let runtime = HostTestSupport.runtime(root: root, port: port, legacyProbe: legacy)
        try await runtime.start()
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .legacyConflict)
        XCTAssertTrue(status.detail?.contains("shell-control down") ?? false)
        XCTAssertFalse(status.acceptingWork)
        // No second authority: nothing is bound and no admin operation runs.
        XCTAssertFalse(FileManager.default.fileExists(atPath: HostStorageLayout(developmentRoot: root).ledgerURL.path))
        do {
            _ = try await runtime.listDevices()
            XCTFail("administration must be refused")
        } catch let error as HostOperationError {
            XCTAssertEqual(error.code, .legacyConflict)
        }
        let reply = await HostXPCService.dispatch(ControlHostRequest(.mintPairing), runtime: runtime)
        XCTAssertEqual(reply.errorCode, ControlHostErrorCode.legacyConflict.rawValue)
        await runtime.shutdown()
    }

    func testLiveStandaloneDaemonIsDetected() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let standalone = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: standalone.appendingPathComponent("installation.json"))
        let listener = try UnixSocketServer(path: standalone.appendingPathComponent("control.sock").path).makeListener()
        defer { close(listener) }
        let detector = LegacyInstallationDetector(probe: StubProbe.silent, standaloneStateDirectory: standalone)
        let conflict = await detector.detect(port: 1, ownServiceIdentity: "shell-control-host")
        XCTAssertEqual(conflict?.evidence, .liveStandaloneDaemon)

        // A stopped standalone installation is not a conflict.
        close(listener)
        let none = await detector.detect(port: 1, ownServiceIdentity: "shell-control-host")
        XCTAssertNil(none)
    }

    func testOccupiedPortIsAConflictNotACrash() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try HostTestSupport.freePort()
        // A non-HTTP listener the probe cannot identify.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        let runtime = HostTestSupport.runtime(root: root, port: port)
        try await runtime.start()
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .legacyConflict)
        await runtime.shutdown()
    }

    func testOwnIdentityOnThePortIsNotAConflict() async {
        let probe = StubProbe { _ in (200, Data(#"{"service_identity":"shell-control-host"}"#.utf8)) }
        let detector = LegacyInstallationDetector(probe: probe, standaloneStateDirectory: nil)
        let conflict = await detector.detect(port: 1, ownServiceIdentity: "shell-control-host")
        XCTAssertNil(conflict)
        let other = await LegacyInstallationDetector(probe: StubProbe { _ in (404, Data("nope".utf8)) }, standaloneStateDirectory: nil)
            .detect(port: 1, ownServiceIdentity: "shell-control-host")
        XCTAssertEqual(other?.evidence, .portInUse)
    }
}
