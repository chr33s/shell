import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

@Suite
final class AdminSetupTests {
    private func makeService(_ harness: BrokerHarness) -> BrokerService {
        BrokerService(
            store: harness.store,
            configuration: BrokerService.Configuration(
                verificationURI: "https://control.example/v1/oauth/confirm",
                allowedAPNsTopics: ["dev.chr33s.shell.watchkitapp"],
                adminSecret: "admin-secret",
                adminAccountID: harness.accountID
            )
        )
    }

    @Test
    func testAdminPendingRequiresLoopbackHostAndAdminSecret() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        _ = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://control.example/v1/oauth/confirm"
        )
        let service = makeService(harness)

        let hidden = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/admin/pending",
            query: [:],
            headers: [
                "authorization": "Admin admin-secret",
                "host": "random.trycloudflare.com"
            ],
            body: Data()
        ))
        #expect(hidden.status == 404)

        let unauthenticated = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/admin/pending",
            query: [:],
            headers: ["host": "127.0.0.1:8443"],
            body: Data()
        ))
        #expect(unauthenticated.status == 403)

        let ok = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/admin/pending",
            query: [:],
            headers: [
                "authorization": "Admin admin-secret",
                "host": "127.0.0.1:8443"
            ],
            body: Data()
        ))
        #expect(ok.status == 200)
        let body = try JSONValue.parse(ok.body)
        #expect(body["pending"]?.arrayValue?.count == 1)
        #expect(body["pending"]?.arrayValue?.first?["label"]?.stringValue == "Watch")
        #expect(body["pending"]?.arrayValue?.first?["key_fingerprint"]?.stringValue == (try key.publicJWK.displayFingerprint()))
    }

    @Test
    func testAdminCanProvisionAnOriginSecretOnce() async throws {
        let harness = BrokerHarness()
        let service = makeService(harness)
        let body = try JSONCanonicalization.canonicalize(.object(["label": "studio mac"]))
        let created = await service.handle(HTTPServer.Request(
            method: "POST",
            path: "/v1/admin/origins",
            query: [:],
            headers: [
                "authorization": "Admin admin-secret",
                "content-type": "application/json",
                "host": "localhost"
            ],
            body: body
        ))
        #expect(created.status == 201)
        let json = try JSONValue.parse(created.body)
        let originID = try #require(json["origin_id"]?.stringValue)
        let secret = try #require(json["origin_secret"]?.stringValue)
        #expect(!(secret.isEmpty))
        let principal = try await harness.store.authenticateOrigin(originID: ControlID(originID)!, secret: secret)
        guard case .origin = principal else { Issue.record("expected origin principal")
return }
    }

    @Test
    func testNativeOriginProvisioningIsIdempotentAndConflictsSafely() async throws {
        let harness = BrokerHarness()
        let service = makeService(harness)
        let originID = ControlID.random()
        func request(secret: String) async throws -> HTTPServer.Response {
            let body = try JSONCanonicalization.canonicalize(.object([
                "label": "native mac", "origin_id": JSONValue(originID), "origin_secret": .string(secret)
            ]))
            return await service.handle(HTTPServer.Request(
                method: "POST", path: "/v1/admin/origins", query: [:],
                headers: ["authorization": "Admin admin-secret", "content-type": "application/json", "host": "127.0.0.1"],
                body: body
            ))
        }
        let stableSecret = String(repeating: "a", count: 32)
        let first = try await request(secret: stableSecret)
        let retry = try await request(secret: stableSecret)
        let conflict = try await request(secret: String(repeating: "b", count: 32))
        #expect(first.status == 200)
        #expect(retry.status == 200)
        #expect(conflict.status == 409)
        let principal = try await harness.store.authenticateOrigin(originID: originID, secret: stableSecret)
        guard case .origin = principal else { Issue.record("expected original credential to remain valid")
return }
    }

    /// `Host` is attacker-controlled, so a request that reaches the broker
    /// through Tailscale Serve can claim to be local. Serve's own forwarding
    /// headers cannot be removed by the client, so they give the check
    /// something the caller does not control.
    @Test
    func testAdminPendingRejectsAProxiedRequestClaimingALoopbackHost() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let service = makeService(harness)

        for header in ["x-forwarded-for", "x-forwarded-proto", "forwarded", "tailscale-user-login"] {
            let spoofed = await service.handle(HTTPServer.Request(
                method: "GET",
                path: "/v1/admin/pending",
                query: [:],
                headers: [
                    "authorization": "Admin admin-secret",
                    "host": "127.0.0.1:8443",
                    header: "203.0.113.7"
                ],
                body: Data()
            ))
            #expect(spoofed.status == 404, "\(header)")
        }
    }

    @Test
    func testAdminPendingAcceptsIPv6Loopback() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let service = makeService(harness)
        let response = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/admin/pending",
            query: [:],
            headers: [
                "authorization": "Admin admin-secret",
                "host": "[::1]:8443"
            ],
            body: Data()
        ))
        #expect(response.status == 200)
    }
}
