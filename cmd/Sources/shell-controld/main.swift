import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellControlDaemon
import ShellControlProtocol

// shell-controld runs on the actual execution host as a per-user service.
// Its socket is local only: no SSH and no unauthenticated control socket is
// exposed to the internet (spec.watch.md section 3).
let environment = ProcessInfo.processInfo.environment

func requiredEnvironment(_ name: String) -> String {
    guard let value = environment[name], !value.isEmpty else {
        FileHandle.standardError.write(Data("shell-controld: \(name) is required\n".utf8))
        exit(2)
    }
    return value
}

let stateDirectory = environment["SHELL_CONTROL_STATE_DIR"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/shell-control").path
let socketPath = environment["SHELL_CONTROL_SOCKET"] ?? "\(stateDirectory)/control.sock"
guard let brokerURL = URL(string: requiredEnvironment("SHELL_CONTROL_BROKER_URL")),
      let originID = ControlID(requiredEnvironment("SHELL_CONTROL_ORIGIN_ID"))
else {
    FileHandle.standardError.write(Data("shell-controld: broker URL and origin id must be valid\n".utf8))
    exit(2)
}

let core = try DaemonCore(configuration: DaemonCore.Configuration(
    brokerURL: brokerURL,
    originID: originID,
    originSecret: requiredEnvironment("SHELL_CONTROL_ORIGIN_SECRET"),
    socketPath: socketPath,
    journalURL: URL(fileURLWithPath: "\(stateDirectory)/dispatch-journal.ndjson")
))

try await core.reconcileAfterRestart()
Task { await core.runHeartbeats() }

let server = UnixSocketServer(path: socketPath)
let listener = try server.makeListener()
FileHandle.standardError.write(Data("shell-controld: listening on \(socketPath)\n".utf8))

let queue = DispatchQueue(label: "dev.chr33s.shell.controld", attributes: .concurrent)
while true {
    let client = accept(listener, nil, nil)
    if client < 0 { continue }
    guard UnixSocketServer.verifyPeer(client) else {
        close(client)
        continue
    }
    queue.async {
        defer { close(client) }
        var buffer = Data()
        while true {
            guard let value = try? FrameIO.readFrame(client, buffer: &buffer) else { return }
            guard let request = try? IPCRequest(json: value) else {
                _ = try? FrameIO.writeFrame(client, IPCResponse(
                    messageID: .random(),
                    ok: false,
                    errorCode: ControlErrorCode.invalidPayload.rawValue,
                    errorMessage: "unreadable frame"
                ).json)
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var response = IPCResponse(messageID: request.messageID, ok: false)
            Task {
                response = await core.handle(request)
                semaphore.signal()
            }
            semaphore.wait()
            try? FrameIO.writeFrame(client, response.json)
        }
    }
}
