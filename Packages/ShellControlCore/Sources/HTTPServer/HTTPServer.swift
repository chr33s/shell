import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellControlProtocol
import Synchronization

/// A minimal HTTP/1.1 server, shared by the broker and the push relay.
///
/// It speaks plain HTTP and is intended to run on loopback behind a
/// TLS-terminating proxy: Tailscale Serve for the Mac-local broker
/// (docs/specs/control-protocol.md section 2.3), or the relay's hosting front end.
public final class HTTPServer: Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: [String: String]
        public let headers: [String: String]
        public let body: Data
        /// The connected peer's IP address, when known. Behind a proxy this is
        /// the proxy.
        public let peerAddress: String?

        public init(
            method: String,
            path: String,
            query: [String: String] = [:],
            headers: [String: String] = [:],
            body: Data = Data(),
            peerAddress: String? = nil
        ) {
            self.peerAddress = peerAddress
            self.method = method
            self.path = path
            self.query = query
            self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
            self.body = body
        }

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
    private let listener = Mutex<(socket: Int32, stopped: Bool)>((-1, false))

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
        let listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        listener.withLock { $0.socket = listenSocket }
        var enable: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        // Loopback by default: Tailscale Serve (or, in the legacy profile,
        // cloudflared) is the only ingress. Binding INADDR_ANY would expose
        // admin routes to the LAN.
        address.sin_addr.s_addr = bindLoopback ? inet_addr("127.0.0.1") : INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ServerError.bind(errno) }
        guard listen(listenSocket, 64) == 0 else { throw ServerError.listen(errno) }
    }

    public func acceptLoop() {
        while true {
            let (socket, done) = listener.withLock { ($0.socket, $0.stopped) }
            if done { return }
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socket, $0, &peerLength) }
            }
            if client < 0 {
                // A persistent accept failure (EMFILE when the process is out
                // of descriptors, say) would otherwise spin this loop at 100%
                // CPU. Yield briefly so the condition can clear.
                if errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM {
                    usleep(50_000)
                }
                continue
            }
            // Slowloris protection: a peer that opens a connection and then
            // stalls would otherwise pin a read forever. Both directions time out.
            HTTPServer.setTimeouts(client)
            // One task per connection. Long polls suspend (`Task.sleep`); they
            // must not occupy a thread, or enough of them would stop short
            // requests from being served. Blocking `recv`/`send` hop to a
            // per-connection queue (`BlockingIO`) and resume a continuation —
            // the accept thread never waits on the handler.
            let handler = self.handler
            let peerAddress = HTTPServer.address(peer)
            Task {
                await HTTPServer.serve(client: client, peerAddress: peerAddress, handler: handler)
            }
        }
    }

    private static func serve(client: Int32, peerAddress: String?, handler: Handler) async {
        defer { close(client) }
        let io = BlockingIO(label: "dev.chr33s.shell.http.connection")
        guard let request = await io.perform({ readRequest(client, peer: peerAddress) }) else {
            await io.perform { write(client, Response(status: 400, body: Data("bad request".utf8))) }
            return
        }
        let response = await handler(request)
        await io.perform { write(client, response) }
    }

    public func stop() {
        let socket = listener.withLock { state in
            defer { state = (-1, true) }
            return state.socket
        }
        if socket >= 0 { close(socket) }
    }

    // MARK: Parsing

    /// Per-connection receive and send deadlines. A request has to arrive, and
    /// a response has to be accepted, within this window; the handler itself is
    /// not covered, so a `wait=30` long poll is unaffected.
    private static let connectionTimeout = timeval(tv_sec: 30, tv_usec: 0)

    private static func setTimeouts(_ client: Int32) {
        var timeout = connectionTimeout
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    private static func address(_ peer: sockaddr_in) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = peer.sin_addr
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func readRequest(_ client: Int32, peer: String?) -> Request? {
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
        guard let contentLength = Int(headers["content-length"] ?? "0"), contentLength >= 0 else { return nil }
        guard contentLength <= 1 << 20 else { return nil }
        while body.count < contentLength {
            let read = recv(client, &chunk, chunk.count, 0)
            // A body that stops short of `Content-Length` is a truncated
            // request, not a short one: handing the handler a partial document
            // would let a peer choose which members a parser sees.
            if read <= 0 { return nil }
            body.append(contentsOf: chunk[0..<read])
        }
        // A pipelined or over-long write can leave bytes past the declared
        // body in the same buffer; they belong to no request this server will
        // serve, so they never reach the handler.
        if body.count > contentLength { body = Data(body.prefix(contentLength)) }
        let (path, query) = parseTarget(target)
        return Request(method: method, path: path, query: query, headers: headers, body: body, peerAddress: peer)
    }

    /// Splits a request target into its path and query.
    ///
    /// `split` drops empty subsequences, so a pair that is just "=" yields no
    /// parts at all: indexing it would let an unauthenticated request take the
    /// process down.
    public static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
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
