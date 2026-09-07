import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity

/// The broker's durable state and every rule that has to hold across it.
///
/// It is a single logical writer: one actor serialises all mutations, which is
/// what preserves per-request and per-job ordering. A horizontally scaled
/// implementation must preserve that serialisation
/// (spec.watch.md sections 3 and 12).
public actor BrokerStore {
    // MARK: State

    var devices: [ControlID: DeviceRecord] = [:]
    var origins: [ControlID: OriginRecord] = [:]
    var runs: [ControlID: RunRecord] = [:]
    var approvals: [ControlID: ApprovalRecordEntry] = [:]
    var notifications: [ControlID: InformationalEvent] = [:]
    var notificationAccounts: [ControlID: ControlID] = [:]
    var challenges: [String: ChallengeRecord] = [:]
    var idempotency: [String: IdempotencyRecord] = [:]
    var originMutations: [String: OriginMutationRecord] = [:]
    var receipts: Set<ControlID> = []
    var tombstones: [ControlID: Tombstone] = [:]
    var changeLog: [ChangeEvent] = []
    var outbox: [OutboxEntry] = []
    var enrollments: [ControlID: EnrollmentRecord] = [:]
    var deviceAuthorizations: [String: DeviceAuthorizationRecord] = [:]
    var enrollmentTokens: [String: TokenRecord] = [:]
    var accessTokens: [String: TokenRecord] = [:]
    var refreshTokens: [String: TokenRecord] = [:]
    var policyVersion: Int64 = 1
    var nextSequence: UInt64 = 1

    let serviceIdentity: String
    let cursorSecret: Data
    let now: @Sendable () -> Date
    var persistence: (any BrokerPersistence)?

    public init(
        serviceIdentity: String,
        cursorSecret: Data = Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        persistence: (any BrokerPersistence)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.serviceIdentity = serviceIdentity
        self.cursorSecret = cursorSecret
        self.persistence = persistence
        self.now = now
    }

    var timestamp: ControlTimestamp { ControlTimestamp(now()) }

    /// Restores state written by ``BrokerSnapshotCodec``. Administrative data
    /// resets must rotate the service identity and invalidate old credentials;
    /// a restore never resurrects authority that was already consumed, because
    /// tombstones and idempotency records come back with everything else
    /// (spec.watch.md section 15).
    public func restore() throws {
        guard let snapshot = try persistence?.load() else { return }
        var reader = try JSONReader(snapshot)
        policyVersion = try reader.integer("policy_version")
        nextSequence = UInt64(try reader.string("next_sequence", maxLength: 20)) ?? 1
        for value in try reader.value("devices").arrayValue ?? [] {
            let device = try BrokerSnapshotCodec.decodeDevice(value)
            devices[device.deviceID] = device
        }
        for value in try reader.value("origins").arrayValue ?? [] {
            let origin = try BrokerSnapshotCodec.decodeOrigin(value)
            origins[origin.originID] = origin
        }
        for value in try reader.value("runs").arrayValue ?? [] {
            let run = try BrokerSnapshotCodec.decodeRun(value)
            runs[run.runID] = run
        }
        for value in try reader.value("approvals").arrayValue ?? [] {
            let entry = try BrokerSnapshotCodec.decodeApproval(value)
            approvals[entry.spec.requestID] = entry
        }
        for value in try reader.value("notifications").arrayValue ?? [] {
            var item = try JSONReader(value)
            let accountID = try item.id("account_id")
            let event = try InformationalEvent(json: try item.value("event"))
            notifications[event.eventID] = event
            notificationAccounts[event.eventID] = accountID
        }
        for value in try reader.value("challenges").arrayValue ?? [] {
            let challenge = try BrokerSnapshotCodec.decodeChallenge(value)
            challenges[challenge.challengeID] = challenge
        }
        for value in try reader.value("idempotency").arrayValue ?? [] {
            let record = try BrokerSnapshotCodec.decodeIdempotency(value)
            idempotency[BrokerStore.idempotencyKey(account: record.accountID, device: record.deviceID, command: record.commandID)] = record
        }
        for value in try reader.value("receipts").arrayValue ?? [] {
            if let id = value.stringValue.flatMap(ControlID.init) { receipts.insert(id) }
        }
        // Origin mutation records are what make a retried withdraw or notify a
        // replay rather than a second execution.
        for value in reader.optionalValue("origin_mutations")?.arrayValue ?? [] {
            var item = try JSONReader(value)
            let originID = try item.id("origin_id")
            let mutationID = try item.id("mutation_id")
            let record = OriginMutationRecord(
                originID: originID,
                mutationID: mutationID,
                bodyHash: try item.string("body_hash", maxLength: 80),
                result: try item.value("result")
            )
            // The key shape must match the one the writers use.
            for prefix in ["notify", "withdraw"] {
                originMutations["\(prefix)|\(originID.rawValue)|\(mutationID.rawValue)"] = record
            }
        }
        for value in reader.optionalValue("item_sequences")?.arrayValue ?? [] {
            var item = try JSONReader(value)
            let id = try item.id("resource_id")
            itemSequences[id] = UInt64(try item.string("sequence", maxLength: 20)) ?? 0
        }
        for value in reader.optionalValue("access_tokens")?.arrayValue ?? [] {
            let record = try BrokerSnapshotCodec.decodeToken(value)
            accessTokens[record.verifier] = record
        }
        for value in reader.optionalValue("refresh_tokens")?.arrayValue ?? [] {
            let record = try BrokerSnapshotCodec.decodeToken(value)
            refreshTokens[record.verifier] = record
        }
        for value in reader.optionalValue("enrollment_tokens")?.arrayValue ?? [] {
            let record = try BrokerSnapshotCodec.decodeToken(value)
            enrollmentTokens[record.verifier] = record
        }
        for value in reader.optionalValue("enrollments")?.arrayValue ?? [] {
            let record = try BrokerSnapshotCodec.decodeEnrollment(value)
            enrollments[record.enrollmentID] = record
        }
        for value in reader.optionalValue("device_authorizations")?.arrayValue ?? [] {
            let record = try BrokerSnapshotCodec.decodeDeviceAuthorization(value)
            deviceAuthorizations[record.deviceCode] = record
        }
        for value in try reader.value("tombstones").arrayValue ?? [] {
            var item = try JSONReader(value)
            let requestID = try item.id("request_id")
            let resolutionText = try item.string("resolution", maxLength: 16)
            tombstones[requestID] = Tombstone(
                requestID: requestID,
                requestHash: try item.string("request_hash", maxLength: 80),
                resolution: Resolution(rawValue: resolutionText) ?? .expired,
                consumedBy: try item.optionalID("consumed_by")
            )
        }
        for value in try reader.value("change_log").arrayValue ?? [] {
            var item = try JSONReader(value)
            let event = try ChangeEvent(json: try item.value("event"))
            changeLog.append(event)
            if let accountID = try item.optionalID("account_id") {
                scopes[event.eventID] = EventScope(accountID: accountID, originID: try item.optionalID("origin_id"))
            }
        }
    }

    // MARK: Administration

    @discardableResult
    public func enrollDevice(
        deviceID: ControlID = .random(),
        accountID: ControlID,
        publicJWK: DeviceJWK,
        platform: PushRegistration.Platform,
        label: String,
        grants: Set<DeviceGrant> = DeviceGrant.watchDefault
    ) throws -> ControlID {
        let record = DeviceRecord(
            deviceID: deviceID,
            accountID: accountID,
            publicJWK: publicJWK,
            platform: platform,
            label: label,
            grants: grants,
            revokedAt: nil,
            push: nil
        )
        devices[deviceID] = record
        try commit()
        return deviceID
    }

    /// Revocation invalidates future commands and unconsumed grants. It cannot
    /// retract an action already dispatched at an origin
    /// (spec.watch.md section 5).
    public func revokeDevice(_ deviceID: ControlID) throws {
        guard var device = devices[deviceID] else { return }
        device.revokedAt = timestamp
        devices[deviceID] = device
        try commit()
    }

    @discardableResult
    public func enrollOrigin(
        originID: ControlID = .random(),
        accountID: ControlID,
        label: String,
        secret: String
    ) throws -> ControlID {
        let record = OriginRecord(
            originID: originID,
            accountID: accountID,
            label: label,
            secretVerifier: BrokerStore.verifier(for: secret),
            revokedAt: nil
        )
        origins[originID] = record
        try commit()
        return originID
    }

    /// Only the verifier is stored server-side (spec.watch.md section 10).
    static func verifier(for secret: String) -> String {
        ContentDigest.digest(of: Data(secret.utf8))
    }

    func device(_ deviceID: ControlID) -> DeviceRecord? { devices[deviceID] }
    func origin(_ originID: ControlID) -> OriginRecord? { origins[originID] }

    public func authenticateDevice(_ deviceID: ControlID) throws -> Principal {
        guard let device = devices[deviceID] else {
            throw ControlError(code: .invalidToken, message: "unknown device")
        }
        guard !device.isRevoked else {
            throw ControlError(code: .deviceRevoked, message: "device revoked")
        }
        return .device(deviceID: device.deviceID, accountID: device.accountID, grants: device.grants)
    }

    public func authenticateOrigin(originID: ControlID, secret: String) throws -> Principal {
        guard let origin = origins[originID], !origin.isRevoked,
              ContentDigest.matches(origin.secretVerifier, BrokerStore.verifier(for: secret))
        else {
            throw ControlError(code: .invalidToken, message: "origin credential rejected")
        }
        return .origin(originID: origin.originID, accountID: origin.accountID)
    }

    public func capabilities() -> ServiceCapabilities {
        ServiceCapabilities(serviceIdentity: serviceIdentity, serverTime: timestamp)
    }

    /// Tightening effective policy changes `policy_version`, which invalidates
    /// outstanding review challenges (spec.watch.md section 9).
    public func bumpPolicyVersion() throws {
        policyVersion += 1
        for (id, var entry) in approvals where entry.projection.resolution == .pending {
            entry.projection.policyVersion = policyVersion
            entry.projection.stateVersion += 1
            approvals[id] = entry
            append(.approvalDispatchUpdated, resourceID: id, version: entry.projection.stateVersion, projection: entry.record.json, accountID: entry.accountID)
        }
        challenges = challenges.filter { $0.value.action != .approvalDecide }
        try commit()
    }

    // MARK: Change log

    func append(
        _ type: ChangeEventType,
        resourceID: ControlID,
        version: Int64,
        projection: JSONValue,
        accountID: ControlID,
        originID: ControlID? = nil
    ) {
        let event = ChangeEvent(
            eventID: .random(),
            sequence: LogSequence(nextSequence),
            type: type,
            resourceID: resourceID,
            resourceVersion: version,
            serverTime: timestamp,
            projection: projection
        )
        nextSequence += 1
        changeLog.append(event)
        scopes[event.eventID] = EventScope(accountID: accountID, originID: originID)
        trimChangeLog()
    }

    struct EventScope: Sendable {
        let accountID: ControlID
        let originID: ControlID?
    }

    var scopes: [ControlID: EventScope] = [:]
    /// The log sequence at which each snapshot item came into existence, so a
    /// paginated snapshot can be taken as of one anchor even while new items
    /// arrive (spec.watch.md section 15).
    var itemSequences: [ControlID: UInt64] = [:]

    /// Ordered deltas are retained for at least seven days
    /// (spec.watch.md section 15).
    private func trimChangeLog() {
        let cutoff = timestamp.adding(-ApprovalPolicy.changeLogRetention)
        while let first = changeLog.first, first.serverTime < cutoff {
            scopes.removeValue(forKey: first.eventID)
            changeLog.removeFirst()
        }
    }

    func isVisible(_ event: ChangeEvent, to principal: Principal) -> Bool {
        guard let scope = scopes[event.eventID], scope.accountID == principal.accountID else { return false }
        switch principal {
        case .device, .admin:
            return true
        case .origin(let originID, _):
            // Origin credentials see only their own runs and requests.
            return scope.originID == originID
        }
    }

    func commit() throws {
        guard let persistence else { return }
        // Never return a success response before durable commit
        // (spec.watch.md section 11).
        try persistence.persist(snapshot: BrokerSnapshotCodec.encode(self))
    }

    // MARK: Lazy expiry

    /// Applies deadline-driven transitions before any read or mutation, so an
    /// expired request can never be authorized even if a stale UI still shows a
    /// button (spec.watch.md section 19).
    func sweepExpired() {
        let now = timestamp
        for (id, var entry) in approvals {
            var changed = false
            if entry.projection.resolution == .pending, entry.spec.isExpired(at: now) {
                entry.projection.resolution = .expired
                entry.projection.stateVersion += 1
                changed = true
            }
            if entry.projection.resolution == .approved,
               entry.projection.dispatch == .awaitingOrigin,
               entry.spec.isExpired(at: now)
            {
                // An unconsumed approval that expires is not applied.
                entry.projection.dispatch = .notApplied
                entry.projection.stateVersion += 1
                changed = true
            }
            if changed {
                approvals[id] = entry
                append(
                    entry.projection.resolution == .expired ? .approvalResolved : .approvalDispatchUpdated,
                    resourceID: id,
                    version: entry.projection.stateVersion,
                    projection: entry.record.json,
                    accountID: entry.accountID,
                    originID: entry.spec.originID
                )
            }
        }
        challenges = challenges.filter { $0.value.expiresAt > now }
    }

    func refreshPresence(for entry: inout ApprovalRecordEntry) {
        let run = runs[entry.spec.runID]
        entry.projection.presence = SourcePresence(
            lastSeenAt: run?.lastSeenAt,
            isWaiting: run?.waitingRequestIDs.contains(entry.spec.requestID) ?? false
        )
    }
}
