import ArgumentParser
import Foundation
import ShellControlManagement

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Create or reconcile a native installation.")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Do not monitor device enrollment.") var noWatch = false
    @Option(help: "quick, named, external-proxy, or loopback.") var tunnelMode: AddressMode?
    @Option(help: "Public HTTPS origin (HTTP only for loopback).") var publicURL: String?
    @Option(help: "Broker port (default: 8443 for a fresh installation).") var port: Int?
    @Option(help: "Named Cloudflare tunnel UUID.") var tunnelID: String?
    @Option(help: "Absolute named-tunnel credentials file.") var tunnelCredentials: String?
    @Option(help: "Absolute cloudflared executable path.") var cloudflaredPath: String?
    @Flag(help: "Explicitly replace a quick-tunnel URL.") var rotateURL = false

    mutating func validate() throws {
        if let port, !(1...65535).contains(port) { throw ValidationError("--port must be between 1 and 65535") }
        for path in [tunnelCredentials, cloudflaredPath].compactMap({ $0 }) where !path.hasPrefix("/") {
            throw ValidationError("file options must be absolute")
        }
        if let tunnelID, UUID(uuidString: tunnelID) == nil { throw ValidationError("--tunnel-id must be a UUID") }
    }

    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, noWatch = noWatch
        let options = SetupOptions(
            mode: tunnelMode, publicURL: publicURL, port: port,
            tunnelID: tunnelID.flatMap(UUID.init(uuidString:)),
            tunnelCredentials: tunnelCredentials, cloudflaredPath: cloudflaredPath, rotateURL: rotateURL
        )
        try await execute {
            let loaded = try await coordinator(state, inherited: inherited).setup(options)
            let url = loaded.installation.publicURL ?? ControlLoopback.url(port: loaded.installation.port)
            let text = try PairingRenderer.output(publicURL: url, token: loaded.secrets.pairingToken, terminal: terminal(STDOUT_FILENO))
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
            if loaded.installation.addressMode == .loopback {
                stderr("loopback readiness is local only; physical devices cannot reach this origin")
            }
            if !noWatch && terminal(STDIN_FILENO) { try await EnrollmentCommands.watch(loaded) } else if !noWatch { stderr("non-interactive setup does not monitor or approve enrollment") }
        }
    }
}
