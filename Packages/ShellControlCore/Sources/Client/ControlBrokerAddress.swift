import Foundation

/// Address checks shared by the HTTP transport and the Mac CLI. Which Mac a
/// device talks to is decided by the pinned origin key, never by a URL
/// (spec.iphone-gateway.md section 7); these only keep plain HTTP to loopback.
public enum ControlBrokerAddress {
    /// The placeholder a build without a configured host carries. Clients
    /// must not dial it.
    public static let unconfiguredHost = "control.invalid"

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

    /// Scheme + host + port only, so paths and query strings cannot leak into
    /// API paths.
    public static func normalize(_ url: URL) -> URL? {
        guard isAcceptable(url), let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        // `URL.host` hands back an IPv6 literal unbracketed, and `URLComponents`
        // will not build a URL from one: it has to go back in brackets.
        let hostname = host.lowercased()
        components.host = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        components.port = url.port
        return components.url
    }
}
