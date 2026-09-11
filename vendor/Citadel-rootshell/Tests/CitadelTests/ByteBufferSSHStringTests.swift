@testable import Citadel
import NIOCore
import XCTest

final class ByteBufferSSHStringTests: XCTestCase {
    // Regression test for the key-exchange crash: writeCompositeSSHString must not
    // trap on a buffer with no spare capacity. Mirrors the swift-nio-ssh test added
    // alongside the backport of apple/swift-nio-ssh db57f32
    // "Correctly resize ByteBuffers (#150)".
    func testCompositeStringDoesTheRightThingWithBB() {
        var buffer = ByteBuffer()
        XCTAssertEqual(buffer.capacity, 0)

        buffer.writeCompositeSSHString {
            $0.writeInteger(UInt64(9))
        }

        XCTAssertEqual(
            buffer.readBytes(length: buffer.readableBytes),
            [0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 9]
        )
    }

    // The composite writer is also used partway through a buffer that has already
    // been filled to a power-of-two boundary, which is what the exchange-hash
    // assembly does. Land the writer index exactly at capacity and check it grows.
    func testCompositeStringGrowsAtCapacityBoundary() {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeBytes(Array(repeating: UInt8(0xAA), count: buffer.capacity))
        XCTAssertEqual(buffer.writerIndex, buffer.capacity)

        buffer.writeCompositeSSHString {
            $0.writeInteger(UInt16(0xBEEF))
        }

        XCTAssertEqual(buffer.readableBytes, 64 + 4 + 2)
        XCTAssertEqual(
            buffer.getBytes(at: 64, length: 6),
            [0, 0, 0, 2, 0xBE, 0xEF]
        )
    }
}
