import Foundation

/// State machine for SSH session lifecycle
/// Used for progress indicator escape sequences (OSC 9;4)
enum SSHSessionState: Equatable, Sendable {
    /// Initial state before starting
    case initial

    /// Connecting to SSH server (or jump host)
    case connecting(host: String, isJumpHost: Bool)

    /// Authenticating with server
    case authenticating(host: String, isJumpHost: Bool)

    /// Connected via jump host, now connecting to target
    case connectingToTarget(host: String)

    /// Authenticating with target through tunnel
    case authenticatingTarget(host: String)

    /// Session is running and ready for input
    case running

    /// Session disconnected
    case disconnected

    /// Session failed with error
    case failed

    /// Waiting to reconnect after unexpected disconnection
    case waitingToReconnect(attempt: Int, delaySeconds: Int)

    /// Actively attempting to reconnect
    case reconnecting(attempt: Int)

    /// Reconnection failed after max attempts or due to permanent error
    case reconnectionFailed(reason: String)

    /// Human-readable description for UI status line
    var statusDescription: String {
        switch self {
        case .initial:
            return "Ready"
        case .connecting(let host, let isJumpHost):
            return isJumpHost ? "Connecting to jump host \(host)..." : "Connecting to \(host)..."
        case .authenticating(_, let isJumpHost):
            return isJumpHost ? "Authenticating with jump host..." : "Authenticating..."
        case .connectingToTarget(let host):
            return "Connecting to \(host)..."
        case .authenticatingTarget:
            return "Authenticating..."
        case .running:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection failed"
        case .waitingToReconnect(let attempt, let delay):
            return "Reconnecting in \(delay)s (attempt \(attempt))..."
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))..."
        case .reconnectionFailed(let reason):
            return "Reconnection failed: \(reason)"
        }
    }

    /// Color style for spinner animation based on current state
    var spinnerColorStyle: SpinnerAnimator.ColorStyle {
        switch self {
        case .connecting, .connectingToTarget:
            return .connecting
        case .authenticating, .authenticatingTarget:
            return .authenticating
        case .running:
            return .success
        case .failed, .reconnectionFailed:
            return .error
        case .waitingToReconnect, .reconnecting:
            return .reconnecting
        default:
            return .connecting
        }
    }
}
