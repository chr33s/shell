import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
import ShellControlHTTPServer
@testable import ShellPushRelay

@Suite
final class RelayServiceTests {
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
        #expect(status == 201)
        return try #require(value["capability"]?.stringValue)
    }

    private func hint(_ capability: String, requestID: ControlID = .random(), event: String = "approval.created") -> JSONValue {
        .object([
            "capability": .string(capability), "event": .string(event), "request_id": JSONValue(requestID),
            "origin_id": JSONValue(ControlID.random()), "collapse_id": .string("approval.\(requestID.rawValue)"),
            "presentation_class": "approval"
        ])
    }

    @Test
    func testCapabilityDeliversOneGenericHintToItsSealedToken() async throws {
        let apns = RecordingRelayAPNs()
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: apns)
        let sealed = try await capability(service)
        let requestID = ControlID.random()
        let (status, _) = try await post(service, "/v1/push", hint(sealed, requestID: requestID))
        #expect(status == 202)
        let deliveries = await apns.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.token == token)
        #expect(deliveries.first?.topic == topic)
        let payload = try JSONValue.parse(try #require(deliveries.first?.payload))
        #expect(payload["request_id"]?.stringValue == requestID.rawValue)
        #expect(payload["aps"]?["category"]?.stringValue == PushCategory.approval)
        #expect(payload["aps"]?["alert"]?["title"]?.stringValue == "Approval needed")
    }

    @Test
    func testQuestionHintIsGenericAndDistinct() async throws {
        let apns = RecordingRelayAPNs()
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: apns)
        let sealed = try await capability(service)
        let requestID = ControlID.random()
        var body = try #require(hint(sealed, requestID: requestID, event: "input.created").objectValue)
        body["presentation_class"] = "input"
        let (status, _) = try await post(service, "/v1/push", .object(body))
        #expect(status == 202)
        let deliveries = await apns.deliveries
        let payload = try JSONValue.parse(try #require(deliveries.first?.payload))
        #expect(payload["event"]?.stringValue == "input.created")
        #expect(payload["request_id"]?.stringValue == requestID.rawValue)
        #expect(payload["aps"]?["alert"]?["title"]?.stringValue == "Question from an agent")
        // The pairing of event and presentation is fixed.
        body["presentation_class"] = "approval"
        let (mismatched, _) = try await post(service, "/v1/push", .object(body))
        #expect(mismatched == 400)
    }

    @Test
    func testUnconfiguredTopicsAndArbitraryTextAreRefused() async throws {
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        let (status, _) = try await post(service, "/v1/capabilities", .object([
            "apns_token": .string(token), "topic": "com.example.other", "environment": "development"
        ]))
        #expect(status == 403)
        let sealed = try await capability(service)
        var withText = try #require(hint(sealed).objectValue)
        withText["alert"] = "Run rm -rf?"
        let (textStatus, _) = try await post(service, "/v1/push", .object(withText))
        #expect(textStatus == 400, "no caller-supplied alert text")
        let (eventStatus, _) = try await post(service, "/v1/push", hint(sealed, event: "approval.approve"))
        #expect(eventStatus == 400)
    }

    @Test
    func testForgedAndExpiredCapabilitiesAreRejected() async throws {
        let clock = Clock()
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs(), now: { clock.now })
        let other = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        let foreign = try await capability(other)
        let (forgedStatus, _) = try await post(service, "/v1/push", hint(foreign))
        #expect(forgedStatus == 403)

        let sealed = try await capability(service)
        clock.advance(PushCapability.lifetime + 1)
        let (expiredStatus, _) = try await post(service, "/v1/push", hint(sealed))
        #expect(expiredStatus == 410)
    }

    @Test
    func testRateLimitIsPerCapability() async throws {
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: RecordingRelayAPNs())
        let sealed = try await capability(service)
        var statuses: [Int] = []
        for _ in 0..<(PushCapability.RateClass.standard.perMinute + 1) {
            statuses.append(try await post(service, "/v1/push", hint(sealed)).0)
        }
        #expect(statuses.last == 429)
        let fresh = try await capability(service)
        let freshStatus = try await post(service, "/v1/push", hint(fresh)).0
        #expect(freshStatus == 202)
    }

    /// One noisy caller cannot lock every other iPhone out of registering.
    @Test
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
        #expect(last == 429)
        let other = try await register(from: "198.51.100.4")
        #expect(other == 201)
    }

    /// Behind a local front end with no configured header, every request is
    /// the proxy: it shares the wider bucket instead of a per-client one.
    @Test
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
        #expect(statuses[119] == 201)
        #expect(statuses[120] == 429)
    }

    /// A relay outage costs a hint, never correctness: the relay's failure is
    /// reported, and it holds nothing to lose.
    @Test
    func testAPNsFailureIsReportedAsUnavailable() async throws {
        struct Failing: RelayAPNsSending { func send(_ delivery: RelayDelivery) async throws { throw URLError(.timedOut) } }
        let service = RelayService(key: OriginSigningKey(), configuration: .init(allowedTopics: [topic]), sender: Failing())
        let sealed = try await capability(service)
        let status = try await post(service, "/v1/push", hint(sealed)).0
        #expect(status == 503)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
