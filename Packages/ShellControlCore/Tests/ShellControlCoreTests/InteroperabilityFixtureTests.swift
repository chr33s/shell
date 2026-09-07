import XCTest
@testable import ShellControlProtocol

/// Checks this implementation against the published fixtures in `protocol/`,
/// which are generated independently of the Swift code
/// (spec.watch.md section 18).
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
}
