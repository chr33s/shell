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
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("shell-controld: \(message)\n".utf8))
    exit(code)
}

func requiredEnvironment(_ name: String) -> String {
    guard let value = environment[name], !value.isEmpty else {
        fail("\(name) is required")
    }
    return value
}

func configFlag() -> String? {
    guard let index = arguments.firstIndex(of: "--config") else { return nil }
    guard index + 1 < arguments.count else { fail("--config requires an absolute path") }
    let path = arguments[index + 1]
    guard path.hasPrefix("/") else { fail("--config must be an absolute path") }
    return path
}

let loadedConfig: [String: Any]
if let path = configFlag() {
    do {
        loadedConfig = try ServiceConfigFile.load(path)
    } catch {
        fail("cannot read --config \(path): \(error)")
    }
} else {
    loadedConfig = [:]
}

func configString(_ key: String, env: String, file: [String: Any]) -> String? {
    ServiceConfigFile.string(file, key) ?? environment[env]
}

let stateDirectory = configString("state_directory", env: "SHELL_CONTROL_STATE_DIR", file: loadedConfig)
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/shell-control").path
let socketPath = configString("socket_path", env: "SHELL_CONTROL_SOCKET", file: loadedConfig) ?? "\(stateDirectory)/control.sock"
let healthSocketPath = configString("health_socket_path", env: "SHELL_CONTROL_HEALTH_SOCKET", file: loadedConfig) ?? "\(stateDirectory)/health.sock"
let journalPath = configString("journal_path", env: "SHELL_CONTROL_JOURNAL", file: loadedConfig) ?? "\(stateDirectory)/dispatch-journal.ndjson"
let brokerURLText = configString("broker_url", env: "SHELL_CONTROL_BROKER_URL", file: loadedConfig)
let originIDText = configString("origin_id", env: "SHELL_CONTROL_ORIGIN_ID", file: loadedConfig)
let originSecret = configString("origin_secret", env: "SHELL_CONTROL_ORIGIN_SECRET", file: loadedConfig)

guard let brokerURLText, let brokerURL = URL(string: brokerURLText),
      let originIDText, let originID = ControlID(originIDText),
      let originSecret, !originSecret.isEmpty
else {
    fail("broker URL and origin id must be valid")
}

let lockPath = "\(stateDirectory)/daemon.lock"
do {
    try FileManager.default.createDirectory(
        atPath: stateDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
} catch {
    fail("cannot create state directory \(stateDirectory): \(error)")
}
let processLock: ProcessLock
do {
    processLock = try ProcessLock.acquire(path: lockPath)
} catch ProcessLock.LockError.alreadyHeld {
    fail("another shell-controld already holds \(lockPath)")
} catch {
    fail("cannot acquire singleton lock: \(error)")
}

let core = try DaemonCore(configuration: DaemonCore.Configuration(
    brokerURL: brokerURL,
    originID: originID,
    originSecret: originSecret,
    socketPath: socketPath,
    journalURL: URL(fileURLWithPath: journalPath),
    healthSocketPath: healthSocketPath
))

try await core.reconcileAfterRestart()
let heartbeat = Task { await core.runHeartbeats() }

let controlServer = UnixSocketServer(path: socketPath)
let healthServer = UnixSocketServer(path: healthSocketPath)
let listener: Int32
let healthListener: Int32
do {
    listener = try controlServer.makeListener()
    healthListener = try healthServer.makeListener()
} catch UnixSocketServer.SocketError.alreadyServing {
    fail("a live instance already owns the control or health socket")
}

FileHandle.standardError.write(Data("shell-controld: listening on \(socketPath)\n".utf8))

final class ListenerState: @unchecked Sendable {
    private var running = true
    private var shutdownRequested = false
    private let lock = NSLock()
    let control: Int32
    let health: Int32
    init(control: Int32, health: Int32) {
        self.control = control
        self.health = health
    }
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()
        close(control)
        close(health)
    }
    func beginShutdown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if shutdownRequested { return false }
        shutdownRequested = true
        return true
    }
}

final class DaemonShutdownCoordinator: @unchecked Sendable {
    private let listeners: ListenerState
    private let core: DaemonCore
    private let heartbeat: Task<Void, Never>

    init(listeners: ListenerState, core: DaemonCore, heartbeat: Task<Void, Never>) {
        self.listeners = listeners
        self.core = core
        self.heartbeat = heartbeat
    }

    func request() {
        guard listeners.beginShutdown() else { return }
        Task { [listeners, core, heartbeat] in
            await core.shutdown()
            await core.waitUntilIdle(timeout: 15)
            heartbeat.cancel()
            listeners.stop()
        }
    }

    func makeSignalSource(_ signalNumber: Int32) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { [weak self] in self?.request() }
        source.resume()
        return source
    }
}

let listeners = ListenerState(control: listener, health: healthListener)
let queue = DispatchQueue(label: "dev.chr33s.shell.controld", attributes: .concurrent)

queue.async {
    while listeners.isRunning {
        let client = accept(healthListener, nil, nil)
        if client < 0 {
            if !listeners.isRunning { return }
            continue
        }
        defer { close(client) }
        guard UnixSocketServer.verifyPeer(client) else { continue }
        let snapshot = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var body = Data("{}".utf8)
        Task {
            let json = await core.health()
            body = (try? JSONCanonicalization.canonicalize(json)) ?? body
            snapshot.signal()
        }
        snapshot.wait()
        _ = body.withUnsafeBytes { raw in
            send(client, raw.baseAddress, raw.count, 0)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let shutdown = DaemonShutdownCoordinator(listeners: listeners, core: core, heartbeat: heartbeat)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = shutdown.makeSignalSource(SIGTERM)
let intSource = shutdown.makeSignalSource(SIGINT)

while listeners.isRunning {
    let client = accept(listener, nil, nil)
    if client < 0 {
        if !listeners.isRunning { break }
        continue
    }
    guard UnixSocketServer.verifyPeer(client) else {
        close(client)
        continue
    }
    queue.async {
        defer { close(client) }
        var buffer = Data()
        while listeners.isRunning {
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

termSource.cancel()
intSource.cancel()
processLock.release()
