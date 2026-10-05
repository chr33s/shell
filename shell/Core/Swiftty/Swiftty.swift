//
//  Swiftty.swift
//  shell
//
//  Base namespace for all Swiftty types
//

import Foundation
import OSLog
import SwifttyKit

/// Main namespace for all Swiftty types and functionality
enum Swiftty {
    /// Logger for Swiftty
    nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "swiftty")

    /// Track whether swiftty has been initialized
    private static var _initialized = false

    /// Initialize the Swiftty library. Must be called before creating any configs or apps.
    static func initialize() {
        guard !_initialized else { return }

        // Set SWIFTTY_RESOURCES_DIR to the app bundle's Resources directory
        // so Swiftty can find theme files
        // On Mac Catalyst: Bundle.main.resourceURL points to Contents/Resources
        // On iOS/visionOS: Bundle.main.resourceURL points to the app bundle root
        // Swiftty will look for themes at: $SWIFTTY_RESOURCES_DIR/themes/
        guard let resourceURL = Bundle.main.resourceURL else {
            logger.error("Failed to get bundle resource URL")
            return
        }

        let resourcePath = resourceURL.path
        let themesPath = (resourcePath as NSString).appendingPathComponent("themes")

        // Verify themes directory exists. Deliberately no directory enumeration
        // here — ThemeManager already walks these files, off the main thread.
        if !FileManager.default.fileExists(atPath: themesPath) {
            logger.error("Themes directory not found at: \(themesPath)")
        }

        setenv("SWIFTTY_RESOURCES_DIR", resourcePath, 1)
        logger.info("Set SWIFTTY_RESOURCES_DIR to: \(resourcePath)")

        // Set XDG_CONFIG_HOME to Application Support directory
        // so Swiftty can find config files on iOS (which has no traditional home directory)
        // Swiftty will look for config at: XDG_CONFIG_HOME/swiftty/config
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            setenv("XDG_CONFIG_HOME", appSupport.path, 1)
            logger.info("Set XDG_CONFIG_HOME to: \(appSupport.path)")
        }

        // Mac Catalyst with the native PTY: set up environment variables for the
        // spawned shell before SwifttyKit starts. Wherever the interpreter is
        // the backend (iOS, visionOS, sandboxed Catalyst) ios_system owns these
        // variables: initializeEnvironment() has already run and LocalShellSession
        // sets the rest per session via ios_setenv().
        #if targetEnvironment(macCatalyst)
        if LocalShellBackend.current == .nativePTY {
            setupCatalystEnvironment()
        }
        #endif

        _initialized = true
    }

    #if targetEnvironment(macCatalyst)
    /// Set up environment variables for Mac Catalyst PTY-based shells
    private static func setupCatalystEnvironment() {
        logger.info("Setting up Mac Catalyst environment for PTY shells...")

        // Set HOME to the real macOS home directory
        // Note: On Catalyst, NSHomeDirectory() returns the real macOS home (e.g., /Users/example)
        // not the sandboxed Documents directory like on iOS
        let homeDir = NSHomeDirectory()
        setenv("HOME", homeDir, 1)
        logger.info("   Set HOME=\(homeDir)")

        // Set USER to current username
        let username = NSUserName()
        setenv("USER", username, 1)
        logger.info("   Set USER=\(username)")

        // Set SHELL from environment or default to the user's shell from passwd
        // First check if SHELL is already set, otherwise use default
        if let shellEnv = getenv("SHELL"), let shellPath = String(validatingUTF8: shellEnv) {
            logger.info("   SHELL already set: \(shellPath)")
        } else {
            // Try to get shell from passwd, otherwise default to zsh
            let shell = "/bin/zsh"  // Modern macOS default
            setenv("SHELL", shell, 1)
            logger.info("   Set SHELL=\(shell)")
        }

        // Set TERM for proper terminal capabilities, plus TERMINFO so the
        // bundled xterm-swiftty entry resolves. ncurses checks TERMINFO first
        // and then falls through to the system database, so pointing at a
        // directory holding only xterm-swiftty leaves other names working.
        let termType = TerminalTypeSettings.local
        setenv("TERM", termType, 1)
        logger.info("   Set TERM=\(termType)")

        if let terminfoPath = TerminalTypeSettings.terminfoPath {
            setenv("TERMINFO", terminfoPath, 1)
            logger.info("   Set TERMINFO=\(terminfoPath)")
        }

        // Set terminal identification for apps that check capabilities
        // Apps like Claude Code use TERM_PROGRAM to detect notification support
        setenv("TERM_PROGRAM", "swiftty", 1)
        setenv("TERM_PROGRAM_VERSION", TerminalIdentity.shortVersion, 1)
        setenv("COLORTERM", "truecolor", 1)
        logger.info("   Set TERM_PROGRAM=swiftty, COLORTERM=truecolor")

        // Product identity, matching what the local shell and remote sessions advertise
        for envVar in TerminalIdentity.forwardedVariables {
            setenv(envVar.name, envVar.value, 1)
        }

        // Set locale for UTF-8 support
        setenv("LANG", "en_US.UTF-8", 1)
        logger.info("   Set LANG=en_US.UTF-8")

        // Set PATH - preserve existing PATH if present, otherwise use defaults
        if let pathEnv = getenv("PATH"), let pathValue = String(validatingUTF8: pathEnv) {
            logger.info("   PATH already set: \(pathValue)")
        } else {
            let paths = [
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                "/opt/homebrew/bin"  // Add Homebrew for Apple Silicon Macs
            ]
            setenv("PATH", paths.joined(separator: ":"), 1)
            logger.info("   Set PATH=\(paths.joined(separator: ":"))")
        }

        logger.info("Mac Catalyst environment setup complete")
    }
    #endif
}

/// Shell escaping utilities (matches macOS Swiftty.Shell)
extension Swiftty {
    // nonisolated: pure string helpers, also called from off-main clipboard transforms.
    nonisolated struct Shell {
        /// Characters that need escaping in shell commands
        static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Escape shell-sensitive characters in a string.
        /// Used when dropping files/URLs into the terminal to ensure paths with
        /// spaces and special characters work correctly.
        static func escape(_ str: String) -> String {
            var result = str
            for char in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(char),
                    with: "\\\(char)"
                )
            }
            return result
        }
    }
}

/// Swiftty actions and related types
extension Swiftty {
    enum Action {
        /// Scrollbar state from the terminal
        struct Scrollbar {
            let total: UInt64   // Total rows (scrollback + active area)
            let offset: UInt64  // First visible row (0 = top of history)
            let len: UInt64     // Number of visible rows (viewport height)
        }
    }
}

#if os(iOS)
typealias OSSize = CGSize
#elseif os(macOS)
typealias OSSize = NSSize
#endif
