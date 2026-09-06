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
        // Shell integration is keyed on the shell's *basename*, never its absolute
        // path. Matching the literal "/bin/zsh" meant a Homebrew zsh
        // (/opt/homebrew/bin/zsh — the standard setup on Apple silicon), a
        // MacPorts zsh, or any user-built zsh silently lost cursor-shape reports
        // and title updates with nothing to explain why. `pw_shell` is whatever
        // the user ran `chsh` with, so the literal match was only ever true for
        // the stock system build.
        //
        // For the `!isPath` form (`tmux new -A`, a bare `fish`) the child is
        // `/bin/sh -c "exec <command>"`, so argv belongs to /bin/sh and the
        // basename comes from the command word. zsh integration is still applied
        // there — it is environment-only (ZDOTDIR), which the exec'd zsh picks
        // up — but bash integration is not, because it needs `--posix` in argv.
        let shellName = executable.split(separator: "/").last.map { String($0) } ?? executable
        // This dictionary is the child's ENTIRE environment: `NativeShellProcess` turns it
        // into an explicit `envp` for `execve`, so nothing the app process exports is
        // inherited. TERM therefore has to be resolved from the synced setting right here —
        // it was hardcoded to "xterm-ghostty", which made Settings > Terminal > TERM > Local
        // a no-op on Catalyst while it worked on iOS. Likewise TERM_PROGRAM must say
        // "ghostty" (tools sniff it for terminal capabilities, and the iOS and app-process
        // spawn sites both say it) rather than the product name.
        var environment = ["HOME": home, "USER": login, "LOGNAME": login,
                           "SHELL": isPath ? executable : defaultShell,
                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                           "TERM": TerminalTypeSettings.local, "COLORTERM": "truecolor",
                           "TERM_PROGRAM": "ghostty",
                           "TERM_PROGRAM_VERSION": TerminalIdentity.shortVersion,
                           "LANG": LocaleHelper.posixLocale]
        // Product identity, in the one namespace that survives SSH to a remote host — the
        // same pair the iOS and app-process spawn sites export.
        for envVar in TerminalIdentity.forwardedVariables { environment[envVar.name] = envVar.value }
        var arguments = isPath ? ["-l"] : ["-c", "exec " + executable]
        if let resources = Bundle.main.resourcePath {
            environment["TERMINFO"] = resources + "/terminfo"
            environment["GHOSTTY_RESOURCES_DIR"] = resources
            if integration {
                switch shellName {
                case "zsh":
                    environment["ZDOTDIR"] = resources + "/shell-integration/zsh"
                    environment["GHOSTTY_SHELL_FEATURES"] = "cursor,title"
                case "bash" where isPath:
                    // bash only sources $ENV when it is in POSIX mode, so the
                    // bundled Resources/shell-integration/bash/ghostty.bash (which
                    // ships in the .app and, until now, was never activated by
                    // anything) is installed the way upstream ghostty does it:
                    // launch `bash --posix -l`, point ENV at the script, and let
                    // GHOSTTY_BASH_INJECT tell it to replay bash's normal startup
                    // sequence and then `set +o posix`. Long options must precede
                    // short ones — `bash -l --posix` is rejected as "invalid
                    // option" — hence the prepend. A POSIX-mode bash skips the
                    // profile files itself, so the script sourcing them is not a
                    // double-source. This dictionary is the child's whole
                    // environment, so there is no inherited ENV/HISTFILE to
                    // preserve into GHOSTTY_BASH_ENV.
                    environment["ENV"] = resources + "/shell-integration/bash/ghostty.bash"
                    environment["GHOSTTY_BASH_INJECT"] = "1"
                    environment["GHOSTTY_SHELL_FEATURES"] = "cursor,title"
                    arguments.insert("--posix", at: 0)
                default:
                    break
                }
            }
        }
        if let paneToken { environment["SHELL_PANE_TOKEN"] = paneToken }
        return try bridge.createShell(executable: isPath ? executable : "/bin/sh",
            arguments: arguments, environment: environment,
            directory: directory ?? home, rows: rows, columns: columns)
    }
}
#endif
