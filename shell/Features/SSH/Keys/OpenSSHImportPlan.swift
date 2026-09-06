//
//  OpenSSHImportPlan.swift
//  shell
//
//  Builds an importable plan from a parsed ssh_config + the directory it
//  lives in. Resolves IdentityFile references against existing keychain
//  entries, lifts new key files into pending-import rows, and applies the
//  plan in one shot once the user confirms.
//

import Foundation
import os.log

// MARK: - Plan data

/// One profile to be created from a concrete Host entry.
struct OpenSSHProfilePlan: Identifiable, Hashable {
    let id = UUID()

    /// All aliases declared on the `Host` line; the first is the profile name.
    var aliases: [String]
    /// Final resolved hostname (after applying HostName / wildcards).
    var hostName: String
    var port: Int
    var user: String
    /// Stable keys for the linked `OpenSSHKeyPlan` rows (in declaration order).
    var identityKeyPlanIDs: [UUID]
    /// Parsed jump host coordinates, if a ProxyJump / ProxyCommand was found.
    /// The final SSHKey UUIDs are resolved at apply time so they reference
    /// real keychain entries, not preview-side plan UUIDs.
    var jumpHostSource: JumpHostSource?
    /// Source diagnostic ("config:42") for tooltip / debug.
    var source: String

    /// Profile name (first alias).
    var name: String { aliases.first ?? hostName }

    /// Display string for any jump host extracted from ProxyJump / ProxyCommand.
    var jumpHostDisplay: String? { jumpHostSource?.display }

    /// Raw jump host data captured during parse. Apply uses the
    /// `identityKeyPlanIDs` field to look up the eventual `SSHKey.id`.
    struct JumpHostSource: Hashable {
        var host: String
        var port: Int
        var username: String
        /// Plan IDs of identity files the target uses; shared with the jump host.
        var identityKeyPlanIDs: [UUID]
        /// Pre-built display string for the preview UI.
        var display: String
    }
}

/// One private-key file referenced by `IdentityFile`.
struct OpenSSHKeyPlan: Identifiable, Hashable {
    let id = UUID()

    /// Filename only, e.g. `id_ed25519`.
    var filename: String
    /// Absolute path inside the .ssh directory.
    var path: String
    /// Suggested profile-friendly key name (filename without extension).
    var suggestedName: String

    enum Status: Hashable {
        /// File was found and parsed; fingerprint computed.
        case readyForImport(fingerprint: String, encrypted: Bool)
        /// File matched an existing key in the SSHKeyManager keychain.
        case alreadyImported(existingKeyID: UUID, existingKeyName: String, fingerprint: String)
        /// File could not be read (missing, unreadable, etc.).
        case fileMissing
        /// Parser rejected the file (corrupt / unsupported format).
        case parseFailed(message: String)
    }

    var status: Status

    /// User-editable: whether to actually import this key on Apply.
    var includeOnImport: Bool
    /// User-editable: passphrase to use on Apply (for encrypted keys).
    var passphrase: String

    /// File contents captured during preview so apply works even after the
    /// security-scoped folder URL has been released (sandboxed Mac Catalyst).
    var cachedKeyContents: String?

    /// True when the parsed file's cipher is non-`none`.
    var isEncrypted: Bool {
        if case .readyForImport(_, let enc) = status { return enc }
        return false
    }

    /// Fingerprint, if known.
    var fingerprint: String? {
        switch status {
        case .readyForImport(let fp, _): return fp
        case .alreadyImported(_, _, let fp): return fp
        case .fileMissing, .parseFailed: return nil
        }
    }
}

/// A host entry that was deliberately not imported.
struct OpenSSHSkippedEntry: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var reason: String
}

/// Everything the preview sheet needs to render.
struct OpenSSHImportPlan: Identifiable {
    let id = UUID()

    /// Directory the import came from (Documents/.ssh or ~/.ssh).
    var sshDirectory: URL
    /// Concrete profiles to be created.
    var profiles: [OpenSSHProfilePlan]
    /// All distinct key files referenced; rows the user can toggle.
    var keys: [OpenSSHKeyPlan]
    /// Hosts deliberately skipped (wildcards, conflicts).
    var skipped: [OpenSSHSkippedEntry]
    /// Free-form parse warnings to surface in a Notes section.
    var warnings: [String]

    /// True when there is anything actionable to apply.
    var hasAnythingToApply: Bool {
        !profiles.isEmpty
    }
}

/// Summary of what an Apply actually did.
struct OpenSSHImportSummary: Identifiable {
    let id = UUID()
    var profilesCreated: Int
    var keysImported: Int
    var keysSkippedAlreadyPresent: Int
    var keysFailedToImport: [(filename: String, reason: String)]
    var profilesFailedToCreate: [(name: String, reason: String)]
    var folderPath: String
    var skippedCount: Int
    var warnings: [String]
}

// MARK: - Importer

/// Builds preview plans and applies them. Pure facade over `SSHKeyManager`
/// and `ConnectionProfileManager`.
@MainActor
enum OpenSSHImporter {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "OpenSSHImporter")

    enum PreviewError: LocalizedError {
        case configMissing(URL)
        case parserError(String)

        var errorDescription: String? {
            switch self {
            case .configMissing(let url):
                return "No ssh config found at \(url.path). Add a 'config' file to this folder and try again."
            case .parserError(let msg):
                return msg
            }
        }
    }

    /// Build a preview plan from a `.ssh` directory.
    static func preview(sshDirectory: URL) throws -> OpenSSHImportPlan {
        let configURL = sshDirectory.appendingPathComponent("config")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw PreviewError.configMissing(configURL)
        }

        let parseResult: OpenSSHConfigParseResult
        do {
            parseResult = try OpenSSHConfigParser.parse(fileURL: configURL, sshDirectory: sshDirectory)
        } catch {
            throw PreviewError.parserError(error.localizedDescription)
        }

        // Split wildcard from concrete entries; concrete entries are the
        // profiles we actually create.
        let wildcards = parseResult.entries.filter { $0.isWildcard }
        let concretes = parseResult.entries.filter { !$0.isWildcard }

        // Build the key registry first by collecting every distinct IdentityFile
        // path across all concrete entries (after wildcard inheritance).
        var resolvedConcretes: [(entry: OpenSSHHostEntry, identityPaths: [String])] = []
        for entry in concretes {
            let resolved = resolveWithWildcards(entry: entry, wildcards: wildcards)
            let paths = resolved.identityFiles.map { resolveIdentityPath($0, sshDirectory: sshDirectory) }
            resolvedConcretes.append((resolved, paths))
        }

        var keyPlanByPath: [String: OpenSSHKeyPlan] = [:]
        for (_, paths) in resolvedConcretes {
            for path in paths where keyPlanByPath[path] == nil {
                keyPlanByPath[path] = buildKeyPlan(path: path)
            }
        }
        // Stable order: by filename then path.
        let keys = keyPlanByPath.values.sorted { lhs, rhs in
            if lhs.filename != rhs.filename { return lhs.filename < rhs.filename }
            return lhs.path < rhs.path
        }
        var keyIDByPath: [String: UUID] = [:]
        for key in keys { keyIDByPath[key.path] = key.id }

        // Build profiles, detecting conflicts against existing ConnectionProfileManager rows.
        let existing = ConnectionProfileManager.shared.profiles
        var profiles: [OpenSSHProfilePlan] = []
        var skipped: [OpenSSHSkippedEntry] = []
        var warnings = parseResult.warnings

        for (entry, identityPaths) in resolvedConcretes {
            let hostName = entry.hostName ?? entry.aliases.first ?? ""
            let port = entry.port ?? 22
            let user = entry.user ?? Self.defaultUsername

            // Conflict detection: existing profile with same host+user+port.
            let conflict = existing.first { candidate in
                let candidateHost = candidate.sshConfig.host
                let hostMatches = candidateHost.caseInsensitiveCompare(hostName) == .orderedSame
                let portMatches = candidate.sshConfig.port == port
                let userMatches = candidate.sshConfig.username == user
                return hostMatches && portMatches && userMatches
            }
            if let conflict {
                skipped.append(OpenSSHSkippedEntry(
                    label: entry.aliases.first ?? hostName,
                    reason: "Already exists as '\(conflict.name)' (\(user)@\(hostName):\(port))"
                ))
                continue
            }

            let identityKeyPlanIDs = identityPaths.compactMap { keyIDByPath[$0] }
            let (jumpSource, jumpWarning) = resolveJumpHost(
                entry: entry,
                identityKeyPlanIDs: identityKeyPlanIDs
            )
            if let jumpWarning { warnings.append(jumpWarning) }

            let profile = OpenSSHProfilePlan(
                aliases: entry.aliases,
                hostName: hostName,
                port: port,
                user: user,
                identityKeyPlanIDs: identityKeyPlanIDs,
                jumpHostSource: jumpSource,
                source: "\(entry.sourceFile.lastPathComponent):\(entry.sourceLine)"
            )
            profiles.append(profile)
        }

        for wildcard in wildcards {
            let label = wildcard.aliases.joined(separator: ", ")
            skipped.append(OpenSSHSkippedEntry(
                label: label,
                reason: "Wildcard pattern, not a concrete host"
            ))
        }

        return OpenSSHImportPlan(
            sshDirectory: sshDirectory,
            profiles: profiles,
            keys: keys,
            skipped: skipped,
            warnings: warnings
        )
    }

    /// Apply a preview plan: import any opted-in new keys, then create profiles.
    static func apply(plan: OpenSSHImportPlan, folderPath: String) -> OpenSSHImportSummary {
        var keysImported = 0
        var keysSkippedAlreadyPresent = 0
        var keysFailedToImport: [(String, String)] = []
        var profilesFailedToCreate: [(String, String)] = []

        // Pass 1: import keys. We track UUIDs for both the success map (used to
        // build profile auth) and the unrecoverable set (keys that the user
        // *can't* use even after the import attempt: parseFailed, fileMissing,
        // or opted-in-but-import-threw). The unrecoverable set lets pass 2
        // distinguish "user toggled this off" (intentional) from "we tried
        // and it didn't work" (need to skip the dependent profile).
        var resolvedKeyIDs: [UUID: UUID] = [:]  // plan.id -> SSHKey.id
        var unrecoverableKeyPlanIDs: Set<UUID> = []
        var firstFailureReasonByPlanID: [UUID: String] = [:]

        for keyPlan in plan.keys {
            switch keyPlan.status {
            case .alreadyImported(let existingID, _, _):
                resolvedKeyIDs[keyPlan.id] = existingID
                keysSkippedAlreadyPresent += 1

            case .readyForImport(_, let encrypted):
                guard keyPlan.includeOnImport else { continue }
                let passphrase = encrypted ? keyPlan.passphrase : nil
                do {
                    let keyString: String
                    if let cached = keyPlan.cachedKeyContents {
                        keyString = cached
                    } else {
                        keyString = try String(contentsOfFile: keyPlan.path, encoding: .utf8)
                    }

                    // For encrypted keys we couldn't compute the fingerprint at
                    // preview time, so we re-parse here to look for an existing
                    // match before attempting an import that would fail with
                    // ImportError.duplicateKey.
                    if encrypted {
                        if let parsed = try? SSHKeyParser.parse(keyString: keyString, passphrase: passphrase),
                           let existing = SSHKeyManager.shared.findKey(byFingerprint: parsed.fingerprint) {
                            resolvedKeyIDs[keyPlan.id] = existing.id
                            keysSkippedAlreadyPresent += 1
                            continue
                        }
                    }

                    let imported = try SSHKeyManager.shared.importKey(
                        name: keyPlan.suggestedName,
                        keyString: keyString,
                        passphrase: passphrase,
                        storageLevel: .backupOnly,
                        authRequirement: .none
                    )
                    resolvedKeyIDs[keyPlan.id] = imported.id
                    keysImported += 1
                } catch {
                    let reason = error.localizedDescription
                    let name = keyPlan.filename
                    keysFailedToImport.append((name, reason))
                    unrecoverableKeyPlanIDs.insert(keyPlan.id)
                    firstFailureReasonByPlanID[keyPlan.id] = "\(name): \(reason)"
                    logger.error("Key import failed for \(name): \(reason)")
                }

            case .fileMissing:
                unrecoverableKeyPlanIDs.insert(keyPlan.id)
                firstFailureReasonByPlanID[keyPlan.id] = "\(keyPlan.filename): file missing"

            case .parseFailed(let msg):
                unrecoverableKeyPlanIDs.insert(keyPlan.id)
                firstFailureReasonByPlanID[keyPlan.id] = "\(keyPlan.filename): \(msg)"
            }
        }

        // Pass 2: create profiles.
        var profilesCreated = 0
        var passwordFallbackWarnings: [String] = []
        for profilePlan in plan.profiles {
            let requestedKeyCount = profilePlan.identityKeyPlanIDs.count
            let resolvedIDs = profilePlan.identityKeyPlanIDs.compactMap { resolvedKeyIDs[$0] }
            let unrecoverableUsed = profilePlan.identityKeyPlanIDs.filter { unrecoverableKeyPlanIDs.contains($0) }

            // If the profile declared IdentityFile keys, none of them resolved,
            // AND at least one of the declared keys was unrecoverable (vs.
            // simply being toggled off by the user), skip the profile. Saving
            // it as password auth would look "imported" but never actually
            // authenticate the way ssh_config promised it would.
            if requestedKeyCount > 0 && resolvedIDs.isEmpty && !unrecoverableUsed.isEmpty {
                let reasons = unrecoverableUsed.compactMap { firstFailureReasonByPlanID[$0] }
                let joined = reasons.joined(separator: "; ")
                profilesFailedToCreate.append((
                    profilePlan.name,
                    "Skipped because its IdentityFile keys could not be used: \(joined)"
                ))
                let nameForLog = profilePlan.name
                logger.error("Profile skipped (broken IdentityFile chain): \(nameForLog)")
                continue
            }

            let primaryAuth: SSHConfig.AuthMethod
            let fallbackKeys: [UUID]?
            if let first = resolvedIDs.first {
                primaryAuth = .key(first)
                fallbackKeys = resolvedIDs.count > 1 ? Array(resolvedIDs.dropFirst()) : nil
            } else {
                primaryAuth = .password("")
                fallbackKeys = nil
                if requestedKeyCount > 0 {
                    // All declared keys were toggled off by the user (none
                    // unrecoverable). Honor their choice but flag the auth
                    // mismatch so they aren't surprised the profile lands as
                    // password auth.
                    passwordFallbackWarnings.append(
                        "Profile '\(profilePlan.name)' saved with password auth: IdentityFile keys were not imported."
                    )
                }
            }

            // Build the jump host config NOW using the same resolved-key map so
            // jump hosts that share identity files with the target end up
            // pointing at real keychain UUIDs, not preview plan UUIDs.
            let jumpHost = makeJumpHostConfig(
                source: profilePlan.jumpHostSource,
                resolvedKeyIDs: resolvedKeyIDs
            )

            let sshConfig = SSHConfig(
                host: profilePlan.hostName,
                port: profilePlan.port,
                username: profilePlan.user,
                authMethod: primaryAuth,
                jumpHost: jumpHost
            )
            var configWithFallbacks = sshConfig
            configWithFallbacks.fallbackKeyIDs = fallbackKeys

            do {
                _ = try ConnectionProfileManager.shared.createProfile(
                    name: profilePlan.name,
                    sshConfig: configWithFallbacks
                )
                profilesCreated += 1
            } catch {
                let reason = error.localizedDescription
                let name = profilePlan.name
                profilesFailedToCreate.append((name, reason))
                logger.error("Profile creation failed for \(name): \(reason)")
            }
        }

        return OpenSSHImportSummary(
            profilesCreated: profilesCreated,
            keysImported: keysImported,
            keysSkippedAlreadyPresent: keysSkippedAlreadyPresent,
            keysFailedToImport: keysFailedToImport,
            profilesFailedToCreate: profilesFailedToCreate,
            folderPath: folderPath,
            skippedCount: plan.skipped.count,
            warnings: plan.warnings + passwordFallbackWarnings
        )
    }

    /// Build a JumpHostConfig at apply time. Maps the plan's
    /// `identityKeyPlanIDs` into real `SSHKey.id`s using `resolvedKeyIDs`.
    private static func makeJumpHostConfig(
        source: OpenSSHProfilePlan.JumpHostSource?,
        resolvedKeyIDs: [UUID: UUID]
    ) -> SSHConfig.JumpHostConfig? {
        guard let source else { return nil }
        let resolved = source.identityKeyPlanIDs.compactMap { resolvedKeyIDs[$0] }
        let auth: SSHConfig.AuthMethod
        let fallback: [UUID]?
        if let primary = resolved.first {
            auth = .key(primary)
            fallback = resolved.count > 1 ? Array(resolved.dropFirst()) : nil
        } else {
            auth = .password("")
            fallback = nil
        }
        return SSHConfig.JumpHostConfig(
            host: source.host,
            port: source.port,
            username: source.username,
            authMethod: auth,
            fallbackKeyIDs: fallback
        )
    }

    // MARK: - Default username

    /// Best-effort default username when a Host block omits `User`. Falls back
    /// to `NSUserName()` on Mac Catalyst Standalone, and `"root"` elsewhere
    /// since iOS has no concept of a real Unix user.
    private static var defaultUsername: String {
        #if STANDALONE
        let name = NSUserName()
        return name.isEmpty ? "root" : name
        #else
        return "root"
        #endif
    }

    // MARK: - Wildcard inheritance

    /// Apply matching wildcard blocks to fill in unset directives on a concrete
    /// entry. First-match-wins per directive matches OpenSSH semantics for
    /// directives like `HostName`, `User`, `Port`, etc.
    private static func resolveWithWildcards(
        entry: OpenSSHHostEntry,
        wildcards: [OpenSSHHostEntry]
    ) -> OpenSSHHostEntry {
        var resolved = entry
        for wildcard in wildcards {
            // A wildcard block applies to this entry if any of the entry's
            // aliases satisfies the block's full pattern list (positive +
            // negation, OpenSSH semantics).
            let matches = resolved.aliases.contains { alias in
                patternsApply(aliases: wildcard.aliases, target: alias)
            }
            guard matches else { continue }

            if resolved.hostName == nil { resolved.hostName = wildcard.hostName }
            if resolved.port == nil { resolved.port = wildcard.port }
            if resolved.user == nil { resolved.user = wildcard.user }
            if resolved.proxyJump == nil { resolved.proxyJump = wildcard.proxyJump }
            if resolved.proxyCommand == nil { resolved.proxyCommand = wildcard.proxyCommand }
            // IdentityFile semantics across blocks:
            // - A wildcard with `IdentityFile none` discards the cumulative
            //   list (concrete + earlier wildcards) and then appends its own
            //   remaining identities. The clear propagates so later wildcards
            //   cannot re-add identities for this profile.
            // - A wildcard without a clear contributes its identities only if
            //   no prior block has cleared.
            if wildcard.identityFilesCleared {
                resolved.identityFiles.removeAll()
                resolved.identityFilesCleared = true
                for path in wildcard.identityFiles where !resolved.identityFiles.contains(path) {
                    resolved.identityFiles.append(path)
                }
            } else if !resolved.identityFilesCleared {
                for path in wildcard.identityFiles where !resolved.identityFiles.contains(path) {
                    resolved.identityFiles.append(path)
                }
            }
        }
        return resolved
    }

    /// True if a Host block's pattern list applies to `target` under OpenSSH
    /// semantics: at least one positive pattern matches AND no negated pattern
    /// matches. A block of only negations never matches (matches OpenSSH).
    private static func patternsApply(aliases: [String], target: String) -> Bool {
        var sawPositiveMatch = false
        for pattern in aliases {
            if pattern.hasPrefix("!") {
                let body = String(pattern.dropFirst())
                if fnmatch(pattern: body, name: target) { return false }
            } else if fnmatch(pattern: pattern, name: target) {
                sawPositiveMatch = true
            }
        }
        return sawPositiveMatch
    }

    private static func fnmatch(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var pi = 0
        var ni = 0
        var starPi = -1
        var starNi = -1
        while ni < n.count {
            if pi < p.count, p[pi] == "?" {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starNi = ni
                pi += 1
            } else if pi < p.count, p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starNi += 1
                ni = starNi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Identity path resolution

    private static func resolveIdentityPath(_ raw: String, sshDirectory: URL) -> String {
        if raw.hasPrefix("/") { return raw }
        if raw.hasPrefix("~") {
            let home = sshDirectory.deletingLastPathComponent().path
            if raw == "~" { return home }
            if raw.hasPrefix("~/") { return home + String(raw.dropFirst(1)) }
            return raw
        }
        return sshDirectory.appendingPathComponent(raw).path
    }

    // MARK: - Key plan construction

    private static func buildKeyPlan(path: String) -> OpenSSHKeyPlan {
        let filename = (path as NSString).lastPathComponent
        let suggestedName = (filename as NSString).deletingPathExtension

        guard FileManager.default.fileExists(atPath: path) else {
            return OpenSSHKeyPlan(
                filename: filename,
                path: path,
                suggestedName: suggestedName,
                status: .fileMissing,
                includeOnImport: false,
                passphrase: "",
                cachedKeyContents: nil
            )
        }

        let keyString: String
        do {
            keyString = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return OpenSSHKeyPlan(
                filename: filename,
                path: path,
                suggestedName: suggestedName,
                status: .parseFailed(message: error.localizedDescription),
                includeOnImport: false,
                passphrase: "",
                cachedKeyContents: nil
            )
        }

        // Encrypted? Surface the row with the encrypted flag set; we can't
        // compute a real fingerprint until the user supplies the passphrase
        // at apply time. The parser will then dedupe against existing keys
        // via SSHKeyManager.importKey's own fingerprint check.
        let encrypted = SSHKeyParser.isEncrypted(keyString: keyString)
        if encrypted {
            return OpenSSHKeyPlan(
                filename: filename,
                path: path,
                suggestedName: suggestedName,
                status: .readyForImport(fingerprint: "", encrypted: true),
                includeOnImport: true,
                passphrase: "",
                cachedKeyContents: keyString
            )
        }

        do {
            let parsed = try SSHKeyParser.parse(keyString: keyString)
            let fingerprint = parsed.fingerprint
            if let existing = SSHKeyManager.shared.findKey(byFingerprint: fingerprint) {
                return OpenSSHKeyPlan(
                    filename: filename,
                    path: path,
                    suggestedName: suggestedName,
                    status: .alreadyImported(
                        existingKeyID: existing.id,
                        existingKeyName: existing.name,
                        fingerprint: fingerprint
                    ),
                    includeOnImport: false,
                    passphrase: "",
                    cachedKeyContents: nil
                )
            }
            return OpenSSHKeyPlan(
                filename: filename,
                path: path,
                suggestedName: suggestedName,
                status: .readyForImport(fingerprint: fingerprint, encrypted: false),
                includeOnImport: true,
                passphrase: "",
                cachedKeyContents: keyString
            )
        } catch {
            return OpenSSHKeyPlan(
                filename: filename,
                path: path,
                suggestedName: suggestedName,
                status: .parseFailed(message: error.localizedDescription),
                includeOnImport: false,
                passphrase: "",
                cachedKeyContents: nil
            )
        }
    }

    // MARK: - Jump host resolution

    /// Resolve a `ProxyJump` or `ProxyCommand` line into a `JumpHostSource`,
    /// capturing the parsed coordinates and sharing identity key plan IDs
    /// with the target. The real `SSHKey.id` substitution happens at apply.
    /// Returns a warning string if the directive is partially supported
    /// (multi-hop) or unparseable.
    private static func resolveJumpHost(
        entry: OpenSSHHostEntry,
        identityKeyPlanIDs: [UUID]
    ) -> (source: OpenSSHProfilePlan.JumpHostSource?, warning: String?) {
        if let proxyJump = entry.proxyJump, !proxyJump.isEmpty {
            // ProxyJump none is OpenSSH's "clear inherited proxy" sentinel.
            // No jump host should be created for this profile.
            if proxyJump.caseInsensitiveCompare("none") == .orderedSame {
                return (nil, nil)
            }

            // Multi-hop: take the first hop, warn about the rest.
            let hops = proxyJump.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let first = hops.first ?? proxyJump
            let parsed = parseProxyJumpHop(first)
            let warning: String? = hops.count > 1
                ? "Multi-hop ProxyJump for \(entry.aliases.first ?? "host") truncated to first hop (\(first))."
                : nil
            let portSuffix = parsed.port == 22 ? "" : ":\(parsed.port)"
            let display = "\(parsed.username ?? "")@\(parsed.host)\(portSuffix)"
            let source = OpenSSHProfilePlan.JumpHostSource(
                host: parsed.host,
                port: parsed.port,
                username: parsed.username ?? defaultUsername,
                identityKeyPlanIDs: identityKeyPlanIDs,
                display: display
            )
            return (source, warning)
        }

        if let proxyCommand = entry.proxyCommand, !proxyCommand.isEmpty {
            // `ssh -W %h:%p [user@]bastion` is exactly ProxyJump spelled the
            // old way, so it maps onto the supported jump host. Any other
            // ProxyCommand needs a local helper process, which this app has
            // no way to run.
            if let parsed = parseProxyCommandJumpHost(proxyCommand) {
                let portSuffix = parsed.port == 22 ? "" : ":\(parsed.port)"
                let display = "\(parsed.username ?? "")@\(parsed.host)\(portSuffix)"
                let source = OpenSSHProfilePlan.JumpHostSource(
                    host: parsed.host,
                    port: parsed.port,
                    username: parsed.username ?? defaultUsername,
                    identityKeyPlanIDs: identityKeyPlanIDs,
                    display: display
                )
                return (source, nil)
            }
            return (
                nil,
                "Unsupported ProxyCommand for \(entry.aliases.first ?? "host"): \(proxyCommand)"
            )
        }

        return (nil, nil)
    }

    /// A `[user@]host[:port]` hop parsed out of a ProxyJump entry.
    private struct ParsedJumpHost {
        let host: String
        let port: Int
        let username: String?
    }

    /// Extract a jump host from an `ssh -W %h:%p` style ProxyCommand — the
    /// pre-ProxyJump spelling of the same hop. Returns nil for any other
    /// ProxyCommand (those need a local helper process).
    ///
    /// Supported forms:
    /// - `ssh -W %h:%p user@jumphost`
    /// - `ssh -W %h:%p -p 2222 user@jumphost`
    /// - `ssh -W %h:%p jumphost -l user`
    private static func parseProxyCommandJumpHost(_ proxyCommand: String) -> ParsedJumpHost? {
        var input = proxyCommand.trimmingCharacters(in: .whitespaces)

        // Must start with ssh
        guard input.lowercased().hasPrefix("ssh ") else { return nil }
        input = String(input.dropFirst(4)).trimmingCharacters(in: .whitespaces)

        // Must contain -W %h:%p (the tunnel directive)
        guard input.contains("-W") && input.contains("%h:%p") else { return nil }

        // Remove the -W %h:%p part
        input = input.replacingOccurrences(of: "-W %h:%p", with: "")
            .replacingOccurrences(of: "-W%h:%p", with: "")
            .trimmingCharacters(in: .whitespaces)

        var host = ""
        var port = 22
        var username: String?

        let tokens = tokenizeProxyCommand(input)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]

            // Stop at shell subcommand syntax $(...) / backticks
            if token.hasPrefix("$(") || token.hasPrefix("`") { break }

            if token == "-p" && i + 1 < tokens.count {
                port = Int(tokens[i + 1]) ?? 22
                i += 2
            } else if token == "-l" && i + 1 < tokens.count {
                username = tokens[i + 1]
                i += 2
            } else if token.hasPrefix("-") {
                // Skip other options
                i += 1
            } else {
                // First non-option token is the jump host (user@host or host).
                // Split on the LAST @ so AD-style user@domain names survive.
                if let atIndex = token.lastIndex(of: "@") {
                    username = String(token[..<atIndex])
                    host = String(token[token.index(after: atIndex)...])
                } else {
                    host = token
                }
                break
            }
        }

        guard !host.isEmpty else { return nil }
        return ParsedJumpHost(host: host, port: port, username: username)
    }

    /// Whitespace tokenizer that honours single and double quotes.
    private static func tokenizeProxyCommand(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in input {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
            } else {
                switch char {
                case "\"", "'":
                    inQuote = true
                    quoteChar = char
                case " ", "\t":
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                default:
                    current.append(char)
                }
            }
        }

        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Parse a `[user@]host[:port]` hop (the format used by ProxyJump entries).
    private static func parseProxyJumpHop(_ raw: String) -> ParsedJumpHost {
        var host = raw.trimmingCharacters(in: .whitespaces)
        var port = 22
        var username: String? = nil
        if let atIdx = host.lastIndex(of: "@") {
            username = String(host[..<atIdx])
            host = String(host[host.index(after: atIdx)...])
        }
        if let colon = host.lastIndex(of: ":"), let parsedPort = Int(host[host.index(after: colon)...]) {
            port = parsedPort
            host = String(host[..<colon])
        }
        return ParsedJumpHost(host: host, port: port, username: username)
    }
}
