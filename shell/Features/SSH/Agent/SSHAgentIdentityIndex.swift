//
//  SSHAgentIdentityIndex.swift
//  shell
//
//  The identities the local SSH agent advertises, and the exact-blob lookup
//  that maps a sign request back to a key (ssh-agent-bridge-spec.md §7, §11.1).
//
//  Built from the device-local agent grant list
//  (`LocalSSHAgentPolicy.allowedKeyIDs`, ssh-agent-bridge-v2-delta.md §4) —
//  never from `defaultKeyIDs` or every stored key. The index is a value
//  computed per request (enumeration and sign alike), so grants, revokes,
//  imports/deletes, unlocks and certificate changes or expiry take effect
//  for already-connected clients without any invalidation.
//

import Foundation
import NIOCore
import NIOFoundationCompat
import Citadel

nonisolated struct SSHAgentIdentityIndex: Sendable {

    struct Entry: Sendable, Equatable {
        let keyID: UUID
        let keyType: SSHKey.KeyType
        /// Exact wire blob a client presents: a raw public key or a certificate.
        let blob: Data
        let comment: String
        let isCertificate: Bool
    }

    /// Advertised identities, in `SSH_AGENT_IDENTITIES_ANSWER` order.
    let entries: [Entry]

    static let empty = SSHAgentIdentityIndex(entries: [])

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// - Parameters:
    ///   - memberKeyIDs: agent membership and order (the allowlist).
    ///   - keys: the current local `savedKeys`.
    ///   - locallyUsable: keys whose private material is usable on this device
    ///     right now (present in the local Keychain / Secure Enclave and not
    ///     awaiting a legacy unlock). Anything else is not advertised.
    ///   - now: clock for certificate validity.
    init(
        memberKeyIDs: [UUID],
        keys: [SSHKey],
        locallyUsable: Set<UUID>,
        now: Date = Date()
    ) {
        let keysByID = Dictionary(keys.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        var entries: [Entry] = []

        for id in memberKeyIDs {
            guard seen.insert(id).inserted,
                  let key = keysByID[id],
                  locallyUsable.contains(id),
                  let rawBlob = key.publicKeyBlob,
                  SSHPublicKeyBlob.isComplete(rawBlob, keyType: key.keyType) else {
                continue
            }

            if let certificate = key.userCertificate,
               Self.isCurrentlyValid(certificate, now: now) {
                entries.append(Entry(
                    keyID: id,
                    keyType: key.keyType,
                    blob: certificate.certificateBlob,
                    comment: "Shell: \(key.name) (certificate)",
                    isCertificate: true
                ))
            }
            entries.append(Entry(
                keyID: id,
                keyType: key.keyType,
                blob: rawBlob,
                comment: "Shell: \(key.name)",
                isCertificate: false
            ))
        }

        self.entries = entries
    }

    /// The index a policy permits: nothing while the agent is disabled,
    /// otherwise exactly the allowlist in its order.
    init(
        policy: LocalSSHAgentPolicy,
        keys: [SSHKey],
        locallyUsable: Set<UUID>,
        now: Date = Date()
    ) {
        guard policy.enabled else {
            self.init(entries: [])
            return
        }
        self.init(memberKeyIDs: policy.allowedKeyIDs, keys: keys, locallyUsable: locallyUsable, now: now)
    }

    /// Identity list for `SSH_AGENT_IDENTITIES_ANSWER`.
    var identities: [SSHAgentIdentity] {
        entries.map { SSHAgentIdentity(publicKeyBlob: ByteBuffer(data: $0.blob), comment: $0.comment) }
    }

    /// Resolves a sign request by exact blob equality — never by name,
    /// fingerprint, algorithm or position.
    func entry(forBlob blob: Data) -> Entry? {
        entries.first { $0.blob == blob }
    }

    // MARK: - Helpers

    /// Same rule as `SSHUserCertificateInfo.isExpired` / `isNotYetValid`,
    /// against an injectable clock.
    static func isCurrentlyValid(_ certificate: SSHUserCertificateInfo, now: Date) -> Bool {
        let seconds = now.timeIntervalSince1970
        if certificate.validBefore != .max, seconds >= Double(certificate.validBefore) {
            return false
        }
        if certificate.validAfter != 0, seconds < Double(certificate.validAfter) {
            return false
        }
        return true
    }
}
