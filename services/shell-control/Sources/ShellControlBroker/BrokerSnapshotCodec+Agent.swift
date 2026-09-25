import Foundation
import ShellControlProtocol

/// Durable encoding of the `shell-agent/1` ledger. Restoring it cannot
/// reactivate spent authority: claims, idempotency records, and tombstones
/// come back with everything else.
extension BrokerSnapshotCodec {
    static func encodeAgent(_ ledger: AgentLedger) -> JSONValue {
        .object([
            "v": 1,
            "next_sequence": .string(String(ledger.nextSequence)),
            "sessions": .array(ledger.sessions.values.map { entry in
                .object([
                    "account_id": JSONValue(entry.accountID),
                    "origin_id": JSONValue(entry.originID),
                    "projection": entry.projection.json
                ])
            }),
            "inputs": .array(ledger.inputs.values.map { entry in
                JSONWriter.object([
                    "spec": entry.spec.json,
                    "account_id": JSONValue(entry.accountID),
                    "projection": entry.projection.json,
                    "response": entry.response?.json,
                    "response_hash": entry.responseHash.map { .string($0) },
                    "command_jws": entry.commandJWS.map { .string($0) },
                    "command_not_after": entry.commandNotAfter.map { JSONValue($0) },
                    "permit": entry.permit?.json,
                    "withdrawn_at": entry.withdrawnAt.map { JSONValue($0) }
                ])
            }),
            "approvals": .array(ledger.approvals.values.map { entry in
                .object([
                    "account_id": JSONValue(entry.accountID),
                    "origin_id": JSONValue(entry.originID),
                    "run_id": JSONValue(entry.runID),
                    "native_wait_id": JSONValue(entry.nativeWaitID),
                    "reference": entry.reference.json
                ])
            }),
            "change_log": .array(ledger.changeLog.map { event in
                JSONWriter.object([
                    "event": event.json,
                    "account_id": ledger.scopes[event.eventID].map { JSONValue($0.accountID) },
                    "origin_id": ledger.scopes[event.eventID]?.originID.map { JSONValue($0) }
                ])
            }),
            "item_sequences": .array(ledger.itemSequences.sorted { $0.key.rawValue < $1.key.rawValue }.map { entry in
                .object(["resource_id": JSONValue(entry.key), "sequence": .string(String(entry.value))])
            }),
            "challenges": .array(ledger.challenges.values.map { record in
                JSONWriter.object([
                    "challenge_id": .string(record.challengeID),
                    "account_id": JSONValue(record.accountID),
                    "device_id": JSONValue(record.deviceID),
                    "request": record.request.json,
                    "expires_at": JSONValue(record.expiresAt),
                    "consumed_at": record.consumedAt.map { JSONValue($0) }
                ])
            }),
            "idempotency": .array(ledger.idempotency.values.map { record in
                .object([
                    "account_id": JSONValue(record.accountID),
                    "device_id": JSONValue(record.deviceID),
                    "command_id": JSONValue(record.commandID),
                    "payload_hash": .string(record.payloadHash),
                    "result": record.result.json,
                    "recorded_at": JSONValue(record.recordedAt)
                ])
            }),
            "mutations": .array(ledger.mutations.values.map { record in
                .object([
                    "kind": .string(record.kind.rawValue),
                    "origin_id": JSONValue(record.originID),
                    "mutation_id": JSONValue(record.mutationID),
                    "body_hash": .string(record.bodyHash),
                    "result": record.result,
                    "recorded_at": JSONValue(record.recordedAt)
                ])
            }),
            "input_tombstones": .array(ledger.inputTombstones.sorted { $0.key.rawValue < $1.key.rawValue }.map { entry in
                .object(["request_id": JSONValue(entry.key), "request_hash": .string(entry.value)])
            }),
            "session_commands": .array(ledger.sessionCommands.values.map { entry in
                JSONWriter.object([
                    "account_id": JSONValue(entry.accountID),
                    "origin_id": JSONValue(entry.originID),
                    "record": entry.record.json,
                    "command_jws": .string(entry.commandJWS),
                    "permit": entry.permit?.json
                ])
            })
        ])
    }

    static func decodeAgent(_ value: JSONValue) throws -> AgentLedger {
        var reader = try JSONReader(value)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("agent ledger version") }
        var ledger = AgentLedger()
        ledger.nextSequence = max(1, UInt64(try reader.string("next_sequence", maxLength: 20)) ?? 1)
        for item in try reader.value("sessions").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let projection = try AgentSessionProjection(json: try entry.value("projection"))
            ledger.sessions[projection.registration.agentSessionID] = AgentSessionEntry(
                accountID: try entry.id("account_id"), originID: try entry.id("origin_id"), projection: projection
            )
        }
        for item in try reader.value("inputs").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let spec = try InputSpec(json: try entry.value("spec"))
            var decoded = InputEntry(
                spec: spec, requestHash: try spec.requestHash(), accountID: try entry.id("account_id"),
                projection: try InputProjection(json: try entry.value("projection"))
            )
            decoded.response = try entry.optionalValue("response").map(InputResponse.init(json:))
            decoded.responseHash = try entry.optionalString("response_hash", maxLength: 80)
            decoded.commandJWS = try entry.optionalString("command_jws", maxLength: 16384)
            decoded.commandNotAfter = try entry.optionalTimestamp("command_not_after")
            decoded.permit = try entry.optionalValue("permit").map(InputConsumePermit.init(json:))
            decoded.withdrawnAt = try entry.optionalTimestamp("withdrawn_at")
            ledger.inputs[spec.requestID] = decoded
        }
        for item in try reader.value("approvals").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let reference = try AgentApprovalReference(json: try entry.value("reference"))
            ledger.approvals[reference.requestID] = AgentApprovalEntry(
                accountID: try entry.id("account_id"), originID: try entry.id("origin_id"),
                runID: try entry.id("run_id"), nativeWaitID: try entry.id("native_wait_id"), reference: reference
            )
        }
        for item in try reader.value("change_log").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let event = try AgentChangeEvent(json: try entry.value("event"))
            ledger.changeLog.append(event)
            if let accountID = try entry.optionalID("account_id") {
                ledger.scopes[event.eventID] = BrokerStore.EventScope(accountID: accountID, originID: try entry.optionalID("origin_id"))
            }
        }
        for item in try reader.value("item_sequences").arrayValue ?? [] {
            var entry = try JSONReader(item)
            ledger.itemSequences[try entry.id("resource_id")] = UInt64(try entry.string("sequence", maxLength: 20)) ?? 0
        }
        for item in try reader.value("challenges").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let record = AgentChallengeRecord(
                challengeID: try entry.string("challenge_id", maxLength: 128),
                accountID: try entry.id("account_id"),
                deviceID: try entry.id("device_id"),
                request: try AgentReviewChallengeRequest(json: try entry.value("request")),
                expiresAt: try entry.timestamp("expires_at"),
                consumedAt: try entry.optionalTimestamp("consumed_at")
            )
            ledger.challenges[record.challengeID] = record
        }
        for item in try reader.value("idempotency").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let record = AgentIdempotencyRecord(
                accountID: try entry.id("account_id"),
                deviceID: try entry.id("device_id"),
                commandID: try entry.id("command_id"),
                payloadHash: try entry.string("payload_hash", maxLength: 80),
                result: try AgentCommandResult(json: try entry.value("result")),
                recordedAt: try entry.timestamp("recorded_at")
            )
            ledger.idempotency[AgentIdempotencyRecord.key(account: record.accountID, device: record.deviceID, command: record.commandID)] = record
        }
        for item in try reader.value("mutations").arrayValue ?? [] {
            var entry = try JSONReader(item)
            let kindText = try entry.string("kind", maxLength: 32)
            guard let kind = AgentMutationRecord.Kind(rawValue: kindText) else {
                throw ValidationError.unsupported("agent mutation kind \(kindText)")
            }
            let record = AgentMutationRecord(
                kind: kind,
                originID: try entry.id("origin_id"),
                mutationID: try entry.id("mutation_id"),
                bodyHash: try entry.string("body_hash", maxLength: 80),
                result: try entry.value("result"),
                recordedAt: try entry.timestamp("recorded_at")
            )
            ledger.mutations[record.key] = record
        }
        for item in try reader.value("input_tombstones").arrayValue ?? [] {
            var entry = try JSONReader(item)
            ledger.inputTombstones[try entry.id("request_id")] = try entry.string("request_hash", maxLength: 80)
        }
        for item in reader.optionalValue("session_commands")?.arrayValue ?? [] {
            var entry = try JSONReader(item)
            let record = try AgentSessionCommandRecord(json: try entry.value("record"))
            ledger.sessionCommands[record.commandID] = SessionCommandEntry(
                accountID: try entry.id("account_id"), originID: try entry.id("origin_id"), record: record,
                commandJWS: try entry.string("command_jws", maxLength: 16384),
                permit: try entry.optionalValue("permit").map(AgentSessionPermit.init(json:))
            )
        }
        if let last = ledger.changeLog.last { ledger.nextSequence = max(ledger.nextSequence, last.sequence.value + 1) }
        return ledger
    }
}
