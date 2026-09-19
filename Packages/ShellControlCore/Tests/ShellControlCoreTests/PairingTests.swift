import XCTest
@testable import ShellControlClient

/// Transport address checks: HTTPS anywhere, plain HTTP only on loopback.
final class PairingTests: XCTestCase {
    func testThePlaceholderHostIsNeverAnAcceptableAddress() throws {
        XCTAssertFalse(ControlBrokerAddress.isAcceptable(try XCTUnwrap(URL(string: "https://control.invalid"))))
    }

    func testHTTPSAndLoopbackHTTPAreTheOnlyAcceptableAddresses() throws {
        XCTAssertTrue(ControlBrokerAddress.isAcceptable(try XCTUnwrap(URL(string: "https://mac.example.ts.net"))))
        XCTAssertTrue(ControlBrokerAddress.isAcceptable(try XCTUnwrap(URL(string: "http://127.0.0.1:8443"))))
        XCTAssertFalse(ControlBrokerAddress.isAcceptable(try XCTUnwrap(URL(string: "http://mac.example.ts.net"))))
        XCTAssertFalse(ControlBrokerAddress.isAcceptable(try XCTUnwrap(URL(string: "ftp://127.0.0.1"))))
    }

    func testIPv6LoopbackIsRecognisedBracketedAndWithAPort() throws {
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("::1"))
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("[::1]:8443"))
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("localhost:8443"))
        XCTAssertFalse(ControlBrokerAddress.isLoopbackHost("192.168.1.2"))
        let normalized = try XCTUnwrap(ControlBrokerAddress.normalize(try XCTUnwrap(URL(string: "http://[::1]:8443/x?y=1"))))
        XCTAssertEqual(normalized.absoluteString, "http://[::1]:8443")
    }
}
