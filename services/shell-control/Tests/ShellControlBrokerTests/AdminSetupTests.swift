import XCTest
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

final class AdminSetupTests: XCTestCase {
    private func makeService(_ harness: BrokerHarness, publicURL: String = "https://control.example") -> BrokerService {
        BrokerService(
            store: harness.store,
            configuration: BrokerService.Configuration(
                verificationURI: "https://control.example/v1/oauth/confirm",
                allowedAPNsTopics: ["dev.chr33s.shell.watchkitapp"],
                adminSecret: "admin-secret",
                adminAccountID: harness.accountID,
                publicURL: publicURL
            )
        )
    }

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
                "host": "random.trycloudflare.com",
            ],
            body: Data()
        ))
        XCTAssertEqual(hidden.status, 404)

        let unauthenticated = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/admin/pending",
            query: [:],
            headers: ["host": "127.0.0.1:8443"],
            body: Data()
        ))
        XCTAssertEqual(unauthenticated.status, 403)

        let ok = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/admin/pending",
            query: [:],
            headers: [
                "authorization": "Admin admin-secret",
                "host": "127.0.0.1:8443",
            ],
            body: Data()
        ))
        XCTAssertEqual(ok.status, 200)
        let body = try JSONValue.parse(ok.body)
        XCTAssertEqual(body["pending"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["pending"]?.arrayValue?.first?["label"]?.stringValue, "Watch")
        XCTAssertEqual(body["pending"]?.arrayValue?.first?["key_fingerprint"]?.stringValue, try key.publicJWK.displayFingerprint())
    }

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
                "host": "localhost",
            ],
            body: body
        ))
        XCTAssertEqual(created.status, 201)
        let json = try JSONValue.parse(created.body)
        let originID = try XCTUnwrap(json["origin_id"]?.stringValue)
        let secret = try XCTUnwrap(json["origin_secret"]?.stringValue)
        XCTAssertFalse(secret.isEmpty)
        let principal = try await harness.store.authenticateOrigin(originID: ControlID(originID)!, secret: secret)
        guard case .origin = principal else { return XCTFail("expected origin principal") }
    }

    /// `Host` is attacker-controlled, so a request that reaches the broker
    /// through the tunnel can claim to be local. cloudflared's own forwarding
    /// headers cannot be removed by the client, so they give the check
    /// something the caller does not control.
    func testAdminPendingRejectsATunnelledRequestClaimingALoopbackHost() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let service = makeService(harness)

        for header in ["cf-connecting-ip", "cf-ray", "x-forwarded-for", "x-forwarded-proto", "forwarded"] {
            let spoofed = await service.handle(HTTPServer.Request(
                method: "GET",
                path: "/v1/admin/pending",
                query: [:],
                headers: [
                    "authorization": "Admin admin-secret",
                    "host": "127.0.0.1:8443",
                    header: "203.0.113.7",
                ],
                body: Data()
            ))
            XCTAssertEqual(spoofed.status, 404, header)
        }
    }

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
                "host": "[::1]:8443",
            ],
            body: Data()
        ))
        XCTAssertEqual(response.status, 200)
    }

    func testPairPagePercentEncodesTheBrokerAndIgnoresHost() async throws {
        let harness = BrokerHarness()
        let service = makeService(harness, publicURL: "https://random.trycloudflare.com")
        let response = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/pair",
            query: [:],
            headers: [
                "accept": "text/html",
                "host": "evil.example",
            ],
            body: Data()
        ))
        XCTAssertEqual(response.status, 200)
        let page = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(page.contains("broker=https%3A%2F%2Frandom.trycloudflare.com"), page)
        XCTAssertFalse(page.contains("evil.example"))
        XCTAssertTrue(page.contains("Settings"))
    }

    func testPairPageWithoutAPublicURLDoesNotGuessFromHost() async throws {
        let harness = BrokerHarness()
        let service = makeService(harness, publicURL: "")
        let response = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/pair",
            query: [:],
            headers: [
                "accept": "text/html",
                "host": "evil.example",
            ],
            body: Data()
        ))
        XCTAssertEqual(response.status, 503)
        let page = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(page.contains("evil.example"))
        XCTAssertFalse(page.contains("shell-control://pair"))
    }
}
