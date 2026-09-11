import Crypto
import NIOCore
import XCTest
@testable import NIOSSH
@testable import Citadel

final class AESETMTests: XCTestCase {
    private func keys(for protection: NIOSSHTransportProtection.Type, mac: String) throws -> NIOSSHSessionKeys {
        let sizes = try protection.keySizes(forMac: mac)
        let encryption = SymmetricKey(size: .init(bitCount: sizes.encryptionKeySize * 8))
        let authentication = SymmetricKey(size: .init(bitCount: sizes.macKeySize * 8))
        let iv = (0..<sizes.ivSize).map(UInt8.init)
        return NIOSSHSessionKeys(initialInboundIV: iv, initialOutboundIV: iv,
                                inboundEncryptionKey: encryption, outboundEncryptionKey: encryption,
                                inboundMACKey: authentication, outboundMACKey: authentication)
    }

    private func exercise(_ protection: NIOSSHTransportProtection.Type, mac: String) throws {
        let initialKeys = try keys(for: protection, mac: mac)
        let encryptor = try protection.init(initialKeys: initialKeys, mac: mac)
        let decryptor = try protection.init(initialKeys: initialKeys, mac: mac)
        var sequence: UInt32 = 42
        // Append at nonzero offsets and across capacity boundaries. Keep CTR state
        // across packets, then repeat with fresh keys as happens during rekeying.
        var output = ByteBuffer(bytes: [0xaa, 0xbb, 0xcc])
        for epoch in 0..<2 {
            if epoch > 0 {
                let replacement = try keys(for: protection, mac: mac)
                try encryptor.updateKeys(replacement)
                try decryptor.updateKeys(replacement)
            }
            let messages: [SSHMessage] = [.newKeys] + (Array(0...64) + [255, 256, 1023, 32768]).map {
                .ignore(.init(data: ByteBuffer(bytes: [UInt8](repeating: 0x5a, count: $0))))
            }
            for message in messages {
                let payload = NIOSSHEncryptablePayload(message: message)
                var expected = ByteBuffer()
                expected.writeEncryptablePayload(payload)
                let start = output.writerIndex
                try encryptor.encryptPacket(payload, to: &output, sequenceNumber: sequence)
                let length = Int(try XCTUnwrap(output.getInteger(at: start, as: UInt32.self)))
                // OpenSSH aligns only the encrypted body: padding length + payload
                // + at least four padding bytes. The clear uint32 length is excluded.
                let expectedLength = ((1 + expected.readableBytes + 4 + 15) / 16) * 16
                XCTAssertEqual(length, expectedLength, "payload bytes: \(expected.readableBytes)")
                XCTAssertEqual(length % 16, 0)
                XCTAssertEqual(output.writerIndex - start, 4 + length + encryptor.macBytes)
                var packet = try XCTUnwrap(output.getSlice(at: start, length: output.writerIndex - start))
                let encrypted = packet
                try decryptor.decryptFirstBlock(&packet)
                XCTAssertEqual(packet, encrypted, "Reading the clear length must not consume the CTR stream")
                XCTAssertEqual(try decryptor.decryptAndVerifyRemainingPacket(&packet, sequenceNumber: sequence), expected)
                XCTAssertEqual(packet.readableBytes, 0)
                sequence += 1
            }
        }
        XCTAssertEqual(output.getBytes(at: 0, length: 3), [0xaa, 0xbb, 0xcc])
    }

    func testAES128SHA256PacketBoundariesAndRekey() throws {
        try exercise(AES128CTR_ETM.self, mac: AES128CTR_ETM.macNames[0])
    }

    func testAES128SHA512PacketBoundariesAndRekey() throws {
        try exercise(AES128CTR_ETM.self, mac: AES128CTR_ETM.macNames[1])
    }

    func testAES256SHA256PacketBoundariesAndRekey() throws {
        try exercise(AES256CTR_ETM.self, mac: AES256CTR_ETM.macNames[0])
    }

    func testAES256SHA512PacketBoundariesAndRekey() throws {
        try exercise(AES256CTR_ETM.self, mac: AES256CTR_ETM.macNames[1])
    }

    func testAuthenticationFailureDoesNotConsumeCTRStream() throws {
        for protection in [AES128CTR_ETM.self, AES256CTR_ETM.self] as [NIOSSHTransportProtection.Type] {
            for mac in AES128CTR_ETM.macNames {
                let initialKeys = try keys(for: protection, mac: mac)
                let encryptor = try protection.init(initialKeys: initialKeys, mac: mac)
                let decryptor = try protection.init(initialKeys: initialKeys, mac: mac)
                var packet = ByteBuffer()
                try encryptor.encryptPacket(.init(message: .newKeys), to: &packet, sequenceNumber: 7)
                // Corrupt the clear length, ciphertext, and MAC independently.
                for offset in [0, 4, packet.writerIndex - 1] {
                    var corrupt = packet
                    let byte = try XCTUnwrap(corrupt.getInteger(at: offset, as: UInt8.self))
                    corrupt.setInteger(byte ^ 1, at: offset)
                    XCTAssertThrowsError(try decryptor.decryptAndVerifyRemainingPacket(&corrupt, sequenceNumber: 7))
                }
                var wrongSequence = packet
                XCTAssertThrowsError(try decryptor.decryptAndVerifyRemainingPacket(&wrongSequence, sequenceNumber: 8))
                var plaintext = try decryptor.decryptAndVerifyRemainingPacket(&packet, sequenceNumber: 7)
                XCTAssertEqual(try plaintext.readSSHMessage(), .newKeys)
            }
        }
    }
}
