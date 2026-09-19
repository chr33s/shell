import XCTest
import CryptoKit
@testable import ShellControlManagement
import ShellControlHostSupport

actor FakeHealth: ControlHealthChecking {
    var brokerReady = true
    var daemonReady = true
    var publicReady = true
    var brokerProbes = 0
    var daemonProbes = 0
    var publicProbes = 0

    func broker(url: URL, expectedIdentity: String) async -> ComponentObservation {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let loopback = ControlLoopback.isHost(url.host ?? "")
        if loopback { brokerProbes += 1 } else { publicProbes += 1 }
        let ready = loopback ? brokerReady : publicReady
        return .init(state: ready ? "ready" : "not_ready", checkedAt: stamp,
                     reason: ready ? nil : "injected \(loopback ? "broker" : "public") probe failure")
    }

    func daemon(path: String) async -> ComponentObservation {
        daemonProbes += 1
        let stamp = ISO8601DateFormatter().string(from: Date())
        return .init(state: daemonReady ? "ready" : "not_ready", checkedAt: stamp,
                     reason: daemonReady ? nil : "injected daemon probe failure")
    }
}

actor FakeOrigins: OriginProvisioning {
    var calls: [(originID: UUID, secret: String)] = []
    var error: ManagementError?
    func provisionOrigin(port: Int, adminSecret: String, label: String, originID: UUID, originSecret: String) async throws {
        if let error { throw error }
        calls.append((originID, originSecret))
    }
    func callCount() -> Int { calls.count }
}

final class LifecycleHarnessTests: XCTestCase {
    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-lifecycle-harness-\(UUID())")
    }

    private func architecture() -> String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private func makeBundle(in root: URL, releaseID: String = "harness-release") throws -> (installer: NativeBundleInstaller, home: URL) {
        let source = root.appendingPathComponent("bundle")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for name in ["shell-control", "shell-controld", "shell-control-broker"] {
            let data = Data("\(releaseID)-\(name)".utf8)
            try data.write(to: source.appendingPathComponent(name))
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = ReleaseManifest(
            releaseID: releaseID, architecture: architecture(),
            minimumOS: "26.0", toolchain: "test", executables: hashes
        )
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("release-manifest.json"))
        let installer = NativeBundleInstaller(
            executablePath: source.appendingPathComponent("shell-control").path, home: home
        )
        return (installer, home)
    }

    private func coordinator(
        root: URL, installer: NativeBundleInstaller, home: URL,
        services: FakeServices, health: FakeHealth, origins: FakeOrigins,
        deadline: Duration = .milliseconds(200)
    ) -> LifecycleCoordinator {
        LifecycleCoordinator(
            store: InstallationStore(root: root), manager: services, installer: installer,
            home: home, health: health, origins: origins, readinessDeadline: deadline
        )
    }

    func testLoopbackSetupProvisionsOriginOnceAndStartsOwnedJobs() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let services = FakeServices(), health = FakeHealth(), origins = FakeOrigins()
        let manager = coordinator(root: root.appendingPathComponent("state"), installer: bundle.installer, home: bundle.home,
                                  services: services, health: health, origins: origins)
        let loaded = try await manager.setup(SetupOptions(mode: .loopback))
        XCTAssertEqual(loaded.installation.addressMode, .loopback)
        XCTAssertEqual(loaded.installation.publicURL, "http://127.0.0.1:8443")
        XCTAssertNotNil(loaded.secrets.originID)
        let originCalls = await origins.callCount()
        XCTAssertEqual(originCalls, 1)
        let calls = await services.calls
        XCTAssertEqual(calls.filter { $0 == "install:broker" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "install:daemon" }.count, 1)
        XCTAssertFalse(calls.contains(where: { $0.contains("tunnel") }))
        let overall = await manager.status().overall
        XCTAssertEqual(overall, "ready")

        _ = try await manager.setup(SetupOptions(mode: .loopback))
        let originCallsAfterReuse = await origins.callCount()
        XCTAssertEqual(originCallsAfterReuse, 1, "existing origin identity must not be regenerated")
    }

    func testSetupPreservesStoppedIntent() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let services = FakeServices(), health = FakeHealth(), origins = FakeOrigins()
        let state = root.appendingPathComponent("state")
        let manager = coordinator(root: state, installer: bundle.installer, home: bundle.home,
                                  services: services, health: health, origins: origins)
        _ = try await manager.setup(SetupOptions(mode: .loopback))
        try await manager.down()
        do {
            _ = try await manager.setup(SetupOptions(mode: .loopback))
            XCTFail("setup must not override stopped intent")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("stopped"), error.description)
        }
        XCTAssertEqual(try InstallationStore(root: state).load().installation.desiredState, .stopped)
    }

    func testUpAfterDownRestartsOwnedJobs() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let services = FakeServices(), health = FakeHealth(), origins = FakeOrigins()
        let manager = coordinator(root: root.appendingPathComponent("state"), installer: bundle.installer, home: bundle.home,
                                  services: services, health: health, origins: origins)
        _ = try await manager.setup(SetupOptions(mode: .loopback))
        try await manager.down()
        let loaded = try await manager.up()
        XCTAssertEqual(loaded.installation.desiredState, .running)
        let overall = await manager.status().overall
        XCTAssertEqual(overall, "ready")
        let installs = await services.calls.filter { $0 == "install:broker" }.count
        XCTAssertGreaterThanOrEqual(installs, 2)
    }

    func testBrokerHealthFailureRollsBackCreatedJobs() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let services = FakeServices(), health = FakeHealth(), origins = FakeOrigins()
        await health.setBrokerReady(false)
        let manager = coordinator(root: root.appendingPathComponent("state"), installer: bundle.installer, home: bundle.home,
                                  services: services, health: health, origins: origins,
                                  deadline: .milliseconds(80))
        do {
            _ = try await manager.setup(SetupOptions(mode: .loopback))
            XCTFail("setup must fail when the broker never becomes ready")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("readiness deadline"), error.description)
        }
        let originCalls = await origins.callCount()
        XCTAssertEqual(originCalls, 0)
        let calls = await services.calls
        XCTAssertTrue(calls.contains("install:broker"))
        XCTAssertTrue(calls.contains { $0.hasPrefix("disable:") })
        XCTAssertTrue(calls.contains { $0.hasPrefix("stop:") })
        XCTAssertFalse(calls.contains("install:daemon"))
        let runtime = try InstallationStore(root: root.appendingPathComponent("state")).load().runtime
        XCTAssertNotNil(runtime.operation, "failed start before local commit keeps the incomplete operation")
    }

}

extension FakeHealth {
    func setBrokerReady(_ value: Bool) { brokerReady = value }
    func setPublicReady(_ value: Bool) { publicReady = value }
}
