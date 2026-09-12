import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellControlHostSupport
import ShellControlManagement
import ShellControlProtocol

enum ShellControlVersion {
    static let current = "1.0.0"
}

struct StateOptions: ParsableArguments {
    @Option(name: .customLong("state-dir"), help: "Absolute native installation state directory.")
    var stateDirectory: String?

    func root(_ inherited: String? = nil) throws -> URL {
        let explicit = stateDirectory ?? inherited
        if let explicit {
            guard explicit.hasPrefix("/") else { throw ManagementError.invalid("--state-dir must be absolute") }
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }
        return try InstallationStore.defaultRoot()
    }
}

extension AddressMode: ExpressibleByArgument {}
extension Component: ExpressibleByArgument {}

func stderr(_ text: String) {
    try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
}

func stdout(_ data: Data) throws {
    var framed = data
    framed.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: framed)
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try stdout(encoder.encode(value))
}

func emitJSON(_ value: JSONValue) throws {
    try stdout(JSONCanonicalization.canonicalize(value))
}

func terminal(_ descriptor: Int32) -> Bool { isatty(descriptor) == 1 }

func execute(_ body: @escaping @Sendable () async throws -> Void) async throws {
    do { try await InvocationCancellation.shared.run(body) }
    catch let error as SignalCancellation { throw ExitCode(error.exitCode) }
    catch let code as ExitCode { throw code }
    catch let error as ManagementError { stderr("shell-control: \(error)"); throw ExitCode(error.exitCode) }
    catch is CancellationError { throw ExitCode(130) }
    catch { stderr("shell-control: \(error)"); throw ExitCode.failure }
}

func coordinator(_ state: StateOptions, inherited: String? = nil) throws -> LifecycleCoordinator {
    LifecycleCoordinator(store: InstallationStore(root: try state.root(inherited)))
}

enum EnrollmentCommands {
    static func watch(_ loaded: LoadedInstallation) async throws {
        let admin = ControlAdminClient(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        var seen = Set<String>()
        stderr("waiting for enrollment; Ctrl+C cancels only this CLI")
        while true {
            try Task.checkCancellation()
            let value = try await admin.send(method: "GET", path: "/v1/admin/pending")
            for item in value["pending"]?.arrayValue ?? [] {
                guard let code = item["user_code"]?.stringValue, seen.insert(code).inserted else { continue }
                try await confirm(code, loaded: loaded, prompt: true)
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    static func confirm(_ code: String, loaded: LoadedInstallation, prompt: Bool) async throws {
        guard !code.isEmpty, code.count <= 16 else { throw ManagementError.invalid("malformed enrollment code") }
        let admin = ControlAdminClient(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        let value = try await admin.send(method: "GET", path: "/v1/oauth/confirm", query: [("user_code", code)])
        guard let fingerprint = value["key_fingerprint"]?.stringValue,
              fingerprint.range(of: #"^[0-9A-F]{4}(-[0-9A-F]{4}){3}$"#, options: .regularExpression) != nil,
              let platform = value["platform"]?.stringValue, ["iOS", "watchOS"].contains(platform),
              let label = value["label"]?.stringValue, !label.isEmpty else {
            throw ManagementError.unavailable("broker returned a malformed enrollment description")
        }
        let cleanLabel = DisplaySanitizer.sanitize(label, maxScalars: 120).text
        let grants = value["requested_grants"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? "none"
        stderr("device: \(cleanLabel) [\(platform)]\nfingerprint: \(fingerprint)\nrequested permissions: \(grants)")
        if prompt {
            guard let answer = try await TerminalPrompt.ask("Approve this one device? [y/N] "),
                  ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                stderr("not approved")
                throw ExitCode(1)
            }
        }
        _ = try await admin.send(method: "POST", path: "/v1/oauth/confirm", body: .object([
            "user_code": .string(code), "approve": .bool(true),
        ]))
        stderr("approved \(code)")
    }
}

enum LogReader {
    static func tail(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        if let data = try handle.read(upToCount: 65_536) { try FileHandle.standardOutput.write(contentsOf: data) }
    }

    static func follow(_ urls: [URL]) async throws {
        var sizes = Dictionary(uniqueKeysWithValues: urls.map { ($0, UInt64(0)) })
        var inodes: [URL: UInt64] = [:]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            sizes[url] = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            inodes[url] = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        while true {
            try Task.checkCancellation()
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let current = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                var size = sizes[url, default: 0]
                if current < size || (inodes[url] != nil && inodes[url] != currentInode) { size = 0 }
                inodes[url] = currentInode
                if current > size {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: size)
                    while size < current {
                        try Task.checkCancellation()
                        let count = Int(min(UInt64(65_536), current - size))
                        guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
                        try FileHandle.standardOutput.write(contentsOf: data)
                        size += UInt64(data.count)
                    }
                    sizes[url] = size
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
