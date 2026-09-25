import XCTest
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

final class HostXPCTests: XCTestCase {
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
    func testUnauthorizedPeerIsRejected() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        let service = HostXPCService(runtime: runtime, authorizer: CodeSigningPeerAuthorizer.shellApp)
        let (listener, session) = try session(service)
        defer { session.cancel(reason: "done"); listener.cancel() }
        let reply = try send(ControlHostRequest(.status), over: session)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.errorCode, ControlHostErrorCode.unauthorizedPeer.rawValue)
        XCTAssertNil(reply.status)
        let mutation = try send(ControlHostRequest(.stopAcceptingWork), over: session)
        XCTAssertEqual(mutation.errorCode, ControlHostErrorCode.unauthorizedPeer.rawValue)
    }

    func testAuthorizedPeerGetsStatusAndUnsupportedMessagesAreRejected() async throws {
        let root = try HostTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = HostTestSupport.runtime(root: root, port: try HostTestSupport.freePort())
        try await runtime.start()
        let service = HostXPCService(runtime: runtime, authorizer: AllowEveryPeer())
        let (listener, session) = try session(service)
        defer { session.cancel(reason: "done"); listener.cancel() }

        let reply = try send(ControlHostRequest(.status), over: session)
        XCTAssertTrue(reply.ok, reply.errorMessage ?? "")
        XCTAssertEqual(reply.status?.phase, .ready)
        XCTAssertEqual(reply.status?.protocolVersion, ControlHostWire.protocolVersion)

        var unknown = ControlHostRequest(.status)
        unknown.operation = "run_shell_command"
        XCTAssertEqual(try send(unknown, over: session).errorCode, ControlHostErrorCode.unsupportedOperation.rawValue)

        let future = ControlHostRequest(.status, version: ControlHostWire.protocolVersion + 1)
        XCTAssertEqual(try send(future, over: session).errorCode, ControlHostErrorCode.unsupportedVersion.rawValue)

        let missing = try send(ControlHostRequest(.revokeDevice), over: session)
        XCTAssertEqual(missing.errorCode, ControlHostErrorCode.invalidArgument.rawValue)

        // A message that is not a ControlHostRequest at all.
        struct Stray: Codable { var hello = "world" }
        let stray: ControlHostReply = try session.sendSync(Stray())
        XCTAssertEqual(stray.errorCode, ControlHostErrorCode.unsupportedOperation.rawValue)

        let stopped = try send(ControlHostRequest(.stopAcceptingWork), over: session)
        XCTAssertEqual(stopped.status?.phase, .stopped)
        let resumed = try send(ControlHostRequest(.resumeAcceptingWork), over: session)
        XCTAssertEqual(resumed.status?.phase, .ready)
        await runtime.shutdown()
    }
}

final class ReadinessTests: XCTestCase {
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

    func testIntentAndSystemConsent() {
        XCTAssertEqual(evaluate(intent: false, .enabled, status(.ready)), .notEnabled)
        XCTAssertEqual(evaluate(intent: false, .notRegistered), .notEnabled)
        XCTAssertEqual(evaluate(.notRegistered), .notEnabled)
        XCTAssertEqual(evaluate(.requiresApproval), .approvalRequired)
        // Turned off in System Settings after it ran: reported, never re-registered.
        XCTAssertEqual(evaluate(.requiresApproval, ever: true), .disabledByUser)
        XCTAssertEqual(evaluate(.notRegistered, ever: true), .disabledByUser)
        XCTAssertEqual(evaluate(.notFound), .incompatibleBuild)
        XCTAssertEqual(evaluate(.unknown), .degraded)
    }

    func testEnabledIsNotHealth() {
        XCTAssertEqual(evaluate(.enabled, .notQueried), .registeredStarting)
        XCTAssertEqual(evaluate(.enabled, .unreachable(detail: "x"), unreachableFor: 5), .registeredStarting)
        XCTAssertEqual(evaluate(.enabled, .unreachable(detail: "x"), unreachableFor: 120), .degraded)
        XCTAssertEqual(evaluate(.enabled, status(.starting)), .registeredStarting)
        XCTAssertEqual(evaluate(.enabled, status(.recovering)), .registeredStarting)
        XCTAssertEqual(evaluate(.enabled, status(.degraded)), .degraded)
        XCTAssertEqual(evaluate(.enabled, status(.legacyConflict)), .legacyConflict)
        XCTAssertEqual(evaluate(.enabled, status(.ready, route: .verified)), .readyLocal)
        XCTAssertEqual(evaluate(.enabled, status(.ready, route: .notConfigured)), .routeUnavailable)
        XCTAssertEqual(evaluate(.enabled, status(.ready, route: .unavailable)), .routeUnavailable)
        XCTAssertEqual(evaluate(.enabled, status(.ready, version: 99)), .incompatibleBuild)
    }

    func testWireCodingIsStable() throws {
        let request = ControlHostRequest(.setAgentGrants, deviceID: "d", enabled: true)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains(#""op":"set_agent_grants""#))
        XCTAssertTrue(json.contains(#""v":1"#))
        XCTAssertEqual(try JSONDecoder().decode(ControlHostRequest.self, from: Data(json.utf8)), request)
        XCTAssertEqual(ControlReadinessState.allCases.map(\.rawValue), [
            "not_enabled", "approval_required", "registered_starting", "ready_local", "route_unavailable",
            "disabled_by_user", "incompatible_build", "degraded", "legacy_conflict"
        ])
    }
}

final class RouteVerificationTests: XCTestCase {
    let key = OriginSigningKey()
    var origin: OriginIdentity { OriginIdentity(originID: ControlID("7d9f1c3a-2b4e-4f60-8a1b-0c2d3e4f5a6b")!, publicJWK: key.publicJWK) }

    private func proofProbe(signedBy signer: OriginSigningKey, originID: ControlID? = nil) -> StubProbe {
        let originID = originID ?? origin.originID
        return StubProbe { url in
            XCTAssertEqual(url.host, "mac.tailnet.ts.net")
            XCTAssertEqual(url.path, "/v1/origin/proof")
            let nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nonce" }?.value ?? ""
            let proof = try OriginProof.sign(originID: originID, nonce: nonce, issuedAt: ControlTimestamp(Date()), key: signer)
            return (200, try JSONCanonicalization.canonicalize(proof.document))
        }
    }

    func testVerifiedRouteAcceptsBareMagicDNSName() async {
        let result = await TailscaleRouteVerifier(probe: proofProbe(signedBy: key)).verify("mac.tailnet.ts.net", origin: origin)
        XCTAssertEqual(result.state, .verified, result.detail ?? "")
        XCTAssertEqual(result.url, "https://mac.tailnet.ts.net")
    }

    func testAnotherOriginKeyIsAMismatch() async {
        let result = await TailscaleRouteVerifier(probe: proofProbe(signedBy: OriginSigningKey()))
            .verify("https://mac.tailnet.ts.net/", origin: origin)
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.reason, .originMismatch)
    }

    func testPreciseFailureReasons() async {
        func verify(_ text: String, _ probe: StubProbe, origin: OriginIdentity?) async -> ControlHostRouteStatus.Reason? {
            await TailscaleRouteVerifier(probe: probe).verify(text, origin: origin).reason
        }
        let name = "mac.tailnet.ts.net"
        let notFound = await verify(name, StubProbe { _ in (404, Data()) }, origin: origin)
        XCTAssertEqual(notFound, .httpStatus)
        let unreachable = await verify(name, StubProbe { _ in throw URLError(.timedOut) }, origin: origin)
        XCTAssertEqual(unreachable, .unreachable)
        let tls = await verify(name, StubProbe { _ in throw URLError(.serverCertificateUntrusted) }, origin: origin)
        XCTAssertEqual(tls, .tlsFailure)
        let foreign = await verify(name, StubProbe { _ in (200, Data("<html>".utf8)) }, origin: origin)
        XCTAssertEqual(foreign, .notShellBroker)
        let publicName = await verify("example.com", StubProbe.silent, origin: origin)
        XCTAssertEqual(publicName, .invalidName)
        let noIdentity = await verify(name, StubProbe.silent, origin: nil)
        XCTAssertEqual(noIdentity, .noOriginIdentity)
    }
}

final class HostSocketDiscoveryTests: XCTestCase {
    let standalone = URL(fileURLWithPath: "/tmp/standalone")
    let bundled = "/tmp/group/control.sock"

    func testExplicitStateDirectoryAlwaysWins() {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: URL(fileURLWithPath: "/tmp/explicit"), standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { _ in true }, exists: { _ in true }
        )
        XCTAssertEqual(resolution, .init(socketPath: "/tmp/explicit/control.sock", source: .explicitStateDirectory))
    }

    func testLiveStandaloneDaemonIsPreferred() {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { $0 == "/tmp/standalone/control.sock" }, exists: { _ in true }
        )
        XCTAssertEqual(resolution.source, .standalone)
    }

    func testBundledHostSocketWhenStandaloneIsNotLive() {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { _ in false }, exists: { $0 == "/tmp/group/control.sock" }
        )
        XCTAssertEqual(resolution, .init(socketPath: bundled, source: .bundledHost))
    }

    func testFallsBackToStandalonePathWhenNothingServes() {
        let resolution = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: bundled,
            isLive: { _ in false }, exists: { _ in false }
        )
        XCTAssertEqual(resolution, .init(socketPath: "/tmp/standalone/control.sock", source: .standaloneFallback))
        let noGroup = HostSocketDiscovery.resolve(
            explicitRoot: nil, standaloneRoot: standalone, bundledSocketPath: nil,
            isLive: { _ in false }, exists: { _ in true }
        )
        XCTAssertEqual(noGroup.source, .standaloneFallback)
    }

    func testDiscoveryAgreesWithTheHost() {
        XCTAssertEqual(HostSocketDiscovery.appGroupIdentifier, ControlHostWire.appGroupIdentifier)
        XCTAssertEqual(HostSocketDiscovery.socketName, ControlHostWire.adapterSocketName)
        XCTAssertTrue(HostSocketDiscovery.bundledSocketPath()?.hasSuffix("/\(ControlHostWire.appGroupIdentifier)/control.sock") ?? false)
    }
}
