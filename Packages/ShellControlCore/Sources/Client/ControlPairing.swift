import Foundation
import ShellControlProtocol

/// A WatchConnectivity payload for setup assistance. It is replaceable latest
/// state, never the decision ledger, and must not carry private keys, session
/// tokens, or origin secrets (spec.watch.md sections 5 and 7).
public struct ControlPairingMessage: Sendable, Hashable {
    public static let messageType = "control.pairing.v1"
    /// Single key in a `WCSession` application context. The value is a
    /// canonical JSON document so unknown members fail closed.
    public static let applicationContextKey = "shell-control-pairing"

    public var brokerURL: URL
    /// When true, a Watch that still needs enrollment should start it.
    public var startEnrollment: Bool
    public var enrollment: EnrollmentReference?

    public struct EnrollmentReference: Sendable, Hashable {
        public var userCode: String
        public var verificationURI: String
        public var verificationURIComplete: String?
        public var fingerprint: String
        public var expiresAt: ControlTimestamp
        public var platform: String
        public var label: String

        public init(
            userCode: String,
            verificationURI: String,
            verificationURIComplete: String? = nil,
            fingerprint: String,
            expiresAt: ControlTimestamp,
            platform: String,
            label: String
        ) {
            self.userCode = userCode
            self.verificationURI = verificationURI
            self.verificationURIComplete = verificationURIComplete
            self.fingerprint = fingerprint
            self.expiresAt = expiresAt
            self.platform = platform
            self.label = label
        }

        public var confirmationURL: URL? {
            if let complete = verificationURIComplete, let url = URL(string: complete) { return url }
            return URL(string: verificationURI)
        }

        public func isExpired(at now: Date = Date()) -> Bool {
            expiresAt.date <= now
        }
    }

    public init(brokerURL: URL, startEnrollment: Bool = false, enrollment: EnrollmentReference? = nil) {
        self.brokerURL = brokerURL
        self.startEnrollment = startEnrollment
        self.enrollment = enrollment
    }

    public var json: JSONValue {
        var members: [String: JSONValue] = [
            "v": 1,
            "type": .string(Self.messageType),
            "broker_url": .string(brokerURL.absoluteString),
            "start_enrollment": .bool(startEnrollment),
        ]
        if let enrollment {
            var reference: [String: JSONValue] = [
                "user_code": .string(enrollment.userCode),
                "verification_uri": .string(enrollment.verificationURI),
                "key_fingerprint": .string(enrollment.fingerprint),
                "expires_at": JSONValue(enrollment.expiresAt),
                "platform": .string(enrollment.platform),
                "label": .string(enrollment.label),
            ]
            if let complete = enrollment.verificationURIComplete {
                reference["verification_uri_complete"] = .string(complete)
            }
            members["enrollment"] = .object(reference)
        }
        return .object(members)
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let version = try reader.integer("v")
        guard version == 1 else {
            throw JSONReader.ReadError.invalidValue("v", reason: "unsupported pairing version")
        }
        let type = try reader.string("type", maxLength: 64)
        guard type == Self.messageType else {
            throw JSONReader.ReadError.invalidValue("type", reason: "unsupported pairing type")
        }
        let brokerText = try reader.string("broker_url", maxLength: 512)
        guard let brokerURL = URL(string: brokerText), ControlBrokerAddress.isAcceptable(brokerURL) else {
            throw JSONReader.ReadError.invalidValue("broker_url", reason: "not an acceptable broker URL")
        }
        self.brokerURL = brokerURL
        startEnrollment = try reader.optionalBool("start_enrollment") ?? false
        if var enrollmentReader = try reader.optionalObject("enrollment") {
            let complete = try enrollmentReader.optionalString("verification_uri_complete", maxLength: 512)
            enrollment = EnrollmentReference(
                userCode: try enrollmentReader.string("user_code", maxLength: 32),
                verificationURI: try enrollmentReader.string("verification_uri", maxLength: 512),
                verificationURIComplete: complete,
                fingerprint: try enrollmentReader.string("key_fingerprint", maxLength: 128),
                expiresAt: try enrollmentReader.timestamp("expires_at"),
                platform: try enrollmentReader.string("platform", maxLength: 32),
                label: try enrollmentReader.string("label", maxLength: 64)
            )
            try enrollmentReader.rejectUnknownMembers()
        } else {
            enrollment = nil
        }
        try reader.rejectUnknownMembers()
    }

    public func applicationContext() throws -> [String: Any] {
        [Self.applicationContextKey: try JSONCanonicalization.canonicalString(json)]
    }

    public init?(applicationContext: [String: Any]) {
        guard let text = applicationContext[Self.applicationContextKey] as? String,
              let value = try? JSONValue.parse(text),
              let parsed = try? ControlPairingMessage(json: value)
        else {
            return nil
        }
        self = parsed
    }
}
