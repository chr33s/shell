import Foundation
import ShellControlHostSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct JobSpec: Sendable, Equatable {
    public var component: Component
    public var installationID: UUID
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var stdoutPath: String
    public var stderrPath: String
    public var keepAlive: Bool
    public var environment: [String: String]
    public var sessionPlistDirectory: String
    public var launchAgentsDirectory: String

    public var label: String { "dev.chr33s.shell.control.\(installationID.uuidString.lowercased()).\(component.rawValue)" }
}

public struct ServiceObservation: Codable, Sendable, Equatable {
    public var label: String
    public var registered: Bool
    public var loaded: Bool
    public var enabled: Bool
    public var pid: Int?
    public var lastExit: Int?
    public var reason: String?
}

public protocol ServiceManager: Sendable {
    func install(_ spec: JobSpec, persistent: Bool, start: Bool) async throws
    func start(_ spec: JobSpec) async throws
    func stop(label: String) async throws
    func restart(_ spec: JobSpec) async throws
    func enable(label: String) async throws
    func disable(label: String) async throws
    func removePersistence(_ spec: JobSpec) async throws
    func observe(label: String) async -> ServiceObservation
}

public actor LaunchdServiceManager: ServiceManager {
    private let uid: uid_t
    private let runner: any ProcessRunning
    public init(uid: uid_t = getuid(), runner: any ProcessRunning = ProcessRunner()) { self.uid = uid; self.runner = runner }
    private var domain: String { "gui/\(uid)" }
    private func target(_ label: String) -> String { "\(domain)/\(label)" }

    public func install(_ spec: JobSpec, persistent: Bool, start shouldStart: Bool) async throws {
        _ = try await checked(["print", domain], context: "graphical launchd domain is unavailable; log in graphically")
        let data = try Self.plist(spec)
        let canonical = URL(fileURLWithPath: spec.sessionPlistDirectory).appendingPathComponent("\(spec.label).plist")
        let changed = try Self.writeIfChanged(data, to: canonical, mode: 0o600)
        if persistent {
            let login = URL(fileURLWithPath: spec.launchAgentsDirectory).appendingPathComponent("\(spec.label).plist")
            _ = try Self.writeIfChanged(data, to: login, mode: 0o600)
        }
        guard shouldStart else { try await disable(label: spec.label); return }
        try await enable(label: spec.label)
        let before = await observe(label: spec.label)
        if before.reason?.hasPrefix("launchctl observation failed:") == true {
            throw ManagementError.unavailable(before.reason!)
        }
        if changed && before.loaded { try await stop(label: spec.label) }
        if !before.loaded || changed {
            _ = try await checked(["bootstrap", domain, canonical.path], context: "bootstrap \(spec.label)")
        }
        let after = await observe(label: spec.label)
        if after.pid == nil {
            _ = try await checked(["kickstart", "-p", target(spec.label)], context: "start \(spec.label)")
        }
    }

    public func start(_ spec: JobSpec) async throws { try await install(spec, persistent: false, start: true) }

    public func stop(label: String) async throws {
        let result = try await runner.run("/bin/launchctl", ["bootout", target(label)], timeout: 15)
        if result.status != 0 {
            let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isKnownAbsent(detail) else {
                throw ManagementError.unavailable("stop \(label): launchctl exited \(result.status): \(detail)")
            }
            return
        }
        let after = await observe(label: label)
        guard !after.loaded, after.pid == nil,
              after.reason?.hasPrefix("launchctl observation failed:") != true else {
            throw ManagementError.unavailable("\(label) absence could not be verified after bootout: \(after.reason ?? "still loaded")")
        }
    }

    public func restart(_ spec: JobSpec) async throws { try await stop(label: spec.label); try await start(spec) }

    public func enable(label: String) async throws {
        _ = try await checked(["enable", target(label)], context: "enable \(label)")
        guard await disabledOverride(label: label) == false else { throw ManagementError.unavailable("launchd did not enable \(label)") }
    }

    public func disable(label: String) async throws {
        _ = try await checked(["disable", target(label)], context: "disable \(label)")
        guard await disabledOverride(label: label) == true else { throw ManagementError.unavailable("launchd did not persistently disable \(label)") }
    }

    public func removePersistence(_ spec: JobSpec) async throws {
        let login = URL(fileURLWithPath: spec.launchAgentsDirectory).appendingPathComponent("\(spec.label).plist")
        if FileManager.default.fileExists(atPath: login.path) {
            try SecureFileSystem.validateOwnedPath(login.path, type: .typeRegular)
            try FileManager.default.removeItem(at: login)
        }
        // Deliberately do not bootout, restart, enable, or disable the current session job.
    }

    public func observe(label: String) async -> ServiceObservation {
        let disabled = await disabledOverride(label: label) ?? false
        do {
            let result = try await runner.run("/bin/launchctl", ["print", target(label)], timeout: 4)
            guard result.status == 0 else {
                let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = Self.isKnownAbsent(detail) ? "not registered" : "launchctl observation failed: \(detail)"
                return ServiceObservation(label: label, registered: false, loaded: false, enabled: !disabled,
                                          pid: nil, lastExit: nil, reason: reason)
            }
            let text = result.stdoutString
            return ServiceObservation(label: label, registered: true, loaded: true, enabled: !disabled,
                                      pid: Self.matchInt(#"(?m)^\s*pid\s*=\s*(\d+)"#, text),
                                      lastExit: Self.matchInt(#"last exit code\s*=\s*(-?\d+)"#, text), reason: nil)
        } catch {
            return ServiceObservation(label: label, registered: false, loaded: false, enabled: !disabled,
                                      pid: nil, lastExit: nil, reason: String(describing: error))
        }
    }

    private func disabledOverride(label: String) async -> Bool? {
        guard let result = try? await runner.run("/bin/launchctl", ["print-disabled", domain], timeout: 4), result.status == 0 else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "\\\"\(escaped)\\\"\\s*=>\\s*(true|false)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: result.stdoutString, range: NSRange(result.stdoutString.startIndex..., in: result.stdoutString)),
              let range = Range(match.range(at: 1), in: result.stdoutString) else { return false }
        return result.stdoutString[range] == "true"
    }

    private func checked(_ arguments: [String], context: String) async throws -> ProcessResult {
        let result = try await runner.run("/bin/launchctl", arguments, timeout: 15)
        guard result.status == 0 else {
            let detail = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagementError.unavailable("\(context): launchctl exited \(result.status): \(detail)")
        }
        return result
    }

    private static func isKnownAbsent(_ text: String) -> Bool {
        text.range(of: #"could not find service|no such process|service .* not found"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func matchInt(_ pattern: String, _ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private struct Plist: Codable {
        var Label: String; var ProgramArguments: [String]; var WorkingDirectory: String
        var StandardInPath: String; var StandardOutPath: String; var StandardErrorPath: String
        var RunAtLoad: Bool; var KeepAlive: Bool; var ThrottleInterval: Int
        var EnvironmentVariables: [String: String]
    }
    private static func plist(_ spec: JobSpec) throws -> Data {
        let value = Plist(Label: spec.label, ProgramArguments: [spec.executable] + spec.arguments,
                          WorkingDirectory: spec.workingDirectory, StandardInPath: "/dev/null",
                          StandardOutPath: spec.stdoutPath, StandardErrorPath: spec.stderrPath,
                          RunAtLoad: true, KeepAlive: spec.keepAlive, ThrottleInterval: 10,
                          EnvironmentVariables: spec.environment)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        return try encoder.encode(value)
    }
    private static func writeIfChanged(_ data: Data, to url: URL, mode: Int) throws -> Bool {
        if let old = try? Data(contentsOf: url), old == data { return false }
        try SecureFileSystem.atomicWrite(data, to: url, permissions: mode)
        return true
    }
}
