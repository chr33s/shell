import Foundation
import ShellControlHostSupport

/// Which daemon socket an adapter talks to: the standalone installation's, or
/// the bundled Control host's ingress in the shared App Group container
/// (docs/specs/agent-relay.md sections 18.1 and 18.6).
///
/// The App Group socket is a *candidate* external ingress: whether a provider
/// hook launched from a terminal may connect to it under the distributed
/// sandbox, and whether macOS prompts for group-container access, is for the
/// distribution spike to validate. Possession of the socket is never
/// authority either way: every run still needs its per-run capability, and
/// the host checks the peer's user (spec A46).
public enum HostSocketDiscovery {
    /// Mirrors `ControlHostWire.appGroupIdentifier` in ShellControlHostRuntime,
    /// which this module does not link; a test pins the two together.
    public static let appGroupIdentifier = "group.dev.chr33s.shell.control"
    public static let socketName = "control.sock"

    public enum Source: String, Sendable, Equatable {
        /// `--state-dir` or `SHELL_CONTROL_STATE_DIR` named an installation.
        case explicitStateDirectory = "explicit_state_directory"
        /// The standalone installation's daemon is live.
        case standalone
        /// The bundled host's socket exists and the standalone one is not live.
        case bundledHost = "bundled_host"
        /// Neither is live; the standalone path is kept so the adapter reports
        /// Control unavailable exactly as before.
        case standaloneFallback = "standalone_fallback"
    }

    public struct Resolution: Sendable, Equatable {
        public let socketPath: String
        public let source: Source

        public init(socketPath: String, source: Source) {
            self.socketPath = socketPath
            self.source = source
        }
    }

    /// - Parameters:
    ///   - explicitRoot: a state directory the user named; always wins.
    ///   - standaloneRoot: the default standalone state directory.
    ///   - bundledSocketPath: the App Group socket, if the group container
    ///     resolves on this Mac.
    public static func resolve(
        explicitRoot: URL?,
        standaloneRoot: URL,
        bundledSocketPath: String? = HostSocketDiscovery.bundledSocketPath(),
        isLive: (String) -> Bool = { UnixSocketServer(path: $0).isServedByLiveInstance() },
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Resolution {
        if let explicitRoot {
            return Resolution(socketPath: explicitRoot.appendingPathComponent(socketName).path, source: .explicitStateDirectory)
        }
        let standalone = standaloneRoot.appendingPathComponent(socketName).path
        if isLive(standalone) {
            return Resolution(socketPath: standalone, source: .standalone)
        }
        if let bundledSocketPath, exists(bundledSocketPath) {
            return Resolution(socketPath: bundledSocketPath, source: .bundledHost)
        }
        return Resolution(socketPath: standalone, source: .standaloneFallback)
    }

    /// `<group container>/control.sock`. Resolving the URL neither creates the
    /// container nor reads it.
    public static func bundledSocketPath(fileManager: FileManager = .default) -> String? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(socketName).path
    }
}
