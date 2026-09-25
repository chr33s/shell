import XCTest
@testable import ShellControlProtocol

/// Checks this implementation against the published fixtures in `protocol/`,
/// which are generated independently of the Swift code
/// (docs/specs/control-protocol.md section 20).
final class InteroperabilityFixtureTests: XCTestCase {
    private static var fixturesURL: URL {
        // Tests/ShellControlCoreTests/… → repository root → protocol/fixtures
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = Self.fixturesURL.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "fixtures are not present in this build")
        return try Data(contentsOf: url)
    }

    func testPublishedSpecMatchesItsPublishedCanonicalFormAndDigest() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(try fixture("approval-spec.json")))
        let canonical = try JSONCanonicalization.canonicalize(spec.json)
        let expectedCanonical = try fixture("approval-spec.jcs.txt")
        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            String(decoding: expectedCanonical, as: UTF8.self).trimmingCharacters(in: .newlines)
        )
        let expectedDigest = String(decoding: try fixture("approval-spec.hash.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try spec.requestHash(), expectedDigest)
    }

    func testCanonicalizationVectors() throws {
        let document = try JSONValue.parse(try fixture("canonicalization.json"), limits: JSONLimits(maxDocumentBytes: 1 << 20))
        for testCase in document["cases"]?.arrayValue ?? [] {
            var reader = try JSONReader(testCase)
            let name = try reader.string("name", maxLength: 64)
            let input = try reader.value("input")
            let expected = try reader.string("canonical", maxLength: 1024)
            XCTAssertEqual(try JSONCanonicalization.canonicalString(input), expected, "case \(name)")
        }
        for rejection in document["must_reject"]?.arrayValue ?? [] {
            var reader = try JSONReader(rejection)
            let name = try reader.string("name", maxLength: 64)
            let text = try reader.string("text", maxLength: 1024)
            XCTAssertThrowsError(try JSONValue.parse(text), "case \(name) must fail closed")
        }
    }

    func testPublishedDecideCommandDecodes() throws {
        let command = try ApprovalDecideCommand(json: try JSONValue.parse(try fixture("decide-command.json")))
        XCTAssertEqual(command.decision, .approve)
        XCTAssertEqual(command.expectedStateVersion, 1)
        XCTAssertEqual(command.policyVersion, 3)
        XCTAssertEqual(command.envelope.type, .approvalDecide)
        // Re-encoding is byte-identical to the canonical form of the fixture,
        // so a signature over either verifies against the other.
        let reencoded = try JSONCanonicalization.canonicalize(command.json)
        let original = try JSONCanonicalization.canonicalize(try JSONValue.parse(try fixture("decide-command.json")))
        XCTAssertEqual(reencoded, original)
    }

    // MARK: shell-agent/1

    private func checkCanonicalAndDigest(_ name: String, _ json: JSONValue, _ hash: String) throws {
        XCTAssertEqual(
            String(decoding: try JSONCanonicalization.canonicalize(json), as: UTF8.self),
            String(decoding: try fixture("\(name).jcs.txt"), as: UTF8.self).trimmingCharacters(in: .newlines)
        )
        XCTAssertEqual(hash, String(decoding: try fixture("\(name).hash.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testPublishedAgentApprovalMatchesItsCanonicalFormAndDigest() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(try fixture("agent-approval-spec.json")))
        guard case .agentTool(let operation) = spec.operation else { return XCTFail("expected agent.tool.v1") }
        XCTAssertEqual(operation.kind, .shell)
        XCTAssertNil(operation.shellRequest?.shellIdentity)
        try checkCanonicalAndDigest("agent-approval-spec", spec.json, try spec.requestHash())
    }

    func testPublishedInputSpecMatchesItsCanonicalFormAndDigest() throws {
        let spec = try InputSpec(json: try JSONValue.parse(try fixture("input-spec.json")))
        XCTAssertEqual(spec.source.providerRequestID, .integer(23))
        try checkCanonicalAndDigest("input-spec", spec.json, try spec.requestHash())
    }

    func testPublishedInputRespondCommandBindsThePublishedSpec() throws {
        let spec = try InputSpec(json: try JSONValue.parse(try fixture("input-spec.json")))
        let raw = try JSONValue.parse(try fixture("input-respond-command.json"))
        let command = try InputRespondCommand(json: raw)
        XCTAssertEqual(command.requestHash, try spec.requestHash())
        XCTAssertNoThrow(try command.response.validate(against: spec))
        XCTAssertEqual(try JSONCanonicalization.canonicalize(command.json), try JSONCanonicalization.canonicalize(raw))
    }

    func testPublishedNegativeAgentVectorsFailClosed() throws {
        let specJSON = try JSONValue.parse(try fixture("input-spec.json"))
        let spec = try InputSpec(json: specJSON)
        let document = try JSONValue.parse(try fixture("agent-negative.json"))
        for item in document["invalid_responses"]?.arrayValue ?? [] {
            let name = item["name"]?.stringValue ?? "?"
            XCTAssertThrowsError(try InputResponse(json: try XCTUnwrap(item["response"])).validate(against: spec), name)
        }
        for item in document["invalid_specs"]?.arrayValue ?? [] {
            var members = try XCTUnwrap(specJSON.objectValue)
            for (key, value) in try XCTUnwrap(item["patch"]?.objectValue) { members[key] = value }
            XCTAssertThrowsError(try InputSpec(json: .object(members)), item["name"]?.stringValue ?? "?")
        }
    }
}
