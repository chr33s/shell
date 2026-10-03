//
//  LocalSSHAgentTestSupport.swift
//  ShellTests
//
//  Shared fixtures for the local SSH agent bridge tests: in-memory key
//  sources, agent wire helpers, and independent signature verification.
//

import Foundation
import Crypto
import Security
import NIOCore
import NIOFoundationCompat
import Citadel

@testable import Shell

// MARK: - Keys

/// A software identity generated in-process, with its loaded variant and blob.
struct AgentTestKey: @unchecked Sendable {
    let key: SSHKey
    let variant: SSHPrivateKeyVariant

    var blob: Data { key.publicKeyBlob! }

    static func make(_ type: GenerateKeyType, name: String = "test") throws -> AgentTestKey {
        let generated = try SSHKeyGenerator.generate(type: type, comment: name)
        let parsed = try SSHKeyParser.parse(keyString: generated.privateKeyPEM)
        let variant: SSHPrivateKeyVariant
        if let nio = parsed.nioSSHKey {
            variant = .nioSSH(nio)
        } else {
            variant = .rsa(parsed.rsaKey!.citadelKey)
        }
        var key = SSHKey(name: name, keyType: parsed.keyType, fingerprint: parsed.fingerprint)
        key.publicKeyBlob = SSHPublicKeyBlob.makeData(from: variant, keyType: parsed.keyType)
        return AgentTestKey(key: key, variant: variant)
    }
}

/// A user certificate record with only the fields the agent reads made meaningful.
func agentTestCertificate(
    blob: Data = Data("cert-blob".utf8),
    validAfter: UInt64 = 0,
    validBefore: UInt64 = .max
) -> SSHUserCertificateInfo {
    SSHUserCertificateInfo(
        certificateBlob: blob,
        certType: "ssh-ed25519-cert-v01@openssh.com",
        keyID: "test",
        serial: 1,
        validPrincipals: [],
        validAfter: validAfter,
        validBefore: validBefore,
        caKeyType: "ssh-ed25519",
        caFingerprint: "SHA256:00",
        comment: nil,
        addedDate: Date()
    )
}

/// In-memory `LocalSSHAgentKeySource` over an agent policy. `loadError`
/// simulates a cancelled prompt, a deleted key or a locked device.
final class FakeAgentKeySource: LocalSSHAgentKeySource, @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [AgentTestKey]
    private var _policy: LocalSSHAgentPolicy
    private var _loadError: (any Error)?
    private var _loads: [UUID] = []
    private var _loadDelay: Duration?

    /// `allowed` defaults to every key, in order, with the agent enabled.
    init(keys: [AgentTestKey], allowed: [UUID]? = nil) {
        _keys = keys
        _policy = LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: allowed ?? keys.map(\.key.id))
    }

    func setAllowed(_ allowed: Bool, keyID: UUID) {
        lock.withLock { _policy.setAllowed(allowed, keyID: keyID) }
    }

    /// Makes every load wait, to hold a sign request in flight.
    var loadDelay: Duration? {
        get { lock.withLock { _loadDelay } }
        set { lock.withLock { _loadDelay = newValue } }
    }

    var loadError: (any Error)? {
        get { lock.withLock { _loadError } }
        set { lock.withLock { _loadError = newValue } }
    }

    var loads: [UUID] { lock.withLock { _loads } }

    func removeKey(id: UUID) {
        lock.withLock { _keys.removeAll { $0.key.id == id } }
    }

    func identityIndex() async -> SSHAgentIdentityIndex {
        lock.withLock {
            SSHAgentIdentityIndex(
                policy: _policy,
                keys: _keys.map(\.key),
                locallyUsable: Set(_keys.map(\.key.id))
            )
        }
    }

    func loadPrivateKey(id: UUID) async throws -> SSHPrivateKeyVariant {
        // Recorded on entry, so a test can act while the "prompt" is up.
        lock.withLock { _loads.append(id) }
        if let delay = loadDelay {
            try await Task.sleep(for: delay)
        }
        return try lock.withLock {
            if let _loadError { throw _loadError }
            guard let match = _keys.first(where: { $0.key.id == id }) else {
                throw SSHKeyManager.LoadError.keyNotFound
            }
            return match.variant
        }
    }
}

// MARK: - Wire helpers

enum AgentWire {
    static func string(_ value: String) -> [UInt8] {
        bytes(Array(value.utf8))
    }

    static func bytes(_ value: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(value.count).bigEndian, Array.init) + value
    }

    /// `uint32 length || payload`.
    static func frame(_ payload: [UInt8]) -> [UInt8] {
        bytes(payload)
    }

    static func signRequest(blob: Data, data: [UInt8], flags: UInt32) -> [UInt8] {
        [13] + bytes(Array(blob)) + bytes(data) + withUnsafeBytes(of: flags.bigEndian, Array.init)
    }

    static func readString(_ buffer: inout ByteBuffer) -> ByteBuffer? {
        guard let length = buffer.readInteger(as: UInt32.self) else { return nil }
        return buffer.readSlice(length: Int(length))
    }
}

// MARK: - Independent verification

/// Verifies an SSH signature blob against an SSH public key blob using
/// CryptoKit / Security directly — never the signer under test.
enum AgentSignatureVerifier {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func verify(signatureBlob: ByteBuffer, publicKeyBlob: Data, data: Data) throws -> (algorithm: String, valid: Bool) {
        var sig = signatureBlob
        guard let algoBuffer = AgentWire.readString(&sig),
              let algorithm = algoBuffer.getString(at: algoBuffer.readerIndex, length: algoBuffer.readableBytes),
              var raw = AgentWire.readString(&sig) else {
            throw Failure(description: "malformed signature blob")
        }
        guard sig.readableBytes == 0 else { throw Failure(description: "trailing bytes") }

        var pub = ByteBuffer(data: publicKeyBlob)
        guard let typeBuffer = AgentWire.readString(&pub),
              let keyType = typeBuffer.getString(at: typeBuffer.readerIndex, length: typeBuffer.readableBytes) else {
            throw Failure(description: "malformed public key blob")
        }

        switch keyType {
        case "ssh-ed25519":
            guard algorithm == "ssh-ed25519", let point = AgentWire.readString(&pub) else {
                throw Failure(description: "ed25519 mismatch")
            }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(buffer: point))
            return (algorithm, key.isValidSignature(Data(buffer: raw), for: data))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard algorithm == keyType,
                  AgentWire.readString(&pub) != nil,
                  let pointBuffer = AgentWire.readString(&pub),
                  let rBuffer = AgentWire.readString(&raw),
                  let sBuffer = AgentWire.readString(&raw) else {
                throw Failure(description: "ecdsa mismatch")
            }
            let point = Data(buffer: pointBuffer)
            let width = keyType.hasSuffix("256") ? 32 : keyType.hasSuffix("384") ? 48 : 66
            let rs = try fixedWidth(Data(buffer: rBuffer), width) + fixedWidth(Data(buffer: sBuffer), width)
            switch width {
            case 32:
                let key = try P256.Signing.PublicKey(x963Representation: point)
                return (algorithm, key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: rs), for: data))
            case 48:
                let key = try P384.Signing.PublicKey(x963Representation: point)
                return (algorithm, key.isValidSignature(try P384.Signing.ECDSASignature(rawRepresentation: rs), for: data))
            default:
                let key = try P521.Signing.PublicKey(x963Representation: point)
                return (algorithm, key.isValidSignature(try P521.Signing.ECDSASignature(rawRepresentation: rs), for: data))
            }

        case "ssh-rsa":
            guard let e = AgentWire.readString(&pub), let n = AgentWire.readString(&pub) else {
                throw Failure(description: "rsa blob")
            }
            let secAlgorithm: SecKeyAlgorithm
            switch algorithm {
            case "rsa-sha2-256": secAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
            case "rsa-sha2-512": secAlgorithm = .rsaSignatureMessagePKCS1v15SHA512
            case "ssh-rsa": secAlgorithm = .rsaSignatureMessagePKCS1v15SHA1
            default: throw Failure(description: "unexpected rsa algorithm \(algorithm)")
            }
            let der = derSequence(derInteger(Data(buffer: n)) + derInteger(Data(buffer: e)))
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
                throw Failure(description: "SecKeyCreateWithData failed")
            }
            let valid = SecKeyVerifySignature(key, secAlgorithm, data as CFData, Data(buffer: raw) as CFData, nil)
            return (algorithm, valid)

        default:
            throw Failure(description: "unsupported key type \(keyType)")
        }
    }

    /// SSH mpint → fixed-width big-endian integer.
    private static func fixedWidth(_ mpint: Data, _ width: Int) throws -> Data {
        let trimmed = Data(mpint.drop { $0 == 0 })
        guard trimmed.count <= width else { throw Failure(description: "mpint too wide") }
        return Data(repeating: 0, count: width - trimmed.count) + trimmed
    }

    private static func derLength(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func derInteger(_ mpint: Data) -> Data {
        // An SSH mpint is already a minimal two's-complement big-endian integer.
        Data([0x02]) + derLength(mpint.count) + mpint
    }

    private static func derSequence(_ body: Data) -> Data {
        Data([0x30]) + derLength(body.count) + body
    }
}
