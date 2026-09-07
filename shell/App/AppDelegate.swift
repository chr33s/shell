//
//  AppDelegate.swift
//  shell
//
//  Base AppDelegate for handling remote notifications (CloudKit push)
//  and app lifecycle events. CatalystAppDelegate inherits from this.
//

import AppIntents
import AVFoundation
import UIKit
import UserNotifications
import os.log

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "AppDelegate")
    private let protectedDataNotificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.chr33s.shell.appDelegate.protectedData"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Register volatile UserDefaults defaults BEFORE any scene/view construction.
        // This is safe before unlock — `register(defaults:)` only writes to the volatile
        // registration domain and never touches disk.
        LaunchDefaults.registerVolatileDefaults()

        // Control-companion notification categories and the response handler are
        // installed before any scene or view is constructed, so a notification
        // that arrives during a background launch still has its actions and a
        // delegate to route them (spec.watch.md section 2). This runs outside
        // the protected-data gate because it touches no UserDefaults and no
        // Keychain item, and it does not disturb the CloudKit push path below.
        ControlNotifications.registerCategories()
        UNUserNotificationCenter.current().delegate = self

        installLifecycleObservers()

        // Register the keyboard-window visibility observer before the first
        // keyboard appearance so toolbar keys can read the system Shift state.
        SystemShiftReader.shared.activate()

        // Configure audio session to not interrupt other apps' audio.
        // Use .playback category with .mixWithOthers option - this is the pattern used by
        // Twitter/X for video previews and is more reliable than .ambient for video playback.
        // This must be configured BEFORE any AVPlayer is created.
        // (No UserDefaults dependency — safe to run before unlock.)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.logger.warning("Failed to configure audio session: \(error.localizedDescription)")
        }

        SettingsRegistry.shared.assertInvariants()

        // All UserDefaults-dependent initialization must wait until the device is unlocked.
        // Background launches (VPN reconnect, Live Activities, CloudKit push) can start
        // the app process before protected data is available, causing UserDefaults to return
        // empty values and permanently overwrite real settings.
        ProtectedDataGuard.whenAvailable {
            UserDefaultsBackup.detectAndRecover()
            LaunchDefaults.announceProtectedDataAvailable()
            SettingsStore.shared.bootstrap()
            SettingsSyncCoordinator.shared.start()
            // Interim until every manager registers its own reload(keys:).
            // Instantiate eagerly so the battery / Low Power Mode / thermal /
            // activation observers are live from launch rather than from
            // whenever the first surface reads the frame-rate range. Inside
            // the gate because init reads the persisted refresh settings.
            _ = PowerManager.shared
            Task { @MainActor in
                await CloudKitSyncManager.shared.logDiagnostics()
                await CloudKitSyncManager.shared.revalidateSubscriptionsIfNeeded()
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Best-effort deferral: if the process survives until unlock, the observer
        // fires and we sync immediately. If iOS kills the process first, the observer
        // is lost — but ShellApp's activation observer calls syncNow()
        // whenever the user next foregrounds the app, so changes are still picked up.
        guard ProtectedDataGuard.isAvailable else {
            Self.logger.warning("CloudKit push received while locked — deferring sync until unlock")
            ProtectedDataGuard.whenAvailable {
                Self.logger.info("Processing deferred CloudKit push after unlock")
                Task { @MainActor in
                    await CloudKitSyncManager.shared.handleRemoteNotification()
                }
            }
            completionHandler(.noData)
            return
        }

        Self.logger.info("Received remote notification for CloudKit sync")

        Task { @MainActor in
            await CloudKitSyncManager.shared.handleRemoteNotification()
            completionHandler(.newData)
        }
    }

    // MARK: - Control companion

    /// Routes a notification response into the review flow. The response
    /// selects an intent; it never authorizes anything from the payload
    /// (spec.watch.md section 6).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let intent = ControlNotifications.intent(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        Task { @MainActor in
            ControlNotifications.pendingIntent = intent
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Subscribe to OS notifications that may correlate with watchdog wedges:
    /// Keychain availability transitions, memory warnings, and termination.
    /// Each observer logs a single checkpoint to the lifecycle log so the
    /// post-mortem trace shows whether one of these events landed inside a
    /// scene-update transaction.
    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: .main) { _ in
            let appState = String(describing: UIApplication.shared.applicationState)
            ForegroundActivationGate.shared.markWillEnterForeground(appState: appState)
            ForegroundTransitionWatchdog.shared.arm(appState: appState)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in
            Ghostty.isSecureDrawProhibitedAtomic = false
            let appState = String(describing: UIApplication.shared.applicationState)
            ForegroundActivationGate.shared.markDidBecomeActive(appState: appState)
            ForegroundTransitionWatchdog.shared.disarm(reason: "didBecomeActive", appState: appState)
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification,
                       object: nil, queue: .main) { _ in
            Ghostty.isSecureDrawProhibitedAtomic = true
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { _ in
            Ghostty.isSecureDrawProhibitedAtomic = true
            let appState = String(describing: UIApplication.shared.applicationState)
            ForegroundActivationGate.shared.markDidEnterBackground(appState: appState)
            ForegroundTransitionWatchdog.shared.disarm(reason: "didEnterBackground", appState: appState)
        }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                       object: nil, queue: .main) { _ in
            // A lock that reaches us here rather than via willResignActive must
            // still close the secure-draw gate.
            Ghostty.isSecureDrawProhibitedAtomic = true
        }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                       object: nil, queue: protectedDataNotificationQueue) { _ in
            Task { @MainActor in
            }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                       object: nil, queue: .main) { _ in
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification,
                       object: nil, queue: .main) { _ in
        }
    }
}

final class ForegroundActivationGate: Sendable {
    nonisolated static let shared = ForegroundActivationGate()

    enum TimeoutPolicy: Sendable, Equatable {
        case drop
        case fireIfNotBackgrounded
    }

    private struct State: Sendable {
        var nextToken: UInt64 = 0
        var activeToken: UInt64 = 0
        var settlingUntil: TimeInterval = 0
        var lastEvent: String = "initial"
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private nonisolated static let defaultSettlingDelay: TimeInterval = 0
    private nonisolated static let retryDelay: TimeInterval = 0.02
    private nonisolated static let maxRetryAttempts = 800

    private init() {}

    nonisolated var isUnsafeForSceneMutation: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return state.withLock { state in
            state.activeToken != 0 || now < state.settlingUntil
        }
    }

    nonisolated func diagnosticFields() -> [(String, Any)] {
        let now = Date().timeIntervalSinceReferenceDate
        return state.withLock { state in
            [
                ("activationGateUnsafe", state.activeToken != 0 || now < state.settlingUntil),
                ("activationToken", state.activeToken),
                ("activationLastEvent", state.lastEvent),
                ("activationSettlingMs", max(0, (state.settlingUntil - now) * 1000)),
            ]
        }
    }

    nonisolated func markWillEnterForeground(appState: String) {
        // This observer is installed early, but NotificationCenter ordering is
        // still registration-order. Callers should not rely on this being armed
        // for synchronous work inside their own willEnterForeground observer;
        // hop/defer through runWhenSafe before mutating scene/UI state.
        _ = state.withLock { state -> UInt64 in
            state.nextToken &+= 1
            state.activeToken = state.nextToken
            state.settlingUntil = .greatestFiniteMagnitude
            state.lastEvent = "willEnterForeground"
            return state.activeToken
        }

    }

    nonisolated func markDidBecomeActive(
        appState: String,
        settlingDelay: TimeInterval = defaultSettlingDelay
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        let token = state.withLock { state -> UInt64 in
            if state.activeToken == 0 {
                state.nextToken &+= 1
                state.activeToken = state.nextToken
            }
            state.settlingUntil = now + settlingDelay
            state.lastEvent = "didBecomeActive.settling"
            return state.activeToken
        }


        DispatchQueue.main.asyncAfter(deadline: .now() + settlingDelay) { [self] in
            clearIfSettled(token: token, appState: String(describing: UIApplication.shared.applicationState))
        }
    }

    nonisolated func markDidEnterBackground(appState: String) {
        _ = state.withLock { state -> UInt64 in
            let token = state.activeToken
            state.activeToken = 0
            state.settlingUntil = 0
            state.lastEvent = "didEnterBackground"
            return token
        }

    }

    @MainActor
    func runWhenSafe(
        reason: String,
        delay: TimeInterval = retryDelay,
        timeoutPolicy: TimeoutPolicy = .drop,
        _ block: @MainActor @escaping () -> Void
    ) {
        runWhenSafe(reason: reason, delay: delay, timeoutPolicy: timeoutPolicy, attempt: 0, block)
    }

    @MainActor
    private func runWhenSafe(
        reason: String,
        delay: TimeInterval,
        timeoutPolicy: TimeoutPolicy,
        attempt: Int,
        _ block: @MainActor @escaping () -> Void
    ) {
        guard isUnsafeForSceneMutation || UIApplication.shared.applicationState != .active else {
            block()
            return
        }

        guard attempt < Self.maxRetryAttempts else {
            if timeoutPolicy == .fireIfNotBackgrounded,
               UIApplication.shared.applicationState != .background,
               !Ghostty.isAppBackgroundedAtomic {
                block()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.runWhenSafe(
                    reason: reason,
                    delay: delay,
                    timeoutPolicy: timeoutPolicy,
                    attempt: attempt + 1,
                    block
                )
            }
        }
    }

    private nonisolated func clearIfSettled(token: UInt64, appState: String) {
        let now = Date().timeIntervalSinceReferenceDate
        let didClear = state.withLock { state -> Bool in
            guard state.activeToken == token else { return false }
            guard now >= state.settlingUntil else { return false }
            state.activeToken = 0
            state.settlingUntil = 0
            state.lastEvent = "clear"
            return true
        }

        guard didClear else { return }
    }
}

private final class ForegroundTransitionWatchdog: Sendable {
    nonisolated static let shared = ForegroundTransitionWatchdog()

    private struct State: Sendable {
        var token: UInt64 = 0
        var activeToken: UInt64 = 0
        var armedAt: Date?
        var firedToken: UInt64 = 0
        var firedAt: Date?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let queue = DispatchQueue(label: "dev.chr33s.shell.foregroundTransitionWatchdog", qos: .utility)

    private init() {}

    nonisolated func arm(appState: String) {
        let token = state.withLock { state -> UInt64 in
            state.token &+= 1
            state.activeToken = state.token
            state.armedAt = Date()
            state.firedToken = 0
            state.firedAt = nil
            return state.token
        }



        scheduleHeartbeat(token: token, ordinal: 1)
        queue.asyncAfter(deadline: .now() + 8.0) { [self] in
            fireIfStillArmed(token: token)
        }
    }

    nonisolated func disarm(reason: String, appState: String) {
        let snapshot = state.withLock { state -> (token: UInt64, elapsedMs: Double, fired: Bool, firedElapsedMs: Double) in
            let token = state.activeToken != 0 ? state.activeToken : state.firedToken
            let now = Date()
            let elapsedMs = state.armedAt.map { now.timeIntervalSince($0) * 1000 } ?? -1
            let fired = state.activeToken == 0 && state.firedToken != 0
            let firedElapsedMs = state.firedAt.map { now.timeIntervalSince($0) * 1000 } ?? -1
            state.activeToken = 0
            state.armedAt = nil
            state.firedToken = 0
            state.firedAt = nil
            return (token, elapsedMs, fired, firedElapsedMs)
        }
        guard snapshot.token != 0 else { return }
    }

    private nonisolated func scheduleHeartbeat(token: UInt64, ordinal: Int) {
        queue.asyncAfter(deadline: .now() + 1.0) { [self] in
            let snapshot = state.withLock { state -> (active: Bool, elapsedMs: Double) in
                guard state.activeToken == token, let armedAt = state.armedAt else {
                    return (false, -1)
                }
                return (true, Date().timeIntervalSince(armedAt) * 1000)
            }
            guard snapshot.active else { return }


            Task { @MainActor in
            }

            if ordinal < 8 {
                scheduleHeartbeat(token: token, ordinal: ordinal + 1)
            }
        }
    }

    private nonisolated func fireIfStillArmed(token: UInt64) {
        let snapshot = state.withLock { state -> (active: Bool, elapsedMs: Double) in
            guard state.activeToken == token, let armedAt = state.armedAt else {
                return (false, -1)
            }
            state.activeToken = 0
            state.firedToken = token
            state.firedAt = Date()
            return (true, Date().timeIntervalSince(armedAt) * 1000)
        }
        guard snapshot.active else { return }

        // Keep sampling for one more interval after the fire to capture the
        // last main-thread state, then stop. We rely on the cap (40 samples =
        // 10 s) and the disarm path to bound total samples.


    }
}
