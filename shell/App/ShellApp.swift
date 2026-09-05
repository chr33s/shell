//
//  ShellApp.swift
//  shell
//

import SwiftUI
import Combine
import GhosttyKit

#if canImport(UIKit)
import UIKit
#endif

@main
struct ShellApp: App {
    @StateObject private var ghosttyApp = Ghostty.App()
    @StateObject private var appearanceManager = AppearanceManager.shared

    #if targetEnvironment(macCatalyst)
    @UIApplicationDelegateAdaptor(CatalystAppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    /// Guards the app-level startup work in the WindowGroup `.task` so it runs
    /// ONCE per launch, not per window. SwiftUI runs that `.task` for every
    /// window; re-running CloudKit sync on each new window saturated the
    /// MainActor during window open, which made new windows feel slow.
    @MainActor private static var didRunAppStartupTasks = false

    init() {
        // Guard against background launches before device unlock.
        // These singletons read UserDefaults in init() and have didSet observers
        // that write values back — if defaults are empty (encrypted), they overwrite
        // the real settings with zeros/nils.
        guard ProtectedDataGuard.isAvailable else { return }

        // Initialize FontManager early to register bundled fonts
        // before Ghostty surfaces try to use them
        _ = FontManager.shared

        // Initialize RemoteSessionTracker early to ensure notification observer
        // is set up before any MainView instances post notifications
        _ = RemoteSessionTracker.shared
    }

    var body: some Scene {
        WindowGroup(id: "main-terminal") {
            MainView()
                .environmentObject(ghosttyApp)
                .preferredColorScheme(appearanceManager.colorScheme)
                .statusBarStyleForTerminalTheme()
                .task {
                    guard ProtectedDataGuard.isAvailable else { return }
                    guard !Self.didRunAppStartupTasks else { return }
                    Self.didRunAppStartupTasks = true

                    // Sync CloudKit data on launch (profiles, identities, known hosts)
                    if CloudKitSyncManager.shared.isSyncEnabled {
                        try? await CloudKitSyncManager.shared.syncNow()
                    }
                }
                // Catalyst routes ssh:// through CatalystSceneDelegate instead, so
                // the open is addressed to the scene it arrived on. Posting here
                // as well would open the same host a second time in that window.
                #if !targetEnvironment(macCatalyst)
                .onOpenURL { url in
                    guard let components = SSHURLParser.parse(url) else { return }
                    NotificationCenter.default.post(
                        name: .sshURLReceived,
                        object: nil,
                        userInfo: [SSHURLPayload.key: SSHURLPayload(components: components)]
                    )
                }
                #endif
                #if !targetEnvironment(macCatalyst)
                // iOS: use UIKit activation notifications for app activation sync.
                // Keeping this out of SwiftUI scenePhase avoids subscribing the
                // root app scene graph to foreground environment updates.
                // Mac Catalyst uses NSWorkspace notifications instead - see CatalystAppDelegate.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in

                    // Save a snapshot of sentinel UserDefaults keys while data is available.
                    // Used to detect and recover from corruption caused by background launches.
                    DispatchQueue.global(qos: .utility).async {
                        UserDefaultsBackup.saveSnapshot()
                    }

                    // Capture the lifecycle background epoch at activation
                    // observe time. The deferred closure below re-reads the live
                    // value at fire time and aborts if a `handleAppBackgrounded`
                    // ran in between.
                    let scheduledAtBgEpoch = LifecycleEpoch.shared.background

                    Task { @MainActor in
                        let currentBgEpoch = LifecycleEpoch.shared.background
                        guard currentBgEpoch == scheduledAtBgEpoch else {
                            return
                        }
                        guard CloudKitSyncManager.shared.isSyncEnabled else { return }

                        try? await CloudKitSyncManager.shared.syncNow()
                        // Re-check after the sync await — sync can span seconds;
                        // a backgrounding mid-sync means the completion
                        // checkpoint we'd log is misleading.
                        let postCkEpoch = LifecycleEpoch.shared.background
                        if postCkEpoch == scheduledAtBgEpoch {
                        } else {
                        }
                    }
                }
                #endif
        }
        .commands {
            AppCommands()
        }
        .handlesExternalEvents(matching: ["ssh", "file://"])
    }
}
