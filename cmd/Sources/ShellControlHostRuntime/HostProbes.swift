import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

/// One HTTP GET, injectable so route verification and legacy detection are
/// testable without a network or a tailnet.
public protocol HostHTTPProbe: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data)
}

/// URLSession-backed probe: ephemeral, no cookies, no cache, no redirects to
/// another origin. The sandboxed host needs `network.client` for it.
public struct URLSessionHostProbe: HostHTTPProbe {
    public init() {}

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

// MARK: - Legacy standalone installation

/// A standalone Developer ID/CLI installation that already owns the port,
/// origin, or ledger (spec.agent-relay.md sections 19.1 and 19.8).
public struct LegacyConflict: Sendable, Equatable, CustomStringConvertible {
    public enum Evidence: String, Sendable, Equatable {
        /// `~/.local/state/shell-control` holds a live daemon socket.
        case liveStandaloneDaemon = "live_standalone_daemon"
        /// A Shell Control broker that is not this host answers on the port.
        case standaloneBrokerOnPort = "standalone_broker_on_port"
        /// Something else listens on the port.
        case portInUse = "port_in_use"
    }

    public let evidence: Evidence
    public let detail: String

    public var description: String { detail }

    /// What the user can do about it; the host never stops another
    /// installation itself (spec 19.8).
    public var remedy: String {
        switch evidence {
        case .liveStandaloneDaemon, .standaloneBrokerOnPort:
            "Stop the standalone installation with `shell-control down` (and `shell-control service uninstall` to keep it stopped at login), then enable Control again. Migrating its pairings needs an explicit export/import; until then, pair again."
        case .portInUse:
            "Free loopback port or choose another broker port, then enable Control again."
        }
    }
}

/// Detects a standalone installation before the host claims any authority.
/// The host never runs a second authority beside one (spec A49).
public struct LegacyInstallationDetector: Sendable {
    let probe: any HostHTTPProbe
    /// The standalone state directory. In the App Sandbox the host usually
    /// cannot read it; that evidence is then simply absent and the port probe
    /// still guards the shared loopback port.
    let standaloneStateDirectory: URL?

    public init(probe: any HostHTTPProbe = URLSessionHostProbe(), standaloneStateDirectory: URL? = LegacyInstallationDetector.defaultStandaloneStateDirectory()) {
        self.probe = probe
        self.standaloneStateDirectory = standaloneStateDirectory
    }

    /// `~/.local/state/shell-control` of the real user, from the password
    /// database rather than `$HOME`, which the sandbox redirects.
    public static func defaultStandaloneStateDirectory() -> URL? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".local/state/shell-control")
    }

    /// - Parameters:
    ///   - port: the loopback port the host is about to bind.
    ///   - ownServiceIdentity: the host broker's own identity, which is not a
    ///     conflict (a restart racing its own previous listener).
    public func detect(port: UInt16, ownServiceIdentity: String) async -> LegacyConflict? {
        if let standaloneStateDirectory {
            let installation = standaloneStateDirectory.appendingPathComponent("installation.json")
            let socket = standaloneStateDirectory.appendingPathComponent("control.sock").path
            if FileManager.default.isReadableFile(atPath: installation.path),
               UnixSocketServer(path: socket).isServedByLiveInstance() {
                return LegacyConflict(
                    evidence: .liveStandaloneDaemon,
                    detail: "A standalone Shell Control installation is running from \(standaloneStateDirectory.path)."
                )
            }
        }
        return await probePort(port, ownServiceIdentity: ownServiceIdentity)
    }

    func probePort(_ port: UInt16, ownServiceIdentity: String) async -> LegacyConflict? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/capabilities") else { return nil }
        guard let (status, body) = try? await probe.get(url, timeout: 2) else {
            // Nothing answered: the port is free as far as HTTP can tell. A
            // non-HTTP listener is still caught when the bind fails.
            return nil
        }
        if status == 200, let json = try? JSONValue.parse(body), var reader = try? JSONReader(json),
           let identity = try? reader.string("service_identity", maxLength: 200) {
            if identity == ownServiceIdentity { return nil }
            return LegacyConflict(
                evidence: .standaloneBrokerOnPort,
                detail: "A Shell Control broker (\(identity)) already serves 127.0.0.1:\(port)."
            )
        }
        return LegacyConflict(evidence: .portInUse, detail: "Another program already listens on 127.0.0.1:\(port).")
    }
}

// MARK: - Tailscale route verification

/// Verifies the user-configured Tailscale Serve route by asking it for an
/// origin proof and checking the signature under this host's origin key.
///
/// The sandboxed host never runs the `tailscale` CLI or edits another
/// application's settings; the user configures Serve outside Shell and the host
/// only observes the result through a permitted interface (spec 19.7, A48).
public struct TailscaleRouteVerifier: Sendable {
    let probe: any HostHTTPProbe

    public init(probe: any HostHTTPProbe = URLSessionHostProbe()) {
        self.probe = probe
    }

    /// Accepts `name.tailnet.ts.net`, `https://name.tailnet.ts.net`, or the
    /// same with a trailing slash, and returns the normalized origin route.
    public static func normalize(_ text: String) throws -> OriginRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= ControlHostWire.maximumRouteLength + 8 else {
            throw ValidationError.invalid("route", "enter this Mac's MagicDNS name")
        }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let route = try OriginRoute(withScheme)
        return route
    }

    public func verify(_ text: String, origin: OriginIdentity?, now: Date = Date()) async -> ControlHostRouteStatus {
        func unavailable(_ url: String?, _ reason: ControlHostRouteStatus.Reason, _ detail: String) -> ControlHostRouteStatus {
            ControlHostRouteStatus(state: .unavailable, url: url, reason: reason, detail: detail, checkedAt: now)
        }
        let route: OriginRoute
        do {
            route = try Self.normalize(text)
        } catch {
            return unavailable(nil, .invalidName, "Not a Tailscale HTTPS name (https://<mac>.<tailnet>.ts.net): \(error)")
        }
        let urlText = route.url.absoluteString
        guard let origin else {
            return unavailable(urlText, .noOriginIdentity, "This host has no origin identity yet.")
        }
        let nonce = OriginProof.freshNonce()
        var components = URLComponents(url: route.url.appendingPathComponent("v1/origin/proof"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        guard let proofURL = components?.url else {
            return unavailable(urlText, .invalidName, "Cannot build the proof URL.")
        }
        let status: Int, body: Data
        do {
            (status, body) = try await probe.get(proofURL, timeout: 8)
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
                return unavailable(urlText, .tlsFailure, "TLS failed for \(route.url.host ?? urlText); enable HTTPS certificates for the tailnet.")
            default:
                return unavailable(urlText, .unreachable, "Cannot reach \(urlText): is Tailscale connected and Serve configured for this Mac? (\(error.code.rawValue))")
            }
        } catch {
            return unavailable(urlText, .unreachable, "Cannot reach \(urlText): \(error)")
        }
        guard status == 200 else {
            return unavailable(urlText, .httpStatus, "\(urlText) answered HTTP \(status); point Tailscale Serve HTTPS 443 at this host's loopback broker.")
        }
        let proof: OriginProof
        do {
            proof = try OriginProof(unverified: try JSONValue.parse(body))
        } catch {
            return unavailable(urlText, .notShellBroker, "\(urlText) does not serve a Shell Control origin proof.")
        }
        do {
            try proof.verify(expected: origin, nonce: nonce)
        } catch {
            return unavailable(urlText, .originMismatch, "\(urlText) reaches a different Shell Control origin, not this host.")
        }
        return ControlHostRouteStatus(state: .verified, url: urlText, checkedAt: now)
    }
}
