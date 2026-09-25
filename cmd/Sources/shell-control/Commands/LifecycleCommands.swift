import ArgumentParser
import Foundation
import ShellControlHostSupport
import ShellControlManagement

struct UpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        try await execute { _ = try await coordinator(state, inherited: inherited).up(); stderr("started") }
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
    enum Selection: String, ExpressibleByArgument { case broker, daemon, all }
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
    @Flag(help: "Print a short human-readable summary instead of JSON.") var text = false
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, check = check, text = text
        try await execute {
            let manager = try coordinator(state, inherited: inherited)
            let status = await manager.status()
            if text {
                try FileHandle.standardOutput.write(contentsOf: Data(StatusText.render(status).utf8))
            } else {
                try emit(status)
            }
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
            let urls = names.flatMap { name in
                ["out", "err"].map { store.paths.logs.appendingPathComponent("\(name.rawValue).\($0).log") }
            }
            for url in urls { try LogReader.tail(url) }
            if following { try await LogReader.follow(urls) }
        }
    }
}

/// The summary of docs/specs/control-protocol.md section 16.
enum StatusText {
    static func render(_ status: ManagementStatus) -> String {
        func state(_ name: String) -> String { status.components[name]?.state ?? "n/a" }
        var rows: [(String, String)] = []
        if let tailscale = status.components["tailscale"] { rows.append(("tailscale", tailscale.state)) }
        if status.components["serve"] != nil {
            rows.append(("serve", state("serve") == "active" ? (status.publicURL ?? "active") : state("serve")))
        } else if let url = status.publicURL {
            rows.append(("route", url))
        }
        rows.append(("broker", state("broker") == "ready" ? "ready (loopback)" : state("broker")))
        rows.append(("daemon", state("daemon")))
        rows.append(("origin", status.origin.map { "\($0.originID) \($0.fingerprint)" } ?? "not provisioned"))
        if let enrollment = status.enrollment {
            rows.append(("iphone", enrollment.iphones.isEmpty ? "not enrolled" : "enrolled (\(enrollment.iphones.count))"))
            rows.append(("watch", enrollment.watches.isEmpty ? "not enrolled" : "enrolled via iPhone (\(enrollment.watches.count))"))
        }
        rows.append(("push", state("push") == "configured" ? "configured" : "disabled"))
        if let enrollment = status.enrollment { rows.append(("pending", String(enrollment.pendingApprovals))) }
        rows.append(("overall", status.overall))
        return rows.map { $0.0.padding(toLength: 14, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n") + "\n"
    }
}
