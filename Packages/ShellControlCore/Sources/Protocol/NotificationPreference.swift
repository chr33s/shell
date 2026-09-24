import Foundation

/// One iPhone's remote-alert preference as the Mac holds it:
/// `GET`/`PUT /v1/devices/me/notification-preference`
/// (spec.control-companion-setup.md section 10.3).
///
/// It changes notification delivery only, never reviewer authorization. A
/// record with no stored preference reports version 0 with its legacy
/// effective value, so a migrated installation keeps its prior eligibility
/// until the user explicitly changes it.
public struct NotificationPreference: Sendable, Hashable {
    public static let path = "/v1/devices/me/notification-preference"

    public let enabled: Bool
    public let version: Int64

    public init(enabled: Bool, version: Int64) {
        self.enabled = enabled
        self.version = version
    }

    public var json: JSONValue {
        .object(["enabled": .bool(enabled), "version": .number(.int(version))])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        enabled = try reader.bool("enabled")
        version = try reader.integer("version")
        guard version >= 0 else { throw ValidationError.invalid("version", "must be nonnegative") }
        try reader.rejectUnknownMembers()
    }
}

/// The body of `PUT /v1/devices/me/notification-preference`: a
/// compare-and-set on the version the client last observed, so a delayed
/// enable can never undo a later disable.
public struct NotificationPreferenceUpdate: Sendable, Hashable {
    public let enabled: Bool
    public let expectedVersion: Int64

    public init(enabled: Bool, expectedVersion: Int64) {
        self.enabled = enabled
        self.expectedVersion = expectedVersion
    }

    public var json: JSONValue {
        .object(["enabled": .bool(enabled), "expected_version": .number(.int(expectedVersion))])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        enabled = try reader.bool("enabled")
        expectedVersion = try reader.integer("expected_version")
        guard expectedVersion >= 0 else { throw ValidationError.invalid("expected_version", "must be nonnegative") }
        try reader.rejectUnknownMembers()
    }
}

extension ControlFeature {
    /// Advertised by a broker that serves the per-device notification
    /// preference. Its absence is how a client tells an older host apart.
    public static let notificationPreference = "notification.preference.v1"
}
