import XCTest
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlClient

/// The `shell-watch-gateway/1` profile's portable rules: identity versus
/// route, signed route updates, pairing invitations, and strict gateway
/// framing (spec.iphone-gateway.md).
final class GatewayProfileTests: XCTestCase {
    private let originID = ControlID.random()

    // MARK: Route policy

    func testOnlyTailnetHTTPSAndLoopbackRoutesAreAccepted() throws {
        XCTAssertEqual(try OriginRoute("https://MacBook.Example.ts.net/").url.absoluteString, "https://macbook.example.ts.net")
        XCTAssertEqual(try OriginRoute("https://macbook.example.ts.net").kind, .tailscaleHTTPS)
        XCTAssertEqual(try OriginRoute("http://127.0.0.1:8443").kind, .loopbackHTTP)
        for rejected in [
            "http://macbook.example.ts.net",          // no TLS off loopback
            "https://control.example.com",            // not in the tailnet
            "https://abc.trycloudflare.com",          // a public tunnel
            "https://ts.net",                         // no machine name
            "https://evil.ts.net.example.com",        // suffix trick
            "https://macbook.example.ts.net/path",
            "https://user@macbook.example.ts.net",
            "https://macbook.example.ts.net?x=1"
        ] {
            XCTAssertThrowsError(try OriginRoute(rejected), rejected)
        }
    }

    // MARK: Route updates

    func testRouteUpdateSignedByThePinnedKeyChangesRoutingOnly() throws {
        let key = OriginSigningKey()
        let origin = OriginIdentity(originID: originID, publicJWK: key.publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [try OriginRoute("https://old.example.ts.net")], pairedAt: ControlTimestamp(Date()))
        let update = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://new.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)

        // The QR link round-trips to the same signed document.
        let scanned = try OriginRouteUpdate(link: try update.link())
        let next = try OriginTrust.apply(scanned, to: pinned)
        XCTAssertEqual(next.origin, pinned.origin, "identity is unchanged")
        XCTAssertEqual(next.routes.map(\.url.absoluteString), ["https://new.example.ts.net", "https://old.example.ts.net"])
    }

    func testRouteUpdateSignedByAnotherKeyIsRejected() throws {
        let origin = OriginIdentity(originID: originID, publicJWK: OriginSigningKey().publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [], pairedAt: ControlTimestamp(Date()))
        let forged = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://evil.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: OriginSigningKey())
        XCTAssertThrowsError(try OriginTrust.apply(forged, to: pinned))
    }

    func testRouteUpdateForAnotherOriginIsRejectedEvenWithAValidSignature() throws {
        let key = OriginSigningKey()
        let pinned = PinnedOrigin(origin: OriginIdentity(originID: originID, publicJWK: key.publicJWK), routes: [], pairedAt: ControlTimestamp(Date()))
        let other = try OriginRouteUpdate.sign(originID: .random(), route: try OriginRoute("https://new.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)
        XCTAssertThrowsError(try OriginTrust.apply(other, to: pinned))
    }

    func testTamperedRouteUpdateFailsVerification() throws {
        let key = OriginSigningKey()
        let pinned = PinnedOrigin(origin: OriginIdentity(originID: originID, publicJWK: key.publicJWK), routes: [], pairedAt: ControlTimestamp(Date()))
        let update = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://new.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)
        var members = try XCTUnwrap(update.document.objectValue)
        members["route"] = try OriginRoute("https://evil.example.ts.net").json
        let tampered = try OriginRouteUpdate(unverified: .object(members))
        XCTAssertThrowsError(try OriginTrust.apply(tampered, to: pinned))
    }

    /// A proof and a route update share a key but not a domain.
    func testSignedDocumentTypesAreDomainSeparated() throws {
        let key = OriginSigningKey()
        let proof = try OriginProof.sign(originID: originID, nonce: "n", issuedAt: ControlTimestamp(Date()), key: key)
        XCTAssertThrowsError(try SignedDocument.verify(proof.document, type: OriginRouteUpdate.type, publicKey: key.publicJWK))
        XCTAssertNoThrow(try proof.verify(expected: OriginIdentity(originID: originID, publicJWK: key.publicJWK), nonce: "n"))
        XCTAssertThrowsError(try proof.verify(expected: OriginIdentity(originID: originID, publicJWK: key.publicJWK), nonce: "other"))
    }

    // MARK: Pairing and trust assessment

    func testInvitationRoundTripsThroughItsLinkAndRawJSON() throws {
        let key = OriginSigningKey()
        let invitation = try PairingInvitation(
            origin: OriginIdentity(originID: originID, publicJWK: key.publicJWK),
            route: try OriginRoute("https://macbook.example.ts.net"),
            pairingID: .random(),
            pairingSecret: Base64URL.encode(Data(repeating: 9, count: 32)),
            expiresAt: ControlTimestamp(Date().addingTimeInterval(600))
        )
        XCTAssertEqual(try PairingInvitation(scanned: try invitation.link().absoluteString), invitation)
        XCTAssertEqual(try PairingInvitation(scanned: try JSONCanonicalization.canonicalString(invitation.json)), invitation)
        XCTAssertThrowsError(try PairingInvitation(scanned: "https://macbook.example.ts.net"))
    }

    func testReplacingTheOriginKeyRequiresANewTrustDecision() throws {
        let key = OriginSigningKey()
        let origin = OriginIdentity(originID: originID, publicJWK: key.publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [try OriginRoute("https://old.example.ts.net")], pairedAt: ControlTimestamp(Date()))
        func invite(_ identity: OriginIdentity, _ route: String) throws -> PairingInvitation {
            try PairingInvitation(origin: identity, route: try OriginRoute(route), pairingID: .random(),
                                  pairingSecret: Base64URL.encode(Data(repeating: 1, count: 32)), expiresAt: ControlTimestamp(Date()))
        }
        XCTAssertEqual(OriginTrust.assess(try invite(origin, "https://renamed.example.ts.net"), against: pinned), .sameOrigin)
        let replaced = OriginIdentity(originID: originID, publicJWK: OriginSigningKey().publicJWK)
        XCTAssertEqual(OriginTrust.assess(try invite(replaced, "https://old.example.ts.net"), against: pinned), .differentOrigin)
        XCTAssertEqual(OriginTrust.assess(try invite(origin, "https://old.example.ts.net"), against: nil), .firstPairing)
    }

    func testPinnedOriginPersistsAndBoundsItsRouteCache() throws {
        var pinned = PinnedOrigin(origin: OriginIdentity(originID: originID, publicJWK: OriginSigningKey().publicJWK), routes: [], pairedAt: ControlTimestamp(Date()))
        for index in 0..<12 { pinned.prefer(try OriginRoute("https://m\(index).example.ts.net")) }
        XCTAssertEqual(pinned.routes.count, PinnedOrigin.maximumRoutes)
        XCTAssertEqual(pinned.routes.first?.url.host, "m11.example.ts.net")
        XCTAssertEqual(try PinnedOrigin(json: pinned.json), pinned)
    }

    /// Route recovery tries the last known route first, then older signed
    /// routes; an endpoint that cannot prove the pinned key never wins.
    func testResolverSkipsUnreachableAndImpostorRoutes() async throws {
        let key = OriginSigningKey()
        let origin = OriginIdentity(originID: originID, publicJWK: key.publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [
            try OriginRoute("https://down.example.ts.net"),
            try OriginRoute("https://impostor.example.ts.net"),
            try OriginRoute("https://good.example.ts.net")
        ], pairedAt: ControlTimestamp(Date()))
        let transport = ProofTransport(originID: originID, keys: [
            "good.example.ts.net": key,
            "impostor.example.ts.net": OriginSigningKey()
        ])
        let resolver = OriginRouteResolver { ControlAPIClient(baseURL: $0, transport: transport) }
        let resolved = try await resolver.resolve(pinned)
        XCTAssertEqual(resolved.route.url.host, "good.example.ts.net")

        let onlyImpostor = PinnedOrigin(origin: origin, routes: [try OriginRoute("https://impostor.example.ts.net")], pairedAt: ControlTimestamp(Date()))
        do {
            _ = try await resolver.resolve(onlyImpostor)
            XCTFail("expected mismatch")
        } catch let error as OriginRouteResolver.ResolutionError {
            XCTAssertEqual(error, .originMismatch)
        }
    }

    // MARK: Gateway framing

    func testGatewayRequestRoundTrips() throws {
        let request = try WatchGatewayRequest(type: .approvalFetch, watchDeviceID: .random(), body: .object(["request_id": JSONValue(ControlID.random())]))
        XCTAssertEqual(try WatchGatewayRequest(data: try request.encoded()), request)
    }

    func testGatewayRejectsDuplicateKeysUnknownTypesAndMembersAndOversize() throws {
        let id = ControlID.random().rawValue
        let duplicate = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","message_id":"\#(id)","type":"approval.fetch","watch_device_id":"\#(id)","body":{}}"#
        XCTAssertThrowsError(try WatchGatewayRequest(data: Data(duplicate.utf8)))
        let unknownType = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","type":"approval.auto","watch_device_id":"\#(id)","body":{}}"#
        XCTAssertThrowsError(try WatchGatewayRequest(data: Data(unknownType.utf8))) { error in
            XCTAssertEqual(error as? WatchGatewayError, .unknownType("approval.auto"))
        }
        let extra = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","type":"approval.fetch","watch_device_id":"\#(id)","body":{},"gateway_id":"x"}"#
        XCTAssertThrowsError(try WatchGatewayRequest(data: Data(extra.utf8)))
        let badVersion = #"{"v":2,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","type":"approval.fetch","watch_device_id":"\#(id)","body":{}}"#
        XCTAssertThrowsError(try WatchGatewayRequest(data: Data(badVersion.utf8))) { error in
            XCTAssertEqual(error as? WatchGatewayError, .unsupportedVersion)
        }
        let badID = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"not-a-uuid","type":"approval.fetch","watch_device_id":"\#(id)","body":{}}"#
        XCTAssertThrowsError(try WatchGatewayRequest(data: Data(badID.utf8)))
        XCTAssertThrowsError(try WatchGatewayRequest(data: Data(repeating: 0x20, count: WatchGatewayProtocol.maximumMessageBytes + 1))) { error in
            XCTAssertEqual(error as? WatchGatewayError, .messageTooLarge)
        }
        // Everything but enrollment must name its Watch.
        XCTAssertThrowsError(try WatchGatewayRequest(type: .commandSubmit, watchDeviceID: nil))
    }

    func testWatchEnrollmentRequestProvesPossessionOfItsKey() throws {
        let key = InMemoryDeviceKey()
        let request = try WatchEnrollmentRequest.make(key: key, label: "Apple Watch")
        XCTAssertNoThrow(try request.verifySignature())
        let swapped = try WatchEnrollmentRequest(publicJWK: InMemoryDeviceKey().publicJWK, label: request.label, nonce: request.nonce, signature: request.signature)
        XCTAssertThrowsError(try swapped.verifySignature())
        XCTAssertEqual(try WatchEnrollmentRequest(json: request.json), request)
    }
}

/// Answers `/v1/origin/proof` per host with the configured key; hosts without
/// a key are unreachable.
private struct ProofTransport: ControlHTTPTransport {
    let originID: ControlID
    let keys: [String: OriginSigningKey]

    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        guard let host = baseURL.host, let key = keys[host] else { throw TransportError.offline }
        let nonce = request.query.first { $0.0 == "nonce" }?.1 ?? ""
        let proof = try OriginProof.sign(originID: originID, nonce: nonce, issuedAt: ControlTimestamp(Date()), key: key)
        return ControlHTTPResponse(status: 200, body: try JSONCanonicalization.canonicalize(proof.document))
    }
}
