import Foundation
import XCTest
import Crypto
import Citadel
import NIOCore
import NIOSSH

/// Tests for OpenSSH user certificates over Citadel's custom RSA key type.
/// The fixtures are ssh-keygen-generated; the CA validation test proves the
/// certificate (including the embedded RSA key, which serializes with no inner
/// type string) re-serializes byte-exactly to what the CA signed.
final class CertificateTests: XCTestCase {
    // The P384 certificate authority that signed the cert below.
    static let caPublicKey = "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBHYlMSXacXt13oBLpMXEP0OSMw5okd5c7G3hoim1MR/THUOyOS2AVQKEqLZs+td3Y6yYCrq5TGWDNGY2dfKFX99nLqJCq2kxR//CP3UherkZnn6u4eW4biLL7xODqNOzkQ== ca"

    // An RSA-2048 user cert. id "User RSA key" serial 7 for foo,bar valid 2020-01-01 to 2070-01-01.
    // Generated using ssh-keygen -s ca -I "User RSA key" -n foo,bar -V 20200101000000:20700101000000 -z 7 user-rsa.pub
    static let rsaUserCert = "ssh-rsa-cert-v01@openssh.com AAAAHHNzaC1yc2EtY2VydC12MDFAb3BlbnNzaC5jb20AAAAg7flgLFaLeTYWMcQcu6S1F/zyuD4teKoYwpPIy8mLsIwAAAADAQABAAABAQDiKl/yM4JheFTduA6QBJl1D+Wwy7AHlk46yApS5JaTzcHaZRhH+Fjb/r+6pw6U0Gakx9icL8Aj2qUiBUdnXKMcTOKOtlYGtNLTtIfIyeoTiN/hp3IlJNNruX4l/cKgWILq4T3pXYxfgVLXxK+Szy3AdCaQqWI4czven3EF0TLJj+BL2QHjuTBtxILlIRIxCez8miMuyTWiupNkd96AYYD81uz86A0Qpvz7UAXTZtcku/TOeeuZS3I0RMRSndQfrc/DCXSMdl3IFLDbYYGrXzI4ivOLEVtGcPE831KJkkmW49bU7uTT5P9qeYKYXRIguKPIHW/tOu7lxZIMmDmygJs9AAAAAAAAAAcAAAABAAAADFVzZXIgUlNBIGtleQAAAA4AAAADZm9vAAAAA2JhcgAAAABeDFGAAAAAALwZhAAAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAiAAAABNlY2RzYS1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQR2JTEl2nF7dd6AS6TFxD9DkjMOaJHeXOxt4aIptTEf0x1DsjktgFUChKi2bPrXd2OsmAq6uUxlgzRmNnXyhV/fZy6iQqtpMUf/wj91IXq5GZ5+ruHluG4iy+8Tg6jTs5EAAACEAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAABpAAAAMQCVpAZ8bKvYWuKe+fcRHxOb6ay6WwQNqdqpdtUXZ4hucaxj+gUIkYOr2c6GVrNNXa8AAAAwIqcLYqdsNlLFs0gDrcIWFb1DCotQ+YcgMLzz/2mPk8gRqD8gUkQeVg8TU9c8caEF rsa-test"

    // The matching plain RSA public key.
    static let rsaUserBase = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDiKl/yM4JheFTduA6QBJl1D+Wwy7AHlk46yApS5JaTzcHaZRhH+Fjb/r+6pw6U0Gakx9icL8Aj2qUiBUdnXKMcTOKOtlYGtNLTtIfIyeoTiN/hp3IlJNNruX4l/cKgWILq4T3pXYxfgVLXxK+Szy3AdCaQqWI4czven3EF0TLJj+BL2QHjuTBtxILlIRIxCez8miMuyTWiupNkd96AYYD81uz86A0Qpvz7UAXTZtcku/TOeeuZS3I0RMRSndQfrc/DCXSMdl3IFLDbYYGrXzI4ivOLEVtGcPE831KJkkmW49bU7uTT5P9qeYKYXRIguKPIHW/tOu7lxZIMmDmygJs9 rsa-test"

    override func setUp() {
        // Same registration that SSHClient.connect performs for standard algorithms.
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.Signature.self)
    }

    func testParseRSAUserCertificate() throws {
        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Self.rsaUserCert)
        XCTAssertEqual(cert.serial, 7)
        XCTAssertEqual(cert.type, .user)
        XCTAssertEqual(cert.keyID, "User RSA key")
        XCTAssertEqual(cert.validPrincipals, ["foo", "bar"])

        // The embedded key is the plain RSA public key.
        let baseKey = try NIOSSHPublicKey(openSSHPublicKey: Self.rsaUserBase)
        XCTAssertEqual(cert.key, baseKey)

        // Byte-exact export under the certificate algorithm name.
        let exported = String(openSSHPublicKey: NIOSSHPublicKey(cert))
        let expected = Self.rsaUserCert.split(separator: " ", maxSplits: 2).prefix(2).joined(separator: " ")
        XCTAssertEqual(exported, expected)
    }

    func testRSAUserCertificateValidatesAgainstCA() throws {
        let caKey = try NIOSSHPublicKey(openSSHPublicKey: Self.caPublicKey)
        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Self.rsaUserCert)

        // Proves the re-serialized signable bytes (embedded RSA key included) match
        // exactly what ssh-keygen signed.
        let criticalOptions = try cert.validate(principal: "foo", type: .user, allowedAuthoritySigningKeys: [caKey])
        XCTAssertEqual(criticalOptions, [:])

        XCTAssertThrowsError(try cert.validate(principal: "nobody", type: .user, allowedAuthoritySigningKeys: [caKey]))
        XCTAssertThrowsError(try cert.validate(principal: "foo", type: .host, allowedAuthoritySigningKeys: [caKey]))
    }

    func testRSACertificateAuthenticationMethodConstruction() throws {
        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: Self.rsaUserCert)
        let privateKey = try Insecure.RSA.PrivateKey(sshRsa: rsaPrivateKeyForTesting)
        // Construction must not trap; the offer wiring is covered by NIOSSH's own tests.
        _ = SSHAuthenticationMethod.rsaCertificate(username: "foo", privateKey: privateKey, certifiedKey: cert)
        _ = SSHAuthenticationMethod.certificate(username: "foo", privateKey: .init(custom: privateKey), certifiedKey: cert)
    }
}

// The RSA-2048 private key matching rsaUserBase/rsaUserCert (test-only material).
private let rsaPrivateKeyForTesting = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEA4ipf8jOCYXhU3bgOkASZdQ/lsMuwB5ZOOsgKUuSWk83B2mUYR/hY
2/6/uqcOlNBmpMfYnC/AI9qlIgVHZ1yjHEzijrZWBrTS07SHyMnqE4jf4adyJSTTa7l+Jf
3CoFiC6uE96V2MX4FS18Svks8twHQmkKliOHM73p9xBdEyyY/gS9kB47kwbcSC5SESMQns
/JojLsk1orqTZHfegGGA/Nbs/OgNEKb8+1AF02bXJLv0znnrmUtyNETEUp3UH63Pwwl0jH
ZdyBSw22GBq18yOIrzixFbRnDxPN9SiZJJluPW1O7k0+T/anmCmF0SILijyB1v7Tru5cWS
DJg5soCbPQAAA8CIw4LBiMOCwQAAAAdzc2gtcnNhAAABAQDiKl/yM4JheFTduA6QBJl1D+
Wwy7AHlk46yApS5JaTzcHaZRhH+Fjb/r+6pw6U0Gakx9icL8Aj2qUiBUdnXKMcTOKOtlYG
tNLTtIfIyeoTiN/hp3IlJNNruX4l/cKgWILq4T3pXYxfgVLXxK+Szy3AdCaQqWI4czven3
EF0TLJj+BL2QHjuTBtxILlIRIxCez8miMuyTWiupNkd96AYYD81uz86A0Qpvz7UAXTZtck
u/TOeeuZS3I0RMRSndQfrc/DCXSMdl3IFLDbYYGrXzI4ivOLEVtGcPE831KJkkmW49bU7u
TT5P9qeYKYXRIguKPIHW/tOu7lxZIMmDmygJs9AAAAAwEAAQAAAQAPycN+5eehJERQYgvq
M9f+mwh+yglUzkJRyismVDzKvp9cvpfuVkDlwqfhwM28x7uSnzzY0mCIYDgM4u90ILxmOl
vKeKISv8bD7qNX+fh0OqbeWtEWFLcJmx5aSpeul98zxFuNEfG9rQp6c4mKJxpbiAA1Mw3f
QPQZ+2lpbYwtE9N/hLOmrrMCP9gYFX/UZpsc2xvq9LO0nL0ITNx4/whIdW5ArjvLm5fLTb
Z9JNiI/4/m1mDYq0T85JNIeOl+qCh9d92rrBbkNnNPXcUX0xsShcpgo9R6u23BpoNWcUNe
4+PilGMt2IgmTcmVtRRDqO9gkhQv5LM8DPPXGp4cHKXFAAAAgAt3Anhhg9lXCP26b0+BTa
16V0w+7tso6pimpGv4We3Z20tXQvzztx3gaR8cS9vY/BajBlrrVYoK1oTI8MvezVmmim19
a53fkeLs/vetA4fKGzN1Iuf8TK+7EM3eqFBy80wMLHRWjPnKMwQ5LCz+dckw3fy6KkE0j6
yZyUhhIAYCAAAAgQD+n4erF7IETuc+mLSSJUyot4X1T54MpUaDIMDfCLZupDfI4PhhjxX1
4OQ/Zmi/dqn6Mdia5ak7/z+0APF1oHro20EWW2Vf2lphMu3sTmppUOYismw0H6hplR6O3p
aujRwsgEsXn8RxRAh3t5h4DvOd8Pd8cULOOUifiydOpbd9UwAAAIEA42Nzkyb+SuY+qt7U
Bi28grDzO80dsY/PZ3E2l0jqn1Qa7rh5hQRe3lEeLOPE3f9s24ijWOyz22/asesJ37lbWa
L+FAT8evlY+VPlpxFncenjxa/XZR6ebGZv2ioxnSftADJ9w8o31VXztObGK5ICoOxGMguA
4Kx6RHp6FUGQ4y8AAAAIcnNhLXRlc3QBAgM=
-----END OPENSSH PRIVATE KEY-----
"""
