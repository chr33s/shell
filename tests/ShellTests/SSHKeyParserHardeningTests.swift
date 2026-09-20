import XCTest

@testable import Shell

/// Pins that a malformed key file is rejected, not fatal.
///
/// THE REGRESSION THIS EXISTS FOR: `parseASN1Length` shifted up to 127
/// attacker-chosen bytes into an `Int`. The result silently wrapped, and the
/// caller then either trapped adding it to an offset or built a reversed
/// `Range` for `subdata(in:)`. A key file is untrusted input — pasted,
/// imported from disk, or restored from a backup — so a crafted one took the
/// whole app down. Lengths are now bounded before anything indexes with them.
final class SSHKeyParserHardeningTests: XCTestCase {
    private func pem(_ der: [UInt8]) -> String {
        """
        -----BEGIN RSA PRIVATE KEY-----
        \(Data(der).base64EncodedString())
        -----END RSA PRIVATE KEY-----
        """
    }

    func testAnOverflowingASN1LengthIsRejected() {
        // SEQUENCE(10) { INTEGER with a long-form length of eight 0xFF bytes }.
        // That length wrapped to -1, passed the "is it in range?" guard, and
        // produced the range 12..<11.
        let der: [UInt8] = [0x30, 0x0A, 0x02, 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: pem(der)))
    }

    func testAnASN1LengthLongerThanTheDocumentIsRejected() {
        // A four-byte length claiming 16 MiB inside a 9-byte document.
        let der: [UInt8] = [0x30, 0x07, 0x02, 0x84, 0x01, 0x00, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: pem(der)))
    }

    func testTheIndefiniteLengthFormIsRejected() {
        // 0x80 is the indefinite form, which DER forbids.
        let der: [UInt8] = [0x30, 0x80, 0x02, 0x01, 0x00]
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: pem(der)))
    }

    func testATruncatedLongFormLengthIsRejected() {
        // Declares eight length bytes and supplies two.
        let der: [UInt8] = [0x30, 0x04, 0x02, 0x88, 0xFF, 0xFF]
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: pem(der)))
    }

    func testGarbageAndEmptyInputAreRejected() {
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: ""))
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: "not a key"))
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: pem([])))
        XCTAssertThrowsError(try SSHKeyParser.parse(keyString: pem([0x30])))
    }
}
