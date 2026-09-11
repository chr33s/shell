@testable import Citadel
import Crypto
import NIOCore
import XCTest

final class Sntrup761X25519Sha512Tests: XCTestCase {
    func testHybridSharedSecretExchangeHashUsesSSHStringEncoding() {
        let combinedSecret = Data((0..<SHA512.byteCount).map(UInt8.init))

        var exchangeBytes = ByteBuffer()
        exchangeBytes.writeBytes([0x01, 0x02, 0x03, 0x04])
        exchangeBytes.writeSSHStringBytes(combinedSecret)

        var expectedBytes = Data([0x01, 0x02, 0x03, 0x04])
        var encodedLength = UInt32(combinedSecret.count).bigEndian
        withUnsafeBytes(of: &encodedLength) { expectedBytes.append(contentsOf: $0) }
        expectedBytes.append(combinedSecret)

        XCTAssertEqual(Data(exchangeBytes.readableBytesView), expectedBytes)
        XCTAssertEqual(SHA512.hash(data: exchangeBytes.readableBytesView), SHA512.hash(data: expectedBytes))
    }

    func testHybridSharedSecretSSHStringEncodingDoesNotMatchLegacyMPIntPath() {
        let combinedSecret = Data([0x80] + Array(repeating: 0x11, count: SHA512.byteCount - 1))

        var sshStringHasher = SHA512()
        combinedSecret.withUnsafeBytes { sshStringHasher.updateAsSSHString($0) }

        var mpintHasher = SHA512()
        mpintHasher.updateAsMPInt(sharedSecret: combinedSecret)

        XCTAssertNotEqual(
            Data(sshStringHasher.finalize()),
            Data(mpintHasher.finalize()),
            "sntrup761 hybrid secrets must use SSH string framing, not mpint encoding"
        )
    }
}
