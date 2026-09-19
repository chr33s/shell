import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity

/// A relay-signed, self-contained delivery address.
///
/// The relay keeps no user or device registry: everything it needs to send is
/// inside the capability, and its signature is checked on every use
/// (spec.iphone-gateway.md section 16.1). The capability is not
/// authentication, and it authorizes nothing but one generic hint.
public struct PushCapability: Sendable, Hashable {
    public static let prefix = "pc1"
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    public enum RateClass: String, Sendable, Hashable, CaseIterable {
        case standard

        /// Hints per capability per minute.
        public var perMinute: Int {
            switch self {
            case .standard: return 30
            }
        }
    }

    public let capabilityID: ControlID
    public let apnsToken: String
    public let topic: String
    public let environment: PushRegistration.Environment
    public let expiresAt: ControlTimestamp
    public let rateClass: RateClass
    /// The only notification schema the relay will build from it.
    public let schema: String

    public static let approvalSchema = "shell.approval.v1"

    public init(
        capabilityID: ControlID = .random(),
        apnsToken: String,
        topic: String,
        environment: PushRegistration.Environment,
        expiresAt: ControlTimestamp,
        rateClass: RateClass = .standard,
        schema: String = PushCapability.approvalSchema
    ) throws {
        // Reuse the token and topic validation of a push registration.
        let registration = try PushRegistration(token: apnsToken, platform: .iOS, environment: environment, topic: topic)
        self.capabilityID = capabilityID
        self.apnsToken = registration.token
        self.topic = registration.topic
        self.environment = environment
        self.expiresAt = expiresAt
        self.rateClass = rateClass
        self.schema = schema
    }

    var json: JSONValue {
        .object([
            "v": 1,
            "capability_id": JSONValue(capabilityID),
            "apns_token": .string(apnsToken),
            "topic": .string(topic),
            "environment": .string(environment.rawValue),
            "expires_at": JSONValue(expiresAt),
            "rate_class": .string(rateClass.rawValue),
            "schema": .string(schema)
        ])
    }

    init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("capability version") }
        let environmentText = try reader.string("environment", maxLength: 16)
        guard let environment = PushRegistration.Environment(rawValue: environmentText) else {
            throw ValidationError.unsupported("environment \(environmentText)")
        }
        let rateText = try reader.string("rate_class", maxLength: 16)
        guard let rateClass = RateClass(rawValue: rateText) else { throw ValidationError.unsupported("rate class \(rateText)") }
        try self.init(
            capabilityID: try reader.id("capability_id"),
            apnsToken: try reader.string("apns_token", maxLength: 200),
            topic: try reader.string("topic", maxLength: 200),
            environment: environment,
            expiresAt: try reader.timestamp("expires_at"),
            rateClass: rateClass,
            schema: try reader.string("schema", maxLength: 64)
        )
        try reader.rejectUnknownMembers()
    }

    /// `pc1.<payload>.<signature>` under the relay's own key.
    public func sealed(with key: some DeviceSigningKey) throws -> String {
        let payload = Base64URL.encode(try JSONCanonicalization.canonicalize(json))
        let signingInput = "\(Self.prefix).\(payload)"
        return "\(signingInput).\(Base64URL.encode(try key.signature(for: Data(signingInput.utf8))))"
    }

    public enum OpenError: Error, Equatable, Sendable {
        case malformed
        case badSignature
        case expired
    }

    /// Verifies the relay signature and expiry. No database lookup is needed.
    public static func open(_ sealed: String, publicKey: DeviceJWK, now: Date = Date()) throws -> PushCapability {
        let parts = sealed.split(separator: ".", omittingEmptySubsequences: false)
        guard sealed.utf8.count <= 4096, parts.count == 3, parts[0] == Substring(prefix),
              let payload = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2])), signature.count == 64
        else { throw OpenError.malformed }
        guard let key = publicKey.publicKey,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8))
        else { throw OpenError.badSignature }
        let capability: PushCapability
        do { capability = try PushCapability(json: try JSONValue.parse(payload)) } catch { throw OpenError.malformed }
        guard now < capability.expiresAt.date else { throw OpenError.expired }
        return capability
    }
}
