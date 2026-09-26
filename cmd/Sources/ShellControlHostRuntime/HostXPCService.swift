import Foundation
import ShellControlProtocol
import XPC

/// Decides whether one XPC message comes from the Shell app.
///
/// The production check is ``CodeSigningPeerAuthorizer``: the system evaluates
/// a code-signing requirement against the sender's audit token, per message,
/// so a PID race cannot substitute another process. An App Group is not
/// authorization (docs/specs/agent-relay.md section 18.6, A45). Tests inject their
/// own authorizer; the library ships no bypass.
public protocol HostPeerAuthorizer: Sendable {
    func authorize(_ message: XPCReceivedMessage) -> Bool
}

public struct CodeSigningPeerAuthorizer: HostPeerAuthorizer {
    public let requirement: XPCPeerRequirement

    public init(requirement: XPCPeerRequirement) {
        self.requirement = requirement
    }

    /// Signed by this host's team, with the Shell app's signing identifier.
    public static let shellApp = CodeSigningPeerAuthorizer(
        requirement: .isFromSameTeam(andMatchesSigningIdentifier: ControlHostWire.appBundleIdentifier)
    )

    public func authorize(_ message: XPCReceivedMessage) -> Bool {
        message.senderSatisfies(requirement)
    }
}

/// The host's side of the owned UI boundary: a launchd-published Mach
/// service inside the App Group namespace, bounded to the operations of
/// ``ControlHostRequest``. Anything else is rejected (spec 19.6).
public final class HostXPCService: Sendable {
    let runtime: HostRuntime
    let authorizer: any HostPeerAuthorizer
    let log: @Sendable (String) -> Void
    private let replyQueue = DispatchQueue(label: "dev.chr33s.shell.control-host.xpc-replies", attributes: .concurrent)

    public init(runtime: HostRuntime, authorizer: any HostPeerAuthorizer, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.runtime = runtime
        self.authorizer = authorizer
        self.log = log
    }

    /// Publishes the Mach service. The listener-level requirement makes the
    /// system refuse a session from any other code before a message arrives;
    /// ``authorizer`` then re-checks every message.
    public func listen(machService: String = ControlHostWire.machServiceName, requirement: XPCPeerRequirement?) throws -> XPCListener {
        let handler: @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision = { [self] request in
            accept(request)
        }
        if let requirement {
            return try XPCListener(service: machService, requirement: requirement, incomingSessionHandler: handler)
        }
        return try XPCListener(service: machService, incomingSessionHandler: handler)
    }

    /// An anonymous listener for tests; its endpoint is handed to a session
    /// in the same process.
    public func anonymousListener() -> XPCListener {
        XPCListener { [self] request in accept(request) }
    }

    func accept(_ request: XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        request.accept { [self] (message: XPCReceivedMessage) -> (any Encodable)? in
            receive(message)
        }
    }

    /// Replies are handed off to a private queue that waits for the runtime
    /// actor, so XPC's delivery queue and the cooperative pool never block.
    func receive(_ message: XPCReceivedMessage) -> (any Encodable)? {
        guard authorizer.authorize(message) else {
            log("rejected a message from an unauthorized peer")
            return ControlHostReply.failure(.unauthorizedPeer, "this peer is not the Shell app")
        }
        let request: ControlHostRequest
        do {
            request = try message.decode(as: ControlHostRequest.self)
        } catch {
            return ControlHostReply.failure(.unsupportedOperation, "unreadable request")
        }
        // `handoffReply` returns immediately so XPC's delivery queue is not
        // blocked. The task owns the message from here and replies exactly once;
        // joining it with a semaphore would block `replyQueue` across the await.
        let pending = PendingReply(message)
        return message.handoffReply(to: replyQueue) { [runtime] in
            Task {
                pending.send(await HostXPCService.dispatch(request, runtime: runtime))
            }
        }
    }

    /// Routes one request. Pure over the runtime, so it is tested directly.
    public static func dispatch(_ request: ControlHostRequest, runtime: HostRuntime) async -> ControlHostReply {
        guard request.version == ControlHostWire.protocolVersion else {
            return .failure(.unsupportedVersion, "host protocol \(ControlHostWire.protocolVersion), request \(request.version)")
        }
        guard let operation = ControlHostRequest.Operation(rawValue: request.operation) else {
            return .failure(.unsupportedOperation, "unsupported operation \(request.operation.prefix(64))")
        }
        do {
            switch operation {
            case .status:
                return ControlHostReply(status: await runtime.status())
            case .mintPairing:
                return ControlHostReply(invitation: try await runtime.mintPairingInvitation())
            case .listDevices:
                return ControlHostReply(devices: try await runtime.listDevices())
            case .listPendingPairings:
                return ControlHostReply(pending: try await runtime.listPendingPairings())
            case .confirmPairing:
                guard let code = request.userCode, let approve = request.enabled else {
                    return .failure(.invalidArgument, "user_code and enabled are required")
                }
                try await runtime.confirmPairing(userCode: code, approve: approve)
                return ControlHostReply(pending: try await runtime.listPendingPairings())
            case .revokeDevice:
                guard let id = request.deviceID else { return .failure(.invalidArgument, "device_id is required") }
                try await runtime.revokeDevice(id)
                return ControlHostReply(devices: try await runtime.listDevices())
            case .setAgentGrants:
                guard let id = request.deviceID, let enabled = request.enabled else {
                    return .failure(.invalidArgument, "device_id and enabled are required")
                }
                try await runtime.setAgentGrants(id, enabled: enabled)
                return ControlHostReply(devices: try await runtime.listDevices())
            case .setRoute:
                guard let route = request.route else { return .failure(.invalidArgument, "route is required") }
                return ControlHostReply(route: try await runtime.setRoute(route))
            case .verifyRoute:
                return ControlHostReply(route: await runtime.verifyRoute())
            case .stopAcceptingWork:
                try await runtime.stopAcceptingWork()
                return ControlHostReply(status: await runtime.status())
            case .resumeAcceptingWork:
                try await runtime.resumeAcceptingWork()
                return ControlHostReply(status: await runtime.status())
            }
        } catch let error as HostOperationError {
            return .failure(error.code, error.message)
        } catch let error as ControlError {
            switch error.code {
            case .notFound: return .failure(.notFound, error.message)
            case .invalidPayload: return .failure(.invalidArgument, error.message)
            default: return .failure(.failed, "\(error.code.rawValue): \(error.message)")
            }
        } catch {
            return .failure(.failed, "\(error)")
        }
    }
}

/// `XPCReceivedMessage` is not Sendable; it is replied to exactly once, from
/// the task that owns it.
private final class PendingReply: @unchecked Sendable {
    private let message: XPCReceivedMessage
    init(_ message: XPCReceivedMessage) { self.message = message }
    func send(_ reply: ControlHostReply) { message.reply(reply) }
}
