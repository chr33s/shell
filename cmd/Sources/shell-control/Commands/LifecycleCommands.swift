import ArgumentParser
import Foundation
import ShellControlHostSupport
import ShellControlManagement

struct UpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Explicitly replace a dead quick-tunnel URL.") var rotateURL = false
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, rotateURL = rotateURL
        try await execute { _ = try await coordinator(state, inherited: inherited).up(rotateURL: rotateURL); stderr("started") }
    }
}

struct DownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        try await execute { try await coordinator(state, inherited: inherited).down(); stderr("stopped and persistently disabled") }
    }
}

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart")
    enum Selection: String, ExpressibleByArgument { case broker, daemon, tunnel, all }
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Argument var selection: Selection
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        let chosen = selection == .all ? Component.allCases : [Component(rawValue: selection.rawValue)!]
        try await execute { try await coordinator(state, inherited: inherited).restart(chosen); stderr("restarted") }
    }
}

struct ServiceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "service", subcommands: [Install.self, Uninstall.self])
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions

    struct Install: AsyncParsableCommand {
        @ParentCommand var parent: ServiceCommand
        @OptionGroup var state: StateOptions
        mutating func run() async throws {
            let inherited = parent.state.stateDirectory ?? parent.parent.state.stateDirectory, state = state
            try await execute { try await coordinator(state, inherited: inherited).installPersistence(); stderr("login persistence installed") }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        @ParentCommand var parent: ServiceCommand
        @OptionGroup var state: StateOptions
        mutating func run() async throws {
            let inherited = parent.state.stateDirectory ?? parent.parent.state.stateDirectory, state = state
            try await execute {
                try await coordinator(state, inherited: inherited).uninstallPersistence()
                stderr("login persistence removed; current jobs were not interrupted")
            }
        }
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Fail unless the configured control path is ready.") var check = false
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, check = check
        try await execute {
            let manager = try coordinator(state, inherited: inherited)
            let status = await manager.status()
            try emit(status)
            if check && !manager.isReady(status) { throw ManagementError.unavailable("control path is not ready") }
        }
    }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Argument var component: Component?
    @Flag var follow = false
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        let names = component.map { [$0] } ?? Component.allCases
        let following = follow
        try await execute {
            let store = InstallationStore(root: try state.root(inherited))
            _ = try store.load()
            let urls = names.flatMap { name -> [URL] in
                if name == .tunnel { return [store.paths.logs.appendingPathComponent("tunnel.transport.log")] }
                return ["out", "err"].map { store.paths.logs.appendingPathComponent("\(name.rawValue).\($0).log") }
            }
            for url in urls { try LogReader.tail(url) }
            if following { try await LogReader.follow(urls) }
        }
    }
}
