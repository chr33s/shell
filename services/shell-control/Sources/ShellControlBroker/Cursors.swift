import Foundation
import CryptoKit
import ShellControlProtocol

/// Snapshot tokens and change cursors are authenticated and bound to the
/// account and permission scope (spec.watch.md section 15).
enum CursorCodec {
    private static func tag(for principal: Principal, secret: Data) -> String {
        var material = Data(principal.accountID.rawValue.utf8)
        switch principal {
        case .device(let deviceID, _, let grants):
            material.append(Data("device:\(deviceID.rawValue):".utf8))
            material.append(Data(grants.map(\.rawValue).sorted().joined(separator: ",").utf8))
        case .origin(let originID, _):
            material.append(Data("origin:\(originID.rawValue)".utf8))
        case .admin:
            material.append(Data("admin".utf8))
        }
        let mac = HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret))
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func encodeCursor(sequence: LogSequence, principal: Principal, secret: Data) -> ChangeCursor {
        ChangeCursor("c1.\(sequence.decimalString).\(tag(for: principal, secret: secret))")
    }

    /// Returns the sequence, or throws `cursor_expired` / `not_authorized` if
    /// the cursor does not belong to this principal.
    static func decodeCursor(_ cursor: ChangeCursor, principal: Principal, secret: Data) throws -> LogSequence {
        let parts = cursor.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c1", let sequence = LogSequence(decimalString: String(parts[1])) else {
            throw ControlError(code: .cursorExpired, message: "cursor is not readable")
        }
        // A permissions change changes the tag, which forces a fresh snapshot
        // so stale unauthorized objects are removed.
        guard ContentDigest.matches(String(parts[2]), tag(for: principal, secret: secret)) else {
            throw ControlError(code: .cursorExpired, message: "cursor scope changed")
        }
        return sequence
    }

    static func encodeSnapshotToken(sequence: LogSequence, principal: Principal, secret: Data) -> String {
        "s1.\(sequence.decimalString).\(tag(for: principal, secret: secret))"
    }

    static func decodeSnapshotToken(_ token: String, principal: Principal, secret: Data) throws -> LogSequence {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "s1", let sequence = LogSequence(decimalString: String(parts[1])) else {
            throw ControlError(code: .cursorExpired, message: "snapshot token is not readable")
        }
        guard ContentDigest.matches(String(parts[2]), tag(for: principal, secret: secret)) else {
            throw ControlError(code: .cursorExpired, message: "snapshot scope changed")
        }
        return sequence
    }
}
