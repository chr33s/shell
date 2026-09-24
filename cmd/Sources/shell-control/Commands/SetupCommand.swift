import ArgumentParser
import Foundation
import ShellControlClient
import ShellControlManagement
import ShellControlProtocol
import ShellControlSecurity

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create or reconcile a native installation.",
        discussion: """
        --guided walks through Control companion setup: preflight, services, iPhone pairing, a safe \
        review test, then the optional Apple Watch and remote-alert steps. It needs an interactive terminal.

        --skip-watch-setup (with --guided) skips only the optional Apple Watch step. It is unrelated to \
        --no-watch, which keeps its meaning: do not monitor device enrollment after a non-guided setup.
        """
    )
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Do not monitor device enrollment (non-guided setup). Not the same as --skip-watch-setup.") var noWatch = false
    @Option(name: .customLong("mode"), help: "tailscale (default), or loopback for local development.") var mode: AddressMode?
    @Option(help: "Broker port (default: 8443 for a fresh installation).") var port: Int?
    @Option(help: "Absolute Tailscale CLI path.") var tailscalePath: String?
    @Flag(help: "Replace the origin signing key. Every iPhone and Watch must pair again.") var resetOriginKey = false
    @Flag(help: "Guided Control companion setup in an interactive terminal.") var guided = false
    @Flag(help: "With --guided: skip the optional Apple Watch step. iPhone pairing is never skipped.") var skipWatchSetup = false

    mutating func validate() throws {
        if let port, !(1...65535).contains(port) { throw ValidationError("--port must be between 1 and 65535") }
        if let tailscalePath, !tailscalePath.hasPrefix("/") { throw ValidationError("--tailscale-path must be absolute") }
        if skipWatchSetup && !guided { throw ValidationError("--skip-watch-setup applies only to --guided") }
        if guided && noWatch {
            throw ValidationError("--no-watch disables enrollment monitoring in non-guided setup; with --guided use --skip-watch-setup to skip the Apple Watch step")
        }
        if guided && resetOriginKey {
            throw ValidationError("--reset-origin-key is a separate recovery step; run it without --guided")
        }
    }

    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, noWatch = noWatch
        let options = SetupOptions(
            mode: mode, port: port, tailscalePath: tailscalePath, resetOriginKey: resetOriginKey
        )
        if guided {
            // Refuse before any mutation: the guide asks questions only a
            // person at a terminal can answer.
            guard terminal(STDIN_FILENO), terminal(STDERR_FILENO) else {
                stderr("shell-control: setup --guided needs an interactive terminal. Use the explicit commands instead: shell-control setup --no-watch, shell-control pair, shell-control confirm <CODE> --yes, shell-control test-review, and shell-control doctor.")
                throw ExitCode(2)
            }
            let skipWatch = skipWatchSetup
            try await execute {
                let manager = try coordinator(state, inherited: inherited)
                try await GuidedSetupCommand.run(manager: manager, options: GuidedSetupOptions(setup: options, skipWatchSetup: skipWatch))
            }
            return
        }
        try await execute {
            let manager = try coordinator(state, inherited: inherited)
            let loaded = try await manager.setup(options)
            try await PairingOutput.write(manager: manager)
            if loaded.installation.addressMode == .loopback {
                stderr("loopback readiness is local only; physical devices cannot reach this origin")
            }
            if !noWatch && terminal(STDIN_FILENO) { try await EnrollmentCommands.watch(loaded) } else if !noWatch { stderr("non-interactive setup does not monitor or approve enrollment") }
        }
    }
}

enum GuidedSetupCommand {
    static func run(manager: LifecycleCoordinator, options: GuidedSetupOptions) async throws {
        let store = manager.store
        let guide = GuidedSetupCoordinator(
            lifecycle: manager,
            presenter: TerminalGuidedPresenter(),
            reviewTest: { reviewer, device in
                let test = SetupReviewTest(adapter: AdapterClient(stateDirectory: store.paths.root))
                return try await test.run(reviewer: reviewer, deviceID: device.deviceID) { stderr($0) }
            }
        )
        do {
            let summary = try await guide.run(options)
            if !summary.primaryComplete { throw ExitCode(1) }
        } catch let stopped as GuidedSetupStopped {
            // Stopped before completion is not success for a caller script.
            stderr(stopped.description)
            throw ExitCode(1)
        } catch {
            if error is CancellationError || error is SignalCancellation {
                await reportLeftRunning(manager)
            }
            throw error
        }
    }

    /// Cancellation stops the guide only: pairings, keys, and services stay.
    /// Say what is still running (spec.control-companion-setup.md 7.4).
    private static func reportLeftRunning(_ manager: LifecycleCoordinator) async {
        let status = await Task.detached { await manager.status() }.value
        stderr("\nGuide cancelled. Nothing already set up was undone.")
        if manager.store.exists() {
            stderr("Control services: \(status.overall) (desired \(status.desiredState)). Stop them with shell-control down; resume with shell-control setup --guided.")
        }
    }
}

/// Renders the guide on the terminal: prose and prompts on stderr, the
/// pairing QR on stdout.
struct TerminalGuidedPresenter: GuidedSetupPresenter {
    func heading(_ text: String) async { stderr("\n== \(text) ==") }

    func say(_ text: String) async { stderr(text) }

    func show(_ checks: [DiagnosticCheck]) async {
        for check in checks {
            let mark = switch check.state {
            case .pass: "✓"
            case .fail: "✗"
            case .unknown: "?"
            case .warn: "!"
            case .notConfigured, .disabled: "–"
            }
            stderr("  \(mark) \(check.summary)")
            if check.state != .pass, let command = check.action?.macCommand { stderr("      → \(command)") }
        }
    }

    func showPairing(_ invitation: PairingInvitation) async throws {
        let text = try PairingRenderer.invitationOutput(invitation, terminal: terminal(STDOUT_FILENO))
        try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }

    func choose(_ question: String, _ choices: [GuidedChoice]) async throws -> String {
        guard let first = choices.first else { return "" }
        let legend = choices.enumerated().map { index, choice in
            index == 0 ? "\(choice.key.uppercased())=\(choice.title)" : "\(choice.key)=\(choice.title)"
        }.joined(separator: ", ")
        while true {
            guard let answer = try await TerminalPrompt.ask("\(question) [\(legend)] ") else { return first.key }
            let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty { return first.key }
            if let match = choices.first(where: { $0.key == normalized || $0.title.lowercased() == normalized
                || ($0.key == "y" && normalized == "yes") || ($0.key == "n" && normalized == "no") }) {
                return match.key
            }
        }
    }
}
