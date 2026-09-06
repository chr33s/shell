//
//  SSHURLParser.swift
//  shell
//
//  Parses ssh:// and ssh: URL schemes into connection components
//

import Foundation

/// Parsed components from an SSH URL
struct SSHURLComponents: Sendable {
    let host: String

    /// The port the URL actually named, or `nil` when it named none.
    ///
    /// Kept distinct from the 22 default: collapsing "no port" into 22 made an
    /// `ssh://host` deep link indistinguishable from `ssh://host:22`, so the
    /// deep-link handler overwrote the custom port of the saved profile it
    /// matched and connected to :22. Callers that merge into an existing
    /// profile must apply this only when it is non-nil.
    let explicitPort: Int?

    let username: String?

    /// The port to connect to, falling back to 22 when the URL named none.
    /// Correct for a fresh connection; use `explicitPort` when merging into a
    /// configuration that already has a port.
    var port: Int { explicitPort ?? 22 }
}

/// Parser for SSH URL schemes
///
/// Supports both standard and non-standard formats:
/// - `ssh://user@host:port` (RFC 4819 standard)
/// - `ssh://host:port` (no user)
/// - `ssh:user@host:port` (without double slash)
/// - `ssh:host` (minimal)
enum SSHURLParser {

    /// Parse an SSH URL into components
    /// - Parameter url: The URL to parse (must have `ssh` scheme)
    /// - Returns: Parsed components, or nil if URL is invalid
    static func parse(_ url: URL) -> SSHURLComponents? {
        guard url.scheme?.lowercased() == "ssh" else {
            return nil
        }

        // Standard format: ssh://user@host:port
        // URL class parses this correctly
        if let host = url.host, !host.isEmpty {
            return SSHURLComponents(
                host: host,
                // Foundation defines no default port for the `ssh` scheme, so a
                // nil `url.port` means the URL named no port at all.
                explicitPort: url.port,
                username: url.user?.isEmpty == false ? url.user : nil
            )
        }

        // Non-standard format: ssh:user@host:port (no double slash)
        // URL class treats everything after "ssh:" as the path
        // We need to parse it manually
        if let path = url.path.isEmpty ? nil : url.path,
           let components = parsePathAsHostSpec(path) {
            return components
        }

        // Try opaque part for ssh:host format
        if let opaque = url.absoluteString.dropFirst("ssh:".count).description.removingPercentEncoding,
           !opaque.isEmpty,
           !opaque.hasPrefix("//") {
            return parsePathAsHostSpec(opaque)
        }

        return nil
    }

    /// Parse a path string as user@host:port
    private static func parsePathAsHostSpec(_ spec: String) -> SSHURLComponents? {
        var remaining = spec.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !remaining.isEmpty else {
            return nil
        }

        // Extract username if present (before last @ — allows @ in username)
        var username: String?
        if let atIndex = remaining.lastIndex(of: "@") {
            let user = String(remaining[..<atIndex])
            if !user.isEmpty {
                username = user
            }
            remaining = String(remaining[remaining.index(after: atIndex)...])
        }

        guard !remaining.isEmpty else {
            return nil
        }

        // Extract port if present (after last :)
        // Be careful with IPv6 addresses (multiple colons)
        var host: String
        // Left nil unless the spec actually names a port, so "no port" stays
        // distinguishable from an explicit ":22".
        var explicitPort: Int?

        // Check for IPv6 address in brackets: [::1]:port
        if remaining.hasPrefix("[") {
            if let closeBracket = remaining.firstIndex(of: "]") {
                host = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket])
                let afterBracket = remaining.index(after: closeBracket)
                if afterBracket < remaining.endIndex {
                    let portPart = String(remaining[afterBracket...])
                    if portPart.hasPrefix(":"), let portNum = Int(portPart.dropFirst()) {
                        explicitPort = portNum
                    }
                }
            } else {
                // Malformed IPv6
                return nil
            }
        } else {
            // Regular hostname or IPv4
            // Port is after the last colon
            if let colonIndex = remaining.lastIndex(of: ":") {
                let potentialPort = String(remaining[remaining.index(after: colonIndex)...])
                if let portNum = Int(potentialPort), portNum > 0, portNum <= 65535 {
                    host = String(remaining[..<colonIndex])
                    explicitPort = portNum
                } else {
                    // Not a valid port number, treat whole thing as host
                    host = remaining
                }
            } else {
                host = remaining
            }
        }

        guard !host.isEmpty else {
            return nil
        }

        return SSHURLComponents(
            host: host,
            explicitPort: explicitPort,
            username: username
        )
    }
}

// MARK: - Delivery

extension Notification.Name {
    /// Posted when an `ssh://` URL is opened. `userInfo[SSHURLPayload.key]`
    /// carries the parsed components.
    static let sshURLReceived = Notification.Name("dev.chr33s.shell.sshURLReceived")
}

/// Boxes `SSHURLComponents` for `Notification.userInfo`.
struct SSHURLPayload: Sendable {
    static let key = "components"
    let components: SSHURLComponents
}
