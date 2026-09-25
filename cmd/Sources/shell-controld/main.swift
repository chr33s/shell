import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellControlDaemon
import ShellControlHostSupport
import ShellControlProtocol
import Synchronization

// shell-controld runs on the actual execution host as a per-user service.
// Its socket is local only: no SSH and no unauthenticated control socket is
// exposed to the internet (docs/specs/control-protocol.md section 2).
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

let core: DaemonCore
do {
    core = try DaemonCore(configuration: DaemonCore.Configuration(
        brokerURL: brokerURL,
        originID: originID,
        originSecret: originSecret,
        socketPath: socketPath,
        journalURL: URL(fileURLWithPath: journalPath),
        healthSocketPath: healthSocketPath
    ))
} catch {
    fail("cannot open the dispatch journal \(journalPath): \(error)")
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("shell-controld: \(message)\n".utf8))
}

// The startup frontier must be captured before any IPC work is admitted
// (docs/specs/control-cli.md section 9.1). A torn or corrupt journal is repaired in place;
// anything else that stops discovery (an unreadable file, a full disk) is
// retried here with backoff rather than by exiting into a launchd crash loop.
var discoveryDelay: UInt64 = 1
while true {
    do {
        try await core.discoverInterruptedWorkAtStartup()
        break
    } catch {
        log("cannot read the dispatch journal \(journalPath), retrying in \(discoveryDelay)s: \(error)")
        try? await Task.sleep(nanoseconds: discoveryDelay * 1_000_000_000)
        discoveryDelay = min(discoveryDelay * 2, 60)
    }
}
// Broker and journal-append failures leave obligations pending; the heartbeat
// loop retries them, so they never stop the daemon from starting.
do {
    try await core.reconcileAfterRestart()
} catch {
    log("startup recovery is incomplete and will be retried: \(error)")
}
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

// The accept loops live in ShellControlHostSupport so the bundled Control host
// serves adapters exactly as this daemon does (docs/specs/agent-relay.md 18.2).
let queue = DispatchQueue(label: "dev.chr33s.shell.controld", attributes: .concurrent)
let controlLoop = FramedIPCServer(listener: listener, queue: queue) { request in
    await core.handle(request)
}
let healthLoop = HealthSocketServer(listener: healthListener) { await core.health() }

final class ListenerState: Sendable {
    private let shutdownRequested = Atomic(false)
    let control: FramedIPCServer
    let health: HealthSocketServer
    init(control: FramedIPCServer, health: HealthSocketServer) {
        self.control = control
        self.health = health
    }
    var isRunning: Bool { control.isRunning }
    func stop() {
        control.stop()
        health.stop()
    }
    func beginShutdown() -> Bool {
        !shutdownRequested.exchange(true, ordering: .acquiringAndReleasing)
    }
}

final class DaemonShutdownCoordinator: Sendable {
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

let listeners = ListenerState(control: controlLoop, health: healthLoop)
queue.async { healthLoop.acceptLoop() }

signal(SIGPIPE, SIG_IGN)
let shutdown = DaemonShutdownCoordinator(listeners: listeners, core: core, heartbeat: heartbeat)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = shutdown.makeSignalSource(SIGTERM)
let intSource = shutdown.makeSignalSource(SIGINT)

// A waiting adapter that disappears — killed at its provider's timeout, or
// exited — takes its native wait with it; FramedIPCServer cancels the wait
// rather than keep it alive in a healthy daemon (docs/specs/agent-relay.md 4.2, 9.2).
controlLoop.acceptLoop()

termSource.cancel()
intSource.cancel()
processLock.release()
