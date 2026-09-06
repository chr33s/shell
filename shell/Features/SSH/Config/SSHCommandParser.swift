//
//  SSHCommandParser.swift
//  shell
//
//  Parses SSH command-line arguments into SSHConfig for internal SSH client integration
//

import Foundation
import os.log

/// Parser for SSH command-line arguments
/// Supports: -p (port), -l (user), -J (jump host), -i (identity), -A (agent forwarding),
///           -L (local forward), -R (remote forward), -o (options),
///           --path (Shell-specific remote exec wrapper)
@MainActor
struct SSHCommandParser {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHCommandParser")

    /// The stored-credential lookups both auth ladders consult, held as values
    /// rather than called directly on the singletons.
    ///
    /// TESTABILITY SEAM ONLY — `.live` forwards to exactly the same singletons
    /// the ladders called before, in the same order, so production behavior is
    /// unchanged. It exists because `SSHKeyManager` and `SSHPasswordManager`
    /// are `private init()` singletons backed by the Keychain, and
    /// `addToDefaults(id:)` refuses any id that is not already in `savedKeys` —
    /// so there is no way to exercise rungs 1 and 2 of the ladder without real
    /// Keychain writes.
    struct CredentialSources {
        /// Is a password saved for this exact `host:port:user`?
        var hasSavedPassword: (_ host: String, _ port: Int, _ username: String) -> Bool
        /// The identity a `-i` path names, if it matches a saved key.
        var keyIDForIdentityPath: (_ path: String) -> UUID?
        /// The configured default identities, in preference order.
        var defaultKeyIDs: () -> [UUID]

        static let live = CredentialSources(
            hasSavedPassword: { host, port, username in
                SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username)
            },
            keyIDForIdentityPath: { SSHCommandParser.findKeyByIdentityPath($0) },
            defaultKeyIDs: { SSHKeyManager.shared.defaultKeyIDs }
        )
    }

    /// Overridden only by tests; reset to `.live` in `tearDown`.
    static var credentials: CredentialSources = .live

    /// Result of parsing an SSH command
    enum ParseResult {
        /// Successfully parsed with complete config (has auth method)
        case success(SSHConfig)
        /// Parsed but needs password (no key match, no stored password)
        case needsPassword(PartialSSHConfig)
        /// Parse error with message
        case error(String)
        /// User requested help (bare ssh, -h, or --help)
        case help
    }

    /// Which hop a pending password prompt is collecting a credential for.
    /// One prompt serves both hops: the prompt text names the right host and
    /// `toSSHConfig(password:)` applies the typed secret to the right side.
    enum PasswordSubject: Sendable, Hashable {
        case target
        case jumpHost
    }

    /// Partial config when password is needed
    struct PartialSSHConfig: Sendable {
        var host: String
        var port: Int
        var username: String
        var jumpHost: SSHConfig.JumpHostConfig?
        /// Which hop this prompt is for. `.target` preserves the historical shape.
        var passwordSubject: PasswordSubject = .target
        /// Target-hop credential already resolved by the parser. Non-nil only when
        /// `passwordSubject == .jumpHost`, so a target key or saved password
        /// survives the bastion prompt round trip instead of being re-asked.
        var targetAuthMethod: SSHConfig.AuthMethod?
        /// Fallback identities for `targetAuthMethod` when it is `.key`.
        var targetFallbackKeyIDs: [UUID]?
        var tmuxAutoEnable: Bool = false
        var tmuxAutoMode: TmuxAutoMode = .regular
        /// Per-profile tmux session name, carried through the password prompt
        /// round-trip. Not settable from the command line.
        var tmuxSessionName: String?

        /// Convert to full SSHConfig, applying the typed password to the hop the
        /// prompt was actually collecting for.
        func toSSHConfig(password: String) -> SSHConfig {
            var config = SSHConfig(
                host: host,
                port: port,
                username: username,
                password: "",
                jumpHost: jumpHost,
                tmuxAutoEnable: tmuxAutoEnable,
                tmuxAutoMode: tmuxAutoMode
            )
            switch passwordSubject {
            case .target:
                config.authMethod = .password(password)
            case .jumpHost:
                // `targetAuthMethod` is nil only when the target has no credential
                // either; the prompt site chains a second prompt before reaching
                // here, so this never launches with an empty target password.
                config.authMethod = targetAuthMethod ?? .password("")
                config.fallbackKeyIDs = targetFallbackKeyIDs
                if var jump = config.jumpHost {
                    jump.authMethod = .password(password)
                    config.jumpHost = jump
                }
            }
            config.tmuxSessionName = tmuxSessionName
            return config
        }
    }

    /// Parse an SSH command string into configuration
    /// - Parameter command: Full command string (e.g., "ssh -p 2222 user@host")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "ssh"
        guard tokens[0].text.lowercased() == "ssh" else {
            return .error("Not an ssh command")
        }

        // Check for help request: bare "ssh", "ssh -h", or "ssh --help"
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1].text == "-h" || tokens[1].text == "--help") {
            return .help
        }

        var port = 22
        var username: String?
        var host: String?
        var identityFile: String?
        var jumpHostString: String?
        var sshOptions: [String: String] = [:]
        // Settings ▸ tmux ▸ Default Mode seeds every parsed connection; `--tmux`
        // still forces tmux on when the default is Off.
        let defaultTmuxMode = SettingsStore.shared.value(Settings.Tmux.defaultMode)
        var tmuxAutoEnable = defaultTmuxMode.tmuxEnabled
        var tmuxAutoMode = defaultTmuxMode.autoMode

        var i = 1
        while i < tokens.count {
            let token = tokens[i].text

            // Once we have a destination, the rest of the line is ignored:
            // this fork opens an interactive session, never a remote command.
            if host != nil {
                break
            }

            if token.hasPrefix("-") {
                // Handle flags
                switch token {
                case "-p":
                    // Port
                    i += 1
                    guard i < tokens.count, let p = Int(tokens[i].text), p > 0, p <= 65535 else {
                        return .error("Invalid port number")
                    }
                    port = p

                case "-l":
                    // Username
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing username after -l")
                    }
                    username = tokens[i].text

                case "-J":
                    // Jump host
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing jump host after -J")
                    }
                    jumpHostString = tokens[i].text

                case "-i":
                    // Identity file
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing identity file after -i")
                    }
                    identityFile = tokens[i].text

                case "-o":
                    // SSH option
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing option after -o")
                    }
                    if let (key, value) = parseOption(tokens[i].text) {
                        sshOptions[key] = value
                    }

                case "--tmux":
                    // Enable tmux auto-start. When the default was Off the mode
                    // is meaningless, so normalise it to plain tmux; a default of
                    // Control Mode is left alone and still launches `-CC`.
                    if !tmuxAutoEnable { tmuxAutoMode = .regular }
                    tmuxAutoEnable = true

                default:
                    // Unknown flags are ignored.
                    break
                }
            } else {
                // First positional argument - should be [user@]host[:port]
                let parsed = parseDestination(token)
                if let u = parsed.username {
                    username = u
                }
                host = parsed.host
                if let p = parsed.port {
                    port = p
                }
            }

            i += 1
        }

        // Apply -o options that we recognize
        if let optPort = sshOptions["Port"], let p = Int(optPort) {
            port = p
        }
        if let optUser = sshOptions["User"] {
            username = optUser
        }
        if let optJump = sshOptions["ProxyJump"] {
            jumpHostString = optJump
        }
        if let optIdentity = sshOptions["IdentityFile"] {
            identityFile = optIdentity
        }

        // Validate we have a host
        guard let finalHost = host, !finalHost.isEmpty else {
            return .error("Missing hostname")
        }

        // Default username to current user if not specified
        let finalUsername = username ?? UserPreferences.effectiveUsername

        logger.info("Parsed SSH: \(finalUsername)@\(finalHost):\(port), identity=\(identityFile ?? "none"), jump=\(jumpHostString ?? "none")")

        // Build jump host config if specified
        var jumpHostConfig: SSHConfig.JumpHostConfig?
        var jumpNeedsPassword = false
        if let jumpStr = jumpHostString {
            let jumpParsed = parseDestination(jumpStr)
            let jumpUser = jumpParsed.username ?? finalUsername
            guard let jumpHost = jumpParsed.host, !jumpHost.isEmpty else {
                return .error("Invalid jump host")
            }
            let jumpPort = jumpParsed.port ?? 22

            switch resolveJumpAuth(
                for: jumpUser,
                host: jumpHost,
                port: jumpPort,
                identityFile: identityFile
            ) {
            case .resolved(let method):
                jumpHostConfig = SSHConfig.JumpHostConfig(
                    host: jumpHost,
                    port: jumpPort,
                    username: jumpUser,
                    authMethod: method
                )
            case .needsPassword:
                jumpNeedsPassword = true
                // Placeholder filled in by the prompt. Never launched as-is:
                // every return path below runs through
                // `resultAwaitingJumpPassword`, which diverts to the prompt.
                jumpHostConfig = SSHConfig.JumpHostConfig(
                    host: jumpHost,
                    port: jumpPort,
                    username: jumpUser,
                    authMethod: .password("")
                )
            }
        }

        // Try to find a matching key
        var keyID: UUID?

        // First try explicit identity file
        if let identity = identityFile {
            keyID = credentials.keyIDForIdentityPath(identity)
        }

        // If no explicit key, try to find from history
        if keyID == nil {
            keyID = findMatchingKey(for: finalUsername, host: finalHost, identityHint: identityFile)
        }

        // If we found a key, return success
        if let foundKeyID = keyID {
            let config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                keyID: foundKeyID,
                jumpHost: jumpHostConfig,
                tmuxAutoEnable: tmuxAutoEnable,
                tmuxAutoMode: tmuxAutoMode
            )
            return resultAwaitingJumpPassword(config, jumpNeedsPassword: jumpNeedsPassword)
        }

        // Check if we have a saved password for this connection
        if credentials.hasSavedPassword(finalHost, port, finalUsername) {
            logger.info("Found saved password for \(finalUsername)@\(finalHost):\(port)")
            let config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                authMethod: .savedPassword,
                jumpHost: jumpHostConfig,
                tmuxAutoEnable: tmuxAutoEnable,
                tmuxAutoMode: tmuxAutoMode
            )
            return resultAwaitingJumpPassword(config, jumpNeedsPassword: jumpNeedsPassword)
        }

        // Fall back to default keys if set and no saved password found
        let allDefaults = credentials.defaultKeyIDs()
        if let primaryKeyID = allDefaults.first {
            // Build fallback keys list from remaining defaults
            let fallbackIDs = Array(allDefaults.dropFirst())

            logger.info("Using default key for \(finalUsername)@\(finalHost): \(primaryKeyID) (+ \(fallbackIDs.count) fallbacks)")
            let config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                keyID: primaryKeyID,
                fallbackKeyIDs: fallbackIDs.isEmpty ? nil : fallbackIDs,
                jumpHost: jumpHostConfig,
                tmuxAutoEnable: tmuxAutoEnable,
                tmuxAutoMode: tmuxAutoMode
            )
            return resultAwaitingJumpPassword(config, jumpNeedsPassword: jumpNeedsPassword)
        }

        // Neither hop resolved a credential. Ask for the bastion's first — it is
        // the first hop, and OpenSSH asks in the same order. `targetAuthMethod`
        // stays nil, which the prompt site reads as "the target still needs one
        // too" and chains a second prompt.
        var partial = PartialSSHConfig(
            host: finalHost,
            port: port,
            username: finalUsername,
            jumpHost: jumpHostConfig,
            tmuxAutoEnable: tmuxAutoEnable,
            tmuxAutoMode: tmuxAutoMode,
        )
        partial.passwordSubject = jumpNeedsPassword ? .jumpHost : .target

        return .needsPassword(partial)
    }

    /// Wrap a fully-resolved target config: launch it, or divert to the bastion
    /// password prompt when the bastion has no stored credential.
    ///
    /// The bastion prompt is strictly LAST: it runs only after the target ladder
    /// produced a credential, so a key that would have worked is never skipped,
    /// and the user is asked for exactly one secret — the bastion's.
    private static func resultAwaitingJumpPassword(
        _ config: SSHConfig,
        jumpNeedsPassword: Bool
    ) -> ParseResult {
        guard jumpNeedsPassword else { return .success(config) }

        var partial = PartialSSHConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            jumpHost: config.jumpHost,
            tmuxAutoEnable: config.tmuxAutoEnable,
            tmuxAutoMode: config.tmuxAutoMode,
            tmuxSessionName: config.tmuxSessionName
        )
        partial.passwordSubject = .jumpHost
        partial.targetAuthMethod = config.authMethod
        partial.targetFallbackKeyIDs = config.fallbackKeyIDs
        return .needsPassword(partial)
    }

    // MARK: - Private Helpers

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    /// Tokenize command string, respecting quotes and preserving source ranges.
    private static func tokenize(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuote: Character?
        var tokenStart: String.Index?

        var index = command.startIndex
        while index < command.endIndex {
            let char = command[index]
            if let quote = inQuote {
                if char == quote {
                    inQuote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                if tokenStart == nil {
                    tokenStart = index
                }
                inQuote = char
            } else if char.isWhitespace {
                if let start = tokenStart {
                    tokens.append(Token(text: current, range: start..<index))
                    current = ""
                    tokenStart = nil
                }
            } else {
                if tokenStart == nil {
                    tokenStart = index
                }
                current.append(char)
            }

            index = command.index(after: index)
        }

        if let tokenStart {
            tokens.append(Token(text: current, range: tokenStart..<command.endIndex))
        }

        return tokens
    }

    /// Parse -o option string (key=value or key value)
    private static func parseOption(_ option: String) -> (String, String)? {
        if let eqIndex = option.firstIndex(of: "=") {
            let key = String(option[..<eqIndex])
            let value = String(option[option.index(after: eqIndex)...])
            return (key, value)
        }
        return nil
    }

    /// Parse [user@]host[:port] destination string
    private static func parseDestination(_ dest: String) -> (username: String?, host: String?, port: Int?) {
        var remaining = dest
        var username: String?
        var port: Int?

        // Extract user@ prefix (split on LAST @ so usernames containing @ — e.g.
        // Active-Directory-style user@domain — survive host separation)
        if let atIndex = remaining.lastIndex(of: "@") {
            username = String(remaining[..<atIndex])
            remaining = String(remaining[remaining.index(after: atIndex)...])
        }

        // Extract :port suffix (but be careful with IPv6 [host]:port)
        if remaining.hasPrefix("[") {
            // IPv6 format: [host]:port
            if let closeIndex = remaining.firstIndex(of: "]") {
                let afterClose = remaining.index(after: closeIndex)
                if afterClose < remaining.endIndex && remaining[afterClose] == ":" {
                    let portStr = String(remaining[remaining.index(after: afterClose)...])
                    port = Int(portStr)
                    remaining = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                } else {
                    remaining = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                }
            }
        } else if let colonIndex = remaining.lastIndex(of: ":") {
            // Regular host:port - but only if what follows looks like a port number
            let portStr = String(remaining[remaining.index(after: colonIndex)...])
            if let p = Int(portStr), p > 0, p <= 65535 {
                port = p
                remaining = String(remaining[..<colonIndex])
            }
        }

        return (username, remaining.isEmpty ? nil : remaining, port)
    }

    /// Find an SSH key by identity file path
    /// Matches the filename against key names in the key manager
    static func findKeyByIdentityPath(_ path: String) -> UUID? {
        // Extract filename from path
        let filename = (path as NSString).lastPathComponent
        // Remove common extensions
        let baseName = filename
            .replacingOccurrences(of: ".pub", with: "")
            .replacingOccurrences(of: ".pem", with: "")

        let keys = SSHKeyManager.shared.savedKeys

        // Try exact match first
        if let key = keys.first(where: { $0.name.lowercased() == baseName.lowercased() }) {
            logger.info("Found exact key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        // Try prefix match
        if let key = keys.first(where: { $0.name.lowercased().hasPrefix(baseName.lowercased()) }) {
            logger.info("Found prefix key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        // Try contains match
        if let key = keys.first(where: { $0.name.lowercased().contains(baseName.lowercased()) }) {
            logger.info("Found partial key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        logger.info("No key match found for identity '\(baseName)'")
        return nil
    }

    /// The fork has no connection history, so there is no host-specific key
    /// to recover here; the caller falls back to saved passwords and then to
    /// the configured default identities.
    private static func findMatchingKey(for username: String, host: String, identityHint: String?) -> UUID? {
        nil
    }

    /// Outcome of the bastion credential ladder.
    private enum JumpAuthResolution {
        /// A stored credential usable without asking the user.
        case resolved(SSHConfig.AuthMethod)
        /// Nothing configured for this bastion — the caller must prompt.
        case needsPassword
    }

    /// Resolve the credential to present at a jump host (bastion). Exactly three
    /// rungs, in order, and NO key fallbacks beyond the one chosen:
    ///
    ///   1. the explicit `-i` identity (OpenSSH applies `-i` to every hop of the
    ///      chain unless overridden),
    ///   2. a password saved for that exact `host:port:user`,
    ///   3. the configured primary default identity.
    ///
    /// The fallback list is deliberately absent. A bastion's `MaxAuthTries` is
    /// the scarce resource here: `MultiKeyAuthDelegate` offers a certificate and
    /// then the plain key for each candidate, so every certified identity costs
    /// TWO `MSG_USERAUTH_REQUEST`s. Four default identities is eight attempts —
    /// past a stock `MaxAuthTries 6`, which locks the account out before the
    /// working key is reached and leaves no budget for a password. The target hop
    /// keeps its fallbacks: it is a separate SSH connection over the tunnel with
    /// its own budget.
    ///
    /// Returns `.needsPassword` when the user has configured nothing for this
    /// bastion; the caller then prompts rather than sending an empty password.
    private static func resolveJumpAuth(
        for username: String,
        host: String,
        port: Int,
        identityFile: String?
    ) -> JumpAuthResolution {
        if let identity = identityFile, let keyID = credentials.keyIDForIdentityPath(identity) {
            logger.info("Jump host \(username)@\(host):\(port) using -i identity \(keyID)")
            return .resolved(.key(keyID))
        }

        if credentials.hasSavedPassword(host, port, username) {
            logger.info("Jump host \(username)@\(host):\(port) using saved password")
            return .resolved(.savedPassword)
        }

        if let primaryKeyID = credentials.defaultKeyIDs().first {
            logger.info("Jump host \(username)@\(host):\(port) using primary default key \(primaryKeyID)")
            return .resolved(.key(primaryKeyID))
        }

        logger.info("No stored credential for jump host \(username)@\(host):\(port) — prompting")
        return .needsPassword
    }
}
