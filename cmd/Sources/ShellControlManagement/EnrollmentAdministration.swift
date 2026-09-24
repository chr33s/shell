import Foundation
import ShellControlProtocol

/// An enrolled iPhone or Watch reviewer as the loopback admin API reports it.
/// Enrolled is not reachable: this says nothing about a live path.
public struct EnrolledDevice: Sendable, Equatable {
    public var deviceID: String
    public var platform: String
    public var label: String
    public var fingerprint: String
    public var gatewayDeviceID: String?
    /// Whether the Mac holds delivery material for it.
    public var push: Bool
    /// The iPhone's explicit remote-alert choice; nil from an older broker.
    public var alertsEnabled: Bool?

    public init(deviceID: String, platform: String, label: String, fingerprint: String,
                gatewayDeviceID: String? = nil, push: Bool = false, alertsEnabled: Bool? = nil) {
        self.deviceID = deviceID; self.platform = platform; self.label = label; self.fingerprint = fingerprint
        self.gatewayDeviceID = gatewayDeviceID; self.push = push; self.alertsEnabled = alertsEnabled
    }

    public var isWatch: Bool { gatewayDeviceID != nil }
    public var isIPhone: Bool { gatewayDeviceID == nil && platform == "iOS" }

    init?(json item: JSONValue) {
        guard let id = item["device_id"]?.stringValue, let platform = item["platform"]?.stringValue else { return nil }
        self.init(
            deviceID: id, platform: platform,
            label: DisplaySanitizer.sanitize(item["label"]?.stringValue ?? "", maxScalars: 120).text,
            fingerprint: item["key_fingerprint"]?.stringValue ?? "",
            gatewayDeviceID: item["gateway_device_id"]?.stringValue,
            push: item["push"]?.boolValue ?? false,
            alertsEnabled: item["alerts_enabled"]?.boolValue
        )
    }
}

/// An enrollment waiting for explicit confirmation on this Mac.
public struct PendingEnrollment: Sendable, Equatable {
    public var userCode: String
    public var platform: String
    public var label: String
    public var fingerprint: String
    /// For a Watch: the iPhone it will be reached through.
    public var gateway: String?
    public var rebinding: Bool
    public var requestedGrants: [String]

    public init(userCode: String, platform: String, label: String, fingerprint: String,
                gateway: String? = nil, rebinding: Bool = false, requestedGrants: [String] = []) {
        self.userCode = userCode; self.platform = platform; self.label = label; self.fingerprint = fingerprint
        self.gateway = gateway; self.rebinding = rebinding; self.requestedGrants = requestedGrants
    }

    public var isWatch: Bool { platform == "watchOS" }

    init?(json item: JSONValue) {
        guard let code = item["user_code"]?.stringValue, !code.isEmpty, code.count <= 16,
              let platform = item["platform"]?.stringValue, ["iOS", "watchOS"].contains(platform),
              let fingerprint = item["key_fingerprint"]?.stringValue,
              fingerprint.range(of: #"^[0-9A-F]{4}(-[0-9A-F]{4}){3}$"#, options: .regularExpression) != nil
        else { return nil }
        self.init(
            userCode: code, platform: platform,
            label: DisplaySanitizer.sanitize(item["label"]?.stringValue ?? "", maxScalars: 120).text,
            fingerprint: fingerprint,
            gateway: item["gateway"]?.stringValue.map { DisplaySanitizer.sanitize($0, maxScalars: 120).text },
            rebinding: item["rebinding"]?.boolValue ?? false,
            requestedGrants: item["requested_grants"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

/// The loopback admin calls guided setup, `doctor`, and `test-review` use.
/// Injectable so the guide's stages are tested without a broker.
public protocol EnrollmentAdministration: Sendable {
    func devices(port: Int, adminSecret: String) async throws -> [EnrolledDevice]
    func pending(port: Int, adminSecret: String) async throws -> [PendingEnrollment]
    /// The full description shown before confirming, including grants.
    func describe(userCode: String, port: Int, adminSecret: String) async throws -> PendingEnrollment
    func confirm(userCode: String, port: Int, adminSecret: String) async throws
}

public struct LiveEnrollmentAdministration: EnrollmentAdministration {
    public init() {}

    public func devices(port: Int, adminSecret: String) async throws -> [EnrolledDevice] {
        let value = try await ControlAdminClient(port: port, adminSecret: adminSecret).send(method: "GET", path: "/v1/admin/devices")
        return (value["devices"]?.arrayValue ?? []).compactMap(EnrolledDevice.init(json:))
    }

    public func pending(port: Int, adminSecret: String) async throws -> [PendingEnrollment] {
        let value = try await ControlAdminClient(port: port, adminSecret: adminSecret).send(method: "GET", path: "/v1/admin/pending")
        return (value["pending"]?.arrayValue ?? []).compactMap(PendingEnrollment.init(json:))
    }

    public func describe(userCode: String, port: Int, adminSecret: String) async throws -> PendingEnrollment {
        let value = try await ControlAdminClient(port: port, adminSecret: adminSecret)
            .send(method: "GET", path: "/v1/oauth/confirm", query: [("user_code", userCode)])
        guard var described = PendingEnrollment(json: value) ?? PendingEnrollment(json: Self.withCode(value, userCode)) else {
            throw ManagementError.unavailable("broker returned a malformed enrollment description")
        }
        described.userCode = userCode
        return described
    }

    public func confirm(userCode: String, port: Int, adminSecret: String) async throws {
        _ = try await ControlAdminClient(port: port, adminSecret: adminSecret).send(method: "POST", path: "/v1/oauth/confirm", body: .object([
            "user_code": .string(userCode), "approve": .bool(true)
        ]))
    }

    /// The iPhone description carries no `user_code`; add the one asked for.
    private static func withCode(_ value: JSONValue, _ code: String) -> JSONValue {
        guard var object = value.objectValue else { return value }
        object["user_code"] = .string(code)
        return .object(object)
    }
}
