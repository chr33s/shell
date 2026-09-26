import Foundation
import Testing
@testable import ShellControlClient

/// Transport address checks: HTTPS anywhere, plain HTTP only on loopback.
@Suite
final class PairingTests {
    @Test
    func testThePlaceholderHostIsNeverAnAcceptableAddress() throws {
        #expect(!(ControlBrokerAddress.isAcceptable(try #require(URL(string: "https://control.invalid")))))
    }

    @Test
    func testHTTPSAndLoopbackHTTPAreTheOnlyAcceptableAddresses() throws {
        #expect(ControlBrokerAddress.isAcceptable(try #require(URL(string: "https://mac.example.ts.net"))))
        #expect(ControlBrokerAddress.isAcceptable(try #require(URL(string: "http://127.0.0.1:8443"))))
        #expect(!(ControlBrokerAddress.isAcceptable(try #require(URL(string: "http://mac.example.ts.net")))))
        #expect(!(ControlBrokerAddress.isAcceptable(try #require(URL(string: "ftp://127.0.0.1")))))
    }

    @Test
    func testIPv6LoopbackIsRecognisedBracketedAndWithAPort() throws {
        #expect(ControlBrokerAddress.isLoopbackHost("::1"))
        #expect(ControlBrokerAddress.isLoopbackHost("[::1]:8443"))
        #expect(ControlBrokerAddress.isLoopbackHost("localhost:8443"))
        #expect(!(ControlBrokerAddress.isLoopbackHost("192.168.1.2")))
        let url = try #require(URL(string: "http://[::1]:8443/x?y=1"))
        let normalized = try #require(ControlBrokerAddress.normalize(url))
        #expect(normalized.absoluteString == "http://[::1]:8443")
    }
}
