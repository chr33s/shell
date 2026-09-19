import ArgumentParser
import Foundation
import ShellControlManagement

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Create or reconcile a native installation.")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Do not monitor device enrollment.") var noWatch = false
    @Option(name: .customLong("mode"), help: "tailscale (default), or loopback for local development.") var mode: AddressMode?
    @Option(help: "Broker port (default: 8443 for a fresh installation).") var port: Int?
    @Option(help: "Absolute Tailscale CLI path.") var tailscalePath: String?
    @Flag(help: "Replace the origin signing key. Every iPhone and Watch must pair again.") var resetOriginKey = false

    mutating func validate() throws {
        if let port, !(1...65535).contains(port) { throw ValidationError("--port must be between 1 and 65535") }
        if let tailscalePath, !tailscalePath.hasPrefix("/") { throw ValidationError("--tailscale-path must be absolute") }
    }

    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, noWatch = noWatch
        let options = SetupOptions(
            mode: mode, port: port, tailscalePath: tailscalePath, resetOriginKey: resetOriginKey
        )
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
