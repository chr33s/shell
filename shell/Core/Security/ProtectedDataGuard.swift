//
//  ProtectedDataGuard.swift
//  shell
//
//  Guards against reading/writing UserDefaults before the device is unlocked.
//  On iPadOS 26+, background launches (VPN, Live Activities, CloudKit push)
//  can start the app process before protected data is available, causing
//  UserDefaults to return empty values and overwrite real settings.
//

import UIKit
import os.log

enum ProtectedDataGuard {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "ProtectedDataGuard")
    private nonisolated static let protectedDataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.chr33s.shell.protectedDataGuard"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// Whether the device is unlocked and protected data (including UserDefaults) is readable.
    @MainActor
    static var isAvailable: Bool {
        UIApplication.shared.isProtectedDataAvailable
    }

    /// Runs `action` once protected data is available.
    ///
    /// This is intentionally not gated on foreground activation: protected-data
    /// work such as migrations, push registration, and CloudKit maintenance must
    /// still run during background launches/unlocks.
    @MainActor
    static func whenAvailable(_ action: @MainActor @escaping @Sendable () -> Void) {
        if isAvailable {
            runWhenProtectedDataAvailable(action, reason: "available")
            return
        }
        logger.warning("Protected data NOT available — deferring initialization")
        // The observer must stay armed until `action` has actually been handed off.
        // Previously the token was removed on the utility queue *before* the MainActor
        // hop, so if the device re-locked between the notification landing and the hop
        // draining (the process can be suspended in between on a background launch), the
        // re-check in `runWhenProtectedDataAvailable` failed with nothing left listening
        // and the deferred work — the app's entire UserDefaults-dependent startup — was
        // dropped for the life of the process. Deregistering on the MainActor, only once
        // the action is committed to run, also removes the data race on `token`: this
        // method is @MainActor and non-suspending, so the assignment below always
        // completes before any `Task { @MainActor }` body can start.
        final class TokenHolder: @unchecked Sendable {
            var token: NSObjectProtocol?
            var didRun = false
        }
        let holder = TokenHolder()
        holder.token = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: protectedDataQueue
        ) { _ in
            Task { @MainActor in
                guard UIApplication.shared.isProtectedDataAvailable else {
                    // Re-locked before this hop drained; stay registered for the next unlock.
                    logger.warning("Protected data notification fired but protected data is unavailable — still waiting")
                    return
                }
                // Two notifications can queue two hops before the first drains.
                guard !holder.didRun else { return }
                holder.didRun = true
                if let token = holder.token {
                    NotificationCenter.default.removeObserver(token)
                    holder.token = nil
                }
                runWhenProtectedDataAvailable(action, reason: "unlock")
            }
        }
    }

    @MainActor
    private static func runWhenProtectedDataAvailable(
        _ action: @MainActor @escaping @Sendable () -> Void,
        reason: String
    ) {
        guard UIApplication.shared.isProtectedDataAvailable else {
            logger.warning("Protected data notification fired but protected data is unavailable")
            return
        }

        logger.info("Protected data available (\(reason, privacy: .public))")

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
