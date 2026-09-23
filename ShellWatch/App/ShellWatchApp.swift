import SwiftUI
import UserNotifications
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// Shell Watch: a review and signing client behind its paired iPhone. Its
/// critical path is Watch → WatchConnectivity → iPhone → Tailscale → Mac; the
/// Watch never talks to the Mac or the network itself
/// (spec.iphone-gateway.md section 1).
@main
struct ShellWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var session: ControlSession?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let session {
                    RootView(session: session)
                        .environment(session)
                        .environment(WatchConnectivityGateway.shared)
                } else if let startupError {
                    ContentUnavailableView(
                        String(localized: "Setup needed"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(startupError)
                    )
                } else {
                    ProgressView()
                }
            }
            .task { await bootstrap() }
        }
    }

    private func bootstrap() async {
        guard session == nil else { return }
        let gateway = WatchConnectivityGateway.shared
        do {
            let session = try ControlSession(
                link: gateway.link,
                keys: KeychainCredentialStore(
                    service: "dev.chr33s.shell.control",
                    accessGroup: ShellWatchConfiguration.keychainAccessGroup
                ),
                reviewerStore: DefaultsWatchReviewerStore(),
                cache: try ProtectedInboxCache(),
                journalStore: try FileCommandJournalStore(protection: .completeFileProtection)
            )
            gateway.onReachabilityChange = { reachable in session.gatewayReachabilityChanged(reachable) }
            gateway.onContext = { context in session.applyContext(context) }
            gateway.activate()
            self.session = session
            delegate.session = session
            await session.start()
        } catch {
            startupError = String(describing: error)
        }
    }
}

/// Build-time configuration. There is deliberately no broker URL: the Watch
/// has no route of its own (spec.iphone-gateway.md section 4.6).
enum ShellWatchConfiguration {
    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "SHELLWatchKeychainAccessGroup") as? String
    }
}

struct RootView: View {
    let session: ControlSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                ProgressView()
            case .needsEnrollment, .awaitingConfirmation:
                EnrollmentView()
            case .ready:
                InboxView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            session.noteSceneActive(phase == .active)
        }
        .onAppear {
            session.noteSceneActive(scenePhase == .active)
        }
    }
}
