import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlClient

/// The `shell-watch-gateway/1` profile's portable rules: identity versus
/// route, signed route updates, pairing invitations, and strict gateway
/// framing (docs/specs/control-protocol.md).
@Suite
final class GatewayProfileTests {
    private let originID = ControlID.random()

    // MARK: Route policy

    @Test
    func testOnlyTailnetHTTPSAndLoopbackRoutesAreAccepted() throws {
        #expect((try OriginRoute("https://MacBook.Example.ts.net/").url.absoluteString) == "https://macbook.example.ts.net")
        #expect((try OriginRoute("https://macbook.example.ts.net").kind) == .tailscaleHTTPS)
        #expect((try OriginRoute("http://127.0.0.1:8443").kind) == .loopbackHTTP)
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
            #expect(throws: (any Error).self, "\(rejected)") { try OriginRoute(rejected) }
        }
    }

    // MARK: Route updates

    @Test
    func testRouteUpdateSignedByThePinnedKeyChangesRoutingOnly() throws {
        let key = OriginSigningKey()
        let origin = OriginIdentity(originID: originID, publicJWK: key.publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [try OriginRoute("https://old.example.ts.net")], pairedAt: ControlTimestamp(Date()))
        let update = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://new.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)

        // The QR link round-trips to the same signed document.
        let scanned = try OriginRouteUpdate(link: try update.link())
        let next = try OriginTrust.apply(scanned, to: pinned)
        #expect(next.origin == pinned.origin, "identity is unchanged")
        #expect(next.routes.map(\.url.absoluteString) == ["https://new.example.ts.net", "https://old.example.ts.net"])
    }

    @Test
    func testRouteUpdateSignedByAnotherKeyIsRejected() throws {
        let origin = OriginIdentity(originID: originID, publicJWK: OriginSigningKey().publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [], pairedAt: ControlTimestamp(Date()))
        let forged = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://evil.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: OriginSigningKey())
        #expect(throws: (any Error).self) { try OriginTrust.apply(forged, to: pinned) }
    }

    @Test
    func testRouteUpdateForAnotherOriginIsRejectedEvenWithAValidSignature() throws {
        let key = OriginSigningKey()
        let pinned = PinnedOrigin(origin: OriginIdentity(originID: originID, publicJWK: key.publicJWK), routes: [], pairedAt: ControlTimestamp(Date()))
        let other = try OriginRouteUpdate.sign(originID: .random(), route: try OriginRoute("https://new.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)
        #expect(throws: (any Error).self) { try OriginTrust.apply(other, to: pinned) }
    }

    @Test
    func testTamperedRouteUpdateFailsVerification() throws {
        let key = OriginSigningKey()
        let pinned = PinnedOrigin(origin: OriginIdentity(originID: originID, publicJWK: key.publicJWK), routes: [], pairedAt: ControlTimestamp(Date()))
        let update = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://new.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)
        var members = try #require(update.document.objectValue)
        members["route"] = try OriginRoute("https://evil.example.ts.net").json
        let tampered = try OriginRouteUpdate(unverified: .object(members))
        #expect(throws: (any Error).self) { try OriginTrust.apply(tampered, to: pinned) }
    }

    /// A proof and a route update share a key but not a domain.
    @Test
    func testSignedDocumentTypesAreDomainSeparated() throws {
        let key = OriginSigningKey()
        let proof = try OriginProof.sign(originID: originID, nonce: "n", issuedAt: ControlTimestamp(Date()), key: key)
        #expect(throws: (any Error).self) { try SignedDocument.verify(proof.document, type: OriginRouteUpdate.type, publicKey: key.publicJWK) }
        do { _ = try proof.verify(expected: OriginIdentity(originID: originID, publicJWK: key.publicJWK), nonce: "n") } catch { Issue.record("unexpected error: \(error)") }
        #expect(throws: (any Error).self) { try proof.verify(expected: OriginIdentity(originID: originID, publicJWK: key.publicJWK), nonce: "other") }
    }

    // MARK: Pairing and trust assessment

    @Test
    func testInvitationRoundTripsThroughItsLinkAndRawJSON() throws {
        let key = OriginSigningKey()
        let invitation = try PairingInvitation(
            origin: OriginIdentity(originID: originID, publicJWK: key.publicJWK),
            route: try OriginRoute("https://macbook.example.ts.net"),
            pairingID: .random(),
            pairingSecret: Base64URL.encode(Data(repeating: 9, count: 32)),
            expiresAt: ControlTimestamp(Date().addingTimeInterval(600))
        )
        #expect((try PairingInvitation(scanned: try invitation.link().absoluteString)) == invitation)
        #expect((try PairingInvitation(scanned: try JSONCanonicalization.canonicalString(invitation.json))) == invitation)
        #expect(throws: (any Error).self) { try PairingInvitation(scanned: "https://macbook.example.ts.net") }
    }

    @Test
    func testReplacingTheOriginKeyRequiresANewTrustDecision() throws {
        let key = OriginSigningKey()
        let origin = OriginIdentity(originID: originID, publicJWK: key.publicJWK)
        let pinned = PinnedOrigin(origin: origin, routes: [try OriginRoute("https://old.example.ts.net")], pairedAt: ControlTimestamp(Date()))
        func invite(_ identity: OriginIdentity, _ route: String) throws -> PairingInvitation {
            try PairingInvitation(origin: identity, route: try OriginRoute(route), pairingID: .random(),
                                  pairingSecret: Base64URL.encode(Data(repeating: 1, count: 32)), expiresAt: ControlTimestamp(Date()))
        }
        #expect(OriginTrust.assess(try invite(origin, "https://renamed.example.ts.net"), against: pinned) == .sameOrigin)
        let replaced = OriginIdentity(originID: originID, publicJWK: OriginSigningKey().publicJWK)
        #expect(OriginTrust.assess(try invite(replaced, "https://old.example.ts.net"), against: pinned) == .differentOrigin)
        #expect(OriginTrust.assess(try invite(origin, "https://old.example.ts.net"), against: nil) == .firstPairing)
    }

    @Test
    func testPinnedOriginPersistsAndBoundsItsRouteCache() throws {
        var pinned = PinnedOrigin(origin: OriginIdentity(originID: originID, publicJWK: OriginSigningKey().publicJWK), routes: [], pairedAt: ControlTimestamp(Date()))
        for index in 0..<12 { pinned.prefer(try OriginRoute("https://m\(index).example.ts.net")) }
        #expect(pinned.routes.count == PinnedOrigin.maximumRoutes)
        #expect(pinned.routes.first?.url.host == "m11.example.ts.net")
        #expect((try PinnedOrigin(json: pinned.json)) == pinned)
    }

    /// Route recovery tries the last known route first, then older signed
    /// routes; an endpoint that cannot prove the pinned key never wins.
    @Test
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
        #expect(resolved.route.url.host == "good.example.ts.net")

        let onlyImpostor = PinnedOrigin(origin: origin, routes: [try OriginRoute("https://impostor.example.ts.net")], pairedAt: ControlTimestamp(Date()))
        do {
            _ = try await resolver.resolve(onlyImpostor)
            Issue.record("expected mismatch")
        } catch let error as OriginRouteResolver.ResolutionError {
            #expect(error == .originMismatch)
        }
    }

    // MARK: Gateway framing

    @Test
    func testGatewayRequestRoundTrips() throws {
        let request = try WatchGatewayRequest(type: .approvalFetch, watchDeviceID: .random(), body: .object(["request_id": JSONValue(ControlID.random())]))
        #expect((try WatchGatewayRequest(data: try request.encoded())) == request)
    }

    @Test
    func testGatewayRejectsDuplicateKeysUnknownTypesAndMembersAndOversize() throws {
        let id = ControlID.random().rawValue
        let duplicate = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","message_id":"\#(id)","type":"approval.fetch","watch_device_id":"\#(id)","body":{}}"#
        #expect(throws: (any Error).self) { try WatchGatewayRequest(data: Data(duplicate.utf8)) }
        let unknownType = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","type":"approval.auto","watch_device_id":"\#(id)","body":{}}"#
        do { _ = try WatchGatewayRequest(data: Data(unknownType.utf8))
Issue.record("expected an error")
} catch let error {
            #expect(error as? WatchGatewayError == .unknownType("approval.auto"))
        }
        let extra = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","type":"approval.fetch","watch_device_id":"\#(id)","body":{},"gateway_id":"x"}"#
        #expect(throws: (any Error).self) { try WatchGatewayRequest(data: Data(extra.utf8)) }
        let badVersion = #"{"v":2,"protocol":"shell-watch-gateway/1","message_id":"\#(id)","type":"approval.fetch","watch_device_id":"\#(id)","body":{}}"#
        do { _ = try WatchGatewayRequest(data: Data(badVersion.utf8))
Issue.record("expected an error")
} catch let error {
            #expect(error as? WatchGatewayError == .unsupportedVersion)
        }
        let badID = #"{"v":1,"protocol":"shell-watch-gateway/1","message_id":"not-a-uuid","type":"approval.fetch","watch_device_id":"\#(id)","body":{}}"#
        #expect(throws: (any Error).self) { try WatchGatewayRequest(data: Data(badID.utf8)) }
        do { _ = try WatchGatewayRequest(data: Data(repeating: 0x20, count: WatchGatewayProtocol.maximumMessageBytes + 1))
Issue.record("expected an error")
} catch let error {
            #expect(error as? WatchGatewayError == .messageTooLarge)
        }
        // Everything but enrollment must name its Watch.
        #expect(throws: (any Error).self) { try WatchGatewayRequest(type: .commandSubmit, watchDeviceID: nil) }
    }

    @Test
    func testWatchEnrollmentRequestProvesPossessionOfItsKey() throws {
        let key = InMemoryDeviceKey()
        let request = try WatchEnrollmentRequest.make(key: key, label: "Apple Watch")
        do { _ = try request.verifySignature() } catch { Issue.record("unexpected error: \(error)") }
        let swapped = try WatchEnrollmentRequest(publicJWK: InMemoryDeviceKey().publicJWK, label: request.label, nonce: request.nonce, signature: request.signature)
        #expect(throws: (any Error).self) { try swapped.verifySignature() }
        #expect((try WatchEnrollmentRequest(json: request.json)) == request)
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
