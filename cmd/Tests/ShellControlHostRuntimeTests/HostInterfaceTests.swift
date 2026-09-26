import Testing
import Foundation
import XPC
import ShellControlAgentAdapter
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlHostRuntime

/// Test-only: accepts every peer. The library ships no such authorizer.
struct AllowEveryPeer: HostPeerAuthorizer {
    func authorize(_ message: XPCReceivedMessage) -> Bool { true }
}

@Suite
final class HostXPCTests {
    private func session(_ service: HostXPCService) throws -> (XPCListener, XPCSession) {
        // Created active; activating it again is XPC API misuse.
        let listener = service.anonymousListener()
        return (listener, try XPCSession(endpoint: listener.endpoint))
    }

    private func send(_ request: ControlHostRequest, over session: XPCSession) throws -> ControlHostReply {
        try session.sendSync(request)
    }

    /// The real code-signing check rejects this unsigned test process: it is
    /// not the Shell app signed by the host's team (spec A45).
    @Test
    func testUnauthorizedPeerIsRejected() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        let service = HostXPCService(runtime: runtime, authorizer: CodeSigningPeerAuthorizer.shellApp)
        let (listener, session) = try session(service)
        defer { session.cancel(reason: "done"); listener.cancel() }
        let reply = try send(ControlHostRequest(.status), over: session)
        #expect(!(reply.ok))
        #expect(reply.errorCode == ControlHostErrorCode.unauthorizedPeer.rawValue)
        #expect((reply.status) == nil)
        let mutation = try send(ControlHostRequest(.stopAcceptingWork), over: session)
        #expect(mutation.errorCode == ControlHostErrorCode.unauthorizedPeer.rawValue)
    }

    @Test
    func testAuthorizedPeerGetsStatusAndUnsupportedMessagesAreRejected() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        try await runtime.start()
        let service = HostXPCService(runtime: runtime, authorizer: AllowEveryPeer())
        let (listener, session) = try session(service)
        defer { session.cancel(reason: "done"); listener.cancel() }

        let reply = try send(ControlHostRequest(.status), over: session)
        #expect(reply.ok, "\(reply.errorMessage ?? "")")
        #expect(reply.status?.phase == .ready)
        #expect(reply.status?.protocolVersion == ControlHostWire.protocolVersion)

        var unknown = ControlHostRequest(.status)
        unknown.operation = "run_shell_command"
        #expect((try send(unknown, over: session).errorCode) == ControlHostErrorCode.unsupportedOperation.rawValue)

        let future = ControlHostRequest(.status, version: ControlHostWire.protocolVersion + 1)
        #expect((try send(future, over: session).errorCode) == ControlHostErrorCode.unsupportedVersion.rawValue)

        let missing = try send(ControlHostRequest(.revokeDevice), over: session)
        #expect(missing.errorCode == ControlHostErrorCode.invalidArgument.rawValue)

        // A message that is not a ControlHostRequest at all.
        struct Stray: Codable { var hello = "world" }
        let stray: ControlHostReply = try session.sendSync(Stray())
        #expect(stray.errorCode == ControlHostErrorCode.unsupportedOperation.rawValue)

        let stopped = try send(ControlHostRequest(.stopAcceptingWork), over: session)
        #expect(stopped.status?.phase == .stopped)
        let resumed = try send(ControlHostRequest(.resumeAcceptingWork), over: session)
        #expect(resumed.status?.phase == .ready)
        await runtime.shutdown()
    }
}

@Suite
final class ReadinessTests {
    private func status(_ phase: ControlHostStatus.Phase, route: ControlHostRouteStatus.State = .verified, version: Int = ControlHostWire.protocolVersion) -> ControlHostObservation {
        .reachable(ControlHostStatus(
            protocolVersion: version, hostBuild: "1", phase: phase, acceptingWork: phase == .ready, brokerPort: 8443,
            route: ControlHostRouteStatus(state: route)
        ))
    }

    private func evaluate(
        intent: Bool = true,
        _ registration: ControlHostRegistration,
        ever: Bool = false,
        _ host: ControlHostObservation = .notQueried,
        unreachableFor: TimeInterval? = nil
    ) -> ControlReadinessState {
        ControlReadiness.evaluate(intentEnabled: intent, registration: registration, everObservedEnabled: ever,
                                  host: host, unreachableFor: unreachableFor)
    }

    @Test
    func testIntentAndSystemConsent() throws {
        #expect(evaluate(intent: false, .enabled, status(.ready)) == .notEnabled)
        #expect(evaluate(intent: false, .notRegistered) == .notEnabled)
        #expect(evaluate(.notRegistered) == .notEnabled)
        #expect(evaluate(.requiresApproval) == .approvalRequired)
        // Turned off in System Settings after it ran: reported, never re-registered.
        #expect(evaluate(.requiresApproval, ever: true) == .disabledByUser)
        #expect(evaluate(.notRegistered, ever: true) == .disabledByUser)
        #expect(evaluate(.notFound) == .incompatibleBuild)
        #expect(evaluate(.unknown) == .degraded)
    }

    @Test
    func testEnabledIsNotHealth() throws {
        #expect(evaluate(.enabled, .notQueried) == .registeredStarting)
        #expect(evaluate(.enabled, .unreachable(detail: "x"), unreachableFor: 5) == .registeredStarting)
        #expect(evaluate(.enabled, .unreachable(detail: "x"), unreachableFor: 120) == .degraded)
        #expect(evaluate(.enabled, status(.starting)) == .registeredStarting)
        #expect(evaluate(.enabled, status(.recovering)) == .registeredStarting)
        #expect(evaluate(.enabled, status(.degraded)) == .degraded)
        #expect(evaluate(.enabled, status(.legacyConflict)) == .legacyConflict)
        #expect(evaluate(.enabled, status(.ready, route: .verified)) == .readyLocal)
        #expect(evaluate(.enabled, status(.ready, route: .notConfigured)) == .routeUnavailable)
        #expect(evaluate(.enabled, status(.ready, route: .unavailable)) == .routeUnavailable)
        #expect(evaluate(.enabled, status(.ready, version: 99)) == .incompatibleBuild)
    }

    @Test
    func testWireCodingIsStable() throws {
        let request = ControlHostRequest(.setAgentGrants, deviceID: "d", enabled: true)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(json.contains(#""op":"set_agent_grants""#))
        #expect(json.contains(#""v":1"#))
        #expect((try JSONDecoder().decode(ControlHostRequest.self, from: Data(json.utf8))) == request)
        #expect(ControlReadinessState.allCases.map(\.rawValue) == [
            "not_enabled", "approval_required", "registered_starting", "ready_local", "route_unavailable",
            "disabled_by_user", "incompatible_build", "degraded", "legacy_conflict"
        ])
    }
}

@Suite
final class RouteVerificationTests {
    let key = OriginSigningKey()
    var origin: OriginIdentity { OriginIdentity(originID: ControlID("7d9f1c3a-2b4e-4f60-8a1b-0c2d3e4f5a6b")!, publicJWK: key.publicJWK) }

    private func proofProbe(signedBy signer: OriginSigningKey, originID: ControlID? = nil) -> StubProbe {
        let originID = originID ?? origin.originID
        return StubProbe { url in
            #expect(url.host == "mac.tailnet.ts.net")
            #expect(url.path == "/v1/origin/proof")
            let nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nonce" }?.value ?? ""
            let proof = try OriginProof.sign(originID: originID, nonce: nonce, issuedAt: ControlTimestamp(Date()), key: signer)
            return (200, try JSONCanonicalization.canonicalize(proof.document))
        }
    }

    @Test
    func testVerifiedRouteAcceptsBareMagicDNSName() async throws {
        let result = await TailscaleRouteVerifier(probe: proofProbe(signedBy: key)).verify("mac.tailnet.ts.net", origin: origin)
        #expect(result.state == .verified, "\(result.detail ?? "")")
        #expect(result.url == "https://mac.tailnet.ts.net")
    }

    @Test
    func testAnotherOriginKeyIsAMismatch() async throws {
        let result = await TailscaleRouteVerifier(probe: proofProbe(signedBy: OriginSigningKey()))
            .verify("https://mac.tailnet.ts.net/", origin: origin)
        #expect(result.state == .unavailable)
        #expect(result.reason == .originMismatch)
    }

    @Test
    func testPreciseFailureReasons() async throws {
        func verify(_ text: String, _ probe: StubProbe, origin: OriginIdentity?) async -> ControlHostRouteStatus.Reason? {
            await TailscaleRouteVerifier(probe: probe).verify(text, origin: origin).reason
        }
        let name = "mac.tailnet.ts.net"
        let notFound = await verify(name, StubProbe { _ in (404, Data()) }, origin: origin)
        #expect(notFound == .httpStatus)
        let unreachable = await verify(name, StubProbe { _ in throw URLError(.timedOut) }, origin: origin)
        #expect(unreachable == .unreachable)
        let tls = await verify(name, StubProbe { _ in throw URLError(.serverCertificateUntrusted) }, origin: origin)
        #expect(tls == .tlsFailure)
        let foreign = await verify(name, StubProbe { _ in (200, Data("<html>".utf8)) }, origin: origin)
        #expect(foreign == .notShellBroker)
        let publicName = await verify("example.com", StubProbe.silent, origin: origin)
        #expect(publicName == .invalidName)
        let noIdentity = await verify(name, StubProbe.silent, origin: nil)
        #expect(noIdentity == .noOriginIdentity)
    }
}

@Suite
final class HostSocketDiscoveryTests {
    let standalone = URL(fileURLWithPath: "/tmp/standalone")
    let bundled = "/tmp/group/control.sock"

    @Test
    func testExplicitStateDirectoryAlwaysWins() throws {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: URL(fileURLWithPath: "/tmp/explicit"), standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { _ in true }, exists: { _ in true }
        )
        #expect(resolution == .init(socketPath: "/tmp/explicit/control.sock", source: .explicitStateDirectory))
    }

    @Test
    func testLiveStandaloneDaemonIsPreferred() throws {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { $0 == "/tmp/standalone/control.sock" }, exists: { _ in true }
        )
        #expect(resolution.source == .standalone)
    }

    @Test
    func testBundledHostSocketWhenStandaloneIsNotLive() throws {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { _ in false }, exists: { $0 == "/tmp/group/control.sock" }
        )
        #expect(resolution == .init(socketPath: bundled, source: .bundledHost))
    }

    @Test
    func testFallsBackToStandalonePathWhenNothingServes() throws {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { _ in false }, exists: { _ in false }
        )
        #expect(resolution == .init(socketPath: "/tmp/standalone/control.sock", source: .standaloneFallback))
        let noGroup = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: nil,
            isLive: { _ in false }, exists: { _ in true }
        )
        #expect(noGroup.source == .standaloneFallback)
    }

    @Test
    func testDiscoveryAgreesWithTheHost() throws {
        #expect(HostSocketDiscovery.appGroupIdentifier == ControlHostWire.appGroupIdentifier)
        #expect(HostSocketDiscovery.socketName == ControlHostWire.adapterSocketName)
        #expect(HostSocketDiscovery.bundledSocketPath()?.hasSuffix("/\(ControlHostWire.appGroupIdentifier)/control.sock") ?? false)
    }
}
