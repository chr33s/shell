import XCTest
import CryptoKit
@testable import ShellControlProtocol
@testable import ShellControlSecurity

final class SecurityTests: XCTestCase {
    private func makeCommand(deviceID: ControlID) throws -> ApprovalDecideCommand {
        let issued = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:20Z"))
        return try ApprovalDecideCommand(
            envelope: try ControlCommandEnvelope(
                type: .approvalDecide,
                commandID: try XCTUnwrap(ControlID("50000000-0000-4000-8000-000000000001")),
                deviceID: deviceID,
                audience: "shell-control:70000000-0000-4000-8000-000000000001",
                issuedAt: issued,
                notAfter: issued.adding(40)
            ),
            requestID: try XCTUnwrap(ControlID("10000000-0000-4000-8000-000000000001")),
            requestHash: "sha256:" + String(repeating: "0", count: 64),
            expectedStateVersion: 1,
            policyVersion: 3,
            decision: .approve,
            challengeID: "server-issued-256-bit-base64url-value"
        )
    }

    func testSignAndVerifyRoundTrip() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let command = try makeCommand(deviceID: deviceID)
        let jws = try ControlJWS.sign(payload: command.json, deviceID: deviceID, key: key)
        let verified = try ControlJWS.verify(compactSerialization: jws) { id in
            id == deviceID ? key.publicJWK : nil
        }
        XCTAssertEqual(verified.deviceID, deviceID)
        guard case .approvalDecide(let decoded) = verified.command else { return XCTFail("wrong command") }
        XCTAssertEqual(decoded.decision, .approve)
        XCTAssertEqual(jws.split(separator: ".").count, 3)
    }

    func testSignatureIsSixtyFourRawBytesNotDER() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let jws = try ControlJWS.sign(payload: try makeCommand(deviceID: deviceID).json, deviceID: deviceID, key: key)
        let signature = try XCTUnwrap(Base64URL.decode(String(jws.split(separator: ".")[2])))
        XCTAssertEqual(signature.count, 64)
    }

    func testUnknownKeyIsRejected() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let jws = try ControlJWS.sign(payload: try makeCommand(deviceID: deviceID).json, deviceID: deviceID, key: key)
        XCTAssertThrowsError(try ControlJWS.verify(compactSerialization: jws) { _ in nil })
    }

    func testAlgorithmNoneIsRejected() throws {
        let payload = try JSONCanonicalization.canonicalize(try makeCommand(deviceID: .random()).json)
        let header = try JSONCanonicalization.canonicalize(.object([
            "alg": "none",
            "kid": JSONValue(ControlID.random()),
            "typ": .string(ControlJWS.type),
        ]))
        let forged = "\(Base64URL.encode(header)).\(Base64URL.encode(payload)).\(Base64URL.encode(Data(repeating: 0, count: 64)))"
        XCTAssertThrowsError(try ControlJWS.verify(compactSerialization: forged) { _ in InMemoryDeviceKey().publicJWK })
    }

    func testEmbeddedKeyHeaderIsRejected() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let payload = try JSONCanonicalization.canonicalize(try makeCommand(deviceID: deviceID).json)
        let header = try JSONCanonicalization.canonicalize(.object([
            "alg": "ES256",
            "kid": JSONValue(deviceID),
            "typ": .string(ControlJWS.type),
            "jwk": key.publicJWK.json,
        ]))
        let input = "\(Base64URL.encode(header)).\(Base64URL.encode(payload))"
        let signature = try key.signature(for: Data(input.utf8))
        let forged = "\(input).\(Base64URL.encode(signature))"
        XCTAssertThrowsError(try ControlJWS.verify(compactSerialization: forged) { _ in key.publicJWK })
    }

    func testTamperedPayloadFailsVerification() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let jws = try ControlJWS.sign(payload: try makeCommand(deviceID: deviceID).json, deviceID: deviceID, key: key)
        var segments = jws.split(separator: ".").map(String.init)
        var payload = try JSONReader(try JSONValue.parse(try XCTUnwrap(Base64URL.decode(segments[1])))).members
        payload["decision"] = .string("reject")
        segments[1] = Base64URL.encode(try JSONCanonicalization.canonicalize(.object(payload)))
        XCTAssertThrowsError(try ControlJWS.verify(compactSerialization: segments.joined(separator: ".")) { _ in key.publicJWK })
    }

    func testKeyIdentifierMustMatchTheCommandDevice() throws {
        let key = InMemoryDeviceKey()
        let signer = ControlID.random()
        let command = try makeCommand(deviceID: .random())
        let jws = try ControlJWS.sign(payload: command.json, deviceID: signer, key: key)
        XCTAssertThrowsError(try ControlJWS.verify(compactSerialization: jws) { _ in key.publicJWK })
    }

    func testJWKThumbprintIsStable() throws {
        let key = InMemoryDeviceKey()
        XCTAssertEqual(try key.publicJWK.thumbprint(), try DeviceJWK(json: key.publicJWK.json).thumbprint())
        XCTAssertEqual(try key.publicJWK.displayFingerprint().count, 19)
    }

    func testBase64URLRejectsPaddedInput() {
        XCTAssertNil(Base64URL.decode("AAAA="))
        XCTAssertEqual(Base64URL.encode(Data([0xFF, 0xFE])), "__4")
    }
}
