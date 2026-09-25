import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellPushRelay
import ShellControlSecurity
import ShellControlHTTPServer

// The relay executable. Configuration is environment only; the relay has no
// durable state to configure (docs/specs/control-protocol.md section 12).
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shell-push-relay: \(message)\n".utf8))
    exit(2)
}

func required(_ name: String) -> String {
    guard let value = environment[name], !value.isEmpty else { fail("\(name) is required") }
    return value
}

let signingKey: OriginSigningKey
do {
    signingKey = try OriginSigningKey(pemRepresentation: try String(contentsOfFile: required("SHELL_RELAY_SIGNING_KEY_FILE"), encoding: .utf8))
} catch {
    fail("cannot load SHELL_RELAY_SIGNING_KEY_FILE: \(error)")
}
let topics = Set(required("SHELL_RELAY_APNS_TOPICS").split(separator: ",").map(String.init))
let pem: String
do {
    pem = try String(contentsOfFile: required("SHELL_RELAY_APNS_KEY_FILE"), encoding: .utf8)
} catch {
    fail("cannot load SHELL_RELAY_APNS_KEY_FILE: \(error)")
}
let service = RelayService(
    key: signingKey,
    configuration: .init(allowedTopics: topics, clientAddressHeader: environment["SHELL_RELAY_CLIENT_ADDRESS_HEADER"]),
    sender: RelayAPNsClient(credentials: .init(
        keyID: required("SHELL_RELAY_APNS_KEY_ID"),
        teamID: required("SHELL_RELAY_APNS_TEAM_ID"),
        privateKeyPEM: pem
    ))
)
let port = UInt16(environment["SHELL_RELAY_PORT"] ?? "8080") ?? 8080
let server = HTTPServer(port: port, bindLoopback: environment["SHELL_RELAY_BIND"] != "any") { request in
    await service.handle(request)
}
do {
    try server.start()
} catch {
    fail("\(error)")
}
signal(SIGPIPE, SIG_IGN)
FileHandle.standardError.write(Data("shell-push-relay: listening on \(port)\n".utf8))
server.acceptLoop()
