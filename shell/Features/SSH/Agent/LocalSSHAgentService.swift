//
//  LocalSSHAgentService.swift
//  shell
//
//  Process-local SSH agent listener for the ios_system interpreter
//  (ssh-agent-bridge-spec.md §9, §10, §15). Bundled `ssh`/`scp`/`sftp` find it
//  through `SSH_AUTH_SOCK` and authenticate with Shell's default identities
//  without a private-key file. Read-only, never forwarded to a remote host,
//  never outlives the app process.
//

import Foundation
import UIKit
import NIOCore
import NIOPosix
import Citadel
import os

actor LocalSSHAgentService {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "LocalSSHAgent")

    static let shared = LocalSSHAgentService(
        delegate: ShellSSHAgentDelegate(source: SSHKeyManagerAgentKeySource())
    )

    enum StartError: Error, Equatable {
        /// The in-container path does not fit `sockaddr_un.sun_path`.
        case socketPathTooLong(String)
    }

    private typealias ClientChannel = NIOAsyncChannel<ByteBuffer, ByteBuffer>

    private let responder: LocalSSHAgentResponder
    private let clients: LocalSSHAgentClientRegistry
    private let directory: URL
    private let group: any EventLoopGroup

    /// The bound path; nil whenever no listener is live.
    private(set) var socketPath: String?

    /// Whether `path` is the socket of the listener that is live right now.
    func isListening(at path: String) -> Bool {
        socketPath == path && serverChannel != nil
    }
    private var serverChannel: (any Channel)?
    private var serverTask: Task<Void, Never>?
    private var pendingStart: Task<String, any Error>?
    /// Distinguishes listener generations so a stale exit cannot clear a newer one.
    private var generation = 0

    init(
        delegate: any SSHAgentDelegate,
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        maxClients: Int = LocalSSHAgentClientRegistry.defaultClientLimit,
        maxInFlightSigns: Int = LocalSSHAgentSignLimiter.defaultGlobalLimit
    ) {
        self.responder = LocalSSHAgentResponder(
            delegate: delegate,
            signLimiter: LocalSSHAgentSignLimiter(limit: maxInFlightSigns)
        )
        self.clients = LocalSSHAgentClientRegistry(limit: maxClients)
        self.directory = directory
        self.group = group
    }

    /// Binds the listener if it is not already live and returns its path.
    /// The path is returned only after `bind` has completed.
    func startIfNeeded() async throws -> String {
        if let socketPath {
            return socketPath
        }
        if let pendingStart {
            return try await pendingStart.value
        }
        let start = Task { try await self.bindListener() }
        pendingStart = start
        defer { pendingStart = nil }
        return try await start.value
    }

    /// Closes the listener, every live client connection (including one
    /// waiting on a biometric prompt), and unlinks the socket file.
    func stop() async {
        if let pendingStart {
            _ = try? await pendingStart.value
        }
        guard let channel = serverChannel else { return }
        let path = socketPath
        serverChannel = nil
        socketPath = nil
        generation += 1
        // Unlink before the await so a restart that binds the same path while
        // this close is in flight never loses its fresh socket file.
        if let path {
            unlink(path)
        }
        serverTask?.cancel()
        serverTask = nil
        clients.closeAll()
        try? await channel.close()
        Self.logger.info("Local SSH agent stopped")
    }

    // MARK: - Listener

    /// `<TMPDIR>/sa-<pid>.sock`: inside the app container, unique per process,
    /// and reused across restarts so a running shell's `SSH_AUTH_SOCK` stays valid.
    ///
    /// An iOS container path is close to the 104-byte `sun_path` limit, so
    /// when the `/private/var/…` spelling is too long the equivalent
    /// `/var/…` one (the system symlink into the same directory) is used.
    /// Nil when neither fits: the agent then fails closed.
    nonisolated static func socketPath(in directory: URL, pid: Int32 = getpid()) -> String? {
        let path = directory.appendingPathComponent("sa-\(pid).sock", isDirectory: false).path
        var candidates = [path]
        if path.hasPrefix("/private/var/") {
            candidates.append(String(path.dropFirst("/private".count)))
        }
        return candidates.first { $0.utf8.count < maxSocketPathBytes }
    }

    /// `sun_path` capacity, including the terminating NUL.
    nonisolated static var maxSocketPathBytes: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    private func bindListener() async throws -> String {
        guard let path = Self.socketPath(in: directory) else {
            Self.logger.error("Local SSH agent socket path does not fit sun_path; agent disabled")
            throw StartError.socketPathTooLong(directory.path)
        }

        // A previous process's socket at this path is stale by definition:
        // `cleanupExistingSocketFile` unlinks it (and refuses a non-socket).
        let server = try await ServerBootstrap(group: group)
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(LocalSSHAgentFrameDecoder())
                    )
                    return try ClientChannel(wrappingChannelSynchronously: channel)
                }
            }
        chmod(path, 0o600)

        generation += 1
        let current = generation
        socketPath = path
        serverChannel = server.channel
        let responder = responder
        let clients = clients
        serverTask = Task { [weak self] in
            await Self.serve(server, responder: responder, clients: clients)
            await self?.listenerDidExit(generation: current)
        }
        Self.logger.info("Local SSH agent listening")
        return path
    }

    private func listenerDidExit(generation exited: Int) {
        guard exited == generation, let path = socketPath else { return }
        Self.logger.error("Local SSH agent listener exited unexpectedly")
        clients.closeAll()
        unlink(path)
        socketPath = nil
        serverChannel = nil
        serverTask = nil
    }

    private static func serve(
        _ server: NIOAsyncChannel<ClientChannel, Never>,
        responder: LocalSSHAgentResponder,
        clients: LocalSSHAgentClientRegistry
    ) async {
        do {
            try await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await client in inbound {
                        // Over the concurrent-client bound: close at once.
                        guard clients.admit(client.channel) else {
                            logger.info("Local SSH agent refused a client: connection limit reached")
                            group.addTask {
                                try? await client.executeThenClose { _, _ in }
                            }
                            continue
                        }
                        group.addTask {
                            defer { clients.remove(client.channel) }
                            await handle(client, responder: responder)
                        }
                    }
                }
            }
        } catch {
            logger.debug("Local SSH agent accept loop ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// One client: answer each frame in order. A framing error (oversized
    /// length) or a write failure ends this connection only.
    private static func handle(_ client: ClientChannel, responder: LocalSSHAgentResponder) async {
        do {
            try await client.executeThenClose { requests, responses in
                for try await request in requests {
                    try await responses.write(await responder.respond(to: request))
                }
            }
        } catch {
            logger.debug("Local SSH agent client closed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

// MARK: - Local shell integration

/// Decides whether a new interpreter session gets `SSH_AUTH_SOCK`, keeps the
/// listener in step with Settings > Connections > Local SSH Agent, and
/// invalidates local-agent authorization on background, device lock, revoke
/// and disable (ssh-agent-bridge-v2-delta.md §3.3, §6).
///
/// Deliberately never wired into Citadel's `enableAgentForwarding`: the
/// local agent is not an `auth-agent@openssh.com` delegate and enabling it
/// never requests or accepts remote agent forwarding (§9).
@MainActor
enum LocalSSHAgent {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "LocalSSHAgent")
    private static var observers: [any NSObjectProtocol] = []

    /// Bumped by every invalidation. A key load that started under an older
    /// epoch is refused when it finishes (see `SSHAgentKeyAvailability`), so
    /// a prompt approved after a revoke, disable or background cannot sign.
    private(set) static var authorizationEpoch = 0

    /// Whether this build has local programs that can use the agent: the
    /// interpreter backend with the OpenSSH clients (`ssh_cmd.framework`)
    /// embedded. False on visionOS and on the native macOS PTY shell, where
    /// the setting is hidden and nothing is exported.
    static let isAvailable: Bool = LocalShellBackend.current == .interpreter && hasOpenSSHClients

    /// Whether the OpenSSH `ssh`/`scp`/`sftp` framework is embedded in this
    /// build (Packages/OpenSSHCommands; iOS and Mac Catalyst).
    nonisolated static let hasOpenSSHClients: Bool = {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return false }
        return FileManager.default.fileExists(atPath: frameworks + "/ssh_cmd.framework")
    }()

    /// Installs the settings and lifecycle observers. Called once at launch
    /// (GhosttyApp) so toggles made before any local shell opens still apply;
    /// the listener itself still starts lazily.
    static func activate() {
        guard isAvailable, observers.isEmpty else { return }
        let center = NotificationCenter.default
        let name = Settings.Connections.localSSHAgent.name
        let keysField = SettingsChange.userInfoKeys

        observers.append(center.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { notification in
            let keys = notification.userInfo?[keysField] as? [String] ?? []
            guard keys.contains(name) else { return }
            MainActor.assumeIsolated { applySetting() }
        })
        // Backgrounding and device lock both end agent sessions. Inactive
        // alone is not used: a Face ID / passcode sheet makes the app inactive
        // while it authenticates the very request being served.
        for event in [UIApplication.didEnterBackgroundNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { invalidateAuthorization() }
            })
        }
    }

    /// The socket path to export, or nil to leave `SSH_AUTH_SOCK` unset.
    /// Starts the listener lazily on first use; a failure never blocks the shell.
    static func socketPathForNewSession() async -> String? {
        // The native macOS shell keeps the user's own agent environment.
        guard isAvailable else { return nil }
        activate()
        guard LocalSSHAgentPolicy.current.enabled else { return nil }
        let service = LocalSSHAgentService.shared
        do {
            let path = try await service.startIfNeeded()
            // A disable racing this start may already have closed the
            // listener; never export a path that is not live.
            guard LocalSSHAgentPolicy.current.enabled, await service.isListening(at: path) else {
                return nil
            }
            return path
        } catch {
            logger.error("Local SSH agent failed to start: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Ends local-agent `.perSession` authorization — for one key, or (nil)
    /// all — so `.perSession` keys must authenticate again on their next agent
    /// use. Native SSH sessions are untouched. With `resetCooldowns`, pending
    /// post-cancel cooldowns are cleared too (on disable).
    static func invalidateAuthorization(keyID: UUID? = nil, resetCooldowns: Bool = false) {
        authorizationEpoch &+= 1
        let auth = SSHKeyAuthManager.shared
        if let keyID {
            auth.clearAuthentication(for: keyID, purpose: .localAgent)
            LocalSSHAgentAuthThrottle.shared.reset(keyID: keyID)
        } else {
            auth.clearAuthentication(purpose: .localAgent)
        }
        if resetCooldowns {
            LocalSSHAgentAuthThrottle.shared.resetAll()
        }
    }

    /// Off closes the listener and every client, unlinks the socket, and
    /// clears agent sessions and cooldowns. On binds the listener now so the
    /// next local shell can use it without an app restart; it never grants
    /// any identity.
    private static func applySetting() {
        let enabled = LocalSSHAgentPolicy.current.enabled
        if !enabled {
            invalidateAuthorization(resetCooldowns: true)
        }
        Task {
            if enabled {
                _ = try? await LocalSSHAgentService.shared.startIfNeeded()
            } else {
                await LocalSSHAgentService.shared.stop()
            }
        }
    }
}
