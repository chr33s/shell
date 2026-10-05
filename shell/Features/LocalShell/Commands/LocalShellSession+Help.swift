
import Foundation

extension LocalShellSession {
    /// Displays help information
    func displayHelp() {
        let header = String(localized: "Available commands:", comment: "Help: main header")
        let fileOpsHeader = String(localized: "File Operations:", comment: "Help: file operations section header")
        let textProcHeader = String(localized: "Text Processing:", comment: "Help: text processing section header")
        let archivesHeader = String(localized: "Archives & Compression:", comment: "Help: archives section header")
        let networkHeader = String(localized: "Network:", comment: "Help: network section header")
        let shellUtilHeader = String(localized: "Shell Utilities:", comment: "Help: shell utilities section header")
        let builtinHeader = String(localized: "Built-in Shell Commands:", comment: "Help: built-in commands section header")
        let helpDesc = String(localized: "Show this help message", comment: "Help: help command description")
        let historyDesc = String(localized: "Show command history", comment: "Help: history command description")
        let clearDesc = String(localized: "Clear the screen (Ctrl-L)", comment: "Help: clear command description")
        let resetDesc = String(localized: "Reset terminal state and clear scrollback", comment: "Help: reset command description")
        let exitDesc = String(localized: "Exit the shell (close tab)", comment: "Help: exit command description")
        let logoutDesc = String(localized: "Same as exit", comment: "Help: logout command description")
        let sourceDesc = String(localized: "Re-source .shellrc (or source <file>)", comment: "Help: source command description")
        let editrcDesc = String(localized: "Edit .shellrc ($EDITOR or vim)", comment: "Help: editrc command description")
        let reloadConfigDesc = String(localized: "Reload imported Swiftty keybind config", comment: "Help: reloadconfig command description")
        let shortcutsHeader = String(localized: "Keyboard Shortcuts:", comment: "Help: keyboard shortcuts section header")
        let ctrlADesc = String(localized: "Move to beginning of line", comment: "Help: Ctrl-A description")
        let ctrlEDesc = String(localized: "Move to end of line", comment: "Help: Ctrl-E description")
        let ctrlKDesc = String(localized: "Kill to end of line", comment: "Help: Ctrl-K description")
        let ctrlUDesc = String(localized: "Kill entire line", comment: "Help: Ctrl-U description")
        let ctrlYDesc = String(localized: "Yank back the last killed text", comment: "Help: Ctrl-Y description")
        let ctrlWDesc = String(localized: "Delete word backward", comment: "Help: Ctrl-W description")
        let ctrlLDesc = String(localized: "Clear screen", comment: "Help: Ctrl-L description")
        let ctrlCDesc = String(localized: "Interrupt current command", comment: "Help: Ctrl-C description")
        let ctrlDDesc = String(localized: "Exit on empty line (close tab)", comment: "Help: Ctrl-D description")
        let tabDesc = String(localized: "Auto-complete commands and paths", comment: "Help: Tab description")
        let arrowDesc = String(localized: "Navigate command history", comment: "Help: Up/Down description")
        let footer = String(localized: "For command-specific help, try: <command> --help or <command> -h", comment: "Help: footer tip")

        // Only commands that actually resolve at runtime belong here: the
        // ios_system core frameworks (awk, files, shell, text) plus the command
        // packages under vendor/ that the app links (libarchive_ios for tar,
        // vim, curl_ios, jq_ios, ripgrep_ios). The rest of upstream's list
        // (cpio/unzip/bsdcat, xz, the network_ios tools, traceroute/whatismyip*
        // mapped to MAIN) is not linked and MUST NOT be advertised: every one
        // printed "command not found".
        let helpText = """
\(header)

\(fileOpsHeader)
  ls, pwd, cd, cat, cp, mv, rm, ln, mkdir, rmdir, touch, find, du, stat,
  chmod, chown, chflags, readlink

\(textProcHeader)
  grep, egrep, fgrep, rg, sed, awk, jq, wc, sort, uniq, diff, head, tail, tr,
  md5, vim, vi

\(archivesHeader)
  tar, gzip, gunzip, compress, uncompress

\(networkHeader)
  ssh, curl

\(shellUtilHeader)
  echo, env, printenv, setenv, export, unsetenv, date, uname, whoami, tee,
  uptime, open, openurl, pbcopy, pbpaste, alias

\(builtinHeader)
  help     - \(helpDesc)
  history  - \(historyDesc)
  clear    - \(clearDesc)
  reset    - \(resetDesc)
  source   - \(sourceDesc)
  editrc     - \(editrcDesc)
  reloadconfig - \(reloadConfigDesc)
  exit       - \(exitDesc)
  logout   - \(logoutDesc)

\(shortcutsHeader)
  Ctrl-A   - \(ctrlADesc)
  Ctrl-E   - \(ctrlEDesc)
  Ctrl-K   - \(ctrlKDesc)
  Ctrl-U   - \(ctrlUDesc)
  Ctrl-Y   - \(ctrlYDesc)
  Ctrl-W   - \(ctrlWDesc)
  Ctrl-L   - \(ctrlLDesc)
  Ctrl-C   - \(ctrlCDesc)
  Ctrl-D   - \(ctrlDDesc)
  Tab      - \(tabDesc)
  Up/Down  - \(arrowDesc)

\(footer)

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays reset command help
    func displayResetHelp() {
        let helpText = """
usage: reset

Reset the terminal state and clear scrollback.

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays reloadconfig command help
    func displayReloadConfigHelp() {
        let helpText = """
usage: reloadconfig

Reload the imported Swiftty keybind config from ~/.swiftty/imported_keybinds.conf.
Use this after editing the file from a local shell or through a symlink in your home directory.

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays command history
    func displayHistory() {
        let commands = historyManager.recentCommands(limit: 50)
        if commands.isEmpty {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let msg = String(localized: "No commands in history", comment: "History: empty history message")
                self.onOutput?(self.normalizeLineEndings(msg + "\n"))
                self.displayPrompt()
            }
            return
        }

        let historyText = commands.enumerated().map { index, command in
            String(format: "%4d  %@", commands.count - index, command)
        }.joined(separator: "\n") + "\n"

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(historyText))
            self.displayPrompt()
        }
    }

    /// Displays SSH help with usage and keystore information
    func displaySSHHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let destHeader = String(localized: "Destination:", comment: "SSH help: destination section header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreSelectKey = String(localized: "Use -i <keyname> to select a specific key", comment: "SSH help: select key note")
        let keystoreNoKey = String(localized: "If no key specified, uses default key or prompts for password", comment: "SSH help: no key note")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        // `ssh` is Shell-native and interactive only: SSHCommandParser refuses
        // remote commands, shell composition, and any option not listed here.
        let helpText = """
usage: ssh [-p port] [-l user] [-i identity] [-J jumphost] [--tmux] [-o option] destination

\(optionsHeader)
  -p port       \(String(localized: "Connect to this port (default: 22)", comment: "SSH help: -p option"))
  -l user       \(String(localized: "Log in as this user", comment: "SSH help: -l option"))
  -i identity   \(String(localized: "Use this key (matches saved key names)", comment: "SSH help: -i option"))
  -J jumphost   \(String(localized: "Connect via jump host (ProxyJump)", comment: "SSH help: -J option"))
  --tmux        \(String(localized: "Auto-start tmux on the remote host", comment: "SSH help: --tmux option"))
  -o option     \(String(localized: "Set SSH option (Port, User, ProxyJump, IdentityFile)", comment: "SSH help: -o option"))

\(destHeader)
  [user@]host[:port]    \(String(localized: "Standard format", comment: "SSH help: standard destination format"))
  [IPv6]:port           \(String(localized: "IPv6 with port", comment: "SSH help: IPv6 destination format"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreSelectKey)
  \(keystoreNoKey)

\(examplesHeader)
  ssh user@host.example.com
  ssh -p 2222 admin@server
  ssh -i mykey user@host
  ssh -J bastion user@internal
  ssh --tmux user@host

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

}
