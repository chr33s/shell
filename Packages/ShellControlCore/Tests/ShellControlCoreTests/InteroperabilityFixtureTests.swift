import Foundation
import Testing
@testable import ShellControlProtocol

/// Checks this implementation against the published fixtures in `protocol/`,
/// which are generated independently of the Swift code
/// (docs/specs/control-protocol.md section 20).
private var interoperabilityFixturesAvailable: Bool {
    let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures")
    return FileManager.default.fileExists(atPath: fixturesURL.path)
}

@Suite(.enabled(if: interoperabilityFixturesAvailable, "fixtures are not present in this build"))
final class InteroperabilityFixtureTests {
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
        try #require(FileManager.default.fileExists(atPath: url.path), "fixtures are not present in this build")
        return try Data(contentsOf: url)
    }

    @Test
    func testPublishedSpecMatchesItsPublishedCanonicalFormAndDigest() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(try fixture("approval-spec.json")))
        let canonical = try JSONCanonicalization.canonicalize(spec.json)
        let expectedCanonical = try fixture("approval-spec.jcs.txt")
        #expect(String(decoding: canonical, as: UTF8.self) == String(decoding: expectedCanonical, as: UTF8.self).trimmingCharacters(in: .newlines))
        let expectedDigest = String(decoding: try fixture("approval-spec.hash.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((try spec.requestHash()) == expectedDigest)
    }

    @Test
    func testCanonicalizationVectors() throws {
        let document = try JSONValue.parse(try fixture("canonicalization.json"), limits: JSONLimits(maxDocumentBytes: 1 << 20))
        for testCase in document["cases"]?.arrayValue ?? [] {
            var reader = try JSONReader(testCase)
            let name = try reader.string("name", maxLength: 64)
            let input = try reader.value("input")
            let expected = try reader.string("canonical", maxLength: 1024)
            #expect((try JSONCanonicalization.canonicalString(input)) == expected, "case \(name)")
        }
        for rejection in document["must_reject"]?.arrayValue ?? [] {
            var reader = try JSONReader(rejection)
            let name = try reader.string("name", maxLength: 64)
            let text = try reader.string("text", maxLength: 1024)
            #expect(throws: (any Error).self, "case \(name) must fail closed") { try JSONValue.parse(text) }
        }
    }

    @Test
    func testPublishedDecideCommandDecodes() throws {
        let command = try ApprovalDecideCommand(json: try JSONValue.parse(try fixture("decide-command.json")))
        #expect(command.decision == .approve)
        #expect(command.expectedStateVersion == 1)
        #expect(command.policyVersion == 3)
        #expect(command.envelope.type == .approvalDecide)
        // Re-encoding is byte-identical to the canonical form of the fixture,
        // so a signature over either verifies against the other.
        let reencoded = try JSONCanonicalization.canonicalize(command.json)
        let original = try JSONCanonicalization.canonicalize(try JSONValue.parse(try fixture("decide-command.json")))
        #expect(reencoded == original)
    }

    // MARK: shell-agent/1

    private func checkCanonicalAndDigest(_ name: String, _ json: JSONValue, _ hash: String) throws {
        let canonical = String(decoding: try JSONCanonicalization.canonicalize(json), as: UTF8.self)
        let published = String(decoding: try fixture("\(name).jcs.txt"), as: UTF8.self)
        #expect(canonical == published.trimmingCharacters(in: .newlines))
        let publishedHash = String(decoding: try fixture("\(name).hash.txt"), as: UTF8.self)
        #expect(hash == publishedHash.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test
    func testPublishedAgentApprovalMatchesItsCanonicalFormAndDigest() throws {
        let spec = try ApprovalSpec(json: try JSONValue.parse(try fixture("agent-approval-spec.json")))
        guard case .agentTool(let operation) = spec.operation else { Issue.record("expected agent.tool.v1")
return }
        #expect(operation.kind == .shell)
        #expect((operation.shellRequest?.shellIdentity) == nil)
        try checkCanonicalAndDigest("agent-approval-spec", spec.json, try spec.requestHash())
    }

    @Test
    func testPublishedInputSpecMatchesItsCanonicalFormAndDigest() throws {
        let spec = try InputSpec(json: try JSONValue.parse(try fixture("input-spec.json")))
        #expect(spec.source.providerRequestID == .integer(23))
        try checkCanonicalAndDigest("input-spec", spec.json, try spec.requestHash())
    }

    @Test
    func testPublishedInputRespondCommandBindsThePublishedSpec() throws {
        let spec = try InputSpec(json: try JSONValue.parse(try fixture("input-spec.json")))
        let raw = try JSONValue.parse(try fixture("input-respond-command.json"))
        let command = try InputRespondCommand(json: raw)
        #expect(command.requestHash == (try spec.requestHash()))
        do { _ = try command.response.validate(against: spec) } catch { Issue.record("unexpected error: \(error)") }
        #expect((try JSONCanonicalization.canonicalize(command.json)) == (try JSONCanonicalization.canonicalize(raw)))
    }

    @Test
    func testPublishedNegativeAgentVectorsFailClosed() throws {
        let specJSON = try JSONValue.parse(try fixture("input-spec.json"))
        let spec = try InputSpec(json: specJSON)
        let document = try JSONValue.parse(try fixture("agent-negative.json"))
        for item in document["invalid_responses"]?.arrayValue ?? [] {
            let name = item["name"]?.stringValue ?? "?"
            #expect(throws: (any Error).self, "\(name)") {
                let response = try #require(item["response"])
                try InputResponse(json: response).validate(against: spec)
            }
        }
        for item in document["invalid_specs"]?.arrayValue ?? [] {
            var members = try #require(specJSON.objectValue)
            for (key, value) in try #require(item["patch"]?.objectValue) { members[key] = value }
            #expect(throws: (any Error).self, "\(item["name"]?.stringValue ?? "?")") { try InputSpec(json: .object(members)) }
        }
    }
}
