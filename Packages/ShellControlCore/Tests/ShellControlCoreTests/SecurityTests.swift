import Foundation
import Testing
import CryptoKit
@testable import ShellControlProtocol
@testable import ShellControlSecurity

@Suite
final class SecurityTests {
    private func makeCommand(deviceID: ControlID) throws -> ApprovalDecideCommand {
        let issued = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:00:20Z"))
        return try ApprovalDecideCommand(
            envelope: try ControlCommandEnvelope(
                type: .approvalDecide,
                commandID: try #require(ControlID("50000000-0000-4000-8000-000000000001")),
                deviceID: deviceID,
                audience: "shell-control:70000000-0000-4000-8000-000000000001",
                issuedAt: issued,
                notAfter: issued.adding(40)
            ),
            requestID: try #require(ControlID("10000000-0000-4000-8000-000000000001")),
            requestHash: "sha256:" + String(repeating: "0", count: 64),
            expectedStateVersion: 1,
            policyVersion: 3,
            decision: .approve,
            challengeID: "server-issued-256-bit-base64url-value"
        )
    }

    @Test
    func testSignAndVerifyRoundTrip() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let command = try makeCommand(deviceID: deviceID)
        let jws = try ControlJWS.sign(payload: command.json, deviceID: deviceID, key: key)
        let verified = try ControlJWS.verify(compactSerialization: jws) { id in
            id == deviceID ? key.publicJWK : nil
        }
        #expect(verified.deviceID == deviceID)
        guard case .approvalDecide(let decoded) = verified.command else { Issue.record("wrong command")
return }
        #expect(decoded.decision == .approve)
        #expect(jws.split(separator: ".").count == 3)
    }

    @Test
    func testSignatureIsSixtyFourRawBytesNotDER() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let jws = try ControlJWS.sign(payload: try makeCommand(deviceID: deviceID).json, deviceID: deviceID, key: key)
        let signature = try #require(Base64URL.decode(String(jws.split(separator: ".")[2])))
        #expect(signature.count == 64)
    }

    @Test
    func testUnknownKeyIsRejected() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let jws = try ControlJWS.sign(payload: try makeCommand(deviceID: deviceID).json, deviceID: deviceID, key: key)
        #expect(throws: (any Error).self) { try ControlJWS.verify(compactSerialization: jws) { _ in nil } }
    }

    @Test
    func testAlgorithmNoneIsRejected() throws {
        let payload = try JSONCanonicalization.canonicalize(try makeCommand(deviceID: .random()).json)
        let header = try JSONCanonicalization.canonicalize(.object([
            "alg": "none",
            "kid": JSONValue(ControlID.random()),
            "typ": .string(ControlJWS.type)
        ]))
        let forged = "\(Base64URL.encode(header)).\(Base64URL.encode(payload)).\(Base64URL.encode(Data(repeating: 0, count: 64)))"
        #expect(throws: (any Error).self) { try ControlJWS.verify(compactSerialization: forged) { _ in InMemoryDeviceKey().publicJWK } }
    }

    @Test
    func testEmbeddedKeyHeaderIsRejected() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let payload = try JSONCanonicalization.canonicalize(try makeCommand(deviceID: deviceID).json)
        let header = try JSONCanonicalization.canonicalize(.object([
            "alg": "ES256",
            "kid": JSONValue(deviceID),
            "typ": .string(ControlJWS.type),
            "jwk": key.publicJWK.json
        ]))
        let input = "\(Base64URL.encode(header)).\(Base64URL.encode(payload))"
        let signature = try key.signature(for: Data(input.utf8))
        let forged = "\(input).\(Base64URL.encode(signature))"
        #expect(throws: (any Error).self) { try ControlJWS.verify(compactSerialization: forged) { _ in key.publicJWK } }
    }

    @Test
    func testTamperedPayloadFailsVerification() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let jws = try ControlJWS.sign(payload: try makeCommand(deviceID: deviceID).json, deviceID: deviceID, key: key)
        var segments = jws.split(separator: ".").map(String.init)
        var payload = try JSONReader(try JSONValue.parse(try #require(Base64URL.decode(segments[1])))).members
        payload["decision"] = .string("reject")
        segments[1] = Base64URL.encode(try JSONCanonicalization.canonicalize(.object(payload)))
        #expect(throws: (any Error).self) { try ControlJWS.verify(compactSerialization: segments.joined(separator: ".")) { _ in key.publicJWK } }
    }

    @Test
    func testKeyIdentifierMustMatchTheCommandDevice() throws {
        let key = InMemoryDeviceKey()
        let signer = ControlID.random()
        let command = try makeCommand(deviceID: .random())
        let jws = try ControlJWS.sign(payload: command.json, deviceID: signer, key: key)
        #expect(throws: (any Error).self) { try ControlJWS.verify(compactSerialization: jws) { _ in key.publicJWK } }
    }

    @Test
    func testJWKThumbprintIsStable() throws {
        let key = InMemoryDeviceKey()
        #expect((try key.publicJWK.thumbprint()) == (try DeviceJWK(json: key.publicJWK.json).thumbprint()))
        #expect((try key.publicJWK.displayFingerprint().count) == 19)
    }

    @Test
    func testBase64URLRejectsPaddedInput() throws {
        #expect((Base64URL.decode("AAAA=")) == nil)
        #expect(Base64URL.encode(Data([0xFF, 0xFE])) == "__4")
    }
}
