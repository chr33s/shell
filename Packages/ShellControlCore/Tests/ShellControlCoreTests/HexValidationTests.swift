import XCTest
@testable import ShellControlProtocol
@testable import ShellControlClient

/// `Character.isHexDigit` accepts fullwidth digits and letters; protocol hex
/// fields must be ASCII so the bytes compared are the bytes signed.
final class HexValidationTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)

    func testContextSHA256AcceptsOnlyLowercaseASCIIHex() {
        XCTAssertNoThrow(try ExecOperation(argv: ["/bin/ls"], cwd: "/", contextSHA256: digest))
        let fullwidthLetter = String(digest.dropLast()) + "\u{FF41}"  // "ａ"
        let fullwidthDigit = String(digest.dropLast()) + "\u{FF10}"   // "０"
        let uppercase = digest.uppercased()
        for bad in [fullwidthLetter, fullwidthDigit, uppercase, String(digest.dropLast()), digest + "0", ""] {
            XCTAssertThrowsError(try ExecOperation(argv: ["/bin/ls"], cwd: "/", contextSHA256: bad), "accepted \(bad)")
        }
    }

    func testRequestHashRejectsFullwidthHex() throws {
        XCTAssertTrue(ExecOperation.isSHA256Hex(digest))
        XCTAssertFalse(ExecOperation.isSHA256Hex(String(repeating: "\u{FF10}", count: 64)))
        XCTAssertFalse(ASCIIHex.isSHA256(String(digest.dropLast()) + "\u{0301}"))
    }

    func testAPNsTokenAcceptsASCIIHexOfEitherCaseOnly() throws {
        let token = String(repeating: "AbCd", count: 16)
        let registration = try PushRegistration(token: token, platform: .iOS, environment: .production, topic: "t")
        XCTAssertEqual(registration.token, token.lowercased())
        for bad in [String(repeating: "\u{FF21}", count: 64), String(repeating: "\u{FF10}", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try PushRegistration(token: bad, platform: .iOS, environment: .production, topic: "t"), "accepted \(bad)")
        }
    }

    func testASCIIHexHelpers() {
        XCTAssertTrue(ASCIIHex.isHex("09afAF"))
        XCTAssertFalse(ASCIIHex.isLowercase("09afAF"))
        XCTAssertTrue(ASCIIHex.isLowercase("09af"))
        XCTAssertFalse(ASCIIHex.isHex(""))
        XCTAssertFalse(ASCIIHex.isHex("\u{FF10}"))
    }

    func testLoopbackPortMustBeASCIIDigits() {
        XCTAssertTrue(ControlBrokerAddress.isLoopbackHost("localhost:8443"))
        XCTAssertFalse(ControlBrokerAddress.isLoopbackHost("localhost:\u{0668}\u{0664}"))
    }
}
