import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellControlManagement

@main
struct ShellControlCommand: AsyncParsableCommand {
    @OptionGroup var state: StateOptions
    static let configuration = CommandConfiguration(
        commandName: "shell-control",
        abstract: "Manage the Shell control companion.",
        version: ShellControlVersion.current,
        subcommands: [
            SetupCommand.self, UpCommand.self, DownCommand.self, RestartCommand.self,
            ServiceCommand.self, StatusCommand.self, LogsCommand.self, PairCommand.self,
            ConfirmCommand.self, PushCommand.self, NotifyCommand.self, RequestCommand.self, ReceiptCommand.self
        ]
    )
    mutating func run() async throws { print(Self.helpMessage()) }

    static func main() async {
        #if canImport(Darwin)
        _ = Darwin.signal(SIGPIPE, SIG_IGN) // surface EPIPE as a write error instead of truncated signal-success ambiguity
        #endif
        do {
            var command = try await asyncParseAsRoot()
            if var asyncCommand = command as? any AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
        } catch let error as ManagementError {
            let code = error.exitCode
            do { try FileHandle.standardError.write(contentsOf: Data("shell-control: \(error)\n".utf8)) } catch { Foundation.exit(code == 0 ? 1 : code) }
            Foundation.exit(code)
        } catch {
            let parserCode = exitCode(for: error).rawValue
            let code: Int32 = parserCode == ExitCode.validationFailure.rawValue ? 2 : parserCode
            let message = fullMessage(for: error)
            if !message.isEmpty {
                let handle = code == 0 ? FileHandle.standardOutput : FileHandle.standardError
                do {
                    try handle.write(contentsOf: Data((message + "\n").utf8))
                } catch {
                    Foundation.exit(code == 0 ? 1 : code)
                }
            }
            Foundation.exit(code)
        }
    }
}
