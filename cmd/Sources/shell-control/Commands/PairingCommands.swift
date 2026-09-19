import ArgumentParser
import Foundation
import ShellControlManagement

struct PairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pair")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Monitor pending enrollment.") var watch = false
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, watch = watch
        try await execute {
            let manager = try coordinator(state, inherited: inherited)
            let loaded = try await manager.store.load()
            try await PairingOutput.write(manager: manager)
            if watch {
                guard terminal(STDIN_FILENO) else {
                    throw ManagementError.unavailable("enrollment monitoring requires an interactive terminal")
                }
                try await EnrollmentCommands.watch(loaded)
            }
        }
    }
}

/// Prints the origin-signed route-update QR for the current Tailscale route.
/// It changes no trust state (spec.iphone-gateway.md section 25.3).
struct RouteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "route",
        abstract: "Show the signed route update for the current route; trust is unchanged."
    )
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        try await execute {
            let manager = try coordinator(state, inherited: inherited)
            let update = try await manager.routeUpdate()
            let fingerprint = try await manager.originIdentity().identity.fingerprint
            try FileHandle.standardOutput.write(contentsOf: Data(
                try PairingRenderer.routeOutput(update, fingerprint: fingerprint, terminal: terminal(STDOUT_FILENO)).utf8
            ))
        }
    }
}

/// Revokes one iPhone or Watch reviewer. Revoking an iPhone also cuts off
/// every Watch it gateways for until that Watch is re-bound.
struct RevokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Revoke an enrolled device.")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Argument(help: "The device ID from shell-control status.") var deviceID: String
    mutating func validate() throws {
        guard UUID(uuidString: deviceID) != nil else { throw ValidationError("device ID must be a UUID") }
    }
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, id = deviceID.lowercased()
        try await execute {
            let loaded = try InstallationStore(root: try state.root(inherited)).load()
            let admin = ControlAdminClient(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
            _ = try await admin.send(method: "POST", path: "/v1/admin/devices/\(id)/revoke")
            stderr("revoked \(id)")
        }
    }
}

enum PairingOutput {
    /// Pairing is by origin-pinned invitation (spec.iphone-gateway.md 9.1).
    static func write(manager: LifecycleCoordinator) async throws {
        let invitation = try await manager.pairingInvitation()
        let text = try PairingRenderer.invitationOutput(invitation, terminal: terminal(STDOUT_FILENO))
        try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }
}

struct ConfirmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "confirm")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Argument(help: "One enrollment user code.") var userCode: String
    @Flag(name: .customLong("yes"), help: "Approve without a confirmation prompt.") var yes = false
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, code = userCode, yes = yes
        try await execute {
            if !yes && !terminal(STDIN_FILENO) {
                throw ManagementError.invalid("non-interactive confirm requires --yes")
            }
            let loaded = try InstallationStore(root: try state.root(inherited)).load()
            try await EnrollmentCommands.confirm(code, loaded: loaded, prompt: !yes)
        }
    }
}

struct PushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", subcommands: [Configure.self, Disable.self])
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions

    struct Configure: AsyncParsableCommand {
        @ParentCommand var parent: PushCommand
        @OptionGroup var state: StateOptions
        @Option(help: "Stateless Shell Push Relay (the iPhone-gateway profile).") var relayURL: String?
        @Option var keyID: String?
        @Option var teamID: String?
        @Option(help: "Absolute APNs .p8 file.") var keyFile: String?
        @Option(parsing: .upToNextOption, help: "Allowed APNs topics.") var topic = ["dev.chr33s.shell.watchkitapp", "dev.chr33s.shell"]
        mutating func validate() throws {
            let direct = [keyID, teamID, keyFile].compactMap { $0 }
            guard (relayURL != nil) != !direct.isEmpty else {
                throw ValidationError("pass either --relay-url or --key-id, --team-id, and --key-file")
            }
            if !direct.isEmpty {
                guard direct.count == 3 else { throw ValidationError("--key-id, --team-id, and --key-file go together") }
                guard keyFile!.hasPrefix("/") else { throw ValidationError("--key-file must be absolute") }
            }
        }
        mutating func run() async throws {
            let inherited = parent.state.stateDirectory ?? parent.parent.state.stateDirectory
            let state = state, keyID = keyID, teamID = teamID, keyFile = keyFile, topics = topic, relayURL = relayURL
            try await execute {
                let manager = try coordinator(state, inherited: inherited)
                if let relayURL {
                    try await manager.configurePushRelay(url: relayURL)
                    stderr("push relay configured; the Mac holds no APNs credential")
                } else if let keyID, let teamID, let keyFile {
                    try await manager.configurePush(keyID: keyID, teamID: teamID, keyFile: keyFile, topics: topics)
                    stderr("push configured")
                }
            }
        }
    }

    struct Disable: AsyncParsableCommand {
        @ParentCommand var parent: PushCommand
        @OptionGroup var state: StateOptions
        mutating func run() async throws {
            let inherited = parent.state.stateDirectory ?? parent.parent.state.stateDirectory, state = state
            try await execute { try await coordinator(state, inherited: inherited).disablePush(); stderr("push disabled") }
        }
    }
}
