import Foundation
import Testing
@testable import ShellControlProtocol

@Suite
final class ApprovalSpecTests {
    /// The worked example from docs/specs/control-protocol.md section 7.
    static let specJSON = """
    {
      "v": 1,
      "type": "approval.request",
      "request_id": "10000000-0000-4000-8000-000000000001",
      "origin_id": "20000000-0000-4000-8000-000000000001",
      "job_id": "30000000-0000-4000-8000-000000000001",
      "run_id": "40000000-0000-4000-8000-000000000001",
      "created_at": "2026-09-07T09:00:00Z",
      "expires_at": "2026-09-07T09:05:00Z",
      "summary": "Push feature branch",
      "operation": {
        "schema": "exec.v1",
        "argv": ["/usr/bin/git", "push", "origin", "feature/watch-controls"],
        "cwd": "/srv/work/shell",
        "context_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      },
      "minimum_review": "watch",
      "allowed_decisions": ["approve", "reject"],
      "required_features": ["exec.v1", "consume.v1"]
    }
    """

    @Test
    func testSpecRoundTripsAndHashesStably() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        let hash = try spec.requestHash()
        #expect(hash.hasPrefix("sha256:"))
        // Re-decoding the re-encoded spec must produce the identical digest.
        let reencoded = try ApprovalSpec(json: try JSONValue.parse(try JSONCanonicalization.canonicalize(spec.json)))
        #expect((try reencoded.requestHash()) == hash)
    }

    @Test
    func testChangedArgvChangesTheDigest() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        guard case .exec(let operation) = spec.operation else { Issue.record("expected exec.v1")
return }
        let tampered = try ApprovalSpec(
            requestID: spec.requestID,
            originID: spec.originID,
            jobID: spec.jobID,
            runID: spec.runID,
            createdAt: spec.createdAt,
            expiresAt: spec.expiresAt,
            summary: spec.summary,
            operation: .exec(try ExecOperation(
                argv: operation.argv.dropLast() + ["main"],
                cwd: operation.cwd,
                contextSHA256: operation.contextSHA256
            )),
            minimumReview: spec.minimumReview,
            requiredFeatures: spec.requiredFeatures
        )
        #expect((try tampered.requestHash()) != (try spec.requestHash()))
    }

    @Test
    func testExecRequiresAbsolutePaths() throws {
        #expect(throws: (any Error).self) { try ExecOperation(argv: ["git", "push"], cwd: "/srv", contextSHA256: String(repeating: "a", count: 64)) }
        #expect(throws: (any Error).self) { try ExecOperation(argv: ["/usr/bin/git"], cwd: "srv", contextSHA256: String(repeating: "a", count: 64)) }
        #expect(throws: (any Error).self) { try ExecOperation(argv: [], cwd: "/srv", contextSHA256: String(repeating: "a", count: 64)) }
    }

    @Test
    func testUnknownOperationSchemaIsCarriedButNotApprovable() throws {
        let json = try JSONValue.parse(Self.specJSON)
        guard var members = json.objectValue else { Issue.record("expected an object")
return }
        members["operation"] = .object(["schema": "k8s.apply.v1", "manifest": "..."])
        members["required_features"] = .array(["k8s.apply.v1"])
        let spec = try ApprovalSpec(json: .object(members))
        #expect(!(spec.operation.isRecognized))
        let record = try ApprovalRecord(
            spec: spec,
            projection: ApprovalProjection(presence: SourcePresence(lastSeenAt: spec.createdAt, isWaiting: true))
        )
        #expect(record.watchApprovability(at: spec.createdAt) == .reviewElsewhere(reason: .unknownOperationSchema))
    }

    @Test
    func testAdvertisedHashCannotSubstituteForTheComputation() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        let record = try ApprovalRecord(spec: spec, projection: ApprovalProjection())
        guard var members = record.json.objectValue else { Issue.record("expected an object")
return }
        members["request_hash"] = .string("sha256:" + String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try ApprovalRecord(json: .object(members)) }
    }

    @Test
    func testExpiryCapIsEnforced() throws {
        let created = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        #expect(throws: (any Error).self) { try ApprovalSpec(
            requestID: .random(),
            originID: .random(),
            jobID: .random(),
            runID: .random(),
            createdAt: created,
            expiresAt: created.adding(31 * 60),
            summary: "too long",
            operation: .exec(try ExecOperation(argv: ["/bin/true"], cwd: "/", contextSHA256: String(repeating: "a", count: 64))),
            minimumReview: .watch,
            requiredFeatures: []
        ) }
    }

    @Test
    func testFullReviewAndPresenceGateApprovalButNotRejection() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        let stale = try ApprovalRecord(spec: spec, projection: ApprovalProjection(presence: .absent))
        #expect(stale.watchApprovability(at: spec.createdAt) == .reviewElsewhere(reason: .sourceNotPresent))
        // Reject can still be recorded while the origin is offline.
        #expect(stale.canReject(at: spec.createdAt))
        #expect(!(stale.canApprove(at: spec.createdAt)))
    }

    @Test
    func testUnsupportedRequiredFeatureBlocksWatchApproval() throws {
        let json = try JSONValue.parse(Self.specJSON)
        guard var members = json.objectValue else { Issue.record("expected an object")
return }
        members["required_features"] = .array(["exec.v1", "attachments.v9"])
        let spec = try ApprovalSpec(json: .object(members))
        let record = try ApprovalRecord(
            spec: spec,
            projection: ApprovalProjection(presence: SourcePresence(lastSeenAt: spec.createdAt, isWaiting: true))
        )
        #expect(record.watchApprovability(at: spec.createdAt) == .reviewElsewhere(reason: .unsupportedRequiredFeature))
    }
}
