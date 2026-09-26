import Foundation
import Testing
import CryptoKit
@testable import ShellControlManagement
import ShellControlHostSupport

actor FailingLaunchctlRunner: ProcessRunning {
    enum Mode: Sendable { case disable, bootstrap }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessResult {
        if mode == .disable && arguments.first == "disable" { return .init(status: 1, stdout: Data(), stderr: Data("denied".utf8)) }
        if arguments.first == "bootstrap" { return .init(status: 1, stdout: Data(), stderr: Data("5: Input/output error".utf8)) }
        if arguments.first == "print-disabled" { return .init(status: 0, stdout: Data("{ \"test\" => false }".utf8), stderr: Data()) }
        if arguments.first == "print", arguments.count == 2 { return .init(status: 1, stdout: Data(), stderr: Data("Could not find service".utf8)) }
        return .init(status: 0, stdout: Data(), stderr: Data())
    }
}

actor FakeServices: ServiceManager {
    var observations: [String: ServiceObservation] = [:]
    var calls: [String] = []
    var specs: [String: JobSpec] = [:]

    private func running(_ spec: JobSpec, enabled: Bool = true) -> ServiceObservation {
        .init(label: spec.label, registered: true, loaded: true, enabled: enabled, pid: 4242, lastExit: nil)
    }

    func install(_ spec: JobSpec, persistent: Bool, start: Bool) {
        calls.append("install:\(spec.component.rawValue)")
        specs[spec.label] = spec
        observations[spec.label] = start
            ? running(spec)
            : .init(label: spec.label, registered: true, loaded: false, enabled: false, pid: nil, lastExit: nil)
    }
    func start(_ spec: JobSpec) {
        calls.append("start:\(spec.component.rawValue)")
        specs[spec.label] = spec
        observations[spec.label] = running(spec)
    }
    func stop(label: String) {
        calls.append("stop:\(label)")
        let previous = observations[label]
        observations[label] = .init(label: label, registered: previous?.registered ?? false, loaded: false,
                                    enabled: previous?.enabled ?? true, pid: nil, lastExit: 0)
    }
    func restart(_ spec: JobSpec) {
        calls.append("restart:\(spec.component.rawValue)")
        specs[spec.label] = spec
        observations[spec.label] = running(spec)
    }
    func enable(label: String) { calls.append("enable:\(label)") }
    func disable(label: String) {
        calls.append("disable:\(label)")
        let previous = observations[label]
        observations[label] = .init(label: label, registered: previous?.registered ?? false, loaded: previous?.loaded ?? false,
                                    enabled: false, pid: previous?.pid, lastExit: nil)
    }
    func removePersistence(_ spec: JobSpec) { calls.append("unpersist:\(spec.component.rawValue)") }
    func observe(label: String) -> ServiceObservation {
        observations[label] ?? .init(label: label, registered: false, loaded: false, enabled: false, pid: nil, lastExit: nil)
    }
}

@Suite
final class ManagementTests {
    private func directory() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-native-tests-\(UUID())") }

    @Test
    func testNativeStoreCreatesOnceAndRejectsMissingSecrets() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallationStore(root: root)
        let lock = try store.lock(); defer { lock.release() }
        let first = try store.create(releaseID: "release", mode: .loopback, publicURL: "http://127.0.0.1:8443", port: 8443)
        let loaded = try store.load()
        #expect(first.installation.installationID == loaded.installation.installationID)
        #expect(first.secrets == loaded.secrets)
        try FileManager.default.removeItem(at: store.paths.secrets)
        #expect(throws: (any Error).self){ try store.load() }
    }

    @Test
    func testUnrecognizedStateIsNotImportedOrDeleted() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("broker.json")
        try Data("legacy".utf8).write(to: legacy)
        let store = InstallationStore(root: root), lock = try store.lock(); defer { lock.release() }
        #expect(throws: (any Error).self){ try store.create(releaseID: "r", mode: .loopback, publicURL: nil, port: 8443) }
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test
    func testPublicOriginValidation() throws {
        #expect((try AddressPolicy.validate("https://MAC.example.ts.net/", mode: .tailscale)) == "https://mac.example.ts.net")
        #expect(throws: (any Error).self){ try AddressPolicy.validate("https://user@mac.example.ts.net/path?q=x", mode: .tailscale) }
        #expect(throws: (any Error).self){ try AddressPolicy.validate("http://example.com", mode: .loopback) }
        #expect(throws: (any Error).self){ try AddressPolicy.validate("https://stable.example", mode: .tailscale) }
        #expect((try AddressPolicy.validate("http://LocalHost:8443", mode: .loopback)) == "http://localhost:8443")
        #expect((try AddressPolicy.validate("http://[::1]:8443", mode: .loopback)) == "http://[::1]:8443")
    }

    @Test
    func testDownCommitsIntentAndDisablesEveryOwnedJob() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallationStore(root: root), lock = try store.lock()
        _ = try store.create(releaseID: "r", mode: .loopback, publicURL: "http://127.0.0.1:8443", port: 8443); lock.release()
        let services = FakeServices()
        let coordinator = LifecycleCoordinator(store: store, manager: services)
        try await coordinator.down()
        #expect((try store.load().installation.desiredState) == .stopped)
        let calls = await services.calls
        #expect(calls.filter { $0.hasPrefix("disable:") }.count == 2)
        #expect(calls.filter { $0.hasPrefix("stop:") }.count == 2)
    }

    @Test
    func testStatusOnMissingInstallationDoesNotCreateDirectory() async throws {
        let root = directory(); let coordinator = LifecycleCoordinator(store: InstallationStore(root: root))
        let status = await coordinator.status()
        #expect(status.schema == "shell-control.status/1")
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testProcessRunnerDrainsConcurrentOutputAndStopsOnItsBound() async throws {
        let runner = ProcessRunner(outputLimit: 65_536)
        let result = try await runner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 500 ]; do echo out-$i; echo err-$i >&2; i=$((i+1)); done"], timeout: 5)
        #expect(result.status == 0)
        #expect(result.stdoutString.contains("out-499"))
        #expect(result.stderrString.contains("err-499"))

        let bounded = ProcessRunner(outputLimit: 1024)
        let clock = ContinuousClock(), start = clock.now
        do { _ = try await bounded.run("/usr/bin/yes", [], timeout: 10); Issue.record("unbounded output should fail") } catch ProcessRunnerError.outputTooLarge {} catch { Issue.record("unexpected process error: \(error)") }
        #expect(start.duration(to: clock.now) < .seconds(3))
    }

    @Test
    func testLaunchctlStateChangingFailuresAreNeverIgnored() async throws {
        let disableManager = LaunchdServiceManager(uid: getuid(), runner: FailingLaunchctlRunner(.disable))
        do { try await disableManager.disable(label: "test"); Issue.record("disable should fail") } catch {}

        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let spec = JobSpec(component: .broker, installationID: UUID(), executable: "/usr/bin/true", arguments: [],
                           workingDirectory: root.path, stdoutPath: root.appendingPathComponent("out").path,
                           stderrPath: root.appendingPathComponent("err").path, keepAlive: true, environment: [:],
                           sessionPlistDirectory: root.appendingPathComponent("session").path,
                           launchAgentsDirectory: root.appendingPathComponent("agents").path)
        let bootstrapManager = LaunchdServiceManager(uid: getuid(), runner: FailingLaunchctlRunner(.bootstrap))
        do { try await bootstrapManager.install(spec, persistent: false, start: true); Issue.record("I/O error should fail") } catch {}
    }

    @Test
    func testBundleValidationCoversEveryExecutableAndRejectsTampering() throws {
        let root = directory(), source = root.appendingPathComponent("source"), home = root.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for name in ["shell-control", "shell-controld", "shell-control-broker"] {
            let data = Data("binary-\(name)".utf8); try data.write(to: source.appendingPathComponent(name))
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let manifest = ReleaseManifest(releaseID: "test-release", architecture: architecture,
                                       minimumOS: "26.0", toolchain: "test", executables: hashes)
        let encoder = JSONEncoder(); try encoder.encode(manifest).write(to: source.appendingPathComponent("release-manifest.json"))
        let installer = NativeBundleInstaller(executablePath: source.appendingPathComponent("shell-control").path, home: home)
        #expect((try installer.validateBundle().releaseID) == "test-release")
        _ = try installer.install(manifest)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/bin/shell-control").path))
        try Data("tampered".utf8).write(to: source.appendingPathComponent("shell-control"))
        #expect(throws: (any Error).self){ try installer.validateBundle() }
    }

    @Test
    func testRestartRejectedWhenStopped() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallationStore(root: root), lock = try store.lock()
        _ = try store.create(releaseID: "r", mode: .loopback, publicURL: "http://127.0.0.1:8443", port: 8443)
        lock.release()
        let coordinator = LifecycleCoordinator(store: store, manager: FakeServices())
        try await coordinator.down()
        do {
            try await coordinator.restart([.broker])
            Issue.record("stopped installations must reject restart")
        } catch let error as ManagementError {
            #expect(error.description.contains("stopped"), "\(error.description)")
        }
    }

    @Test
    func testPublishLinkUpdatesOwnedReleaseSymlinkAndRefusesForeignFiles() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        func bundle(_ name: String, releaseID: String) throws -> (URL, ReleaseManifest) {
            let source = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            var hashes: [String: String] = [:]
            for executable in ["shell-control", "shell-controld", "shell-control-broker"] {
                let data = Data("\(releaseID)-\(executable)".utf8)
                try data.write(to: source.appendingPathComponent(executable))
                hashes[executable] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let manifest = ReleaseManifest(releaseID: releaseID, architecture: architecture,
                                           minimumOS: "26.0", toolchain: "test", executables: hashes)
            try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("release-manifest.json"))
            return (source, manifest)
        }
        let first = try bundle("r1", releaseID: "release-1")
        let installer1 = NativeBundleInstaller(executablePath: first.0.appendingPathComponent("shell-control").path, home: home)
        _ = try installer1.install(first.1)
        let link = home.appendingPathComponent(".local/bin/shell-control")
        #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == home.appendingPathComponent(".local/lib/chr33s-shell/release-1/shell-control").path)

        let second = try bundle("r2", releaseID: "release-2")
        let installer2 = NativeBundleInstaller(executablePath: second.0.appendingPathComponent("shell-control").path, home: home)
        _ = try installer2.install(second.1)
        #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == home.appendingPathComponent(".local/lib/chr33s-shell/release-2/shell-control").path)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../lib/chr33s-shell/release-2/shell-control"
        )
        let third = try bundle("r3", releaseID: "release-3")
        let installer3 = NativeBundleInstaller(executablePath: third.0.appendingPathComponent("shell-control").path, home: home)
        _ = try installer3.install(third.1)
        #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == home.appendingPathComponent(".local/lib/chr33s-shell/release-3/shell-control").path)

        try FileManager.default.removeItem(at: link)
        try Data("foreign".utf8).write(to: link)
        #expect(throws: (any Error).self){ try installer2.install(second.1) }
        #expect((try String(contentsOf: link, encoding: .utf8)) == "foreign")
        let fourth = try bundle("r4", releaseID: "release-4")
        let installer4 = NativeBundleInstaller(executablePath: fourth.0.appendingPathComponent("shell-control").path, home: home)
        #expect(throws: (any Error).self){ try installer4.install(fourth.1) }
        #expect(!(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/lib/chr33s-shell/release-4").path)))
        #expect((try String(contentsOf: link, encoding: .utf8)) == "foreign")
    }

    @Test
    func testAtomicFilesArePrivate() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallationStore(root: root), lock = try store.lock(); defer { lock.release() }
        _ = try store.create(releaseID: "r", mode: .loopback, publicURL: nil, port: 8443)
        for path in [store.paths.installation.path, store.paths.secrets.path, store.paths.runtime.path] {
            guard let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue else {
                Issue.record("Missing POSIX permissions for \(path)")
                return
            }
            #expect(mode == 0o600)
        }
    }
}
