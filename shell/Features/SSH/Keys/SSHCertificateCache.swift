import Foundation
import NIOSSH
import os

/// Parsed user certificates belong to the key metadata that supplied them.
/// A changed blob forces a new parse, including after iCloud refresh.
@MainActor
final class SSHCertificateCache {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHCertificateCache")
    private var entries: [UUID: (blob: Data, cert: NIOSSHCertifiedPublicKey)] = [:]

    func clear() { entries.removeAll() }
    func remove(_ id: UUID) { entries[id] = nil }

    func store(_ certificate: ParsedUserCertificate, for id: UUID) {
        entries[id] = (blob: certificate.info.certificateBlob, cert: certificate.certifiedKey)
    }

    func certifiedKey(for key: SSHKey) -> NIOSSHCertifiedPublicKey? {
        guard let info = key.userCertificate else {
            remove(key.id)
            return nil
        }
        if let entry = entries[key.id], entry.blob == info.certificateBlob {
            return entry.cert
        }
        do {
            let certificate = try SSHUserCertificateParser.certifiedKey(fromStoredBlob: info.certificateBlob)
            entries[key.id] = (blob: info.certificateBlob, cert: certificate)
            return certificate
        } catch {
            remove(key.id)
            Self.logger.error("Stored certificate for key '\(key.name)' failed to parse: \(error.localizedDescription)")
            return nil
        }
    }
}
