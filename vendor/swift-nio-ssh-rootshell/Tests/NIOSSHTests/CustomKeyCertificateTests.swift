//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOCore
@testable import NIOSSH
import XCTest

/// Tests for OpenSSH certificates whose embedded key is a custom `NIOSSHPublicKeyProtocol`
/// type (RSA, sk-ecdsa, sk-ed25519). Custom key types participate in certificate parsing
/// and serialization by declaring `certifiedKeyPrefix` and registering via `NIOSSHAlgorithms`.
private enum Fixtures {
    // The same P384 certificate authority as CertifiedKeyTests; all certs below are signed by it.
    static let caPublicKey = "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBHYlMSXacXt13oBLpMXEP0OSMw5okd5c7G3hoim1MR/THUOyOS2AVQKEqLZs+td3Y6yYCrq5TGWDNGY2dfKFX99nLqJCq2kxR//CP3UherkZnn6u4eW4biLL7xODqNOzkQ== ca"

    // An RSA-2048 user cert. id "User RSA key" serial 7 for foo,bar valid 2020-01-01 to 2070-01-01.
    // Generated using ssh-keygen -s ca -I "User RSA key" -n foo,bar -V 20200101000000:20700101000000 -z 7 user-rsa.pub
    static let rsaUser = "ssh-rsa-cert-v01@openssh.com AAAAHHNzaC1yc2EtY2VydC12MDFAb3BlbnNzaC5jb20AAAAg7flgLFaLeTYWMcQcu6S1F/zyuD4teKoYwpPIy8mLsIwAAAADAQABAAABAQDiKl/yM4JheFTduA6QBJl1D+Wwy7AHlk46yApS5JaTzcHaZRhH+Fjb/r+6pw6U0Gakx9icL8Aj2qUiBUdnXKMcTOKOtlYGtNLTtIfIyeoTiN/hp3IlJNNruX4l/cKgWILq4T3pXYxfgVLXxK+Szy3AdCaQqWI4czven3EF0TLJj+BL2QHjuTBtxILlIRIxCez8miMuyTWiupNkd96AYYD81uz86A0Qpvz7UAXTZtcku/TOeeuZS3I0RMRSndQfrc/DCXSMdl3IFLDbYYGrXzI4ivOLEVtGcPE831KJkkmW49bU7uTT5P9qeYKYXRIguKPIHW/tOu7lxZIMmDmygJs9AAAAAAAAAAcAAAABAAAADFVzZXIgUlNBIGtleQAAAA4AAAADZm9vAAAAA2JhcgAAAABeDFGAAAAAALwZhAAAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAiAAAABNlY2RzYS1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQR2JTEl2nF7dd6AS6TFxD9DkjMOaJHeXOxt4aIptTEf0x1DsjktgFUChKi2bPrXd2OsmAq6uUxlgzRmNnXyhV/fZy6iQqtpMUf/wj91IXq5GZ5+ruHluG4iy+8Tg6jTs5EAAACEAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAABpAAAAMQCVpAZ8bKvYWuKe+fcRHxOb6ay6WwQNqdqpdtUXZ4hucaxj+gUIkYOr2c6GVrNNXa8AAAAwIqcLYqdsNlLFs0gDrcIWFb1DCotQ+YcgMLzz/2mPk8gRqD8gUkQeVg8TU9c8caEF rsa-test"

    // The matching plain RSA public key for the cert above.
    static let rsaUserBase = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDiKl/yM4JheFTduA6QBJl1D+Wwy7AHlk46yApS5JaTzcHaZRhH+Fjb/r+6pw6U0Gakx9icL8Aj2qUiBUdnXKMcTOKOtlYGtNLTtIfIyeoTiN/hp3IlJNNruX4l/cKgWILq4T3pXYxfgVLXxK+Szy3AdCaQqWI4czven3EF0TLJj+BL2QHjuTBtxILlIRIxCez8miMuyTWiupNkd96AYYD81uz86A0Qpvz7UAXTZtcku/TOeeuZS3I0RMRSndQfrc/DCXSMdl3IFLDbYYGrXzI4ivOLEVtGcPE831KJkkmW49bU7uTT5P9qeYKYXRIguKPIHW/tOu7lxZIMmDmygJs9 rsa-test"

    // An sk-ecdsa user cert (application "ssh:"). id "User SK ECDSA key" serial 9 for foo,bar valid 2020-01-01 to 2070-01-01.
    // Generated using ssh-keygen -s ca -I "User SK ECDSA key" -n foo,bar -V 20200101000000:20700101000000 -z 9 user-skecdsa.pub
    static let skEcdsaUser = "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com AAAAK3NrLWVjZHNhLXNoYTItbmlzdHAyNTYtY2VydC12MDFAb3BlbnNzaC5jb20AAAAg5ZHKXzdXPzOmRNcclhyWiX26ZDvVcDMYThzYq2LsAYUAAAAIbmlzdHAyNTYAAABBBLoBltx8pvBL1LjDYtkVm+T2jqxErxryeBq1DSWEaarShBt/ovmKgu+EXFvvQZc6fYZ2mLP7FYyJRSyshybrpXIAAAAEc3NoOgAAAAAAAAAJAAAAAQAAABFVc2VyIFNLIEVDRFNBIGtleQAAAA4AAAADZm9vAAAAA2JhcgAAAABeDFGAAAAAALwZhAAAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAiAAAABNlY2RzYS1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQR2JTEl2nF7dd6AS6TFxD9DkjMOaJHeXOxt4aIptTEf0x1DsjktgFUChKi2bPrXd2OsmAq6uUxlgzRmNnXyhV/fZy6iQqtpMUf/wj91IXq5GZ5+ruHluG4iy+8Tg6jTs5EAAACFAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAABqAAAAMQCBkUYzaC4cwaa9v9ZTocqmmSl4sie5OH2VLuQcqjgITtVmhhQpzeWe3wGDtOcQo+0AAAAxAJhQYIHUQIFL4WGacsy/PBdaId12Hi23Fbac6M4twWvnqmI+imLtQ/u66S5w4+mt/Q== sk-ecdsa-test"

    // An sk-ed25519 user cert (application "ssh:"). id "User SK Ed25519 key" serial 11 for foo,bar valid 2020-01-01 to 2070-01-01.
    // Generated using ssh-keygen -s ca -I "User SK Ed25519 key" -n foo,bar -V 20200101000000:20700101000000 -z 11 user-sked25519.pub
    static let skEd25519User = "sk-ssh-ed25519-cert-v01@openssh.com AAAAI3NrLXNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIOA0mHTBZaQwAgCmOXid5AGdcaWhS+cC+eWaHe/E0uwSAAAAIEYYmqUqOddoCIrUk7c2BHHBPgOBaqKAKPs1qqkYL3oBAAAABHNzaDoAAAAAAAAACwAAAAEAAAATVXNlciBTSyBFZDI1NTE5IGtleQAAAA4AAAADZm9vAAAAA2JhcgAAAABeDFGAAAAAALwZhAAAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAiAAAABNlY2RzYS1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQR2JTEl2nF7dd6AS6TFxD9DkjMOaJHeXOxt4aIptTEf0x1DsjktgFUChKi2bPrXd2OsmAq6uUxlgzRmNnXyhV/fZy6iQqtpMUf/wj91IXq5GZ5+ruHluG4iy+8Tg6jTs5EAAACFAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAABqAAAAMQDinUNGwjl7OmxqGeAg8Zo9KAo9PtM9/DYENxEhMsFm4IT7vgdS2NPtb6p/tojUnzkAAAAxAP+p72IB6heSgUMhreu5CGzFd2lE17+YmI3N2hR8x2emdKOtmNDE9WZuvz9dI9Za6Q== sk-ed25519-test"
}

// MARK: - Test custom key types

/// Stores RSA public key components opaquely: mpint e, mpint n.
private struct TestRSAPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "ssh-rsa"
    static let authAlgorithmName = "rsa-sha2-256"
    static let certifiedKeyPrefix: String? = "ssh-rsa-cert-v01@openssh.com"
    static let certifiedAuthAlgorithmName: String? = "rsa-sha2-256-cert-v01@openssh.com"

    var e: Data
    var n: Data

    var rawRepresentation: Data { self.e + self.n }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeSSHString(self.e)
        written += buffer.writeSSHString(self.n)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> TestRSAPublicKey {
        guard var e = buffer.readSSHString(), var n = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid RSA key")
        }
        return TestRSAPublicKey(
            e: Data(e.readBytes(length: e.readableBytes)!),
            n: Data(n.readBytes(length: n.readableBytes)!)
        )
    }
}

private struct TestRSASignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-256"
    var rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> TestRSASignature {
        guard var bytes = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid RSA signature")
        }
        return TestRSASignature(rawRepresentation: Data(bytes.readBytes(length: bytes.readableBytes)!))
    }
}

/// sk-ecdsa public key: string curve, string ec point, string application.
private struct TestSKEcdsaPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "sk-ecdsa-sha2-nistp256@openssh.com"
    static let certifiedKeyPrefix: String? = "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com"

    var curve: Data
    var point: Data
    var application: Data

    var rawRepresentation: Data { self.curve + self.point + self.application }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeSSHString(self.curve)
        written += buffer.writeSSHString(self.point)
        written += buffer.writeSSHString(self.application)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> TestSKEcdsaPublicKey {
        guard
            var curve = buffer.readSSHString(),
            var point = buffer.readSSHString(),
            var application = buffer.readSSHString()
        else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid sk-ecdsa key")
        }
        return TestSKEcdsaPublicKey(
            curve: Data(curve.readBytes(length: curve.readableBytes)!),
            point: Data(point.readBytes(length: point.readableBytes)!),
            application: Data(application.readBytes(length: application.readableBytes)!)
        )
    }
}

private struct TestSKEcdsaSignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "sk-ecdsa-sha2-nistp256@openssh.com"
    var rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> TestSKEcdsaSignature {
        guard var bytes = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid sk-ecdsa signature")
        }
        return TestSKEcdsaSignature(rawRepresentation: Data(bytes.readBytes(length: bytes.readableBytes)!))
    }
}

/// sk-ed25519 public key: string pk, string application.
private struct TestSKEd25519PublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "sk-ssh-ed25519@openssh.com"
    static let certifiedKeyPrefix: String? = "sk-ssh-ed25519-cert-v01@openssh.com"

    var pk: Data
    var application: Data

    var rawRepresentation: Data { self.pk + self.application }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeSSHString(self.pk)
        written += buffer.writeSSHString(self.application)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> TestSKEd25519PublicKey {
        guard var pk = buffer.readSSHString(), var application = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid sk-ed25519 key")
        }
        return TestSKEd25519PublicKey(
            pk: Data(pk.readBytes(length: pk.readableBytes)!),
            application: Data(application.readBytes(length: application.readableBytes)!)
        )
    }
}

private struct TestSKEd25519Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "sk-ssh-ed25519@openssh.com"
    var rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> TestSKEd25519Signature {
        guard var bytes = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid sk-ed25519 signature")
        }
        return TestSKEd25519Signature(rawRepresentation: Data(bytes.readBytes(length: bytes.readableBytes)!))
    }
}

/// A custom key type that does NOT declare certificate support.
private struct NoCertSupportPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "no-cert-support@example.com"

    var rawRepresentation: Data { Data() }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        0
    }

    static func read(from buffer: inout ByteBuffer) throws -> NoCertSupportPublicKey {
        NoCertSupportPublicKey()
    }
}

/// A second "ssh-rsa" custom type WITHOUT certificate support, mimicking an app's
/// legacy RSA wrapper (e.g. for SHA-1-only servers). Its `read(from:)` throws to
/// model the strictest case: if certificate parsing ever re-dispatches embedded-key
/// reads through the shared base prefix, registration order decides which type is
/// consulted and this one fails the parse.
private struct LegacyStyleRSAPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "ssh-rsa"

    var rawRepresentation: Data { Data() }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        0
    }

    static func read(from buffer: inout ByteBuffer) throws -> LegacyStyleRSAPublicKey {
        throw NIOSSHError.invalidSSHMessage(reason: "legacy RSA type cannot read from wire")
    }
}

private struct LegacyStyleRSASignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "ssh-rsa"
    var rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> LegacyStyleRSASignature {
        guard var bytes = buffer.readSSHString() else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid legacy RSA signature")
        }
        return LegacyStyleRSASignature(rawRepresentation: Data(bytes.readBytes(length: bytes.readableBytes)!))
    }
}

// MARK: - Tests

final class CustomKeyCertificateTests: XCTestCase {
    override func setUp() {
        NIOSSHAlgorithms.register(publicKey: TestRSAPublicKey.self, signature: TestRSASignature.self)
        NIOSSHAlgorithms.register(publicKey: TestSKEcdsaPublicKey.self, signature: TestSKEcdsaSignature.self)
        NIOSSHAlgorithms.register(publicKey: TestSKEd25519PublicKey.self, signature: TestSKEd25519Signature.self)
    }

    override func tearDown() {
        NIOSSHAlgorithms.unregisterAlgorithms()
    }

    private func expectedExport(for fixture: String) -> String {
        fixture.split(separator: " ", maxSplits: 2).prefix(2).joined(separator: " ")
    }

    /// Parse → unwrap → re-serialize, asserting byte-exact output. Byte-exactness matters: the
    /// userauth request re-serializes the certificate, and the CA signature only verifies over
    /// the exact bytes ssh-keygen produced.
    private func roundTripLoadSerialize(fixture: String) throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: fixture)
        guard let certifiedKey = NIOSSHCertifiedPublicKey(key) else {
            XCTFail("Key is not certified")
            return
        }

        // Byte-exact string export (modulo the trailing comment).
        XCTAssertEqual(String(openSSHPublicKey: key), self.expectedExport(for: fixture))

        // Wire round-trip.
        var buffer = ByteBufferAllocator().buffer(capacity: 4096)
        buffer.writeCertifiedKey(certifiedKey)
        let reloaded = try buffer.readCertifiedKey()
        XCTAssertEqual(reloaded, certifiedKey)

        // The convenience initializers agree.
        let fromString = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: fixture)
        XCTAssertEqual(fromString, certifiedKey)

        var blobBuffer = ByteBufferAllocator().buffer(capacity: 4096)
        blobBuffer.writeCertifiedKey(certifiedKey)
        let fromBlob = try NIOSSHCertifiedPublicKey(certificateBlob: blobBuffer)
        XCTAssertEqual(fromBlob, certifiedKey)
    }

    /// The CA signature verifying over our re-serialized signable bytes proves the embedded
    /// custom key serializes exactly as OpenSSH wrote it (no inner type string).
    private func validateAgainstCA(fixture: String) throws {
        let caKey = try NIOSSHPublicKey(openSSHPublicKey: Fixtures.caPublicKey)
        let certifiedKey = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: fixture)
        let criticalOptions = try certifiedKey.validate(principal: "foo", type: .user, allowedAuthoritySigningKeys: [caKey])
        XCTAssertEqual(criticalOptions, [:])
    }

    func testLoadSerializeRSACert() throws {
        try self.roundTripLoadSerialize(fixture: Fixtures.rsaUser)
    }

    func testLoadSerializeSKEcdsaCert() throws {
        try self.roundTripLoadSerialize(fixture: Fixtures.skEcdsaUser)
    }

    func testLoadSerializeSKEd25519Cert() throws {
        try self.roundTripLoadSerialize(fixture: Fixtures.skEd25519User)
    }

    func testCAValidationRSACert() throws {
        try self.validateAgainstCA(fixture: Fixtures.rsaUser)
    }

    func testCAValidationSKEcdsaCert() throws {
        try self.validateAgainstCA(fixture: Fixtures.skEcdsaUser)
    }

    func testCAValidationSKEd25519Cert() throws {
        try self.validateAgainstCA(fixture: Fixtures.skEd25519User)
    }

    func testCertKeyPrefixAndAuthAlgorithmName() throws {
        let rsaCert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.rsaUser)
        XCTAssertEqual(String(rsaCert.keyPrefix), "ssh-rsa-cert-v01@openssh.com")
        XCTAssertEqual(String(rsaCert.authAlgorithmName), "rsa-sha2-256-cert-v01@openssh.com")

        let wrapped = NIOSSHPublicKey(rsaCert)
        XCTAssertEqual(String(wrapped.keyPrefix), "ssh-rsa-cert-v01@openssh.com")
        XCTAssertEqual(String(wrapped.authAlgorithmName), "rsa-sha2-256-cert-v01@openssh.com")
        XCTAssertTrue(wrapped.isValidAuthenticationAlgorithmName("ssh-rsa-cert-v01@openssh.com".utf8))
        XCTAssertTrue(wrapped.isValidAuthenticationAlgorithmName("rsa-sha2-256-cert-v01@openssh.com".utf8))

        let skEcdsaCert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.skEcdsaUser)
        XCTAssertEqual(String(skEcdsaCert.keyPrefix), "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com")
        XCTAssertEqual(String(skEcdsaCert.authAlgorithmName), "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com")

        let skEdCert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.skEd25519User)
        XCTAssertEqual(String(skEdCert.keyPrefix), "sk-ssh-ed25519-cert-v01@openssh.com")
        XCTAssertEqual(String(skEdCert.authAlgorithmName), "sk-ssh-ed25519-cert-v01@openssh.com")
    }

    func testCertificateMetadataParsing() throws {
        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.rsaUser)
        XCTAssertEqual(cert.serial, 7)
        XCTAssertEqual(cert.type, .user)
        XCTAssertEqual(cert.keyID, "User RSA key")
        XCTAssertEqual(cert.validPrincipals, ["foo", "bar"])
    }

    func testUserAuthSignablePayloadContainsCertAuthName() throws {
        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.rsaUser)
        let publicKey = NIOSSHPublicKey(cert)

        var sessionID = ByteBufferAllocator().buffer(capacity: 32)
        sessionID.writeBytes(0 ..< 32)
        let payload = UserAuthSignablePayload(sessionIdentifier: sessionID, userName: "foo", serviceName: "ssh-connection", publicKey: publicKey)

        let payloadBytes = Data(payload.bytes.readableBytesView)
        XCTAssertNotNil(payloadBytes.range(of: Data("rsa-sha2-256-cert-v01@openssh.com".utf8)))

        // The full certificate blob is embedded in the signed payload.
        var certBuffer = ByteBufferAllocator().buffer(capacity: 4096)
        certBuffer.writeCertifiedKey(cert)
        XCTAssertNotNil(payloadBytes.range(of: Data(certBuffer.readableBytesView)))
    }

    func testKnownAlgorithmsIncludeCertificateNames() {
        let known = NIOSSHPublicKey.knownAlgorithms.map { String($0) }
        let advertised = NIOSSHPublicKey.supportedUserAuthenticationAlgorithms.map(String.init)
        // Built-in certificate names.
        XCTAssertTrue(known.contains("ssh-ed25519-cert-v01@openssh.com"))
        XCTAssertTrue(known.contains("ecdsa-sha2-nistp256-cert-v01@openssh.com"))
        XCTAssertTrue(known.contains("ecdsa-sha2-nistp384-cert-v01@openssh.com"))
        XCTAssertTrue(known.contains("ecdsa-sha2-nistp521-cert-v01@openssh.com"))
        // Registered custom certificate names, including RSA's distinct auth name.
        XCTAssertTrue(known.contains("ssh-rsa-cert-v01@openssh.com"))
        XCTAssertTrue(known.contains("rsa-sha2-256-cert-v01@openssh.com"))
        XCTAssertTrue(known.contains("sk-ecdsa-sha2-nistp256-cert-v01@openssh.com"))
        XCTAssertTrue(known.contains("sk-ssh-ed25519-cert-v01@openssh.com"))
        XCTAssertEqual(advertised, known)
    }

    func testRSAAlgorithmsPreferSHA2OverLegacySHA1() throws {
        NIOSSHAlgorithms.register(
            publicKey: TestRSAPublicKey.self,
            signature: LegacyStyleRSASignature.self
        )
        let known = NIOSSHPublicKey.knownAlgorithms.map { String($0) }
        let hostKeyAlgorithms = SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms
            .map(String.init)

        XCTAssertLessThan(
            try XCTUnwrap(known.firstIndex(of: "rsa-sha2-256")),
            try XCTUnwrap(known.firstIndex(of: "ssh-rsa"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(known.firstIndex(of: "rsa-sha2-256-cert-v01@openssh.com")),
            try XCTUnwrap(known.firstIndex(of: "ssh-rsa-cert-v01@openssh.com"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(hostKeyAlgorithms.firstIndex(of: "rsa-sha2-256")),
            try XCTUnwrap(hostKeyAlgorithms.firstIndex(of: "ssh-rsa"))
        )
    }

    func testOnePublicKeyCanRegisterMultipleSignatureParsers() throws {
        NIOSSHAlgorithms.unregisterAlgorithms()
        NIOSSHAlgorithms.register(
            publicKey: TestRSAPublicKey.self,
            signatures: [
                TestRSASignature.self,
                LegacyStyleRSASignature.self,
            ]
        )

        XCTAssertEqual(
            NIOSSHPublicKey.customPublicKeyAlgorithms.filter {
                ObjectIdentifier($0) == ObjectIdentifier(TestRSAPublicKey.self)
            }.count,
            1
        )
        XCTAssertEqual(
            NIOSSHPublicKey.customSignatures.filter {
                ObjectIdentifier($0) == ObjectIdentifier(TestRSASignature.self)
                    || ObjectIdentifier($0) == ObjectIdentifier(LegacyStyleRSASignature.self)
            }.count,
            2
        )

        let key = NIOSSHPublicKey(
            backingKey: .custom(
                TestRSAPublicKey(e: Data([1, 0, 1]), n: Data(repeating: 7, count: 32))
            )
        )

        var modernBuffer = ByteBufferAllocator().buffer(capacity: 64)
        modernBuffer.writeSSHString(TestRSASignature.signaturePrefix.utf8)
        modernBuffer.writeSSHString(Data([1, 2, 3]))
        let modern = try XCTUnwrap(modernBuffer.readSSHSignature())
        guard case .custom(let modernSignature) = modern.backingSignature else {
            return XCTFail("Expected a custom modern RSA signature")
        }
        XCTAssertTrue(modernSignature is TestRSASignature)
        XCTAssertTrue(modern.matches(authenticationAlgorithmName: "rsa-sha2-256", publicKey: key))
        XCTAssertFalse(modern.matches(authenticationAlgorithmName: "ssh-rsa", publicKey: key))

        var legacyBuffer = ByteBufferAllocator().buffer(capacity: 64)
        legacyBuffer.writeSSHString(LegacyStyleRSASignature.signaturePrefix.utf8)
        legacyBuffer.writeSSHString(Data([4, 5, 6]))
        let legacy = try XCTUnwrap(legacyBuffer.readSSHSignature())
        guard case .custom(let legacySignature) = legacy.backingSignature else {
            return XCTFail("Expected a custom legacy RSA signature")
        }
        XCTAssertTrue(legacySignature is LegacyStyleRSASignature)
        XCTAssertTrue(legacy.matches(authenticationAlgorithmName: "ssh-rsa", publicKey: key))
        XCTAssertFalse(legacy.matches(authenticationAlgorithmName: "rsa-sha2-256", publicKey: key))
    }

    func testPreferredPublicKeyCanRegisterMultipleSignatureParsers() {
        NIOSSHAlgorithms.unregisterAlgorithms()
        NIOSSHAlgorithms.registerPreferred(
            publicKey: TestRSAPublicKey.self,
            signatures: [
                TestRSASignature.self,
                LegacyStyleRSASignature.self,
            ]
        )

        XCTAssertEqual(NIOSSHPublicKey.preferredPublicKeyAlgorithms.count, 1)
        XCTAssertEqual(NIOSSHPublicKey.preferredSignatures.count, 2)
    }

    func testSignatureAssociationCombinesPreferredAndRegularRegistrations() throws {
        NIOSSHAlgorithms.unregisterAlgorithms()
        NIOSSHAlgorithms.registerPreferred(
            publicKey: TestRSAPublicKey.self,
            signature: TestRSASignature.self
        )
        NIOSSHAlgorithms.register(
            publicKey: TestRSAPublicKey.self,
            signature: LegacyStyleRSASignature.self
        )

        let key = NIOSSHPublicKey(backingKey: .custom(
            TestRSAPublicKey(e: Data([1, 0, 1]), n: Data(repeating: 7, count: 32))
        ))
        var signatureBuffer = ByteBufferAllocator().buffer(capacity: 64)
        signatureBuffer.writeSSHString(LegacyStyleRSASignature.signaturePrefix.utf8)
        signatureBuffer.writeSSHString(Data([1, 2, 3]))
        let signature = try XCTUnwrap(signatureBuffer.readSSHSignature())

        XCTAssertTrue(signature.matches(authenticationAlgorithmName: "ssh-rsa", publicKey: key))
        XCTAssertTrue(
            NIOSSHPublicKey.supportedUserAuthenticationAlgorithms.contains(Substring("ssh-rsa"))
        )
    }

    func testPKOKRoundTripWithCertificate() throws {
        // PK_OK echoes the algorithm name and key blob from our request; the parser previously
        // rejected every certificate algorithm name because knownAlgorithms had no cert names.
        for fixture in [Fixtures.rsaUser, Fixtures.skEcdsaUser, Fixtures.skEd25519User] {
            let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: fixture)
            let publicKey = NIOSSHPublicKey(cert)

            var buffer = ByteBufferAllocator().buffer(capacity: 4096)
            buffer.writeSSHString(publicKey.authAlgorithmName)
            buffer.writeCompositeSSHString { $0.writeSSHHostKey(publicKey) }

            let message = try buffer.readUserAuthPKOKMessage()
            XCTAssertEqual(message?.key, publicKey)
            XCTAssertEqual(
                message?.publicKeyAlgorithmName,
                String(decoding: publicKey.authAlgorithmName, as: UTF8.self)
            )
        }
    }

    func testUserAuthRequestRoundTripWithCertifiedCustomKey() throws {
        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.rsaUser)
        let publicKey = NIOSSHPublicKey(cert)

        let message = SSHMessage.UserAuthRequestMessage(
            username: "foo",
            service: "ssh-connection",
            method: .publicKey(.known(key: publicKey, signature: nil))
        )

        var buffer = ByteBufferAllocator().buffer(capacity: 4096)
        buffer.writeUserAuthRequestMessage(message)

        let parsed = try buffer.readUserAuthRequestMessage()
        guard case .some(.publicKey(.known(let parsedKey, signature: nil))) = parsed?.method else {
            XCTFail("Unexpected method: \(String(describing: parsed?.method))")
            return
        }
        XCTAssertEqual(parsedKey, publicKey)
        XCTAssertNotNil(NIOSSHCertifiedPublicKey(parsedKey))
    }

    func testUserAuthRequestPreservesSignatureAlgorithmMismatchForAuthenticationFailure() throws {
        NIOSSHAlgorithms.register(
            publicKey: TestRSAPublicKey.self,
            signatures: [
                TestRSASignature.self,
                LegacyStyleRSASignature.self,
            ]
        )

        let key = NIOSSHPublicKey(
            backingKey: .custom(
                TestRSAPublicKey(e: Data([1, 0, 1]), n: Data(repeating: 7, count: 32))
            )
        )
        let modernSignature = NIOSSHSignature(
            backingSignature: .custom(TestRSASignature(rawRepresentation: Data([1, 2, 3])))
        )
        let mislabeledRequest = SSHMessage.UserAuthRequestMessage(
            username: "foo",
            service: "ssh-connection",
            method: .publicKey(.known(key: key, signature: modernSignature)),
            publicKeyAlgorithmName: "ssh-rsa"
        )

        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        buffer.writeUserAuthRequestMessage(mislabeledRequest)

        let parsed = try XCTUnwrap(buffer.readUserAuthRequestMessage())
        XCTAssertEqual(parsed.publicKeyAlgorithmName, "ssh-rsa")
        guard case .publicKey(.known(let parsedKey, let signature?)) = parsed.method else {
            return XCTFail("Expected a parsed signed public-key request")
        }
        XCTAssertFalse(signature.matches(
            authenticationAlgorithmName: "ssh-rsa",
            publicKey: parsedKey
        ))
    }

    func testVendorQualifiedSecurityKeyCertificateUsesRegisteredSignatureAssociation() throws {
        let certificate = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.skEcdsaUser)
        let publicKey = NIOSSHPublicKey(certificate)
        let signature = NIOSSHSignature(
            backingSignature: .custom(TestSKEcdsaSignature(rawRepresentation: Data([1, 2, 3])))
        )

        XCTAssertTrue(signature.matches(
            authenticationAlgorithmName: "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com",
            publicKey: publicKey
        ))
    }

    func testSingleSignatureRegistrationStillRejectsMismatchedAlgorithmName() {
        let publicKey = NIOSSHPublicKey(
            backingKey: .custom(
                TestRSAPublicKey(e: Data([1, 0, 1]), n: Data(repeating: 7, count: 32))
            )
        )
        let signature = NIOSSHSignature(
            backingSignature: .custom(TestRSASignature(rawRepresentation: Data([1, 2, 3])))
        )

        XCTAssertTrue(signature.matches(
            authenticationAlgorithmName: "rsa-sha2-256",
            publicKey: publicKey
        ))
        XCTAssertFalse(signature.matches(
            authenticationAlgorithmName: "ssh-rsa",
            publicKey: publicKey
        ))
    }

    func testConstructionThrowsForUnsupportedCustomKey() throws {
        let template = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.rsaUser)
        let unsupportedKey = NIOSSHPublicKey(backingKey: .custom(NoCertSupportPublicKey()))

        XCTAssertThrowsError(
            try NIOSSHCertifiedPublicKey(
                nonce: template.nonce,
                serial: template.serial,
                type: template.type,
                key: unsupportedKey,
                keyID: template.keyID,
                validPrincipals: template.validPrincipals,
                validAfter: template.validAfter,
                validBefore: template.validBefore,
                criticalOptions: template.criticalOptions,
                extensions: template.extensions,
                signatureKey: template.signatureKey,
                signature: template.signature
            )
        )
    }

    func testUnregisteredCertTypeFailsToParse() {
        NIOSSHAlgorithms.unregisterAlgorithms()
        XCTAssertThrowsError(try NIOSSHPublicKey(openSSHPublicKey: Fixtures.rsaUser))
        XCTAssertThrowsError(try NIOSSHPublicKey(openSSHPublicKey: Fixtures.skEcdsaUser))
    }

    func testCertParsingIsNotRegistrationOrderDependent() throws {
        // Two "ssh-rsa" custom types: a cert-incapable legacy one registered FIRST,
        // then the cert-capable one. Certificate parsing must use the type that
        // claimed the certificate prefix, not the first type sharing the base prefix.
        NIOSSHAlgorithms.unregisterAlgorithms()
        NIOSSHAlgorithms.register(publicKey: LegacyStyleRSAPublicKey.self, signature: LegacyStyleRSASignature.self)
        NIOSSHAlgorithms.register(publicKey: TestRSAPublicKey.self, signature: TestRSASignature.self)

        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Fixtures.rsaUser)
        XCTAssertEqual(cert.keyID, "User RSA key")
        guard case .custom(let embedded) = cert.key.backingKey else {
            XCTFail("Embedded key is not custom")
            return
        }
        XCTAssertTrue(embedded is TestRSAPublicKey, "Embedded key parsed by \(Swift.type(of: embedded)), expected TestRSAPublicKey")

        // And the round trip stays byte-exact.
        XCTAssertEqual(String(openSSHPublicKey: NIOSSHPublicKey(cert)), self.expectedExport(for: Fixtures.rsaUser))
    }

    func testPlainKeyParsingTriesEveryParserSharingPrefix() throws {
        NIOSSHAlgorithms.unregisterAlgorithms()
        NIOSSHAlgorithms.register(publicKey: LegacyStyleRSAPublicKey.self, signature: LegacyStyleRSASignature.self)
        NIOSSHAlgorithms.register(publicKey: TestRSAPublicKey.self, signature: TestRSASignature.self)

        let key = try NIOSSHPublicKey(openSSHPublicKey: Fixtures.rsaUserBase)
        guard case .custom(let parsed) = key.backingKey else {
            XCTFail("Plain key is not custom")
            return
        }
        XCTAssertTrue(parsed is TestRSAPublicKey)
    }
}
