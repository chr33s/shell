import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity

/// A pending enrollment. It grants no control authority until it completes, and
/// it is one-use (spec.watch.md section 5).
struct EnrollmentRecord: Sendable {
    let enrollmentID: ControlID
    let publicJWK: DeviceJWK
    let platform: PushRegistration.Platform
    let label: String
    let challenge: String
    let expiresAt: ControlTimestamp
    var completedAt: ControlTimestamp?
}

/// An RFC 8628 device authorization grant.
struct DeviceAuthorizationRecord: Sendable {
    let deviceCode: String
    let userCode: String
    let scope: String
    let enrollmentID: ControlID
    let expiresAt: ControlTimestamp
    var interval: TimeInterval
    var lastPolledAt: ControlTimestamp?
    var approvedAccountID: ControlID?
    var grants: Set<DeviceGrant> = DeviceGrant.watchDefault
    var deniedAt: ControlTimestamp?
    var issuedTokenVerifier: String?
}

struct TokenRecord: Sendable {
    let verifier: String
    let deviceID: ControlID
    let accountID: ControlID
    var expiresAt: ControlTimestamp
    let isRefresh: Bool
    /// Enrollment tokens carry the `control.enroll:<id>` scope and nothing else.
    let enrollmentID: ControlID?
    /// The device authorization that issued this enrollment token. Access and
    /// refresh tokens leave this nil. Completing enrollment reads grants from
    /// this record, never from an unbound `enrollmentID` lookup.
    let deviceCode: String?
    var revoked = false
}

extension BrokerStore {
    // MARK: Enrollment

    public func createEnrollment(
        publicJWK: DeviceJWK,
        platform: PushRegistration.Platform,
        label: String
    ) throws -> (enrollmentID: ControlID, challenge: String, expiresAt: ControlTimestamp) {
        let enrollmentID = ControlID.random()
        let challenge = Base64URL.encode(BrokerStore.randomBytes(32))
        let record = EnrollmentRecord(
            enrollmentID: enrollmentID,
            publicJWK: publicJWK,
            platform: platform,
            label: label,
            challenge: challenge,
            // Enrollment lifetime is ten minutes.
            expiresAt: timestamp.adding(10 * 60)
        )
        enrollments[enrollmentID] = record
        try commit()
        return (enrollmentID, challenge, record.expiresAt)
    }

    /// Starts the device grant for `control.enroll:<enrollment_id>`, a Shell
    /// extension scope rather than a standard OAuth permission.
    ///
    /// There is at most one live authorization per enrollment. A second record
    /// would let `completeEnrollment` pick grants by dictionary order, which is
    /// how an unapproved `watchDefault` decoy can shadow an administrator's
    /// restricted grant set.
    public func startDeviceAuthorization(scope: String, verificationURI: String) throws -> JSONValue {
        let prefix = "control.enroll:"
        guard scope.hasPrefix(prefix), let enrollmentID = ControlID(String(scope.dropFirst(prefix.count))),
              let enrollment = enrollments[enrollmentID], enrollment.completedAt == nil,
              timestamp < enrollment.expiresAt
        else {
            throw ControlError(code: .invalidPayload, message: "unknown or expired enrollment scope")
        }
        var live: [(deviceCode: String, record: DeviceAuthorizationRecord)] = []
        var mutated = false
        for (deviceCode, record) in deviceAuthorizations where record.enrollmentID == enrollmentID {
            if record.deniedAt != nil || timestamp >= record.expiresAt {
                deviceAuthorizations.removeValue(forKey: deviceCode)
                mutated = true
                continue
            }
            live.append((deviceCode, record))
        }
        if let kept = live.first(where: { $0.record.approvedAccountID != nil }) ?? live.first {
            for extra in live where extra.deviceCode != kept.deviceCode {
                deviceAuthorizations.removeValue(forKey: extra.deviceCode)
                mutated = true
            }
            if mutated { try commit() }
            return deviceAuthorizationResponse(kept.record, verificationURI: verificationURI)
        }
        let record = DeviceAuthorizationRecord(
            deviceCode: Base64URL.encode(BrokerStore.randomBytes(32)),
            userCode: BrokerStore.userCode(),
            scope: scope,
            enrollmentID: enrollmentID,
            expiresAt: enrollment.expiresAt,
            interval: 5
        )
        deviceAuthorizations[record.deviceCode] = record
        try commit()
        return deviceAuthorizationResponse(record, verificationURI: verificationURI)
    }

    func deviceAuthorizationResponse(_ record: DeviceAuthorizationRecord, verificationURI: String) -> JSONValue {
        .object([
            "device_code": .string(record.deviceCode),
            "user_code": .string(record.userCode),
            "verification_uri": .string(verificationURI),
            "verification_uri_complete": .string("\(verificationURI)?user_code=\(record.userCode)"),
            "expires_in": .number(.int(Int64(record.expiresAt.date.timeIntervalSince(now())))),
            "interval": .number(.int(Int64(record.interval))),
        ])
    }

    /// What the authenticated confirmation page displays: requested origin
    /// permissions, platform, device label, and key fingerprint
    /// (spec.watch.md section 5).
    public func describeUserCode(_ userCode: String) throws -> JSONValue {
        guard let record = deviceAuthorizations.values.first(where: { $0.userCode == userCode }),
              let enrollment = enrollments[record.enrollmentID]
        else {
            throw ControlError(code: .notFound, message: "unknown code")
        }
        return .object([
            "user_code": .string(userCode),
            "platform": .string(enrollment.platform.rawValue),
            "label": .string(enrollment.label),
            "key_fingerprint": .string(try enrollment.publicJWK.displayFingerprint()),
            "requested_grants": JSONValue(strings: record.grants.map(\.rawValue).sorted()),
            "expires_at": JSONValue(record.expiresAt),
        ])
    }

    /// Confirmation requires account administration, not a decision credential.
    public func approveDeviceAuthorization(userCode: String, principal: Principal, grants: Set<DeviceGrant>? = nil) throws {
        guard case .admin(let accountID) = principal else {
            throw ControlError(code: .notAuthorized, message: "enrollment requires account administration")
        }
        guard let deviceCode = deviceAuthorizations.first(where: { $0.value.userCode == userCode })?.key else {
            throw ControlError(code: .notFound, message: "unknown code")
        }
        guard timestamp < deviceAuthorizations[deviceCode]!.expiresAt else {
            throw ControlError(code: .requestExpired, message: "authorization expired")
        }
        deviceAuthorizations[deviceCode]?.approvedAccountID = accountID
        if let grants { deviceAuthorizations[deviceCode]?.grants = grants }
        try commit()
    }

    public func denyDeviceAuthorization(userCode: String) throws {
        guard let deviceCode = deviceAuthorizations.first(where: { $0.value.userCode == userCode })?.key else {
            throw ControlError(code: .notFound, message: "unknown code")
        }
        deviceAuthorizations[deviceCode]?.deniedAt = timestamp
        try commit()
    }

    /// RFC 8628 polling, including `slow_down` when a client polls faster than
    /// the interval it was given.
    public func pollDeviceToken(deviceCode: String) throws -> JSONValue {
        guard var record = deviceAuthorizations[deviceCode] else {
            throw OAuthError.invalidGrant
        }
        let now = timestamp
        if now >= record.expiresAt { throw OAuthError.expiredToken }
        if record.deniedAt != nil { throw OAuthError.accessDenied }
        if let last = record.lastPolledAt, now.date.timeIntervalSince(last.date) < record.interval - 1 {
            record.interval += 5
            deviceAuthorizations[deviceCode] = record
            throw OAuthError.slowDown
        }
        record.lastPolledAt = now
        guard let accountID = record.approvedAccountID else {
            deviceAuthorizations[deviceCode] = record
            throw OAuthError.authorizationPending
        }
        let token = Base64URL.encode(BrokerStore.randomBytes(32))
        record.issuedTokenVerifier = BrokerStore.verifier(for: token)
        deviceAuthorizations[deviceCode] = record
        enrollmentTokens[BrokerStore.verifier(for: token)] = TokenRecord(
            verifier: BrokerStore.verifier(for: token),
            deviceID: .random(),
            accountID: accountID,
            expiresAt: record.expiresAt,
            isRefresh: false,
            enrollmentID: record.enrollmentID,
            deviceCode: deviceCode
        )
        try commit()
        return .object([
            "access_token": .string(token),
            "token_type": "Bearer",
            "scope": .string(record.scope),
            "expires_in": .number(.int(Int64(record.expiresAt.date.timeIntervalSince(self.now())))),
        ])
    }

    /// Completes enrollment against the server's challenge, binding the new
    /// device identity to the key that signed it.
    public func completeEnrollment(
        enrollmentID: ControlID,
        enrollmentToken: String,
        challengeSignature: String
    ) throws -> DeviceSession {
        guard let tokenRecord = enrollmentTokens[BrokerStore.verifier(for: enrollmentToken)],
              tokenRecord.enrollmentID == enrollmentID, !tokenRecord.revoked, timestamp < tokenRecord.expiresAt
        else {
            throw ControlError(code: .invalidToken, message: "enrollment token rejected")
        }
        guard var enrollment = enrollments[enrollmentID], enrollment.completedAt == nil, timestamp < enrollment.expiresAt else {
            throw ControlError(code: .requestExpired, message: "enrollment is not usable")
        }
        guard let challengeBytes = Base64URL.decode(enrollment.challenge),
              let signature = Base64URL.decode(challengeSignature), signature.count == 64,
              let publicKey = enrollment.publicJWK.publicKey,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              publicKey.isValidSignature(ecdsa, for: challengeBytes)
        else {
            throw ControlError(code: .notAuthorized, message: "challenge signature rejected")
        }
        // Grants come from the authorization that issued this token, never from
        // an unbound enrollment lookup and never from a watchDefault fallback.
        guard let deviceCode = tokenRecord.deviceCode,
              let authorization = deviceAuthorizations[deviceCode],
              authorization.enrollmentID == enrollmentID,
              authorization.approvedAccountID == tokenRecord.accountID,
              authorization.deniedAt == nil
        else {
            throw ControlError(code: .notAuthorized, message: "enrollment is not bound to an approved authorization")
        }
        let grants = authorization.grants
        let deviceID = try enrollDevice(
            accountID: tokenRecord.accountID,
            publicJWK: enrollment.publicJWK,
            platform: enrollment.platform,
            label: enrollment.label,
            grants: grants
        )
        guard let device = devices[deviceID] else {
            throw ControlError(code: .temporarilyUnavailable, message: "device registration lost")
        }
        // One-use: the enrollment and its token are spent here.
        enrollment.completedAt = timestamp
        enrollments[enrollmentID] = enrollment
        enrollmentTokens[tokenRecord.verifier]?.revoked = true
        let session = try issueSession(for: device)
        try commit()
        return session
    }

    // MARK: Sessions

    func issueSession(for device: DeviceRecord) throws -> DeviceSession {
        let access = Base64URL.encode(BrokerStore.randomBytes(32))
        let refresh = Base64URL.encode(BrokerStore.randomBytes(32))
        // Access tokens last ten minutes; refresh tokens rotate with a 30-day
        // idle lifetime (spec.watch.md section 5).
        let accessExpiry = timestamp.adding(10 * 60)
        accessTokens[BrokerStore.verifier(for: access)] = TokenRecord(
            verifier: BrokerStore.verifier(for: access),
            deviceID: device.deviceID,
            accountID: device.accountID,
            expiresAt: accessExpiry,
            isRefresh: false,
            enrollmentID: nil,
            deviceCode: nil
        )
        refreshTokens[BrokerStore.verifier(for: refresh)] = TokenRecord(
            verifier: BrokerStore.verifier(for: refresh),
            deviceID: device.deviceID,
            accountID: device.accountID,
            expiresAt: timestamp.adding(30 * 24 * 60 * 60),
            isRefresh: true,
            enrollmentID: nil,
            deviceCode: nil
        )
        return DeviceSession(
            deviceID: device.deviceID,
            accountID: device.accountID,
            accessToken: access,
            accessTokenExpiresAt: accessExpiry,
            refreshToken: refresh,
            grants: device.grants
        )
    }

    /// Rotating refresh: the presented token is spent, and revocation is
    /// verified before a new session is issued.
    public func refreshSession(refreshToken: String) throws -> DeviceSession {
        let verifier = BrokerStore.verifier(for: refreshToken)
        guard var record = refreshTokens[verifier], !record.revoked, timestamp < record.expiresAt,
              let device = devices[record.deviceID], !device.isRevoked
        else {
            throw ControlError(code: .invalidToken, message: "refresh token rejected")
        }
        record.revoked = true
        refreshTokens[verifier] = record
        let session = try issueSession(for: device)
        try commit()
        return session
    }

    /// Bearer authentication for device endpoints.
    public func authenticate(bearer token: String) throws -> Principal {
        guard let record = accessTokens[BrokerStore.verifier(for: token)], !record.revoked else {
            throw ControlError(code: .invalidToken, message: "unknown token")
        }
        guard timestamp < record.expiresAt else {
            throw ControlError(code: .invalidToken, message: "token expired")
        }
        return try authenticateDevice(record.deviceID)
    }

    /// Account logout: the device session is revoked here, and the Watch
    /// removes its local credentials (spec.watch.md section 5).
    public func revokeSessions(deviceID: ControlID) throws {
        for (key, record) in accessTokens where record.deviceID == deviceID { accessTokens[key]?.revoked = true; _ = record }
        for (key, record) in refreshTokens where record.deviceID == deviceID { refreshTokens[key]?.revoked = true; _ = record }
        try commit()
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// A short, human-transcribable code, from an alphabet without characters
    /// that are easy to confuse on a small screen.
    static func userCode() -> String {
        let alphabet = Array("BCDFGHJKLMNPQRSTVWXZ23456789")
        let code = (0..<8).map { _ in String(alphabet.randomElement()!) }.joined()
        return "\(code.prefix(4))-\(code.suffix(4))"
    }
}

public enum OAuthError: String, Error, Sendable {
    case authorizationPending = "authorization_pending"
    case slowDown = "slow_down"
    case accessDenied = "access_denied"
    case expiredToken = "expired_token"
    case invalidGrant = "invalid_grant"
}
