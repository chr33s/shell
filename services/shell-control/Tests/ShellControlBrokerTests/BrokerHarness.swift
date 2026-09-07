import Foundation
import XCTest
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

/// A broker with a controllable clock, one account, one origin, and enrolled
/// devices — the fake origin the delivery sequence calls for
/// (spec.watch.md section 20).
final class BrokerHarness {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) { current = start }

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    let clock: Clock
    let store: BrokerStore
    let accountID = ControlID.random()
    let originSecret = "origin-secret-value"
    var originID = ControlID.random()

    init(persistence: (any BrokerPersistence)? = nil) {
        let clock = Clock(Date(timeIntervalSince1970: 1_788_000_000))
        self.clock = clock
        self.store = BrokerStore(
            serviceIdentity: "test-broker",
            cursorSecret: Data(repeating: 7, count: 32),
            persistence: persistence,
            now: { clock.now }
        )
    }

    var timestamp: ControlTimestamp { ControlTimestamp(clock.now) }

    func bootstrap() async throws {
        originID = try await store.enrollOrigin(accountID: accountID, label: "build host", secret: originSecret)
    }

    struct Device {
        let id: ControlID
        let key: InMemoryDeviceKey
        let principal: Principal
    }

    func enrollDevice(grants: Set<DeviceGrant> = DeviceGrant.watchDefault.union([.jobsCancel])) async throws -> Device {
        let key = InMemoryDeviceKey()
        let id = try await store.enrollDevice(
            accountID: accountID,
            publicJWK: key.publicJWK,
            platform: .watchOS,
            label: "Watch",
            grants: grants
        )
        return Device(id: id, key: key, principal: try await store.authenticateDevice(id))
    }

    var originPrincipal: Principal { .origin(originID: originID, accountID: accountID) }

    @discardableResult
    func registerRun(runID: ControlID, jobID: ControlID) async throws -> RunRegistration {
        let registration = try RunRegistration(
            runID: runID,
            jobID: jobID,
            jobLabel: "build",
            adapter: "test",
            capabilities: [ControlFeature.consume],
            startedAt: timestamp
        )
        try await store.registerRun(principal: originPrincipal, registration: registration)
        return registration
    }

    func makeSpec(
        requestID: ControlID = .random(),
        runID: ControlID,
        jobID: ControlID,
        argv: [String] = ["/usr/bin/git", "push", "origin", "feature/watch-controls"],
        minimumReview: MinimumReview = .watch,
        lifetime: TimeInterval = ApprovalPolicy.defaultLifetime
    ) throws -> ApprovalSpec {
        try ApprovalSpec(
            requestID: requestID,
            originID: originID,
            jobID: jobID,
            runID: runID,
            createdAt: timestamp,
            expiresAt: timestamp.adding(lifetime),
            summary: "Push feature branch",
            operation: .exec(try ExecOperation(
                argv: argv,
                cwd: "/srv/work/shell",
                contextSHA256: String(repeating: "0", count: 64)
            )),
            minimumReview: minimumReview,
            requiredFeatures: [ExecOperation.schema, ControlFeature.consume]
        )
    }

    /// Registers a run, heartbeats it as waiting, and publishes the request.
    @discardableResult
    func publish(_ spec: ApprovalSpec) async throws -> ApprovalRecord {
        let record = try await store.createApproval(principal: originPrincipal, spec: spec)
        try await store.heartbeat(
            principal: originPrincipal,
            runIDs: [spec.runID],
            waitingRequestIDs: [spec.requestID]
        )
        return record
    }

    /// The whole device path: challenge, sign, submit.
    @discardableResult
    func decide(
        _ decision: ControlDecision,
        device: Device,
        record: ApprovalRecord,
        commandID: ControlID = .random()
    ) async throws -> (result: CommandResult, isReplay: Bool) {
        let challenge = try await store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: record.spec.requestID,
                    requestHash: record.requestHash,
                    expectedStateVersion: record.projection.stateVersion,
                    policyVersion: record.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        let jws = try signDecision(
            decision,
            device: device,
            record: record,
            challengeID: challenge.challengeID,
            commandID: commandID
        )
        return try await store.submitCommand(principal: device.principal, signedCommand: jws, idempotencyKey: commandID)
    }

    func signDecision(
        _ decision: ControlDecision,
        device: Device,
        record: ApprovalRecord,
        challengeID: String,
        commandID: ControlID = .random(),
        requestHashOverride: String? = nil,
        stateVersionOverride: Int64? = nil
    ) throws -> String {
        let command = try ApprovalDecideCommand(
            envelope: try ControlCommandEnvelope(
                type: .approvalDecide,
                commandID: commandID,
                deviceID: device.id,
                audience: "shell-control:\(accountID.rawValue)",
                issuedAt: timestamp,
                notAfter: min(timestamp.adding(ApprovalPolicy.challengeLifetime), record.spec.expiresAt)
            ),
            requestID: record.spec.requestID,
            requestHash: requestHashOverride ?? record.requestHash,
            expectedStateVersion: stateVersionOverride ?? record.projection.stateVersion,
            policyVersion: record.projection.policyVersion,
            decision: decision,
            challengeID: challengeID
        )
        return try ControlJWS.sign(payload: command.json, deviceID: device.id, key: device.key)
    }
}

func assertControlError(
    _ expected: ControlErrorCode,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected.rawValue)", file: file, line: line)
    } catch let error as ControlError {
        XCTAssertEqual(error.code, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected.rawValue), got \(error)", file: file, line: line)
    }
}
