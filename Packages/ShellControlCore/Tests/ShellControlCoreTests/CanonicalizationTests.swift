import XCTest
@testable import ShellControlProtocol

/// RFC 8785 behaviour the request digest depends on.
final class CanonicalizationTests: XCTestCase {
    func testMemberOrderingUsesUTF16CodeUnits() throws {
        let value = try JSONValue.parse(#"{"€":"euro","é":"e","a":1}"#)
        XCTAssertEqual(try JSONCanonicalization.canonicalString(value), #"{"a":1,"é":"e","€":"euro"}"#)
    }

    func testNonBMPNamesSortByUTF16NotScalar() throws {
        // U+1F600 encodes as the surrogate pair D83D DE00, which sorts before
        // U+FF01 in UTF-16 order but after it by scalar value.
        let value = JSONValue.object(["\u{1F600}": 1, "\u{FF01}": 2])
        XCTAssertEqual(try JSONCanonicalization.canonicalString(value), "{\"\u{1F600}\":1,\"\u{FF01}\":2}")
    }

    func testStringEscapingIsMinimal() throws {
        let value = JSONValue.string("line\nquote\"tab\ttext\u{7}")
        XCTAssertEqual(try JSONCanonicalization.canonicalString(value), "\"line\\nquote\\\"tab\\ttext\\u0007\"")
    }

    func testIntegersSerializeExactly() throws {
        XCTAssertEqual(try JSONCanonicalization.canonicalString(.number(.int(9_007_199_254_740_991))), "9007199254740991")
        XCTAssertEqual(try JSONCanonicalization.canonicalString(.number(.double(1.0))), "1")
    }

    /// RFC 8785 Appendix B: IEEE 754 bit patterns and their ECMAScript
    /// `Number::toString` forms.
    func testDoublesMatchRFC8785AppendixB() throws {
        let samples: [(UInt64, String)] = [
            (0x0000_0000_0000_0000, "0"),
            (0x8000_0000_0000_0000, "0"),
            (0x0000_0000_0000_0001, "5e-324"),
            (0x8000_0000_0000_0001, "-5e-324"),
            (0x7FEF_FFFF_FFFF_FFFF, "1.7976931348623157e+308"),
            (0xFFEF_FFFF_FFFF_FFFF, "-1.7976931348623157e+308"),
            (0x4340_0000_0000_0000, "9007199254740992"),
            (0xC340_0000_0000_0000, "-9007199254740992"),
            (0x4430_0000_0000_0000, "295147905179352830000"),
            (0x44B5_2D02_C7E1_4AF5, "9.999999999999997e+22"),
            (0x44B5_2D02_C7E1_4AF6, "1e+23"),
            (0x44B5_2D02_C7E1_4AF7, "1.0000000000000001e+23"),
            (0x444B_1AE4_D6E2_EF4E, "999999999999999700000"),
            (0x444B_1AE4_D6E2_EF4F, "999999999999999900000"),
            (0x444B_1AE4_D6E2_EF50, "1e+21"),
            (0x3EB0_C6F7_A0B5_ED8C, "9.999999999999997e-7"),
            (0x3EB0_C6F7_A0B5_ED8D, "0.000001"),
            (0x41B3_DE43_5555_5553, "333333333.3333332"),
            (0x41B3_DE43_5555_5554, "333333333.33333325"),
            (0x41B3_DE43_5555_5555, "333333333.3333333"),
            (0x41B3_DE43_5555_5556, "333333333.3333334"),
            (0x41B3_DE43_5555_5557, "333333333.33333343"),
            (0xBECB_F647_612F_3696, "-0.0000033333333333333333"),
            (0x4314_3FF3_C1CB_0959, "1424953923781206.2")
        ]
        for (bits, expected) in samples {
            let value = Double(bitPattern: bits)
            XCTAssertEqual(try JSONCanonicalization.canonicalString(.number(.double(value))), expected, "bits \(String(bits, radix: 16))")
        }
    }

    /// The ES layout switches between plain and exponent form exactly at
    /// 1e-7 and 1e21, and never pads or signs the exponent like `%g` does.
    func testDoubleLayoutBoundaries() throws {
        let samples: [(Double, String)] = [
            (0.00001, "0.00001"),
            (1e-6, "0.000001"),
            (1e-7, "1e-7"),
            (1.5e-7, "1.5e-7"),
            (1.5e20, "150000000000000000000"),
            (123_456_789_012_345_680_000, "123456789012345680000"),
            (1e21, "1e+21"),
            // The literal names the same double as 1e23, as in ECMAScript.
            (9.999999999999999e22, "1e+23"),
            (1.5, "1.5"),
            (-0.5, "-0.5"),
            (100, "100"),
            (0.1, "0.1")
        ]
        for (value, expected) in samples {
            XCTAssertEqual(try JSONCanonicalization.canonicalString(.number(.double(value))), expected)
        }
        XCTAssertThrowsError(try JSONCanonicalization.canonicalString(.number(.double(.nan))))
        XCTAssertThrowsError(try JSONCanonicalization.canonicalString(.number(.double(.infinity))))
        XCTAssertThrowsError(try JSONCanonicalization.canonicalString(.number(.double(-.infinity))))
    }

    func testDuplicateNamesFailClosed() {
        XCTAssertThrowsError(try JSONValue.parse(#"{"a":1,"a":2}"#)) { error in
            XCTAssertEqual(error as? JSONError, .duplicateName("a"))
        }
    }

    func testLoneSurrogateIsRejected() {
        XCTAssertThrowsError(try JSONValue.parse(#"{"a":"\ud800"}"#)) { error in
            XCTAssertEqual(error as? JSONError, .invalidUnicode)
        }
    }

    func testOversizedDocumentIsRejected() {
        let big = Data(repeating: UInt8(ascii: " "), count: JSONLimits.maxDocumentBytes + 1)
        XCTAssertThrowsError(try JSONValue.parse(big))
    }

    func testDepthLimitIsEnforced() {
        let nested = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try JSONValue.parse(nested)) { error in
            XCTAssertEqual(error as? JSONError, .depthExceeded(limit: 32))
        }
    }

    func testTimestampsRoundTripThroughTheWireForm() throws {
        let stamp = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        XCTAssertEqual(stamp.rfc3339, "2026-09-07T09:00:00Z")
        XCTAssertEqual(ControlTimestamp.lenient("2026-09-07T09:00:00.250Z")?.rfc3339, "2026-09-07T09:00:00Z")
        XCTAssertNil(ControlTimestamp.lenient("2026-09-07T09:00:00+01:00"))
    }

    func testControlIDRejectsNonCanonicalForms() {
        XCTAssertNil(ControlID("10000000-0000-4000-8000-00000000ABCD"))
        XCTAssertNotNil(ControlID("10000000-0000-4000-8000-00000000abcd"))
        XCTAssertNil(ControlID("not-a-uuid"))
    }

    func testLogSequenceRejectsLeadingZeros() {
        XCTAssertNil(LogSequence(decimalString: "007"))
        XCTAssertEqual(LogSequence(decimalString: "7")?.value, 7)
    }

    /// A number the parser accepts but cannot re-encode to the same bytes
    /// would break the digest a signature commits to.
    func testNumbersOutsideTheJSONGrammarAreRejected() {
        for text in ["01", "-01", "1.", ".5", "1e", "1e+", "+1", "-", "1.2.3"] {
            XCTAssertThrowsError(try JSONValue.parse("{\"n\":\(text)}"), "accepted \(text)")
        }
        XCTAssertNoThrow(try JSONValue.parse(#"{"n":0}"#))
        XCTAssertNoThrow(try JSONValue.parse(#"{"n":-0.5e-2}"#))
        XCTAssertNoThrow(try JSONValue.parse(#"{"n":10}"#))
    }

    /// `2026-02-31` has no day 31, and accepting it would hand back a March
    /// date whose wire form differs from the text that was signed.
    func testImpossibleCalendarDatesAreRejected() {
        XCTAssertNil(ControlTimestamp.lenient("2026-02-31T00:00:00Z"))
        XCTAssertNil(ControlTimestamp.lenient("2026-04-31T00:00:00Z"))
        XCTAssertNil(ControlTimestamp.lenient("2025-02-29T00:00:00Z"))
        XCTAssertEqual(ControlTimestamp.lenient("2024-02-29T00:00:00Z")?.rfc3339, "2024-02-29T00:00:00Z")
        XCTAssertEqual(ControlTimestamp.lenient("2026-01-31T00:00:00Z")?.rfc3339, "2026-01-31T00:00:00Z")
    }
}
