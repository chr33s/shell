#if targetEnvironment(macCatalyst)
import Foundation

/// Creates native PTYs through the macOS bundle. There is no external helper or socket service.
@MainActor
enum MacLocalShellManager {
    static var isAvailable: Bool { MacSupport.bridge != nil }
    static func stopAll() { MacSupport.bridge?.stopShells() }

    static func create(rows: UInt16, columns: UInt16, directory: String?, shell: String?,
                       integration: Bool, paneToken: String?) throws -> any MacShellProcess {
        guard let bridge = MacSupport.bridge else {
            throw NSError(domain: "MacLocalShell", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The macOS support bundle could not be loaded."])
        }
        let user = getpwuid(getuid())
        let home = user.map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let login = user.map { String(cString: $0.pointee.pw_name) } ?? NSUserName()
        let defaultShell = user.map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let command = shell?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = command.flatMap { $0.isEmpty ? nil : $0 } ?? defaultShell
        // Custom commands are intentionally interpreted by a shell, as in the
        // terminal config. `execve` does no PATH lookup, so anything that is not
        // already an absolute path — a bare `fish` as much as `tmux new -A` —
        // has to go through `/bin/sh -c`, which does.
        let isPath = executable.hasPrefix("/") && !executable.contains(where: { $0.isWhitespace })
        var environment = ["HOME": home, "USER": login, "LOGNAME": login,
                           "SHELL": isPath ? executable : defaultShell,
                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                           "TERM": "xterm-ghostty", "COLORTERM": "truecolor", "TERM_PROGRAM": "Shell",
                           "LANG": LocaleHelper.posixLocale]
        if let resources = Bundle.main.resourcePath {
            environment["TERMINFO"] = resources + "/terminfo"
            environment["GHOSTTY_RESOURCES_DIR"] = resources
            if integration, executable == "/bin/zsh" {
                environment["ZDOTDIR"] = resources + "/shell-integration/zsh"
                environment["GHOSTTY_SHELL_FEATURES"] = "cursor,title"
            }
        }
        if let paneToken { environment["SHELL_PANE_TOKEN"] = paneToken }
        return try bridge.createShell(executable: isPath ? executable : "/bin/sh",
            arguments: isPath ? ["-l"] : ["-c", "exec " + executable], environment: environment,
            directory: directory ?? home, rows: rows, columns: columns)
    }
}
#endif
