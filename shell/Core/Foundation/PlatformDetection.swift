import Foundation

/// Platform detection utilities for differentiating Mac Catalyst from other platforms
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
}
