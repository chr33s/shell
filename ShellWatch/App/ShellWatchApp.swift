import SwiftUI
import UserNotifications
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// Shell Watch: an independent watchOS app. Its critical path is
/// Watch → HTTPS control service → originating host; WatchConnectivity is never
/// required (spec.watch.md section 1).
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
        guard let brokerURL = ShellWatchConfiguration.brokerURL else {
            // Saying so beats dialling a placeholder host and surfacing an
            // opaque network error during enrollment.
            startupError = String(localized: "This build has no control service configured. Set SHELL_CONTROL_BROKER_URL and rebuild.")
            return
        }
        do {
            let session = try ControlSession(
                brokerURL: brokerURL,
                credentials: KeychainCredentialStore(
                    service: "dev.chr33s.shell.control",
                    accessGroup: ShellWatchConfiguration.keychainAccessGroup
                ),
                cache: try ProtectedInboxCache(),
                journalStore: try FileCommandJournalStore()
            )
            self.session = session
            delegate.session = session
            await session.start()
        } catch {
            startupError = String(describing: error)
        }
    }
}

/// Build-time configuration. The broker address is a deployment choice, and
/// changing it requires re-enrollment and clearing the old cache
/// (spec.watch.md section 5).
enum ShellWatchConfiguration {
    /// The placeholder a build without a configured broker carries.
    static let unconfiguredHost = "control.invalid"

    static var brokerURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL") as? String,
              let url = URL(string: text),
              url.host != unconfiguredHost
        else {
            return nil
        }
        return url
    }

    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "SHELLWatchKeychainAccessGroup") as? String
    }

    static var apnsTopic: String {
        Bundle.main.bundleIdentifier ?? "dev.chr33s.shell.watchkitapp"
    }

    static var apnsEnvironment: PushRegistration.Environment {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }
}

struct RootView: View {
    let session: ControlSession

    var body: some View {
        switch session.phase {
        case .loading:
            ProgressView()
        case .needsEnrollment:
            EnrollmentView()
        case .ready:
            InboxView()
        }
    }
}
