import Foundation
import Testing
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
    func disableServe(tailscale: String, rootOnly: Bool) async throws {
        disableCalls += 1
        if rootOnly {
            for key in serve.proxies.keys { serve.proxies[key] = nil }
        } else {
            serve = ServeState()
        }
    }

    func setDNSName(_ name: String) { status.dnsName = name }
    func setFunnel(_ host: String) { serve.funnel.insert("\(host):443") }
    func setConfigureTakesEffect(_ value: Bool) { configureTakesEffect = value }
}

struct FakePairingAdministration: PairingAdministration {
    func createPairing(port: Int, adminSecret: String) async throws -> (pairingID: ControlID, secret: String, expiresAt: ControlTimestamp) {
        (.random(), Base64URL.encode(Data(repeating: 3, count: 32)), ControlTimestamp(Date().addingTimeInterval(600)))
    }
}

@Suite
final class TailscaleLifecycleTests {
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

    @Test
    func testFreshSetupDefaultsToTailscaleServeOverLoopback() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let loaded = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        #expect(loaded.installation.addressMode == .tailscale)
        #expect(loaded.installation.publicURL == "https://macbook.example.ts.net")
        let configured = await rig.tailnet.configureCalls
        #expect(configured == 1)
        let calls = await rig.services.calls
        #expect(!(calls.contains { $0.contains("tunnel") }), "no cloudflared in the tailnet profile")

        // The broker stays on loopback and is told the origin identity.
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: loaded.paths.services.appendingPathComponent("broker.json"))) as? [String: Any]
        #expect(config?["bind_loopback"] as? Bool == true)
        #expect(config?["origin_id"] as? String == loaded.secrets.originID?.uuidString.lowercased())
        #expect(config?["origin_key_file"] as? String == loaded.paths.originKey.path)
        let mode = try FileManager.default.attributesOfItem(atPath: loaded.paths.originKey.path)[.posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0o777) & 0o077 == 0, "origin key is owner-only")

        let status = await rig.manager.status()
        #expect(status.overall == "ready")
        #expect(status.components["tailscale"]?.state == "connected")
        #expect(status.components["serve"]?.state == "active")
        #expect(status.origin?.fingerprint == loaded.secrets.originKeyFingerprint)
        #expect(status.origin?.fingerprint.hasPrefix("SHA256:") ?? false)
        let provisioned = await rig.origins.callCount()
        #expect(provisioned == 1)

        // Re-running setup reuses everything: no second origin, no new key.
        let again = try await rig.manager.setup(SetupOptions())
        #expect(again.secrets.originKeyFingerprint == loaded.secrets.originKeyFingerprint)
        let provisionedAgain = await rig.origins.callCount()
        #expect(provisionedAgain == 1)
    }

    @Test
    func testMissingTailscalePrerequisitesAreReported() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stopped = try rig(root, tailnet: FakeTailnet(backendState: "NeedsLogin"))
        do {
            _ = try await stopped.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            Issue.record("setup must not proceed without a connected tailnet")
        } catch let error as ManagementError {
            #expect(error.description.contains("tailscale up"), "\(error.description)")
        }

        let root2 = directory(); defer { try? FileManager.default.removeItem(at: root2) }
        let noDNS = try rig(root2, tailnet: FakeTailnet(dnsName: nil, magicDNS: false))
        do {
            _ = try await noDNS.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            Issue.record("setup must require MagicDNS")
        } catch let error as ManagementError {
            #expect(error.description.contains("MagicDNS"), "\(error.description)")
        }
    }

    /// Setup validates the resulting Serve state rather than trusting the CLI.
    @Test
    func testServeStateIsValidatedNotAssumed() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tailnet = FakeTailnet()
        await tailnet.setConfigureTakesEffect(false)
        let rig = try rig(root, tailnet: tailnet)
        do {
            _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            Issue.record("an ineffective serve command must be caught")
        } catch let error as ManagementError {
            #expect(error.description.contains("not proxying"), "\(error.description)")
        }
    }

    @Test
    func testFunnelIsRefused() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tailnet = FakeTailnet()
        await tailnet.setFunnel("macbook.example.ts.net")
        let rig = try rig(root, tailnet: tailnet)
        do {
            _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            Issue.record("a public Funnel must be refused")
        } catch let error as ManagementError {
            #expect(error.description.contains("Funnel"), "\(error.description)")
        }
    }

    /// A renamed Mac is a route change: the origin key, and so every pairing,
    /// survives, and the signed route update verifies under the same key.
    @Test
    func testRenamedMacChangesRouteButNotTrust() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        let origin = try await rig.manager.originIdentity().identity

        await rig.tailnet.setDNSName("renamed.example.ts.net")
        let second = try await rig.manager.up()
        #expect(second.installation.publicURL == "https://renamed.example.ts.net")
        #expect(second.secrets.originKeyFingerprint == first.secrets.originKeyFingerprint)
        #expect(second.secrets.originID == first.secrets.originID)

        let update = try await rig.manager.routeUpdate()
        #expect(update.route.url.absoluteString == "https://renamed.example.ts.net")
        do { _ = try update.verify(pinned: origin) } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test
    func testMissingOriginKeyIsNeverSilentlyRegenerated() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        try FileManager.default.removeItem(at: first.paths.originKey)
        do {
            _ = try await rig.manager.up()
            Issue.record("a lost origin key must not be replaced implicitly")
        } catch let error as ManagementError {
            #expect(error.description.contains("--reset-origin-key"), "\(error.description)")
        }
        let reset = try await rig.manager.setup(SetupOptions(resetOriginKey: true))
        #expect(reset.secrets.originKeyFingerprint != first.secrets.originKeyFingerprint)
        #expect(reset.secrets.originID == first.secrets.originID)
        // The broker's config changes with the key, so its job restarts and
        // it signs proofs with the new key.
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: reset.paths.services.appendingPathComponent("broker.json"))) as? [String: Any]
        #expect(config?["origin_key_fingerprint"] as? String == reset.secrets.originKeyFingerprint)
    }

    @Test
    func testPairingInvitationPinsTheOriginAndItsRoute() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        let invitation = try await rig.manager.pairingInvitation(admin: FakePairingAdministration())
        let origin = try await rig.manager.originIdentity().identity
        #expect(invitation.origin == origin)
        #expect(invitation.route.url.absoluteString == "https://macbook.example.ts.net")
        let rendered = try PairingRenderer.invitationOutput(invitation, terminal: false)
        #expect(rendered.contains(origin.fingerprint))
        #expect(rendered.contains("shell-control://pair?invite="))
        #expect((try PairingInvitation(scanned: try invitation.link().absoluteString)) == invitation)
    }

    @Test
    func testRouteValidationIsTailnetOnly() throws {
        #expect(throws: (any Error).self){ try AddressPolicy.validate("https://abc.trycloudflare.com", mode: .tailscale) }
        #expect(throws: (any Error).self){ try AddressPolicy.validate("https://control.example", mode: .tailscale) }
        #expect((try AddressPolicy.validate("https://Mac.Example.ts.net/", mode: .tailscale)) == "https://mac.example.ts.net")
    }

    /// An installation written with a removed Cloudflare mode migrates to
    /// Tailscale, and setup withdraws the old cloudflared job and its files.
    @Test
    func testLegacyTunnelInstallationMigratesToTailscale() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: first.paths.installation)) as? [String: Any] ?? [:]
        json["address_mode"] = "quick"
        json["public_url"] = "https://abc.trycloudflare.com"
        json["tunnel"] = ["cloudflared_path": "/opt/homebrew/bin/cloudflared"]
        try SecureFileSystem.atomicWrite(try JSONSerialization.data(withJSONObject: json), to: first.paths.installation)
        // A quick-tunnel start that failed before the upgrade left its operation.
        var runtime = try JSONSerialization.jsonObject(with: Data(contentsOf: first.paths.runtime)) as? [String: Any] ?? [:]
        runtime["operation"] = ["id": UUID().uuidString, "command": "start", "plan": ["tunnel", "broker"],
                                "pendingStep": "tunnel", "createdResources": ["tunnel", "broker"]]
        try SecureFileSystem.atomicWrite(try JSONSerialization.data(withJSONObject: runtime), to: first.paths.runtime)
        let config = first.paths.services.appendingPathComponent("tunnel.yml")
        try SecureFileSystem.atomicWrite(Data("tunnel: x\n".utf8), to: config)

        let loaded = try InstallationStore(root: rig.state).load()
        #expect(loaded.installation.addressMode == .tailscale)
        #expect((loaded.installation.publicURL) == nil)
        #expect(loaded.runtime.operation?.createdResources == [.broker])
        let again = try await rig.manager.setup(SetupOptions())
        #expect(again.installation.addressMode == .tailscale)
        #expect(!(FileManager.default.fileExists(atPath: config.path)))
        let data = try Data(contentsOf: again.paths.installation)
        #expect(!(String(decoding: data, as: UTF8.self).contains("cloudflared")))
    }

    @Test
    func testServeStatusParsingMatchesTailscaleJSON() throws {
        let json = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"macbook.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8443"}}}}}"#
        let state = try ServeState(json: Data(json.utf8))
        #expect(state.servesBroker(host: "macbook.example.ts.net", port: 8443))
        #expect(!(state.servesBroker(host: "macbook.example.ts.net", port: 9000)))
        #expect(!(state.isFunnelled(host: "macbook.example.ts.net")))
        #expect(try ServeState(json: Data("{}".utf8)).proxies.isEmpty)
        #expect(try ServeState(json: Data()).proxies.isEmpty)
        #expect(ServeState(proxies: ["m.example.ts.net:443": "localhost:8443"]).servesBroker(host: "m.example.ts.net", port: 8443))

        let status = try TailnetStatus(json: Data(#"{"BackendState":"Running","Self":{"DNSName":"MacBook.example.ts.net.","Online":true},"CurrentTailnet":{"MagicDNSEnabled":true}}"#.utf8))
        #expect((try TailscaleTools.requireReady(status)) == "macbook.example.ts.net")
    }
}
