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
    @State private var waitingForPairing = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let session {
                    RootView(session: session)
                        .environment(session)
                } else if waitingForPairing {
                    ContentUnavailableView(
                        String(localized: "Waiting for iPhone"),
                        systemImage: "applewatch.radiowaves.left.and.right",
                        description: Text(String(localized: "Open Settings → Control on iPhone and scan the pairing QR from npx @chr33s/shell."))
                    )
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
        ControlPairingSession.shared.onBrokerURL = { url in
            Task { await adoptBrokerURL(url) }
        }
        ControlPairingSession.shared.activate()
        if let runtime = runtimeBrokerURL {
            await startSession(runtime)
            return
        }
        // Prefer a phone-paired host over a Debug baked localhost, which would
        // otherwise enroll against loopback before WatchConnectivity arrives.
        // WCSession activation plus the first application-context delivery is
        // not bounded by two seconds on a cold launch, and a loopback baked URL
        // is unreachable from the watch anyway, so wait it out in that case.
        let bakedIsReachable = ShellWatchConfiguration.bakedBrokerURL
            .flatMap(\.host)
            .map { !ControlBrokerAddress.isLoopbackHost($0) } ?? false
        if let inbound = await ControlPairingSession.shared.waitForBrokerURL(timeout: bakedIsReachable ? 2 : 10) {
            await adoptBrokerURL(inbound)
            return
        }
        if let baked = ShellWatchConfiguration.bakedBrokerURL {
            await startSession(baked)
        } else {
            waitingForPairing = true
        }
    }

    private var runtimeBrokerURL: URL? {
        guard let stored = UserDefaults.standard.string(forKey: ControlBrokerAddress.runtimeDefaultsKey),
              let url = URL(string: stored)
        else { return nil }
        return ControlBrokerAddress.normalize(url)
    }

    private func adoptBrokerURL(_ url: URL) async {
        guard let broker = ControlBrokerAddress.normalize(url) else { return }
        let defaults = UserDefaults.standard
        let previous = ShellWatchConfiguration.brokerURL
        defaults.set(broker.absoluteString, forKey: ControlBrokerAddress.runtimeDefaultsKey)
        if previous == broker, session != nil { return }
        waitingForPairing = false
        startupError = nil
        session?.signOut()
        session = nil
        await startSession(broker)
    }

    private func startSession(_ brokerURL: URL) async {
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

/// Build-time configuration. A pairing QR may override the baked URL at
/// runtime (spec.watch.md section 5).
enum ShellWatchConfiguration {
    /// The placeholder a build without a configured broker carries.
    static let unconfiguredHost = ControlBrokerAddress.unconfiguredHost

    static var bakedBrokerURL: URL? {
        ControlBrokerAddress.url(from: Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL"))
    }

    static var brokerURL: URL? {
        ControlBrokerAddress.effective(
            runtime: UserDefaults.standard.string(forKey: ControlBrokerAddress.runtimeDefaultsKey),
            baked: bakedBrokerURL
        )
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
