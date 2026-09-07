import Foundation
import ShellControlProtocol

public struct ControlHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [(String, String)]
    public var headers: [String: String]
    public var body: Data?
    /// Long-polling reads use a longer timeout than short foreground control
    /// requests (spec.watch.md section 7).
    public var timeout: TimeInterval

    public init(
        method: String,
        path: String,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct ControlHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public protocol ControlHTTPTransport: Sendable {
    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse
}

public enum TransportError: Error, Sendable, Equatable {
    case offline
    case invalidURL
    case nonHTTPResponse
    case responseTooLarge(Int)
}

/// `URLSession` HTTPS for reads and short, foreground control requests. There
/// is no always-open socket and no background polling loop
/// (spec.watch.md section 7).
public struct URLSessionTransport: ControlHTTPTransport {
    private let session: URLSession
    private let maxResponseBytes: Int

    public init(session: URLSession = .shared, maxResponseBytes: Int = 1 << 20) {
        self.session = session
        self.maxResponseBytes = maxResponseBytes
    }

    public func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: false) else {
            throw TransportError.invalidURL
        }
        if !request.query.isEmpty {
            components.queryItems = request.query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url, url.scheme?.lowercased() == "https" || url.host == "localhost" else {
            // The broker is reachable over authenticated HTTPS; a plain-HTTP
            // base URL is only tolerated for a loopback development broker.
            throw TransportError.invalidURL
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw TransportError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw TransportError.nonHTTPResponse }
        guard data.count <= maxResponseBytes else { throw TransportError.responseTooLarge(data.count) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return ControlHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
