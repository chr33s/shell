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
}
