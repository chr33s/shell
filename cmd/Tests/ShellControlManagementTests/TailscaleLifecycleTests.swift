import XCTest
import CryptoKit
@testable import ShellControlManagement
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

actor FakeTailnet: TailnetRuntime {
    var status: TailnetStatus
    var serve = ServeState()
    var configureCalls = 0
    var disableCalls = 0
    /// When false, `configureServe` "succeeds" but changes nothing, the way a
    /// CLI whose syntax drifted might.
    var configureTakesEffect = true

    init(dnsName: String? = "macbook.example.ts.net", backendState: String = "Running", magicDNS: Bool = true) {
        status = TailnetStatus(backendState: backendState, dnsName: dnsName, magicDNSEnabled: magicDNS, online: true)
    }

    func status(tailscale: String) async throws -> TailnetStatus { status }
    func serveStatus(tailscale: String) async throws -> ServeState { serve }
    func configureServe(tailscale: String, port: Int) async throws {
        configureCalls += 1
        guard configureTakesEffect, let name = status.dnsName else { return }
        serve.proxies["\(name):443"] = "http://127.0.0.1:\(port)"
    }
    func disableServe(tailscale: String) async throws { disableCalls += 1; serve = ServeState() }

    func setDNSName(_ name: String) { status.dnsName = name }
    func setFunnel(_ host: String) { serve.funnel.insert("\(host):443") }
    func setConfigureTakesEffect(_ value: Bool) { configureTakesEffect = value }
}

struct FakePairingAdministration: PairingAdministration {
    func createPairing(port: Int, adminSecret: String) async throws -> (pairingID: ControlID, secret: String, expiresAt: ControlTimestamp) {
        (.random(), Base64URL.encode(Data(repeating: 3, count: 32)), ControlTimestamp(Date().addingTimeInterval(600)))
    }
}

final class TailscaleLifecycleTests: XCTestCase {
    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-tailscale-\(UUID())")
    }

    private func makeBundle(in root: URL) throws -> (installer: NativeBundleInstaller, home: URL) {
        let source = root.appendingPathComponent("bundle")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for name in ["shell-control", "shell-controld", "shell-control-broker"] {
            let data = Data("tailscale-release-\(name)".utf8)
            try data.write(to: source.appendingPathComponent(name))
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let manifest = ReleaseManifest(releaseID: "tailscale-release", architecture: architecture,
                                       minimumOS: "26.0", toolchain: "test", executables: hashes)
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("release-manifest.json"))
        return (NativeBundleInstaller(executablePath: source.appendingPathComponent("shell-control").path, home: home), home)
    }

    private struct Rig {
        let manager: LifecycleCoordinator
        let tailnet: FakeTailnet
        let origins: FakeOrigins
        let services: FakeServices
        let state: URL
    }

    private func rig(_ root: URL, tailnet: FakeTailnet = FakeTailnet()) throws -> Rig {
        let bundle = try makeBundle(in: root)
        let services = FakeServices(), origins = FakeOrigins()
        let state = root.appendingPathComponent("state")
        let manager = LifecycleCoordinator(
            store: InstallationStore(root: state), manager: services, installer: bundle.installer, home: bundle.home,
            health: FakeHealth(), origins: origins, tailnet: tailnet,
            readinessDeadline: .milliseconds(200)
        )
        return Rig(manager: manager, tailnet: tailnet, origins: origins, services: services, state: state)
    }

    func testFreshSetupDefaultsToTailscaleServeOverLoopback() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let loaded = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        XCTAssertEqual(loaded.installation.addressMode, .tailscale)
        XCTAssertEqual(loaded.installation.publicURL, "https://macbook.example.ts.net")
        let configured = await rig.tailnet.configureCalls
        XCTAssertEqual(configured, 1)
        let calls = await rig.services.calls
        XCTAssertFalse(calls.contains { $0.contains("tunnel") }, "no cloudflared in the tailnet profile")

        // The broker stays on loopback and is told the origin identity.
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: loaded.paths.services.appendingPathComponent("broker.json"))) as? [String: Any]
        XCTAssertEqual(config?["bind_loopback"] as? Bool, true)
        XCTAssertEqual(config?["origin_id"] as? String, loaded.secrets.originID?.uuidString.lowercased())
        XCTAssertEqual(config?["origin_key_file"] as? String, loaded.paths.originKey.path)
        let mode = try FileManager.default.attributesOfItem(atPath: loaded.paths.originKey.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0o777) & 0o077, 0, "origin key is owner-only")

        let status = await rig.manager.status()
        XCTAssertEqual(status.overall, "ready")
        XCTAssertEqual(status.components["tailscale"]?.state, "connected")
        XCTAssertEqual(status.components["serve"]?.state, "active")
        XCTAssertEqual(status.origin?.fingerprint, loaded.secrets.originKeyFingerprint)
        XCTAssertTrue(status.origin?.fingerprint.hasPrefix("SHA256:") ?? false)
        let provisioned = await rig.origins.callCount()
        XCTAssertEqual(provisioned, 1)

        // Re-running setup reuses everything: no second origin, no new key.
        let again = try await rig.manager.setup(SetupOptions())
        XCTAssertEqual(again.secrets.originKeyFingerprint, loaded.secrets.originKeyFingerprint)
        let provisionedAgain = await rig.origins.callCount()
        XCTAssertEqual(provisionedAgain, 1)
    }

    func testMissingTailscalePrerequisitesAreReported() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stopped = try rig(root, tailnet: FakeTailnet(backendState: "NeedsLogin"))
        do {
            _ = try await stopped.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            XCTFail("setup must not proceed without a connected tailnet")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("tailscale up"), error.description)
        }

        let root2 = directory(); defer { try? FileManager.default.removeItem(at: root2) }
        let noDNS = try rig(root2, tailnet: FakeTailnet(dnsName: nil, magicDNS: false))
        do {
            _ = try await noDNS.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            XCTFail("setup must require MagicDNS")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("MagicDNS"), error.description)
        }
    }

    /// Setup validates the resulting Serve state rather than trusting the CLI.
    func testServeStateIsValidatedNotAssumed() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tailnet = FakeTailnet()
        await tailnet.setConfigureTakesEffect(false)
        let rig = try rig(root, tailnet: tailnet)
        do {
            _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            XCTFail("an ineffective serve command must be caught")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("not proxying"), error.description)
        }
    }

    func testFunnelIsRefused() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tailnet = FakeTailnet()
        await tailnet.setFunnel("macbook.example.ts.net")
        let rig = try rig(root, tailnet: tailnet)
        do {
            _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            XCTFail("a public Funnel must be refused")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("Funnel"), error.description)
        }
    }

    /// A renamed Mac is a route change: the origin key, and so every pairing,
    /// survives, and the signed route update verifies under the same key.
    func testRenamedMacChangesRouteButNotTrust() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        let origin = try await rig.manager.originIdentity().identity

        await rig.tailnet.setDNSName("renamed.example.ts.net")
        let second = try await rig.manager.up()
        XCTAssertEqual(second.installation.publicURL, "https://renamed.example.ts.net")
        XCTAssertEqual(second.secrets.originKeyFingerprint, first.secrets.originKeyFingerprint)
        XCTAssertEqual(second.secrets.originID, first.secrets.originID)

        let update = try await rig.manager.routeUpdate()
        XCTAssertEqual(update.route.url.absoluteString, "https://renamed.example.ts.net")
        XCTAssertNoThrow(try update.verify(pinned: origin))
    }

    func testMissingOriginKeyIsNeverSilentlyRegenerated() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        try FileManager.default.removeItem(at: first.paths.originKey)
        do {
            _ = try await rig.manager.up()
            XCTFail("a lost origin key must not be replaced implicitly")
        } catch let error as ManagementError {
            XCTAssertTrue(error.description.contains("--reset-origin-key"), error.description)
        }
        let reset = try await rig.manager.setup(SetupOptions(resetOriginKey: true))
        XCTAssertNotEqual(reset.secrets.originKeyFingerprint, first.secrets.originKeyFingerprint)
        XCTAssertEqual(reset.secrets.originID, first.secrets.originID)
        // The broker's config changes with the key, so its job restarts and
        // it signs proofs with the new key.
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: reset.paths.services.appendingPathComponent("broker.json"))) as? [String: Any]
        XCTAssertEqual(config?["origin_key_fingerprint"] as? String, reset.secrets.originKeyFingerprint)
    }

    func testPairingInvitationPinsTheOriginAndItsRoute() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        let invitation = try await rig.manager.pairingInvitation(admin: FakePairingAdministration())
        let origin = try await rig.manager.originIdentity().identity
        XCTAssertEqual(invitation.origin, origin)
        XCTAssertEqual(invitation.route.url.absoluteString, "https://macbook.example.ts.net")
        let rendered = try PairingRenderer.invitationOutput(invitation, terminal: false)
        XCTAssertTrue(rendered.contains(origin.fingerprint))
        XCTAssertTrue(rendered.contains("shell-control://pair?invite="))
        XCTAssertEqual(try PairingInvitation(scanned: try invitation.link().absoluteString), invitation)
    }

    func testRouteValidationIsTailnetOnly() {
        XCTAssertThrowsError(try AddressPolicy.validate("https://abc.trycloudflare.com", mode: .tailscale))
        XCTAssertThrowsError(try AddressPolicy.validate("https://control.example", mode: .tailscale))
        XCTAssertEqual(try AddressPolicy.validate("https://Mac.Example.ts.net/", mode: .tailscale), "https://mac.example.ts.net")
    }

    /// An installation written with a removed Cloudflare mode migrates to
    /// Tailscale, and setup withdraws the old cloudflared job and its files.
    func testLegacyTunnelInstallationMigratesToTailscale() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: first.paths.installation)) as? [String: Any] ?? [:]
        json["address_mode"] = "quick"
        json["tunnel"] = ["cloudflared_path": "/opt/homebrew/bin/cloudflared"]
        try SecureFileSystem.atomicWrite(try JSONSerialization.data(withJSONObject: json), to: first.paths.installation)
        let config = first.paths.services.appendingPathComponent("tunnel.yml")
        try SecureFileSystem.atomicWrite(Data("tunnel: x\n".utf8), to: config)

        let loaded = try InstallationStore(root: rig.state).load()
        XCTAssertEqual(loaded.installation.addressMode, .tailscale)
        let again = try await rig.manager.setup(SetupOptions())
        XCTAssertEqual(again.installation.addressMode, .tailscale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        let data = try Data(contentsOf: again.paths.installation)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("cloudflared"))
    }

    func testServeStatusParsingMatchesTailscaleJSON() throws {
        let json = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"macbook.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8443"}}}}}"#
        let state = try ServeState(json: Data(json.utf8))
        XCTAssertTrue(state.servesBroker(host: "macbook.example.ts.net", port: 8443))
        XCTAssertFalse(state.servesBroker(host: "macbook.example.ts.net", port: 9000))
        XCTAssertFalse(state.isFunnelled(host: "macbook.example.ts.net"))
        XCTAssertTrue(try ServeState(json: Data("{}".utf8)).proxies.isEmpty)
        XCTAssertTrue(try ServeState(json: Data()).proxies.isEmpty)
        XCTAssertTrue(ServeState(proxies: ["m.example.ts.net:443": "localhost:8443"]).servesBroker(host: "m.example.ts.net", port: 8443))

        let status = try TailnetStatus(json: Data(#"{"BackendState":"Running","Self":{"DNSName":"MacBook.example.ts.net.","Online":true},"CurrentTailnet":{"MagicDNSEnabled":true}}"#.utf8))
        XCTAssertEqual(try TailscaleTools.requireReady(status), "macbook.example.ts.net")
    }
}
