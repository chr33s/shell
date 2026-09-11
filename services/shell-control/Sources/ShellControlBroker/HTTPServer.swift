import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A minimal HTTP/1.1 server.
///
/// The broker must be reachable over authenticated HTTPS; this listener speaks
/// plain HTTP and is intended to run behind a TLS-terminating reverse proxy, or
/// on loopback for development (spec.watch.md section 3).
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: [String: String]
        public let headers: [String: String]
        public let body: Data

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let port: UInt16
    private let bindLoopback: Bool
    private let handler: Handler
    private var listenSocket: Int32 = -1

    public init(port: UInt16, bindLoopback: Bool = true, handler: @escaping Handler) {
        self.port = port
        self.bindLoopback = bindLoopback
        self.handler = handler
    }

    public enum ServerError: Error, Sendable, CustomStringConvertible {
        case bind(Int32)
        case listen(Int32)

        public var description: String {
            switch self {
            case .bind(let code):
                // EADDRINUSE is the one a developer hits constantly, so name it
                // rather than printing a bare errno.
                let reason = code == EADDRINUSE
                    ? "the port is already in use — another broker is probably running"
                    : String(cString: strerror(code))
                return "cannot bind the listening socket: \(reason)"
            case .listen(let code):
                return "cannot listen on the socket: \(String(cString: strerror(code)))"
            }
        }
    }

    public func start() throws {
        listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        var enable: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        // Loopback by default: cloudflared is the only public ingress. Binding
        // INADDR_ANY would expose admin routes and /pair to the LAN.
        address.sin_addr.s_addr = bindLoopback ? inet_addr("127.0.0.1") : INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ServerError.bind(errno) }
        guard listen(listenSocket, 64) == 0 else { throw ServerError.listen(errno) }
    }

    public func acceptLoop() {
        while true {
            let client = accept(listenSocket, nil, nil)
            if client < 0 { continue }
            // A detached thread per connection rather than a shared pool: a
            // handler may block for the whole of a `wait=30` long poll, and a
            // bounded pool would stop serving short foreground control
            // requests once enough long polls were in flight.
            Thread.detachNewThread { [handler] in
                defer { close(client) }
                guard let request = HTTPServer.readRequest(client) else {
                    HTTPServer.write(client, Response(status: 400, body: Data("bad request".utf8)))
                    return
                }
                let semaphore = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var response = Response(status: 500)
                Task {
                    response = await handler(request)
                    semaphore.signal()
                }
                semaphore.wait()
                HTTPServer.write(client, response)
            }
        }
    }

    public func stop() {
        if listenSocket >= 0 { close(listenSocket) }
    }

    // MARK: Parsing

    private static func readRequest(_ client: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let read = recv(client, &chunk, chunk.count, 0)
            if read <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<read])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            // Cap the header section so a peer cannot stream headers forever.
            if buffer.count > 64 * 1024 { return nil }
        }
        guard let headerEnd else { return nil }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        var body = Data(buffer[headerEnd.upperBound...])
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= 1 << 20 else { return nil }
        while body.count < contentLength {
            let read = recv(client, &chunk, chunk.count, 0)
            if read <= 0 { break }
            body.append(contentsOf: chunk[0..<read])
        }
        let (path, query) = parseTarget(target)
        return Request(method: method, path: path, query: query, headers: headers, body: body)
    }

    /// Splits a request target into its path and query.
    ///
    /// `split` drops empty subsequences, so a pair that is just "=" yields no
    /// parts at all: indexing it would let an unauthenticated request take the
    /// process down.
    static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let rawName = parts.first else { continue }
            let name = String(rawName).removingPercentEncoding ?? String(rawName)
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            query[name] = value
        }
        return (String(target[target.startIndex..<mark]), query)
    }

    private static func write(_ client: Int32, _ response: Response) {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        out.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let written = send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if written <= 0 { return }
                sent += written
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 412: return "Precondition Failed"
        case 422: return "Unprocessable Content"
        case 423: return "Locked"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return status < 500 ? "Client Error" : "Server Error"
        }
    }
}
