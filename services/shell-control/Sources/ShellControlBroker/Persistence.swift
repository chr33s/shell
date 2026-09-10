import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// Durable storage for the broker.
///
/// V1 uses transactional durable storage with a single logical writer. This
/// file-backed implementation writes the whole state atomically and fsyncs
/// before a mutation is reported as recorded; PostgreSQL is the scale path
/// (spec.watch.md section 3).
public protocol BrokerPersistence: Sendable {
    func persist(snapshot: JSONValue) throws
    func load() throws -> JSONValue?
}

public struct FileBrokerPersistence: BrokerPersistence {
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func persist(snapshot: JSONValue) throws {
        let data = try JSONCanonicalization.canonicalize(snapshot)
        let temporary = url.appendingPathExtension("tmp")
        // Write, fsync, then rename: a crash leaves either the old or the new
        // state, never a torn one.
        let handle = try FileHandle(forWritingTo: try createFile(at: temporary))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private func createFile(at url: URL) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        return url
    }

    public func load() throws -> JSONValue? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try JSONValue.parse(data, limits: JSONLimits(
            maxDocumentBytes: 64 << 20,
            maxStringCharacters: 1 << 20,
            maxNestingDepth: 64,
            maxCollectionElements: 1 << 20
        ))
    }
}

/// Encodes and restores the broker's state.
public enum BrokerSnapshotCodec {
    static func encode(_ store: isolated BrokerStore) -> JSONValue {
        .object([
            "v": 1,
            "policy_version": .number(.int(store.policyVersion)),
            // The in-memory counter, not the log's tail: trimming can empty the
            // log, and restarting sequence numbers would silently strand every
            // client cursor above the new value.
            "next_sequence": .string(String(store.nextSequence)),
            "devices": .array(store.devices.values.map(encodeDevice)),
            "origins": .array(store.origins.values.map(encodeOrigin)),
            "runs": .array(store.runs.values.map(encodeRun)),
            "approvals": .array(store.approvals.values.map(encodeApproval)),
            "notifications": .array(store.notifications.values.map { event in
                .object([
                    "account_id": JSONValue(store.notificationAccounts[event.eventID] ?? event.originID),
                    "event": event.json,
                ])
            }),
            "challenges": .array(store.challenges.values.map(encodeChallenge)),
            "idempotency": .array(store.idempotency.values.map(encodeIdempotency)),
            "origin_mutations": .array(store.originMutations.values.map { record in
                .object([
                    "origin_id": JSONValue(record.originID),
                    "mutation_id": JSONValue(record.mutationID),
                    "body_hash": .string(record.bodyHash),
                    "result": record.result,
                ])
            }),
            "receipts": JSONValue(strings: store.receipts.map(\.rawValue).sorted()),
            // Sessions, enrollments, and in-flight device grants are durable
            // state: without them a restart would 401 every enrolled device and
            // force an admin-approved re-enrollment.
            "item_sequences": .array(store.itemSequences.sorted { $0.key.rawValue < $1.key.rawValue }.map { entry in
                .object(["resource_id": JSONValue(entry.key), "sequence": .string(String(entry.value))])
            }),
            "access_tokens": .array(store.accessTokens.values.map(encodeToken)),
            "refresh_tokens": .array(store.refreshTokens.values.map(encodeToken)),
            "enrollment_tokens": .array(store.enrollmentTokens.values.map(encodeToken)),
            "enrollments": .array(store.enrollments.values.map(encodeEnrollment)),
            "device_authorizations": .array(store.deviceAuthorizations.values.map(encodeDeviceAuthorization)),
            "tombstones": .array(store.tombstones.values.map { tombstone in
                JSONWriter.object([
                    "request_id": JSONValue(tombstone.requestID),
                    "request_hash": .string(tombstone.requestHash),
                    "resolution": .string(tombstone.resolution.rawValue),
                    "consumed_by": tombstone.consumedBy.map { JSONValue($0) },
                ])
            }),
            "change_log": .array(store.changeLog.map { event in
                JSONWriter.object([
                    "event": event.json,
                    "account_id": store.scopes[event.eventID].map { JSONValue($0.accountID) },
                    "origin_id": store.scopes[event.eventID]?.originID.map { JSONValue($0) },
                ])
            }),
        ])
    }

    static func encodeDevice(_ device: DeviceRecord) -> JSONValue {
        JSONWriter.object([
            "device_id": JSONValue(device.deviceID),
            "account_id": JSONValue(device.accountID),
            "public_jwk": device.publicJWK.json,
            "platform": .string(device.platform.rawValue),
            "label": .string(device.label),
            "grants": JSONValue(strings: device.grants.map(\.rawValue).sorted()),
            "revoked_at": device.revokedAt.map { JSONValue($0) },
            "push": device.push?.json,
        ])
    }

    static func decodeDevice(_ value: JSONValue) throws -> DeviceRecord {
        var reader = try JSONReader(value)
        let platformText = try reader.string("platform", maxLength: 16)
        guard let platform = PushRegistration.Platform(rawValue: platformText) else {
            throw ValidationError.unsupported("platform \(platformText)")
        }
        return DeviceRecord(
            deviceID: try reader.id("device_id"),
            accountID: try reader.id("account_id"),
            publicJWK: try DeviceJWK(json: try reader.value("public_jwk")),
            platform: platform,
            label: try reader.string("label", maxLength: 120),
            grants: Set(try reader.stringArray("grants", maxCount: 16, maxLength: 32).compactMap(DeviceGrant.init(rawValue:))),
            revokedAt: try reader.optionalTimestamp("revoked_at"),
            push: try reader.optionalValue("push").map { try PushRegistration(json: $0) }
        )
    }

    static func encodeOrigin(_ origin: OriginRecord) -> JSONValue {
        JSONWriter.object([
            "origin_id": JSONValue(origin.originID),
            "account_id": JSONValue(origin.accountID),
            "label": .string(origin.label),
            "secret_verifier": .string(origin.secretVerifier),
            "revoked_at": origin.revokedAt.map { JSONValue($0) },
        ])
    }

    static func decodeOrigin(_ value: JSONValue) throws -> OriginRecord {
        var reader = try JSONReader(value)
        return OriginRecord(
            originID: try reader.id("origin_id"),
            accountID: try reader.id("account_id"),
            label: try reader.string("label", maxLength: 120),
            secretVerifier: try reader.string("secret_verifier", maxLength: 80),
            revokedAt: try reader.optionalTimestamp("revoked_at")
        )
    }

    static func encodeRun(_ run: RunRecord) -> JSONValue {
        JSONWriter.object([
            "origin_id": JSONValue(run.originID),
            "registration": run.registration.json,
            "last_seen_at": run.lastSeenAt.map { JSONValue($0) },
            "waiting_request_ids": JSONValue(strings: run.waitingRequestIDs.map(\.rawValue).sorted()),
            "job_version": .number(.int(run.jobVersion)),
            "job_state": .string(run.jobState.rawValue),
            "cancellation_requested_at": run.cancellationRequestedAt.map { JSONValue($0) },
        ])
    }

    static func decodeRun(_ value: JSONValue) throws -> RunRecord {
        var reader = try JSONReader(value)
        let registration = try RunRegistration(json: try reader.value("registration"))
        let stateText = try reader.string("job_state", maxLength: 32)
        guard let state = JobState(rawValue: stateText) else { throw ValidationError.unsupported("job state \(stateText)") }
        var run = RunRecord(
            runID: registration.runID,
            originID: try reader.id("origin_id"),
            jobID: registration.jobID,
            registration: registration
        )
        run.lastSeenAt = try reader.optionalTimestamp("last_seen_at")
        run.waitingRequestIDs = Set(try reader.stringArray("waiting_request_ids", maxCount: 1024, maxLength: 36).compactMap(ControlID.init))
        run.jobVersion = try reader.integer("job_version")
        run.jobState = state
        run.cancellationRequestedAt = try reader.optionalTimestamp("cancellation_requested_at")
        return run
    }

    static func encodeApproval(_ entry: ApprovalRecordEntry) -> JSONValue {
        JSONWriter.object([
            "account_id": JSONValue(entry.accountID),
            "spec": entry.spec.json,
            "projection": entry.projection.json,
            "decision_jws": entry.decisionJWS.map { .string($0) },
            "consumed_by": entry.consumedBy.map { JSONValue($0) },
            "permit": entry.permit?.json,
            "receipt_id": entry.receiptID.map { JSONValue($0) },
            "withdrawn_at": entry.withdrawnAt.map { JSONValue($0) },
        ])
    }

    static func decodeApproval(_ value: JSONValue) throws -> ApprovalRecordEntry {
        var reader = try JSONReader(value)
        let spec = try ApprovalSpec(json: try reader.value("spec"))
        return ApprovalRecordEntry(
            spec: spec,
            requestHash: try spec.requestHash(),
            accountID: try reader.id("account_id"),
            projection: try ApprovalProjection(json: try reader.value("projection")),
            decisionJWS: try reader.optionalString("decision_jws", maxLength: 8192),
            consumedBy: try reader.optionalID("consumed_by"),
            permit: try reader.optionalValue("permit").map { try ConsumePermit(json: $0) },
            receiptID: try reader.optionalID("receipt_id"),
            withdrawnAt: try reader.optionalTimestamp("withdrawn_at")
        )
    }

    static func encodeChallenge(_ challenge: ChallengeRecord) -> JSONValue {
        JSONWriter.object([
            "challenge_id": .string(challenge.challengeID),
            "account_id": JSONValue(challenge.accountID),
            "device_id": JSONValue(challenge.deviceID),
            "action": .string(challenge.action.rawValue),
            "request": challenge.request.json,
            "expires_at": JSONValue(challenge.expiresAt),
            "consumed_at": challenge.consumedAt.map { JSONValue($0) },
        ])
    }

    static func decodeChallenge(_ value: JSONValue) throws -> ChallengeRecord {
        var reader = try JSONReader(value)
        let actionText = try reader.string("action", maxLength: 32)
        guard let action = ControlCommandType(rawValue: actionText) else {
            throw ValidationError.unsupported("action \(actionText)")
        }
        return ChallengeRecord(
            challengeID: try reader.string("challenge_id", maxLength: 128),
            accountID: try reader.id("account_id"),
            deviceID: try reader.id("device_id"),
            action: action,
            request: try ReviewChallengeRequest(json: try reader.value("request")),
            expiresAt: try reader.timestamp("expires_at"),
            consumedAt: try reader.optionalTimestamp("consumed_at")
        )
    }

    static func encodeToken(_ record: TokenRecord) -> JSONValue {
        JSONWriter.object([
            "verifier": .string(record.verifier),
            "device_id": JSONValue(record.deviceID),
            "account_id": JSONValue(record.accountID),
            "expires_at": JSONValue(record.expiresAt),
            "is_refresh": .bool(record.isRefresh),
            "enrollment_id": record.enrollmentID.map { JSONValue($0) },
            "device_code": record.deviceCode.map { .string($0) },
            "revoked": .bool(record.revoked),
        ])
    }

    static func decodeToken(_ value: JSONValue) throws -> TokenRecord {
        var reader = try JSONReader(value)
        var record = TokenRecord(
            verifier: try reader.string("verifier", maxLength: 80),
            deviceID: try reader.id("device_id"),
            accountID: try reader.id("account_id"),
            expiresAt: try reader.timestamp("expires_at"),
            isRefresh: try reader.bool("is_refresh"),
            enrollmentID: try reader.optionalID("enrollment_id"),
            deviceCode: try reader.optionalString("device_code", maxLength: 128)
        )
        record.revoked = try reader.optionalBool("revoked") ?? false
        return record
    }

    static func encodeEnrollment(_ record: EnrollmentRecord) -> JSONValue {
        JSONWriter.object([
            "enrollment_id": JSONValue(record.enrollmentID),
            "public_jwk": record.publicJWK.json,
            "platform": .string(record.platform.rawValue),
            "label": .string(record.label),
            "challenge": .string(record.challenge),
            "expires_at": JSONValue(record.expiresAt),
            "completed_at": record.completedAt.map { JSONValue($0) },
        ])
    }

    static func decodeEnrollment(_ value: JSONValue) throws -> EnrollmentRecord {
        var reader = try JSONReader(value)
        let platformText = try reader.string("platform", maxLength: 16)
        guard let platform = PushRegistration.Platform(rawValue: platformText) else {
            throw ValidationError.unsupported("platform \(platformText)")
        }
        return EnrollmentRecord(
            enrollmentID: try reader.id("enrollment_id"),
            publicJWK: try DeviceJWK(json: try reader.value("public_jwk")),
            platform: platform,
            label: try reader.string("label", maxLength: 120),
            challenge: try reader.string("challenge", maxLength: 256),
            expiresAt: try reader.timestamp("expires_at"),
            completedAt: try reader.optionalTimestamp("completed_at")
        )
    }

    static func encodeDeviceAuthorization(_ record: DeviceAuthorizationRecord) -> JSONValue {
        JSONWriter.object([
            "device_code": .string(record.deviceCode),
            "user_code": .string(record.userCode),
            "scope": .string(record.scope),
            "enrollment_id": JSONValue(record.enrollmentID),
            "expires_at": JSONValue(record.expiresAt),
            "interval": .number(.int(Int64(record.interval))),
            "last_polled_at": record.lastPolledAt.map { JSONValue($0) },
            "approved_account_id": record.approvedAccountID.map { JSONValue($0) },
            "grants": JSONValue(strings: record.grants.map(\.rawValue).sorted()),
            "denied_at": record.deniedAt.map { JSONValue($0) },
            "issued_token_verifier": record.issuedTokenVerifier.map { .string($0) },
        ])
    }

    static func decodeDeviceAuthorization(_ value: JSONValue) throws -> DeviceAuthorizationRecord {
        var reader = try JSONReader(value)
        var record = DeviceAuthorizationRecord(
            deviceCode: try reader.string("device_code", maxLength: 128),
            userCode: try reader.string("user_code", maxLength: 16),
            scope: try reader.string("scope", maxLength: 128),
            enrollmentID: try reader.id("enrollment_id"),
            expiresAt: try reader.timestamp("expires_at"),
            interval: TimeInterval(try reader.integer("interval"))
        )
        record.lastPolledAt = try reader.optionalTimestamp("last_polled_at")
        record.approvedAccountID = try reader.optionalID("approved_account_id")
        record.grants = Set(try reader.stringArray("grants", maxCount: 16, maxLength: 32).compactMap(DeviceGrant.init(rawValue:)))
        record.deniedAt = try reader.optionalTimestamp("denied_at")
        record.issuedTokenVerifier = try reader.optionalString("issued_token_verifier", maxLength: 80)
        return record
    }

    static func encodeIdempotency(_ record: IdempotencyRecord) -> JSONValue {
        .object([
            "account_id": JSONValue(record.accountID),
            "device_id": JSONValue(record.deviceID),
            "command_id": JSONValue(record.commandID),
            "payload_hash": .string(record.payloadHash),
            "result": record.result.json,
            "recorded_at": JSONValue(record.recordedAt),
        ])
    }

    static func decodeIdempotency(_ value: JSONValue) throws -> IdempotencyRecord {
        var reader = try JSONReader(value)
        return IdempotencyRecord(
            accountID: try reader.id("account_id"),
            deviceID: try reader.id("device_id"),
            commandID: try reader.id("command_id"),
            payloadHash: try reader.string("payload_hash", maxLength: 80),
            result: try CommandResult(json: try reader.value("result")),
            recordedAt: try reader.timestamp("recorded_at")
        )
    }
}
