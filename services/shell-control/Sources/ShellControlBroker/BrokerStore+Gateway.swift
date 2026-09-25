import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity

/// The Mac's origin identity plus its private signing key. The key never
/// leaves the Mac (docs/specs/control-protocol.md section 4.2).
public struct OriginSigner: Sendable {
    public let identity: OriginIdentity
    let key: OriginSigningKey

    public init(originID: ControlID, key: OriginSigningKey) {
        self.identity = OriginIdentity(originID: originID, publicJWK: key.publicJWK)
        self.key = key
    }
}

extension BrokerStore {
    /// True when this broker is the Mac-local authority of the iPhone-gateway
    /// profile: it holds an origin identity.
    public var isGatewayProfile: Bool { originSigner != nil }

    static let pairingLifetime: TimeInterval = 10 * 60
    static let reviewerRequestLifetime: TimeInterval = 10 * 60
    static let maximumPushCapabilityBytes = 4096

    // MARK: Origin identity

    /// `GET /v1/origin/proof`: signs the caller's nonce so a route can prove it
    /// reaches the pinned origin key (docs/specs/control-protocol.md section 4.4).
    public func originProof(nonce: String) throws -> OriginProof {
        guard let originSigner else {
            throw ControlError(code: .notFound, message: "this broker has no origin identity")
        }
        guard !nonce.isEmpty, nonce.count <= 64 else {
            throw ControlError(code: .invalidPayload, message: "nonce must be 1...64 characters")
        }
        return try OriginProof.sign(originID: originSigner.identity.originID, nonce: nonce, issuedAt: timestamp, key: originSigner.key)
    }

    // MARK: iPhone pairing

    /// Mints the one-use pairing the setup QR carries. Administrative, and the
    /// secret is returned once.
    public func createPairing(principal: Principal) throws -> (pairingID: ControlID, secret: String, expiresAt: ControlTimestamp) {
        guard case .admin(let accountID) = principal else {
            throw ControlError(code: .notAuthorized, message: "pairing requires account administration")
        }
        let now = timestamp
        // Expired and spent pairings are dropped as new ones are minted.
        pairings = pairings.filter { $0.value.claimedAt == nil && now < $0.value.expiresAt }
        let secret = BrokerStore.randomBytes(32)
        let record = PairingRecord(
            pairingID: .random(),
            accountID: accountID,
            secret: secret,
            expiresAt: now.adding(Self.pairingLifetime)
        )
        pairings[record.pairingID] = record
        try commit()
        return (record.pairingID, Base64URL.encode(secret), record.expiresAt)
    }

    /// `POST /v1/pairings/{id}/claim`: spends the pairing and starts an
    /// ordinary enrollment that still needs explicit Mac-local confirmation
    /// (docs/specs/control-protocol.md sections 5.2 and 5.2).
    public func claimPairing(
        pairingID: ControlID,
        publicJWK: DeviceJWK,
        platform: PushRegistration.Platform,
        label: String,
        nonce: String,
        proof: Data,
        keySignature: Data,
        verificationURI: String
    ) throws -> JSONValue {
        guard platform == .iOS else {
            throw ControlError(code: .invalidPayload, message: "a Watch enrolls through its iPhone gateway")
        }
        guard var pairing = pairings[pairingID], pairing.claimedAt == nil else {
            throw ControlError(code: .notFound, message: "no such pairing")
        }
        guard timestamp < pairing.expiresAt else {
            throw ControlError(code: .requestExpired, message: "pairing expired; run shell-control pair again")
        }
        let binding = try PairingInvitation.claimBinding(pairingID: pairingID, publicJWK: publicJWK, nonce: nonce)
        guard PairingProof.isValid(proof, secret: pairing.secret, binding: binding) else {
            throw ControlError(code: .notAuthorized, message: "pairing proof rejected")
        }
        guard keySignature.count == 64, let key = publicJWK.publicKey,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: keySignature),
              key.isValidSignature(ecdsa, for: binding)
        else {
            throw ControlError(code: .notAuthorized, message: "device key signature rejected")
        }
        // One use: spent before anything else can observe it.
        pairing.claimedAt = timestamp
        pairings[pairingID] = pairing
        let enrollment = try createEnrollment(publicJWK: publicJWK, platform: platform, label: label)
        let authorization = try startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: verificationURI
        )
        try commit()
        return .object([
            "enrollment_id": JSONValue(enrollment.enrollmentID),
            "challenge": .string(enrollment.challenge),
            "expires_at": JSONValue(enrollment.expiresAt),
            "device_authorization": authorization,
            "key_fingerprint": .string(try publicJWK.displayFingerprint())
        ])
    }

    // MARK: Push capability

    public func registerPushCapability(principal: Principal, capability: String) throws {
        guard let deviceID = principal.deviceID, var device = devices[deviceID], !device.isWatchReviewer else {
            throw ControlError(code: .notAuthorized, message: "only an iPhone registers a push capability")
        }
        // Registration never resets an explicit off: the iPhone opts in
        // through the preference first (docs/specs/control-setup.md 7.3).
        guard !device.alertsSuppressed else {
            throw ControlError(code: .notAuthorized, message: "remote alerts are off for this device")
        }
        guard !capability.isEmpty, capability.utf8.count <= Self.maximumPushCapabilityBytes,
              capability.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else {
            throw ControlError(code: .invalidPayload, message: "push capability is malformed")
        }
        device.pushCapability = capability
        devices[deviceID] = device
        try commit()
    }

    // MARK: Notification preference

    /// `GET /v1/devices/me/notification-preference`: the authenticated
    /// iPhone's own record only.
    public func notificationPreference(principal: Principal) throws -> NotificationPreference {
        try preferenceDevice(principal).effectiveNotificationPreference
    }

    /// `PUT /v1/devices/me/notification-preference`: an atomic compare-and-set
    /// on `expected_version`. Off durably suppresses relay and direct-APNs
    /// delivery to this device and removes its stored delivery material; it
    /// changes delivery only, never reviewer authorization
    /// (docs/specs/control-setup.md section 7.3).
    public func setNotificationPreference(principal: Principal, update: NotificationPreferenceUpdate) throws -> NotificationPreference {
        var device = try preferenceDevice(principal)
        let current = device.effectiveNotificationPreference
        guard update.expectedVersion == current.version else {
            throw ControlError(
                code: .idempotencyConflict,
                message: "notification preference is at version \(current.version)",
                currentProjection: current.json
            )
        }
        let next = NotificationPreference(enabled: update.enabled, version: current.version + 1)
        device.notificationPreference = next
        if !update.enabled {
            device.push = nil
            device.pushCapability = nil
        }
        devices[device.deviceID] = device
        try commit()
        return next
    }

    private func preferenceDevice(_ principal: Principal) throws -> DeviceRecord {
        guard let deviceID = principal.deviceID, let device = devices[deviceID], !device.isRevoked else {
            throw ControlError(code: .notAuthorized, message: "only an enrolled device has a notification preference")
        }
        guard !device.isWatchReviewer else {
            throw ControlError(code: .notAuthorized, message: "a Watch reviewer's alerts follow its iPhone")
        }
        return device
    }

    // MARK: Watch reviewers

    /// `POST /v1/gateways/me/watch-reviewers`. The gateway is derived from the
    /// authenticated iPhone credential, never from the body.
    public func enrollWatchReviewer(principal: Principal, request: WatchEnrollmentRequest) throws -> WatchReviewerStatus {
        let gateway = try gatewayDevice(principal)
        try request.verifySignature()
        let now = timestamp
        let thumbprint = try request.publicJWK.thumbprint()
        // The same pending request is returned to a retry.
        if let existing = watchReviewerRequests.values.first(where: {
            $0.gatewayDeviceID == gateway.deviceID && $0.approvedAt == nil && $0.deniedAt == nil
                && now < $0.expiresAt && (try? $0.publicJWK.thumbprint()) == thumbprint
        }) {
            return reviewerStatus(existing)
        }
        // A Watch key already enrolled keeps its device ID. If it is bound to
        // another iPhone, confirming this request is the explicit re-binding
        // (docs/specs/control-protocol.md section 5.4).
        let existingWatch = devices.values.first {
            $0.isWatchReviewer && !$0.isRevoked && $0.accountID == gateway.accountID && (try? $0.publicJWK.thumbprint()) == thumbprint
        }
        if let existingWatch, existingWatch.gatewayDeviceID == gateway.deviceID {
            return activeStatus(existingWatch)
        }
        let record = WatchReviewerRequestRecord(
            watchDeviceID: existingWatch?.deviceID ?? .random(),
            accountID: gateway.accountID,
            gatewayDeviceID: gateway.deviceID,
            publicJWK: request.publicJWK,
            label: request.label,
            userCode: BrokerStore.userCode(),
            grants: DeviceGrant.watchReviewerDefault,
            expiresAt: now.adding(Self.reviewerRequestLifetime)
        )
        watchReviewerRequests[record.watchDeviceID] = record
        try commit()
        return reviewerStatus(record)
    }

    /// `GET /v1/gateways/me/watch-reviewers/{id}`. A Watch bound to another
    /// gateway is indistinguishable from one that does not exist: both are
    /// `reviewer_not_bound` to this gateway.
    public func watchReviewer(principal: Principal, watchID: ControlID) throws -> WatchReviewerStatus {
        let gateway = try gatewayDevice(principal)
        if let request = watchReviewerRequests[watchID], request.gatewayDeviceID == gateway.deviceID, request.approvedAt == nil {
            return reviewerStatus(request)
        }
        guard let watch = devices[watchID], watch.gatewayDeviceID == gateway.deviceID else {
            throw ControlError(code: .reviewerNotBound, message: "no watch reviewer is bound to this iPhone under that id")
        }
        return activeStatus(watch)
    }

    /// Resolves the Watch principal a proxied call acts as, checking the
    /// gateway-to-Watch binding, revocation, and the grant every time
    /// (docs/specs/control-protocol.md sections 10.4 and 18.1).
    public func gatewayPrincipal(_ principal: Principal, watchID: ControlID, requiring grant: DeviceGrant?) throws -> Principal {
        let gateway = try gatewayDevice(principal)
        guard let watch = devices[watchID], watch.gatewayDeviceID == gateway.deviceID,
              watch.accountID == gateway.accountID
        else {
            throw ControlError(code: .reviewerNotBound, message: "no watch reviewer is bound to this iPhone under that id")
        }
        guard !watch.isRevoked else {
            throw ControlError(code: .deviceRevoked, message: "watch reviewer revoked")
        }
        let watchPrincipal = Principal.device(deviceID: watch.deviceID, accountID: watch.accountID, grants: watch.grants)
        if let grant { try watchPrincipal.requireGrant(grant) }
        return watchPrincipal
    }

    private func gatewayDevice(_ principal: Principal) throws -> DeviceRecord {
        guard let deviceID = principal.deviceID, let device = devices[deviceID], !device.isRevoked else {
            throw ControlError(code: .notAuthorized, message: "a gateway must be an enrolled iPhone")
        }
        guard !device.isWatchReviewer, device.platform == .iOS else {
            throw ControlError(code: .notAuthorized, message: "only an iPhone may act as a gateway")
        }
        return device
    }

    private func reviewerStatus(_ record: WatchReviewerRequestRecord) -> WatchReviewerStatus {
        let state: WatchReviewerStatus.State = record.deniedAt != nil ? .denied : (timestamp < record.expiresAt ? .pending : .expired)
        return WatchReviewerStatus(
            watchDeviceID: record.watchDeviceID,
            state: state,
            gatewayDeviceID: record.gatewayDeviceID,
            fingerprint: (try? record.publicJWK.displayFingerprint()) ?? "",
            label: record.label,
            userCode: state == .pending ? record.userCode : nil,
            grants: record.grants
        )
    }

    private func activeStatus(_ watch: DeviceRecord) -> WatchReviewerStatus {
        WatchReviewerStatus(
            watchDeviceID: watch.deviceID,
            state: watch.isRevoked ? .revoked : .active,
            gatewayDeviceID: watch.gatewayDeviceID ?? watch.deviceID,
            fingerprint: (try? watch.publicJWK.displayFingerprint()) ?? "",
            label: String(watch.label.prefix(64)),
            accountID: watch.isRevoked ? nil : watch.accountID,
            grants: watch.isRevoked ? [] : watch.grants
        )
    }

    // MARK: Administration of reviewers

    func pendingReviewerItems() throws -> [JSONValue] {
        let now = timestamp
        return try watchReviewerRequests.values
            .filter { $0.approvedAt == nil && $0.deniedAt == nil && now < $0.expiresAt }
            .map { record in
                .object([
                    "user_code": .string(record.userCode),
                    "platform": .string(PushRegistration.Platform.watchOS.rawValue),
                    "label": .string(record.label),
                    "key_fingerprint": .string(try record.publicJWK.displayFingerprint()),
                    "gateway": .string(devices[record.gatewayDeviceID]?.label ?? record.gatewayDeviceID.rawValue),
                    "expires_at": JSONValue(record.expiresAt)
                ])
            }
    }

    func reviewerRequest(userCode: String) -> WatchReviewerRequestRecord? {
        watchReviewerRequests.values.first { $0.userCode == userCode && $0.approvedAt == nil && $0.deniedAt == nil }
    }

    func describeReviewer(_ record: WatchReviewerRequestRecord) throws -> JSONValue {
        let rebinding = devices[record.watchDeviceID].flatMap { $0.gatewayDeviceID != record.gatewayDeviceID ? $0 : nil }
        return JSONWriter.object([
            "user_code": .string(record.userCode),
            "platform": .string(PushRegistration.Platform.watchOS.rawValue),
            "label": .string(record.label),
            "key_fingerprint": .string(try record.publicJWK.displayFingerprint()),
            "requested_grants": JSONValue(strings: record.grants.map(\.rawValue).sorted()),
            "gateway": .string(devices[record.gatewayDeviceID]?.label ?? record.gatewayDeviceID.rawValue),
            "rebinding": rebinding.map { _ in .bool(true) },
            "expires_at": JSONValue(record.expiresAt)
        ])
    }

    /// Confirmation enrolls the Watch reviewer bound to the requesting gateway,
    /// or re-binds an existing reviewer to it.
    func approveReviewer(_ record: WatchReviewerRequestRecord, principal: Principal, grants: Set<DeviceGrant>?) throws {
        guard case .admin(let accountID) = principal, accountID == record.accountID else {
            throw ControlError(code: .notAuthorized, message: "enrollment requires account administration")
        }
        guard timestamp < record.expiresAt else {
            throw ControlError(code: .requestExpired, message: "watch enrollment expired")
        }
        guard let gateway = devices[record.gatewayDeviceID], !gateway.isRevoked else {
            throw ControlError(code: .notAuthorized, message: "the gateway iPhone is no longer enrolled")
        }
        // A Watch reviewer never gains a standalone read grant.
        let effective = (grants ?? record.grants).subtracting([.requestsRead, .notificationsRead])
        if var existing = devices[record.watchDeviceID] {
            existing.gatewayDeviceID = record.gatewayDeviceID
            existing.grants = effective
            devices[record.watchDeviceID] = existing
        } else {
            devices[record.watchDeviceID] = DeviceRecord(
                deviceID: record.watchDeviceID,
                accountID: record.accountID,
                publicJWK: record.publicJWK,
                platform: .watchOS,
                label: record.label,
                grants: effective,
                revokedAt: nil,
                push: nil,
                gatewayDeviceID: record.gatewayDeviceID
            )
        }
        var approved = record
        approved.approvedAt = timestamp
        watchReviewerRequests[record.watchDeviceID] = approved
        try commit()
    }

    func denyReviewer(_ record: WatchReviewerRequestRecord) throws {
        var denied = record
        denied.deniedAt = timestamp
        watchReviewerRequests[record.watchDeviceID] = denied
        try commit()
    }

    /// What `shell-control status` reports about enrolled devices.
    public func deviceSummary() -> JSONValue {
        let active = devices.values.filter { !$0.isRevoked }
        return .object([
            "devices": .array(active.sorted { $0.label < $1.label }.map { device in
                JSONWriter.object([
                    "device_id": JSONValue(device.deviceID),
                    "platform": .string(device.platform.rawValue),
                    "label": .string(device.label),
                    "key_fingerprint": .string((try? device.publicJWK.displayFingerprint()) ?? ""),
                    "gateway_device_id": device.gatewayDeviceID.map { JSONValue($0) },
                    "push": .bool(device.pushCapability != nil || device.push != nil),
                    "alerts_enabled": device.isWatchReviewer ? nil : .bool(!device.alertsSuppressed)
                ])
            }),
            "pending_approvals": .number(.int(Int64(approvals.values.filter { $0.projection.resolution == .pending }.count)))
        ])
    }

    /// Revoking an iPhone gateway disables transport for every Watch bound to
    /// it until re-bound; revoking a Watch leaves its iPhone usable
    /// (docs/specs/control-protocol.md section 17).
    public func revoke(deviceID: ControlID, principal: Principal) throws {
        guard case .admin(let accountID) = principal else {
            throw ControlError(code: .notAuthorized, message: "revocation requires account administration")
        }
        guard let device = devices[deviceID], device.accountID == accountID else {
            throw ControlError(code: .notFound, message: "no such device")
        }
        try revokeDevice(deviceID)
        try revokeSessions(deviceID: deviceID)
    }

    // MARK: Relay outbox

    func enqueueRelayPushes(accountID: ControlID, spec: ApprovalSpec) {
        for device in devices.values where device.accountID == accountID && !device.isRevoked && !device.alertsSuppressed {
            guard let capability = device.pushCapability else { continue }
            relayOutbox.append(RelayPushEntry(
                capability: capability,
                event: "approval.created",
                requestID: spec.requestID,
                originID: spec.originID,
                collapseID: "approval.\(spec.requestID.rawValue)",
                presentationClass: "approval"
            ))
        }
    }

    public func drainRelayOutbox() -> [RelayPushEntry] {
        defer { relayOutbox.removeAll() }
        return relayOutbox
    }
}
