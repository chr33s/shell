import XCTest
@testable import ShellControlProtocol

final class ApprovalSpecTests: XCTestCase {
    /// The worked example from spec.watch.md section 9.
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

    func testSpecRoundTripsAndHashesStably() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        let hash = try spec.requestHash()
        XCTAssertTrue(hash.hasPrefix("sha256:"))
        // Re-decoding the re-encoded spec must produce the identical digest.
        let reencoded = try ApprovalSpec(json: try JSONValue.parse(try JSONCanonicalization.canonicalize(spec.json)))
        XCTAssertEqual(try reencoded.requestHash(), hash)
    }

    func testChangedArgvChangesTheDigest() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        guard case .exec(let operation) = spec.operation else { return XCTFail("expected exec.v1") }
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
        XCTAssertNotEqual(try tampered.requestHash(), try spec.requestHash())
    }

    func testExecRequiresAbsolutePaths() {
        XCTAssertThrowsError(try ExecOperation(argv: ["git", "push"], cwd: "/srv", contextSHA256: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try ExecOperation(argv: ["/usr/bin/git"], cwd: "srv", contextSHA256: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try ExecOperation(argv: [], cwd: "/srv", contextSHA256: String(repeating: "a", count: 64)))
    }

    func testUnknownOperationSchemaIsCarriedButNotApprovable() throws {
        let json = try JSONValue.parse(Self.specJSON)
        guard var members = json.objectValue else { return XCTFail("expected an object") }
        members["operation"] = .object(["schema": "k8s.apply.v1", "manifest": "..."])
        members["required_features"] = .array(["k8s.apply.v1"])
        let spec = try ApprovalSpec(json: .object(members))
        XCTAssertFalse(spec.operation.isRecognized)
        let record = try ApprovalRecord(
            spec: spec,
            projection: ApprovalProjection(presence: SourcePresence(lastSeenAt: spec.createdAt, isWaiting: true))
        )
        XCTAssertEqual(
            record.watchApprovability(at: spec.createdAt),
            .reviewElsewhere(reason: .unknownOperationSchema)
        )
    }

    func testAdvertisedHashCannotSubstituteForTheComputation() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        let record = try ApprovalRecord(spec: spec, projection: ApprovalProjection())
        guard var members = record.json.objectValue else { return XCTFail("expected an object") }
        members["request_hash"] = .string("sha256:" + String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ApprovalRecord(json: .object(members)))
    }

    func testExpiryCapIsEnforced() throws {
        let created = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        XCTAssertThrowsError(try ApprovalSpec(
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
        ))
    }

    func testFullReviewAndPresenceGateApprovalButNotRejection() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(Self.specJSON))
        let stale = try ApprovalRecord(spec: spec, projection: ApprovalProjection(presence: .absent))
        XCTAssertEqual(stale.watchApprovability(at: spec.createdAt), .reviewElsewhere(reason: .sourceNotPresent))
        // Reject can still be recorded while the origin is offline.
        XCTAssertTrue(stale.canReject(at: spec.createdAt))
        XCTAssertFalse(stale.canApprove(at: spec.createdAt))
    }

    func testUnsupportedRequiredFeatureBlocksWatchApproval() throws {
        let json = try JSONValue.parse(Self.specJSON)
        guard var members = json.objectValue else { return XCTFail("expected an object") }
        members["required_features"] = .array(["exec.v1", "attachments.v9"])
        let spec = try ApprovalSpec(json: .object(members))
        let record = try ApprovalRecord(
            spec: spec,
            projection: ApprovalProjection(presence: SourcePresence(lastSeenAt: spec.createdAt, isWaiting: true))
        )
        XCTAssertEqual(
            record.watchApprovability(at: spec.createdAt),
            .reviewElsewhere(reason: .unsupportedRequiredFeature)
        )
    }
}
