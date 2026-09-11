import Foundation
import ShellControlBroker
import ShellControlProtocol

// The broker executable: HTTP front end, durable store, and APNs outbox.
// Configuration comes from the environment so no secret is baked into a build.
let environment = ProcessInfo.processInfo.environment

func requiredEnvironment(_ name: String) -> String {
    guard let value = environment[name], !value.isEmpty else {
        FileHandle.standardError.write(Data("shell-control-broker: \(name) is required\n".utf8))
        exit(2)
    }
    return value
}

let port = UInt16(environment["SHELL_CONTROL_PORT"] ?? "8443") ?? 8443
let statePath = environment["SHELL_CONTROL_STATE"] ?? FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/shell-control/broker.json").path
let adminSecret = requiredEnvironment("SHELL_CONTROL_ADMIN_SECRET")
guard let accountID = ControlID(requiredEnvironment("SHELL_CONTROL_ACCOUNT_ID")) else {
    FileHandle.standardError.write(Data("shell-control-broker: SHELL_CONTROL_ACCOUNT_ID must be a lowercase UUID\n".utf8))
    exit(2)
}

let persistence = try FileBrokerPersistence(url: URL(fileURLWithPath: statePath))
let cursorSecret = environment["SHELL_CONTROL_CURSOR_SECRET"].map { Data($0.utf8) }
    ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
let store = BrokerStore(
    serviceIdentity: environment["SHELL_CONTROL_IDENTITY"] ?? "shell-control",
    cursorSecret: cursorSecret,
    persistence: persistence
)
try await store.restore()

let allowedTopics = Set((environment["SHELL_CONTROL_APNS_TOPICS"] ?? "").split(separator: ",").map(String.init))
if allowedTopics.isEmpty {
    // Push registration fails closed without configured app IDs, so say so
    // rather than letting devices discover it as an opaque 403.
    FileHandle.standardError.write(Data(
        "shell-control-broker: SHELL_CONTROL_APNS_TOPICS is unset, so no device can register a push token\n".utf8
    ))
}

let service = BrokerService(
    store: store,
    configuration: BrokerService.Configuration(
        verificationURI: environment["SHELL_CONTROL_VERIFICATION_URI"] ?? "https://example.invalid/activate",
        allowedAPNsTopics: allowedTopics,
        adminSecret: adminSecret,
        adminAccountID: accountID,
        publicURL: environment["SHELL_CONTROL_PUBLIC_URL"] ?? ""
    )
)

let sender: any PushSender
if let keyID = environment["SHELL_CONTROL_APNS_KEY_ID"],
   let teamID = environment["SHELL_CONTROL_APNS_TEAM_ID"],
   let keyPath = environment["SHELL_CONTROL_APNS_KEY_FILE"],
   let pem = try? String(contentsOfFile: keyPath, encoding: .utf8)
{
    sender = APNsClient(credentials: APNsClient.Credentials(keyID: keyID, teamID: teamID, privateKeyPEM: pem))
} else {
    // Without provider credentials the broker still records everything; only
    // the hint delivery is missing.
    FileHandle.standardError.write(Data("shell-control-broker: APNs credentials absent, pushes will be recorded only\n".utf8))
    sender = RecordingPushSender()
}

let worker = OutboxWorker(store: store, sender: sender)
Task { await worker.run() }

let bindLoopback = environment["SHELL_CONTROL_BIND"] != "any"
let server = HTTPServer(port: port, bindLoopback: bindLoopback) { request in
    await service.handle(request)
}
do {
    try server.start()
} catch {
    // A readable line beats a trap: this is the failure a developer hits when
    // an earlier broker is still running.
    FileHandle.standardError.write(Data("shell-control-broker: \(error)\n".utf8))
    exit(2)
}
let bindHost = bindLoopback ? "127.0.0.1" : "*"
FileHandle.standardError.write(Data("shell-control-broker: listening on \(bindHost):\(port)\n".utf8))
server.acceptLoop()
