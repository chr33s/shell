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
            let loaded = try InstallationStore(root: try state.root(inherited)).load()
            let url = loaded.installation.publicURL ?? ControlLoopback.url(port: loaded.installation.port)
            try FileHandle.standardOutput.write(contentsOf: Data(
                try PairingRenderer.output(publicURL: url, token: loaded.secrets.pairingToken, terminal: terminal(STDOUT_FILENO)).utf8
            ))
            if watch {
                guard terminal(STDIN_FILENO) else {
                    throw ManagementError.unavailable("enrollment monitoring requires an interactive terminal")
                }
                try await EnrollmentCommands.watch(loaded)
            }
        }
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
        @Option var keyID: String
        @Option var teamID: String
        @Option(help: "Absolute APNs .p8 file.") var keyFile: String
        @Option(parsing: .upToNextOption, help: "Allowed APNs topics.") var topic = ["dev.chr33s.shell.watchkitapp", "dev.chr33s.shell"]
        mutating func validate() throws { guard keyFile.hasPrefix("/") else { throw ValidationError("--key-file must be absolute") } }
        mutating func run() async throws {
            let inherited = parent.state.stateDirectory ?? parent.parent.state.stateDirectory
            let state = state, keyID = keyID, teamID = teamID, keyFile = keyFile, topics = topic
            try await execute {
                try await coordinator(state, inherited: inherited).configurePush(keyID: keyID, teamID: teamID, keyFile: keyFile, topics: topics)
                stderr("push configured")
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
