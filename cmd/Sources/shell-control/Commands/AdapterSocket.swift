import Foundation
import ShellControlAgentAdapter

extension StateOptions {
    /// The daemon socket an adapter command talks to. A named state
    /// directory always wins; otherwise a live standalone daemon, then the
    /// bundled Control host's App Group socket (a candidate ingress,
    /// spec.agent-relay.md section 19.6), then the standalone path so an
    /// absent Control is reported exactly as before.
    func adapterSocketPath(_ inherited: String?) -> String {
        let named = stateDirectory ?? inherited ?? ProcessInfo.processInfo.environment["SHELL_CONTROL_STATE_DIR"]
        let explicit = named.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL : nil }
        let standalone = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/shell-control")
        return HostSocketDiscovery.resolve(explicitRoot: explicit, standaloneRoot: standalone).socketPath
    }
}
