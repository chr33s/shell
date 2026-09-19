import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShellControlClient
import ShellControlHostSupport
import ShellControlProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ControlAdminClient: Sendable {
    public let baseURL: URL
    private let adminSecret: String
    private let transport: any ControlHTTPTransport

    public init(port: Int, adminSecret: String, transport: any ControlHTTPTransport = URLSessionTransport()) {
        baseURL = URL(string: ControlLoopback.url(port: port))!
        self.adminSecret = adminSecret; self.transport = transport
    }

    public func send(method: String, path: String, query: [(String, String)] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let data = try body.map(JSONCanonicalization.canonicalize)
        let response = try await transport.send(ControlHTTPRequest(
            method: method, path: path, query: query,
            headers: ["Authorization": "Admin \(adminSecret)", "Content-Type": "application/json", "Cache-Control": "no-store"],
            body: data, timeout: 8
        ), baseURL: baseURL)
        guard response.isSuccess else {
            let detail = String(decoding: response.body.prefix(200), as: UTF8.self)
            throw ManagementError.unavailable("\(method) \(path) returned HTTP \(response.status): \(detail)")
        }
        guard !response.body.isEmpty else { throw ManagementError.unavailable("\(method) \(path) returned an empty response") }
        do { return try JSONValue.parse(response.body) } catch { throw ManagementError.unavailable("\(method) \(path) returned invalid JSON") }
    }

    public func provisionOrigin(label: String, originID: UUID, originSecret: String) async throws {
        let value = try await send(method: "POST", path: "/v1/admin/origins", body: .object([
            "label": .string(label),
            "origin_id": .string(originID.uuidString.lowercased()),
            "origin_secret": .string(originSecret)
        ]))
        var reader = try JSONReader(value)
        let returned = try reader.id("origin_id")
        guard returned.rawValue == originID.uuidString.lowercased() else {
            throw ManagementError.unavailable("broker reconciled a different origin identity")
        }
    }
}

public struct ComponentObservation: Codable, Sendable, Equatable {
    public var state: String
    public var checkedAt: String
    public var reason: String?
    public var pid: Int?
    public var mode: String?
    public var recoveryPending: Int?
    enum CodingKeys: String, CodingKey {
        case state, checkedAt = "checked_at", reason, pid, mode, recoveryPending = "recovery_pending"
    }
}

public struct ManagementStatus: Codable, Sendable {
    public var schema = "shell-control.status/1"
    public var overall: String
    public var readinessScope: String
    public var desiredState: String
    public var persistent: Bool
    public var publicURL: String?
    public var components: [String: ComponentObservation]
    public var origin: OriginSummary?
    public var enrollment: EnrollmentSummary?
    enum CodingKeys: String, CodingKey {
        case schema, overall, readinessScope = "readiness_scope", desiredState = "desired_state"
        case persistent, publicURL = "public_url", components, origin, enrollment
    }

    public init(overall: String, readinessScope: String, desiredState: String, persistent: Bool,
                publicURL: String?, components: [String: ComponentObservation]) {
        self.overall = overall; self.readinessScope = readinessScope; self.desiredState = desiredState
        self.persistent = persistent; self.publicURL = publicURL; self.components = components
    }
}

/// The Shell origin identity: what a phone pins. The route is separate.
public struct OriginSummary: Codable, Sendable, Equatable {
    public var originID: String
    public var fingerprint: String
    enum CodingKeys: String, CodingKey { case originID = "origin_id", fingerprint }
}

/// Enrolled devices by role, as `shell-control status` reports them
/// (spec.iphone-gateway.md section 25.2).
public struct EnrollmentSummary: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public var deviceID: String
        public var platform: String
        public var label: String
        public var fingerprint: String
        public var gatewayDeviceID: String?
        public var push: Bool
        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id", platform, label, fingerprint = "key_fingerprint"
            case gatewayDeviceID = "gateway_device_id", push
        }
    }

    public var iphones: [Device]
    public var watches: [Device]
    public var pendingApprovals: Int
    enum CodingKeys: String, CodingKey { case iphones, watches, pendingApprovals = "pending_approvals" }

    public init(adminDevices value: JSONValue) {
        let devices = (value["devices"]?.arrayValue ?? []).compactMap { item -> Device? in
            guard let id = item["device_id"]?.stringValue, let platform = item["platform"]?.stringValue else { return nil }
            return Device(
                deviceID: id, platform: platform,
                label: DisplaySanitizer.sanitize(item["label"]?.stringValue ?? "", maxScalars: 120).text,
                fingerprint: item["key_fingerprint"]?.stringValue ?? "",
                gatewayDeviceID: item["gateway_device_id"]?.stringValue,
                push: item["push"]?.boolValue ?? false
            )
        }
        iphones = devices.filter { $0.gatewayDeviceID == nil && $0.platform == "iOS" }
        watches = devices.filter { $0.gatewayDeviceID != nil }
        pendingApprovals = value["pending_approvals"]?.intValue ?? 0
    }
}

public enum HealthChecks {
    public static func broker(url: URL, expectedIdentity: String, timeout: TimeInterval = 4,
                              transport: any ControlHTTPTransport = URLSessionTransport()) async -> ComponentObservation {
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            let response = try await transport.send(ControlHTTPRequest(
                method: "GET", path: "/v1/capabilities", headers: ["Cache-Control": "no-store"], timeout: timeout
            ), baseURL: url)
            guard response.status == 200,
                  let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  (object["protocol_versions"] as? [String])?.contains("shell-control/1") == true,
                  object["service_identity"] as? String == expectedIdentity else {
                return .init(state: "not_ready", checkedAt: stamp, reason: "protocol or installation identity mismatch")
            }
            return .init(state: "ready", checkedAt: stamp)
        } catch { return .init(state: "not_ready", checkedAt: stamp, reason: String(describing: error)) }
    }

    public static func daemon(path: String) async -> ComponentObservation {
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            let client = UnixHealthClient(path: path)
            let data = try await client.read(timeout: 2)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["store_loaded"] as? Bool == true, object["ipc_responsive"] as? Bool == true else {
                return .init(state: "not_ready", checkedAt: stamp, reason: "invalid daemon health response")
            }
            let state = object["state"] as? String ?? "not_ready"
            return .init(state: state, checkedAt: stamp, reason: state == "ready" ? nil : "daemon is \(state)",
                         recoveryPending: object["recovery_pending"] as? Int)
        } catch { return .init(state: "not_ready", checkedAt: stamp, reason: String(describing: error)) }
    }
}

private struct UnixHealthClient: Sendable {
    let path: String
    func read(timeout: TimeInterval) async throws -> Data {
        try await Task.detached {
            let client = UnixSocketClient(path: path)
            let fd = try client.connect(); defer { close(fd) }
            var value = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &bytes, bytes.count, 0)
                if count <= 0 { break }
                guard data.count + count <= 65_536 else { throw ManagementError.unavailable("health response too large") }
                data.append(contentsOf: bytes.prefix(count))
            }
            guard !data.isEmpty else { throw ManagementError.unavailable("health socket unavailable") }
            return data
        }.value
    }
}
