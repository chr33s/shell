import SwiftUI
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// Watch setup behind the iPhone gateway: the Watch makes its own key, the
/// iPhone carries the public half to the Mac, and the Mac confirms it
/// locally. No key or token is ever copied between devices
/// (docs/specs/control-protocol.md section 5.3).
struct EnrollmentView: View {
    @Environment(ControlSession.self) private var session
    @Environment(WatchConnectivityGateway.self) private var gateway
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Set up Shell Watch"))
                    .font(.headline)
                switch session.phase {
                case .awaitingConfirmation(let status):
                    if let code = status.userCode {
                        Text(code)
                            .font(.system(.title2, design: .monospaced))
                    }
                    // The same fingerprint is shown by shell-control on the Mac.
                    Text(String(localized: "Key fingerprint \(status.fingerprint)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Confirm this code on the Mac running shell-control setup --guided (or shell-control pair --watch)."))
                        .font(.caption)
                    Button(String(localized: "Check again")) {
                        Task { await session.checkEnrollment() }
                    }
                    .disabled(!gateway.isReachable)
                default:
                    Text(String(localized: "This Watch reaches your Mac through its paired iPhone. Pair the iPhone first in Shell → Settings → Control. The Watch is optional: the iPhone reviews on its own."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Start setup")) {
                        Task {
                            isRunning = true
                            await session.enroll(label: WKInterfaceDeviceLabel.current)
                            isRunning = false
                        }
                    }
                    .disabled(isRunning || !gateway.isReachable)
                }
                if !gateway.isReachable {
                    Label(String(localized: "iPhone unavailable"), systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let message = session.enrollmentMessage {
                    Text(message)
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 4)
        }
        // While this screen is up, ask the Mac every few seconds whether it
        // confirmed; nothing polls once the screen goes away.
        .task(id: session.phase) {
            guard case .awaitingConfirmation = session.phase else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard gateway.isReachable else { continue }
                await session.checkEnrollment()
            }
        }
    }
}

/// A display label for the enrolling device, shown on the Mac.
enum WKInterfaceDeviceLabel {
    static var current: String {
        #if canImport(WatchKit)
        return "Apple Watch"
        #else
        return "Watch"
        #endif
    }
}
