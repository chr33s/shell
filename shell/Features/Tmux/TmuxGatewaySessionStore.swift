//
//  TmuxGatewaySessionStore.swift
//  shell
//
//  Persists, per SSH connection, the tmux session the user was last attached
//  to through a -CC gateway. When a gateway reconnects FROM SCRATCH (the tssh
//  resume path keeps the live pty and doesn't need this), the exec command
//  embeds a session name (`tmux new-session -A -s <name>`); preferring the
//  recorded name over the global default means a user who switched sessions
//  in the dashboard lands back on the session they were actually using.
//

import Foundation

@MainActor
enum TmuxGatewaySessionStore {
    private static let defaultsKey = "tmuxLastSessionByConnection"

    /// Stable identity for a connection: "user@host:port".
    static func connectionKey(host: String, port: Int, username: String) -> String {
        "\(username)@\(host):\(port)"
    }

    static func lastSessionName(forConnection key: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        return dict?[key]
    }

    /// Record the current session name for a connection. Names that can't be
    /// safely embedded in the single-quoted `sh -c '...'` exec command are
    /// dropped (the reconnect falls back to the global default instead).
    static func setLastSessionName(_ name: String, forConnection key: String) {
        guard TmuxControlModeParser.isEmbeddableSessionName(name) else {
            removeLastSessionName(forConnection: key)
            return
        }
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        guard dict[key] != name else { return }
        dict[key] = name
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }

    static func removeLastSessionName(forConnection key: String) {
        guard var dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
              dict.removeValue(forKey: key) != nil
        else { return }
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
}
