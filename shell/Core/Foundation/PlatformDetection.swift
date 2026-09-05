import Foundation
import os

/// Platform detection utilities for differentiating iOS, visionOS, and Mac Catalyst
enum PlatformDetection {
    /// Returns true if running on Mac Catalyst (iOS app on macOS)
    /// Mac Catalyst apps have access to PTY APIs unlike regular iOS apps
    static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Returns true if running natively on iOS (iPhone/iPad hardware)
    static var isNativeIOS: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Returns true if running on visionOS
    static var isVisionOS: Bool {
        #if os(visionOS)
        return true
        #else
        return false
        #endif
    }

    /// Returns true if the platform supports PTY (pseudo-terminal) for local shells
    /// PTY support is available on Mac Catalyst but not on native iOS or visionOS
    static var supportsPTY: Bool {
        let result = isMacCatalyst
        return result
    }

    /// Returns true if the platform requires external I/O (pipe-based) for local shells
    /// This is true for native iOS and visionOS which don't support PTY
    static var requiresExternalIO: Bool {
        return isNativeIOS || isVisionOS
    }

    #if targetEnvironment(macCatalyst)
    /// Detects if app is running in sandbox at runtime by attempting to write to /tmp
    /// Sandboxed apps cannot access /tmp, non-sandboxed apps can
    /// This is cached since sandbox status cannot change at runtime
    static var isSandboxed: Bool = {
        let testPath = "/tmp/.ghostty-sandbox-test-\(ProcessInfo.processInfo.processIdentifier)"
        let success = FileManager.default.createFile(atPath: testPath, contents: nil, attributes: nil)
        if success {
            try? FileManager.default.removeItem(atPath: testPath)
            Ghostty.logger.info("PlatformDetection.isSandboxed: false (can write to /tmp)")
            return false // Not sandboxed - we could write to /tmp
        }
        Ghostty.logger.info("PlatformDetection.isSandboxed: true (cannot write to /tmp)")
        return true // Sandboxed - cannot write to /tmp
    }()
    #endif
}
