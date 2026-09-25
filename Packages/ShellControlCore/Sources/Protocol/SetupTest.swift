import Foundation

/// The fixed, harmless request `shell-control test-review` publishes through
/// the ordinary review, signed-decision, consume, and receipt pipeline
/// (docs/specs/control-setup.md section 8).
///
/// Nothing about it is caller-supplied: no executable, argument, path,
/// environment, terminal target, or network action. The host never runs the
/// described operation; its dispatch records the allowed no-operation
/// result. Recognising the fixture only changes how a request is labelled —
/// it grants nothing, and the decision still needs the reviewer's own
/// signature.
public enum SetupTestFixture {
    public static let adapter = "shell-control-setup-test"
    public static let jobLabel = "Setup test"
    public static let summary = "Setup test — no operation will be executed"
    public static let argv = ["/usr/bin/true"]
    public static let cwd = "/"
    /// Bounded well under the policy maximum: a setup test that nobody
    /// answers should expire while the user is still looking at the guide.
    public static let lifetimeSeconds: Int64 = 180
    /// The reason code of the no-operation receipt.
    public static let receiptReason = "setup_test_noop"

    /// A fixed commitment, so the request context is immutable and the same
    /// on every Mac.
    public static let contextSHA256 = ContentDigest.sha256Hex(Data("shell-control-setup-test/1".utf8))

    public static var operation: ExecOperation {
        // The literals above satisfy every ExecOperation rule.
        // swiftlint:disable:next force_try
        try! ExecOperation(argv: argv, cwd: cwd, contextSHA256: contextSHA256)
    }

    /// The minimum review for a test through the given reviewer. An iPhone
    /// test needs a full-review client; a Watch test must be approvable on
    /// the Watch.
    public static func minimumReview(forWatch: Bool) -> MinimumReview { forWatch ? .watch : .full }

    /// The approval-request body the adapter sends to `shell-controld`.
    public static func requestBody(forWatch: Bool) -> JSONValue {
        .object([
            "summary": .string(summary),
            "operation": operation.json,
            "lifetime_seconds": .number(.int(lifetimeSeconds)),
            "minimum_review": .string(minimumReview(forWatch: forWatch).rawValue)
        ])
    }

    /// Which reviewer a fixture request is meant for: an iPhone test needs
    /// full review, a Watch test is Watch-approvable. Labelling only.
    public static func isWatchTest(_ spec: ApprovalSpec) -> Bool {
        matches(spec) && spec.minimumReview == .watch
    }

    public static func isIPhoneTest(_ spec: ApprovalSpec) -> Bool {
        matches(spec) && spec.minimumReview == .full
    }

    /// Whether a request is the setup-test fixture, for labelling only.
    public static func matches(_ spec: ApprovalSpec) -> Bool {
        guard spec.summary == summary, case .exec(let exec) = spec.operation else { return false }
        return exec.argv == argv && exec.cwd == cwd && exec.contextSHA256 == contextSHA256
    }
}
