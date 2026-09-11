import XCTest
@testable import ShellControlClient
@testable import ShellControlProtocol

final class PairingTests: XCTestCase {
    func testThePlaceholderHostIsNeverAnAcceptableBroker() {
        XCTAssertEqual(ControlBrokerAddress.unconfiguredHost, "control.invalid")
        XCTAssertNil(ControlBrokerAddress.url(from: "https://control.invalid"))
        XCTAssertNil(ControlBrokerAddress.url(from: "http://control.invalid"))
        XCTAssertNil(ControlBrokerAddress.url(from: nil))
        XCTAssertNil(ControlBrokerAddress.url(from: ""))
    }

    func testHTTPSAndLoopbackHTTPAreTheOnlyAcceptableBrokers() throws {
        let https = try XCTUnwrap(URL(string: "https://control.example"))
        XCTAssertTrue(ControlBrokerAddress.isAcceptable(https))
        XCTAssertEqual(ControlBrokerAddress.url(from: "https://control.example"), https)

        let loopback = try XCTUnwrap(URL(string: "http://localhost:8443"))
        XCTAssertTrue(ControlBrokerAddress.isAcceptable(loopback))
        XCTAssertEqual(ControlBrokerAddress.url(from: "http://localhost:8443"), loopback)

        XCTAssertNil(ControlBrokerAddress.url(from: "http://192.168.1.8:8443"))
        XCTAssertNil(ControlBrokerAddress.url(from: "ftp://control.example"))
        let loopbackIP = try XCTUnwrap(URL(string: "http://127.0.0.1:8443"))
        XCTAssertTrue(ControlBrokerAddress.isAcceptable(loopbackIP))
        XCTAssertEqual(ControlBrokerAddress.url(from: "http://127.0.0.1:8443"), loopbackIP)
    }

    func testAMissingStoredBrokerIsNotAChange() throws {
        let url = try XCTUnwrap(URL(string: "https://control.example"))
        XCTAssertFalse(ControlBrokerAddress.hasChanged(from: nil, to: url))
        XCTAssertFalse(ControlBrokerAddress.hasChanged(from: url.absoluteString, to: url))
        XCTAssertTrue(ControlBrokerAddress.hasChanged(from: "https://old.example", to: url))
    }

    /// A reinstall loses the stored broker but keeps the Keychain, so "nothing
    /// stored" with a live session means the credentials belong to some other
    /// broker and must not be offered to this one.
    func testAMissingStoredBrokerIsAChangeWhenCredentialsSurvived() throws {
        let url = try XCTUnwrap(URL(string: "https://control.example"))
        XCTAssertTrue(ControlBrokerAddress.hasChanged(from: nil, to: url, hasCredentials: true))
        XCTAssertFalse(ControlBrokerAddress.hasChanged(from: nil, to: url, hasCredentials: false))
        XCTAssertFalse(ControlBrokerAddress.hasChanged(from: url.absoluteString, to: url, hasCredentials: true))
    }

    func testIPv6LoopbackIsRecognisedBracketedAndWithAPort() throws {
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("::1"))
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("[::1]"))
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("[::1]:8443"))
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("127.0.0.1:8443"))
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("LocalHost"))
        XCTAssertFalse(ControlBrokerAddress.isLoopbackHost("192.168.1.8:8443"))
        XCTAssertFalse(ControlBrokerAddress.isLoopbackHost("[2001:db8::1]:8443"))

        let ipv6 = try XCTUnwrap(URL(string: "http://[::1]:8443"))
        XCTAssertTrue(ControlBrokerAddress.isAcceptable(ipv6))
        XCTAssertNotNil(ControlBrokerAddress.normalize(ipv6))
    }

    /// The deep link carries the code the CLI prints; normalizing first would
    /// strip the query string before anything could read it.
    func testPairingTokenSurvivesTheLinkThatCarriesIt() throws {
        let broker = try XCTUnwrap(URL(string: "https://control.example"))
        let link = try XCTUnwrap(ControlBrokerAddress.pairingLink(broker: broker, token: "ABCD1234"))
        XCTAssertEqual(ControlBrokerAddress.pairingToken(from: link), "ABCD1234")
        XCTAssertEqual(ControlBrokerAddress.parsePairingLink(link), broker)
        XCTAssertNil(ControlBrokerAddress.pairingToken(from: try XCTUnwrap(ControlBrokerAddress.parsePairingLink(link))))
    }

    /// What the paste field validates must be what the companion adopts.
    func testPairPageLinkPrefersTheBrokerParameterOverItsOwnHost() throws {
        let link = try XCTUnwrap(URL(string: "https://front.example/pair?broker=https://real.example"))
        XCTAssertEqual(ControlBrokerAddress.parsePairing(link)?.host, "real.example")
        XCTAssertEqual(ControlBrokerAddress.parsePairingLink(link)?.host, "real.example")
    }

    func testAPairingMessageRoundTripsThroughApplicationContext() throws {
        let expires = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-11T12:00:00Z"))
        let message = ControlPairingMessage(
            brokerURL: try XCTUnwrap(URL(string: "https://control.example")),
            startEnrollment: true,
            enrollment: .init(
                userCode: "ABCD-EFGH",
                verificationURI: "https://control.example/v1/oauth/confirm",
                verificationURIComplete: "https://control.example/v1/oauth/confirm?user_code=ABCD-EFGH",
                fingerprint: "aa:bb",
                expiresAt: expires,
                platform: "watchOS",
                label: "Apple Watch"
            )
        )
        let context = try message.applicationContext()
        XCTAssertEqual(Array(context.keys), [ControlPairingMessage.applicationContextKey])
        let parsed = try XCTUnwrap(ControlPairingMessage(applicationContext: context))
        XCTAssertEqual(parsed, message)
        XCTAssertEqual(
            parsed.enrollment?.confirmationURL?.absoluteString,
            "https://control.example/v1/oauth/confirm?user_code=ABCD-EFGH"
        )
    }

    func testAPairingMessageRejectsUnknownMembersAndSecrets() throws {
        let valid: JSONValue = [
            "v": 1,
            "type": "control.pairing.v1",
            "broker_url": "https://control.example",
            "start_enrollment": false,
        ]
        XCTAssertNoThrow(try ControlPairingMessage(json: valid))

        let withToken: JSONValue = [
            "v": 1,
            "type": "control.pairing.v1",
            "broker_url": "https://control.example",
            "access_token": "nope",
        ]
        XCTAssertThrowsError(try ControlPairingMessage(json: withToken))

        let withKey: JSONValue = [
            "v": 1,
            "type": "control.pairing.v1",
            "broker_url": "https://control.example",
            "private_key": "nope",
        ]
        XCTAssertThrowsError(try ControlPairingMessage(json: withKey))
    }

    func testAPairingMessageRefusesAPlaceholderOrNonTLSBroker() throws {
        let placeholder: JSONValue = [
            "v": 1,
            "type": "control.pairing.v1",
            "broker_url": "https://control.invalid",
        ]
        XCTAssertThrowsError(try ControlPairingMessage(json: placeholder))

        let lan: JSONValue = [
            "v": 1,
            "type": "control.pairing.v1",
            "broker_url": "http://192.168.1.8:8443",
        ]
        XCTAssertThrowsError(try ControlPairingMessage(json: lan))
    }

    func testAPairingLinkRoundTripsThroughParse() throws {
        let broker = try XCTUnwrap(URL(string: "https://random.trycloudflare.com"))
        let link = try XCTUnwrap(ControlBrokerAddress.pairingLink(broker: broker))
        XCTAssertEqual(link.scheme, "shell-control")
        XCTAssertEqual(ControlBrokerAddress.parsePairing(link), broker)
        XCTAssertEqual(ControlBrokerAddress.parsePairing(broker), broker)
        let page = try XCTUnwrap(URL(string: "https://random.trycloudflare.com/pair"))
        XCTAssertEqual(ControlBrokerAddress.parsePairing(page), broker)
        XCTAssertEqual(
            ControlBrokerAddress.parsePairing("https://random.trycloudflare.com/pair?broker=https://other.example"),
            URL(string: "https://other.example")
        )
        XCTAssertNil(ControlBrokerAddress.parsePairing("https://control.invalid/pair"))
        XCTAssertNil(ControlBrokerAddress.parsePairing("http://192.168.1.8/pair"))
        XCTAssertNil(ControlBrokerAddress.parsePairingLink(broker))
        XCTAssertEqual(ControlBrokerAddress.parsePairingLink(page), broker)
        XCTAssertEqual(ControlBrokerAddress.parsePairingLink(link), broker)
        let withToken = try XCTUnwrap(ControlBrokerAddress.pairingLink(broker: broker, token: "ABCD1234"))
        XCTAssertEqual(ControlBrokerAddress.parsePairing(withToken), broker)
        XCTAssertEqual(ControlBrokerAddress.pairingToken(from: withToken), "ABCD1234")
        XCTAssertNil(ControlBrokerAddress.pairingToken(from: broker))
    }

    func testRuntimePairingOverridesABakedBroker() throws {
        let baked = try XCTUnwrap(URL(string: "https://control.example"))
        let runtime = try XCTUnwrap(URL(string: "https://random.trycloudflare.com"))
        XCTAssertEqual(ControlBrokerAddress.effective(runtime: nil, baked: baked), baked)
        XCTAssertEqual(ControlBrokerAddress.effective(runtime: runtime.absoluteString, baked: baked), runtime)
        XCTAssertEqual(ControlBrokerAddress.effective(runtime: "https://control.invalid", baked: baked), baked)
        XCTAssertNil(ControlBrokerAddress.effective(runtime: nil, baked: nil))
    }

    func testNormalizeDropsPairPaths() throws {
        let url = try XCTUnwrap(URL(string: "https://random.trycloudflare.com/pair?x=1"))
        XCTAssertEqual(ControlBrokerAddress.normalize(url)?.absoluteString, "https://random.trycloudflare.com")
    }

    func testAnExpiredEnrollmentReferenceIsNotConfirmable() throws {
        let expired = ControlPairingMessage.EnrollmentReference(
            userCode: "ABCD-EFGH",
            verificationURI: "https://control.example/v1/oauth/confirm",
            fingerprint: "aa:bb",
            expiresAt: ControlTimestamp(Date().addingTimeInterval(-1)),
            platform: "watchOS",
            label: "Apple Watch"
        )
        XCTAssertTrue(expired.isExpired(at: Date()))
        XCTAssertFalse(
            ControlPairingMessage.EnrollmentReference(
                userCode: "ABCD-EFGH",
                verificationURI: "https://control.example/v1/oauth/confirm",
                fingerprint: "aa:bb",
                expiresAt: ControlTimestamp(Date().addingTimeInterval(600)),
                platform: "watchOS",
                label: "Apple Watch"
            ).isExpired(at: Date())
        )
    }
}
