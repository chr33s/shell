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
        final class TokenHolder: @unchecked Sendable {
            var token: NSObjectProtocol?
        }
        let holder = TokenHolder()
        holder.token = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: protectedDataQueue
        ) { _ in
            if let token = holder.token { NotificationCenter.default.removeObserver(token) }
            Task { @MainActor in
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

        logger.info("Protected data available")

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
