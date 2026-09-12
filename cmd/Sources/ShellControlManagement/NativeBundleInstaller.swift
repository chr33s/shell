import Foundation
import CryptoKit
import ShellControlHostSupport

public struct ReleaseManifest: Codable, Sendable {
    public var releaseID: String
    public var architecture: String
    public var minimumOS: String
    public var toolchain: String
    public var executables: [String: String]
    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id", architecture, minimumOS = "minimum_os", toolchain, executables
    }
}

public struct InstalledBinaries: Sendable {
    public let directory: URL
    public var cli: URL { directory.appendingPathComponent("shell-control") }
    public var daemon: URL { directory.appendingPathComponent("shell-controld") }
    public var broker: URL { directory.appendingPathComponent("shell-control-broker") }
}

public struct NativeBundleInstaller: Sendable {
    public let sourceDirectory: URL
    public let libraryRoot: URL
    public let executableLink: URL

    public init(executablePath: String = CommandLine.arguments[0], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        sourceDirectory = executable.deletingLastPathComponent()
        libraryRoot = home.appendingPathComponent(".local/lib/chr33s-shell")
        executableLink = home.appendingPathComponent(".local/bin/shell-control")
    }

    public func validateBundle() throws -> ReleaseManifest {
        let manifestURL = sourceDirectory.appendingPathComponent("release-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ManagementError.unsupported("release-manifest.json is missing beside shell-control; setup requires a prebuilt native release bundle")
        }
        try SecureFileSystem.validateOwnedPath(manifestURL.path, type: .typeRegular)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: manifestURL))
        let required = ["shell-control", "shell-controld", "shell-control-broker"]
        guard Set(manifest.executables.keys) == Set(required), !manifest.releaseID.isEmpty else {
            throw ManagementError.corrupt("release manifest must hash all three Shell executables")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        guard manifest.architecture == architecture else {
            throw ManagementError.unsupported("release architecture \(manifest.architecture) does not match \(architecture)")
        }
        for name in required {
            let file = sourceDirectory.appendingPathComponent(name)
            try SecureFileSystem.validateOwnedPath(file.path, type: .typeRegular)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.executables[name]?.lowercased() else {
                throw ManagementError.corrupt("release bundle checksum failed for \(name)")
            }
        }
        return manifest
    }

    public func install(_ manifest: ReleaseManifest) throws -> InstalledBinaries {
        let destination = libraryRoot.appendingPathComponent(manifest.releaseID)
        if FileManager.default.fileExists(atPath: destination.path) {
            try SecureFileSystem.validateOwnedPath(destination.path, type: .typeDirectory)
            return try validateInstalled(manifest, at: destination)
        }
        try SecureFileSystem.ensureDirectory(libraryRoot, permissions: 0o755)
        let stage = libraryRoot.appendingPathComponent(".\(manifest.releaseID).stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        do {
            for name in manifest.executables.keys {
                let target = stage.appendingPathComponent(name)
                try FileManager.default.copyItem(at: sourceDirectory.appendingPathComponent(name), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
            let installedManifest = stage.appendingPathComponent("release-manifest.json")
            try FileManager.default.copyItem(at: sourceDirectory.appendingPathComponent("release-manifest.json"),
                                             to: installedManifest)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedManifest.path)
            guard rename(stage.path, destination.path) == 0 else {
                throw ManagementError.unavailable("cannot publish native release bundle")
            }
            do {
                try publishLink(to: destination.appendingPathComponent("shell-control"))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return InstalledBinaries(directory: destination)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    private func validateInstalled(_ manifest: ReleaseManifest, at directory: URL) throws -> InstalledBinaries {
        for (name, expected) in manifest.executables {
            let file = directory.appendingPathComponent(name)
            try SecureFileSystem.validateOwnedPath(file.path, type: .typeRegular)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw ManagementError.corrupt("installed release is incomplete or tampered: \(name)") }
        }
        try publishLink(to: directory.appendingPathComponent("shell-control"))
        return InstalledBinaries(directory: directory)
    }

    private func publishLink(to target: URL) throws {
        try SecureFileSystem.ensureDirectory(executableLink.deletingLastPathComponent(), permissions: 0o755)
        let fm = FileManager.default
        let present = fm.fileExists(atPath: executableLink.path)
            || (try? executableLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if present {
            let values = try executableLink.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else {
                throw ManagementError.unavailable("refusing to replace unrelated \(executableLink.path)")
            }
            let destination = try fm.destinationOfSymbolicLink(atPath: executableLink.path)
            let current = URL(fileURLWithPath: destination, relativeTo: executableLink.deletingLastPathComponent())
                .absoluteURL.standardizedFileURL
            if current.path == target.path { return }
            let library = libraryRoot.standardizedFileURL.path
            guard current.path == library || current.path.hasPrefix(library + "/") else {
                throw ManagementError.unavailable("refusing to replace unrelated \(executableLink.path)")
            }
        }
        let temporary = executableLink.deletingLastPathComponent().appendingPathComponent(".shell-control-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: target.path)
        guard rename(temporary.path, executableLink.path) == 0 else {
            try? fm.removeItem(at: temporary)
            throw ManagementError.unavailable("cannot publish \(executableLink.path)")
        }
    }
}
