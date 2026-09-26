import Foundation
import LocalAuthentication
import Security
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Crypto
import Citadel

/// Creates the device-bound key and public metadata. Persistence and default
/// selection remain with SSHKeyManager after duplicate checking.
enum SSHSecureEnclaveKeyFactory {
    struct Material {
        let key: SSHKey
        let dataRepresentation: Data
    }

    static func create(name: String, authRequirement: KeyAuthRequirement) throws -> Material {
        let access = try accessControl(for: authRequirement)
        let enclaveKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            enclaveKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            throw SSHKeyManager.SecureEnclaveError.creationFailed(error)
        }

        let publicPoint = Data(enclaveKey.publicKey.x963Representation)
        let fingerprint = SHA256.hash(data: publicPoint).map { String(format: "%02x", $0) }.joined()
        let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: enclaveKey)
        var key = SSHKey(name: name, keyType: .secureEnclaveP256, fingerprint: fingerprint,
                         hasPassphrase: false, storageLevel: .deviceOnly, authRequirement: authRequirement)
        key.secureEnclaveInfo = SecureEnclaveKeyInfo(publicKeyX963: publicPoint, createdDate: key.createdDate)
        let blob = SSHPublicKeyBlob.make(from: .secureEnclaveP256(nioKey), keyType: .secureEnclaveP256)
        key.publicKeyBlob = blob.getData(at: blob.readerIndex, length: blob.readableBytes)
        return Material(key: key, dataRepresentation: enclaveKey.dataRepresentation)
    }

    /// The key itself enforces biometric or passcode access when requested.
    nonisolated static func accessControl(for authRequirement: KeyAuthRequirement) throws -> SecAccessControl {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if authRequirement != .none {
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                flags.formUnion([.biometryCurrentSet, .or, .devicePasscode])
            } else {
                flags.insert(.devicePasscode)
            }
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error
        ) else {
            throw SSHKeyManager.SecureEnclaveError.accessControlFailed(error?.takeRetainedValue())
        }
        return access
    }
}
