import Foundation

/// The control broker URL is a deployment choice. A build may bake one in; a
/// pairing QR or paste may override it at runtime. Changing it requires
/// re-enrollment and clearing the old cache (spec.watch.md section 5).
public enum ControlBrokerAddress {
    /// The placeholder a build without a configured broker carries. Clients
    /// must not dial it.
    public static let unconfiguredHost = "control.invalid"

    /// Where a client remembers the broker it last enrolled against, so a
    /// later build pointing somewhere else can wipe the old identity.
    public static let defaultsKey = "dev.chr33s.shell.control.broker-url"

    /// User-paired broker, set by a QR / paste / `shell-control://pair` link.
    /// Takes precedence over the baked Info.plist value.
    public static let runtimeDefaultsKey = "dev.chr33s.shell.control.broker-url.runtime"

    public static let pairingScheme = "shell-control"

    public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Accepts HTTPS everywhere, and plain HTTP only on loopback — the one
    /// case `URLSessionTransport` will send without TLS.
    public static func isAcceptable(_ url: URL) -> Bool {
        guard let host = url.host, host != unconfiguredHost else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return isLoopbackHost(host)
        default: return false
        }
    }

    /// Accepts a bare host, `host:port`, or a bracketed IPv6 literal. Brackets
    /// come off first: splitting on `:` up front turned `[::1]:8443` into `[`.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var hostname = host
        if hostname.hasPrefix("["), let end = hostname.firstIndex(of: "]") {
            hostname = String(hostname[hostname.index(after: hostname.startIndex)..<end])
        } else if hostname.filter({ $0 == ":" }).count == 1,
                  let colon = hostname.firstIndex(of: ":"),
                  hostname[hostname.index(after: colon)...].allSatisfy(\.isNumber) {
            hostname = String(hostname[..<colon])
        }
        return loopbackHosts.contains(hostname.lowercased())
    }

    /// Scheme + host + port only, so `/pair` and query strings cannot leak
    /// into API paths.
    public static func normalize(_ url: URL) -> URL? {
        guard isAcceptable(url), let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        // `URL.host` hands back an IPv6 literal unbracketed, and `URLComponents`
        // will not build a URL from one: it has to go back in brackets.
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = url.port
        return components.url
    }

    public static func url(from infoDictionaryValue: Any?) -> URL? {
        guard let text = infoDictionaryValue as? String, let url = URL(string: text) else { return nil }
        return normalize(url)
    }

    public static func effective(runtime stored: String?, baked: URL?) -> URL? {
        if let stored, let url = URL(string: stored), let normalized = normalize(url) {
            return normalized
        }
        return baked
    }

    /// First launch has nothing stored and must not look like a change — but
    /// only when nothing is enrolled either. Keychain items outlive an app
    /// delete while `UserDefaults` does not, so a reinstall that pairs with a
    /// different broker arrives here with `stored == nil` and a live session
    /// for the previous host; treating that as unchanged would present the old
    /// broker's tokens to the new one.
    public static func hasChanged(from stored: String?, to url: URL, hasCredentials: Bool = false) -> Bool {
        guard let stored else { return hasCredentials }
        return stored != url.absoluteString
    }

    /// `shell-control://pair?broker=https://…` with the broker percent-encoded.
    public static func pairingLink(broker: URL, token: String? = nil) -> URL? {
        guard let broker = normalize(broker) else { return nil }
        var components = URLComponents()
        components.scheme = pairingScheme
        components.host = "pair"
        var items = [URLQueryItem(name: "broker", value: broker.absoluteString)]
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        return components.url
    }

    public static func pairingToken(from url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let token = items?.first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty, token.count <= 32,
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return token
    }

    /// Deep links only: `shell-control://pair?…` or `https://host/pair`.
    /// A raw HTTPS URL is not treated as a pairing link so `onOpenURL` cannot
    /// steal unrelated opens.
    public static func parsePairingLink(_ url: URL) -> URL? {
        if url.scheme?.lowercased() == pairingScheme { return parsePairing(url) }
        let path = url.path
        if path == "/pair" || path.hasPrefix("/pair/") { return parsePairing(url) }
        return nil
    }

    /// Accepts a pairing link, a broker `/pair` page, or a raw acceptable
    /// broker URL (what a tester pastes from the CLI).
    public static func parsePairing(_ url: URL) -> URL? {
        if url.scheme?.lowercased() == pairingScheme {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let raw = items?.first(where: { $0.name == "broker" })?.value,
                  let broker = URL(string: raw)
            else { return nil }
            return normalize(broker)
        }
        let path = url.path
        if path == "/pair" || path.hasPrefix("/pair/") {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            if let raw = items?.first(where: { $0.name == "broker" })?.value, let broker = URL(string: raw) {
                return normalize(broker)
            }
            return normalize(url)
        }
        return normalize(url)
    }

    public static func parsePairing(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return parsePairing(url)
    }
}
