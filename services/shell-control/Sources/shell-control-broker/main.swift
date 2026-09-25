import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellControlBroker
import ShellControlProtocol
import ShellControlSecurity
import Synchronization

// The broker executable: HTTP front end, durable store, and APNs outbox.
// Configuration comes from a --config file or the environment so no secret is
// baked into a build. Arguments carry paths, not secrets.
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("shell-control-broker: \(message)\n".utf8))
    exit(code)
}

func required(_ name: String, from file: [String: Any], env: String) -> String {
    if let value = file[name] as? String, !value.isEmpty { return value }
    if let value = environment[env], !value.isEmpty { return value }
    fail("\(env) is required")
}

func optional(_ name: String, from file: [String: Any], env: String) -> String? {
    if let value = file[name] as? String, !value.isEmpty { return value }
    if let value = environment[env], !value.isEmpty { return value }
    return nil
}

var fileConfig: [String: Any] = [:]
if let index = arguments.firstIndex(of: "--config") {
    guard index + 1 < arguments.count else { fail("--config requires an absolute path") }
    let path = arguments[index + 1]
    guard path.hasPrefix("/") else { fail("--config must be an absolute path") }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("config is not a JSON object")
        }
        fileConfig = object
    } catch {
        fail("cannot read --config \(path): \(error)")
    }
}

let port: UInt16
if let number = fileConfig["port"] as? Int {
    port = UInt16(number)
} else {
    port = UInt16(environment["SHELL_CONTROL_PORT"] ?? "8443") ?? 8443
}

let statePath = optional("state_path", from: fileConfig, env: "SHELL_CONTROL_STATE")
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/shell-control/broker.json").path
let adminSecret = required("admin_secret", from: fileConfig, env: "SHELL_CONTROL_ADMIN_SECRET")
let accountIDText = required("account_id", from: fileConfig, env: "SHELL_CONTROL_ACCOUNT_ID")
guard let accountID = ControlID(accountIDText) else {
    fail("SHELL_CONTROL_ACCOUNT_ID must be a lowercase UUID")
}

let lockPath = (fileConfig["state_directory"] as? String).map { "\($0)/broker.lock" }
    ?? URL(fileURLWithPath: statePath).deletingLastPathComponent().appendingPathComponent("broker.lock").path
do {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: lockPath).deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
} catch {
    fail("cannot create state directory for \(lockPath): \(error)")
}
let lockFd = open(lockPath, O_CREAT | O_RDWR, 0o600)
guard lockFd >= 0 else { fail("cannot open singleton lock \(lockPath)") }
if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
    fail("another broker already holds \(lockPath)")
}

let persistence = try FileBrokerPersistence(url: URL(fileURLWithPath: statePath))
let cursorSecretText = optional("cursor_secret", from: fileConfig, env: "SHELL_CONTROL_CURSOR_SECRET")
let cursorSecret = cursorSecretText.map { Data($0.utf8) }
    ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
// The Mac-local authority signs origin proofs with the origin key; the key
// file is written by `shell-control setup` and never leaves the Mac
// (docs/specs/control-protocol.md section 4.2).
var originSigner: OriginSigner?
if let originIDText = optional("origin_id", from: fileConfig, env: "SHELL_CONTROL_ORIGIN_ID"),
   let keyPath = optional("origin_key_file", from: fileConfig, env: "SHELL_CONTROL_ORIGIN_KEY_FILE") {
    guard let originID = ControlID(originIDText) else { fail("origin_id must be a lowercase UUID") }
    do {
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        originSigner = OriginSigner(originID: originID, key: try OriginSigningKey(pemRepresentation: pem))
    } catch {
        fail("cannot load origin signing key \(keyPath): \(error)")
    }
}
let store = BrokerStore(
    serviceIdentity: optional("identity", from: fileConfig, env: "SHELL_CONTROL_IDENTITY") ?? "shell-control",
    cursorSecret: cursorSecret,
    persistence: persistence,
    originSigner: originSigner
)
try await store.restore()

let allowedTopics = Set((optional("apns_topics", from: fileConfig, env: "SHELL_CONTROL_APNS_TOPICS") ?? "")
    .split(separator: ",").map(String.init))
if allowedTopics.isEmpty {
    FileHandle.standardError.write(Data(
        "shell-control-broker: SHELL_CONTROL_APNS_TOPICS is unset, so no device can register a push token\n".utf8
    ))
}

let verificationURI = optional("verification_uri", from: fileConfig, env: "SHELL_CONTROL_VERIFICATION_URI")
    ?? "https://example.invalid/activate"

let service = BrokerService(
    store: store,
    configuration: BrokerService.Configuration(
        verificationURI: verificationURI,
        allowedAPNsTopics: allowedTopics,
        adminSecret: adminSecret,
        adminAccountID: accountID
    )
)

let sender: any PushSender
if let keyID = optional("apns_key_id", from: fileConfig, env: "SHELL_CONTROL_APNS_KEY_ID"),
   let teamID = optional("apns_team_id", from: fileConfig, env: "SHELL_CONTROL_APNS_TEAM_ID"),
   let keyPath = optional("apns_key_file", from: fileConfig, env: "SHELL_CONTROL_APNS_KEY_FILE"),
   let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) {
    sender = APNsClient(credentials: APNsClient.Credentials(keyID: keyID, teamID: teamID, privateKeyPEM: pem))
} else {
    FileHandle.standardError.write(Data("shell-control-broker: APNs credentials absent, pushes will be recorded only\n".utf8))
    sender = RecordingPushSender()
}

let relay: (any RelaySender)? = optional("push_relay_url", from: fileConfig, env: "SHELL_CONTROL_PUSH_RELAY_URL")
    .flatMap(URL.init(string:))
    .flatMap { $0.scheme == "https" ? PushRelayClient(endpoint: $0) : nil }
let worker = OutboxWorker(store: store, sender: sender, relay: relay)
let workerTask = Task { await worker.run() }

let bindLoopback: Bool
if let flag = fileConfig["bind_loopback"] as? Bool {
    bindLoopback = flag
} else {
    bindLoopback = environment["SHELL_CONTROL_BIND"] != "any"
}
let server = HTTPServer(port: port, bindLoopback: bindLoopback) { request in
    await service.handle(request)
}
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("shell-control-broker: \(error)\n".utf8))
    exit(2)
}
let bindHost = bindLoopback ? "127.0.0.1" : "*"
FileHandle.standardError.write(Data("shell-control-broker: listening on \(bindHost):\(port)\n".utf8))

final class BrokerShutdownCoordinator: Sendable {
    private let requested = Atomic(false)
    private let workerTask: Task<Void, Never>
    private let server: HTTPServer

    init(workerTask: Task<Void, Never>, server: HTTPServer) {
        self.workerTask = workerTask
        self.server = server
    }

    func request() {
        guard !requested.exchange(true, ordering: .acquiringAndReleasing) else { return }
        workerTask.cancel()
        server.stop()
    }

    func makeSignalSource(_ signalNumber: Int32) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { [weak self] in self?.request() }
        source.resume()
        return source
    }
}

signal(SIGPIPE, SIG_IGN)
let shutdown = BrokerShutdownCoordinator(workerTask: workerTask, server: server)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = shutdown.makeSignalSource(SIGTERM)
let intSource = shutdown.makeSignalSource(SIGINT)

server.acceptLoop()
termSource.cancel()
intSource.cancel()
flock(lockFd, LOCK_UN)
close(lockFd)
