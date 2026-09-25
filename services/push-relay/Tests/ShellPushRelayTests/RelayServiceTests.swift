import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlHTTPServer
@testable import ShellPushRelay

final class RelayServiceTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private let topic = "dev.chr33s.shell"

    private func post(_ service: RelayService, _ path: String, _ body: JSONValue) async throws -> (Int, JSONValue) {
        let response = await service.handle(HTTPServer.Request(
            method: "POST", path: path, body: try JSONCanonicalization.canonicalize(body)
        ))
        return (response.status, try JSONValue.parse(response.body))
    }

    private func capability(_ service: RelayService) async throws -> String {
        let (status, value) = try await post(service, "/v1/capabilities", .object([
            "apns_token": .string(token), "topic": .string(topic), "environment": "development"
        ]))
        XCTAssertEqual(status, 201)
        return try XCTUnwrap(value["capability"]?.stringValue)
    }

    private func hint(_ capability: String, requestID: ControlID = .random(), event: String = "approval.created") -> JSONValue {
        .object([
            "capability": .string(capability), "event": .string(event), "request_id": JSONValue(requestID),
            "origin_id": JSONValue(ControlID.random()), "collapse_id": .string("approval.\(requestID.rawValue)"),
            "presentation_class": "approval"
        ])
    }

    func testCapabilityDeliversOneGenericHintToItsSealedToken() async throws {
        let apns = RecordingRelayAPNs()
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: apns)
        let sealed = try await capability(service)
        let requestID = ControlID.random()
        let (status, _) = try await post(service, "/v1/push", hint(sealed, requestID: requestID))
        XCTAssertEqual(status, 202)
        let deliveries = await apns.deliveries
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.token, token)
        XCTAssertEqual(deliveries.first?.topic, topic)
        let payload = try JSONValue.parse(try XCTUnwrap(deliveries.first?.payload))
        XCTAssertEqual(payload["request_id"]?.stringValue, requestID.rawValue)
        XCTAssertEqual(payload["aps"]?["category"]?.stringValue, PushCategory.approval)
        XCTAssertEqual(payload["aps"]?["alert"]?["title"]?.stringValue, "Approval needed")
    }

    func testQuestionHintIsGenericAndDistinct() async throws {
        let apns = RecordingRelayAPNs()
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: apns)
        let sealed = try await capability(service)
        let requestID = ControlID.random()
        var body = try XCTUnwrap(hint(sealed, requestID: requestID, event: "input.created").objectValue)
        body["presentation_class"] = "input"
        let (status, _) = try await post(service, "/v1/push", .object(body))
        XCTAssertEqual(status, 202)
        let deliveries = await apns.deliveries
        let payload = try JSONValue.parse(try XCTUnwrap(deliveries.first?.payload))
        XCTAssertEqual(payload["event"]?.stringValue, "input.created")
        XCTAssertEqual(payload["request_id"]?.stringValue, requestID.rawValue)
        XCTAssertEqual(payload["aps"]?["alert"]?["title"]?.stringValue, "Question from an agent")
        // The pairing of event and presentation is fixed.
        body["presentation_class"] = "approval"
        let (mismatched, _) = try await post(service, "/v1/push", .object(body))
        XCTAssertEqual(mismatched, 400)
    }

    func testUnconfiguredTopicsAndArbitraryTextAreRefused() async throws {
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        let (status, _) = try await post(service, "/v1/capabilities", .object([
            "apns_token": .string(token), "topic": "com.example.other", "environment": "development"
        ]))
        XCTAssertEqual(status, 403)
        let sealed = try await capability(service)
        var withText = try XCTUnwrap(hint(sealed).objectValue)
        withText["alert"] = "Run rm -rf?"
        let (textStatus, _) = try await post(service, "/v1/push", .object(withText))
        XCTAssertEqual(textStatus, 400, "no caller-supplied alert text")
        let (eventStatus, _) = try await post(service, "/v1/push", hint(sealed, event: "approval.approve"))
        XCTAssertEqual(eventStatus, 400)
    }

    func testForgedAndExpiredCapabilitiesAreRejected() async throws {
        let clock = Clock()
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs(), now: { clock.now })
        let other = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        let foreign = try await capability(other)
        let (forgedStatus, _) = try await post(service, "/v1/push", hint(foreign))
        XCTAssertEqual(forgedStatus, 403)

        let sealed = try await capability(service)
        clock.advance(PushCapability.lifetime + 1)
        let (expiredStatus, _) = try await post(service, "/v1/push", hint(sealed))
        XCTAssertEqual(expiredStatus, 410)
    }

    func testRateLimitIsPerCapability() async throws {
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        let sealed = try await capability(service)
        var statuses: [Int] = []
        for _ in 0..<(PushCapability.RateClass.standard.perMinute + 1) {
            statuses.append(try await post(service, "/v1/push", hint(sealed)).0)
        }
        XCTAssertEqual(statuses.last, 429)
        let fresh = try await capability(service)
        let freshStatus = try await post(service, "/v1/push", hint(fresh)).0
        XCTAssertEqual(freshStatus, 202)
    }

    /// One noisy caller cannot lock every other iPhone out of registering.
    func testCapabilityRateLimitIsPerClient() async throws {
        let service = RelayService(
            key: OriginSigningKey(),
            configuration: .init(allowedTopics: [topic], clientAddressHeader: "X-Forwarded-For"),
            sender: RecordingRelayAPNs()
        )
        // The client-supplied prefix changes on every request; only the hop
        // the front end appended counts.
        func register(from address: String, spoofed: String = UUID().uuidString) async throws -> Int {
            let response = await service.handle(HTTPServer.Request(
                method: "POST", path: "/v1/capabilities",
                headers: ["x-forwarded-for": "\(spoofed), \(address)"],
                body: try JSONCanonicalization.canonicalize(.object([
                    "apns_token": .string(token), "topic": .string(topic), "environment": "development"
                ]))
            ))
            return response.status
        }
        var last = 0
        for _ in 0..<25 { last = try await register(from: "203.0.113.9") }
        XCTAssertEqual(last, 429)
        let other = try await register(from: "198.51.100.4")
        XCTAssertEqual(other, 201)
    }

    /// Behind a local front end with no configured header, every request is
    /// the proxy: it shares the wider bucket instead of a per-client one.
    func testCapabilityRateLimitBehindUnconfiguredProxyIsShared() async throws {
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        var statuses: [Int] = []
        for _ in 0..<121 {
            let response = await service.handle(HTTPServer.Request(
                method: "POST", path: "/v1/capabilities",
                body: try JSONCanonicalization.canonicalize(.object([
                    "apns_token": .string(token), "topic": .string(topic), "environment": "development"
                ])),
                peerAddress: "127.0.0.1"
            ))
            statuses.append(response.status)
        }
        XCTAssertEqual(statuses[119], 201)
        XCTAssertEqual(statuses[120], 429)
    }

    /// A relay outage costs a hint, never correctness: the relay's failure is
    /// reported, and it holds nothing to lose.
    func testAPNsFailureIsReportedAsUnavailable() async throws {
        struct Failing: RelayAPNsSending { func send(_ delivery: RelayDelivery) async throws { throw URLError(.timedOut) } }
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: Failing())
        let sealed = try await capability(service)
        let status = try await post(service, "/v1/push", hint(sealed)).0
        XCTAssertEqual(status, 503)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
