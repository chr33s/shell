import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// Who is calling. The account is always derived from the authenticated
/// credential, never from a caller-supplied account ID
/// (spec.watch.md section 4).
public enum Principal: Sendable {
    case device(deviceID: ControlID, accountID: ControlID, grants: Set<DeviceGrant>)
    case origin(originID: ControlID, accountID: ControlID)
    /// Device enrollment and policy changes require account administration, not
    /// ordinary decision credentials.
    case admin(accountID: ControlID)

    public var accountID: ControlID {
        switch self {
        case .device(_, let accountID, _): return accountID
        case .origin(_, let accountID): return accountID
        case .admin(let accountID): return accountID
        }
    }

    var deviceID: ControlID? {
        if case .device(let deviceID, _, _) = self { return deviceID }
        return nil
    }

    var originID: ControlID? {
        if case .origin(let originID, _) = self { return originID }
        return nil
    }

    func requireGrant(_ grant: DeviceGrant) throws {
        guard case .device(_, _, let grants) = self, grants.contains(grant) else {
            throw ControlError(code: .notAuthorized, message: "missing grant \(grant.rawValue)")
        }
    }
}
