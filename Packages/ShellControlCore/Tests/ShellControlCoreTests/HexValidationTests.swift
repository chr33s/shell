import Foundation
import Testing
@testable import ShellControlProtocol
@testable import ShellControlClient

/// `Character.isHexDigit` accepts fullwidth digits and letters; protocol hex
/// fields must be ASCII so the bytes compared are the bytes signed.
@Suite
final class HexValidationTests {
    private let digest = String(repeating: "ab", count: 32)

    @Test
    func testContextSHA256AcceptsOnlyLowercaseASCIIHex() throws {
        do { _ = try ExecOperation(argv: ["/bin/ls"], cwd: "/", contextSHA256: digest) } catch { Issue.record("unexpected error: \(error)") }
        let fullwidthLetter = String(digest.dropLast()) + "\u{FF41}"  // "ａ"
        let fullwidthDigit = String(digest.dropLast()) + "\u{FF10}"   // "０"
        let uppercase = digest.uppercased()
        for bad in [fullwidthLetter, fullwidthDigit, uppercase, String(digest.dropLast()), digest + "0", ""] {
            #expect(throws: (any Error).self, "accepted \(bad)") { try ExecOperation(argv: ["/bin/ls"], cwd: "/", contextSHA256: bad) }
        }
    }

    @Test
    func testRequestHashRejectsFullwidthHex() throws {
        #expect(ExecOperation.isSHA256Hex(digest))
        #expect(!(ExecOperation.isSHA256Hex(String(repeating: "\u{FF10}", count: 64))))
        #expect(!(ASCIIHex.isSHA256(String(digest.dropLast()) + "\u{0301}")))
    }

    @Test
    func testAPNsTokenAcceptsASCIIHexOfEitherCaseOnly() throws {
        let token = String(repeating: "AbCd", count: 16)
        let registration = try PushRegistration(token: token, platform: .iOS, environment: .production, topic: "t")
        #expect(registration.token == token.lowercased())
        for bad in [String(repeating: "\u{FF21}", count: 64), String(repeating: "\u{FF10}", count: 64), String(repeating: "g", count: 64)] {
            #expect(throws: (any Error).self, "accepted \(bad)") { try PushRegistration(token: bad, platform: .iOS, environment: .production, topic: "t") }
        }
    }

    @Test
    func testASCIIHexHelpers() throws {
        #expect(ASCIIHex.isHex("09afAF"))
        #expect(!(ASCIIHex.isLowercase("09afAF")))
        #expect(ASCIIHex.isLowercase("09af"))
        #expect(!(ASCIIHex.isHex("")))
        #expect(!(ASCIIHex.isHex("\u{FF10}")))
    }

    @Test
    func testLoopbackPortMustBeASCIIDigits() throws {
        #expect(ControlBrokerAddress.isLoopbackHost("localhost:8443"))
        #expect(!(ControlBrokerAddress.isLoopbackHost("localhost:\u{0668}\u{0664}")))
    }
}
