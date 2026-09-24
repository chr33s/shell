import Foundation
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

/// `shell-control test-review`: one live round trip through the ordinary
/// publication, review, signed-decision, consume, and receipt pipeline, with
/// the fixed no-operation fixture (spec.control-companion-setup.md 11).
///
/// Success is a matching receipt recorded after an approval signed by the
/// selected reviewer — never just a tap, an accepted decision, or an HTTP
/// success. Nothing is executed: the dispatch records the allowed no-op.
public enum SetupReviewer: String, Sendable, CaseIterable {
    case iphone, watch
}

public enum SetupReviewTestResult: Sendable, Equatable {
    case succeeded(receiptID: ControlID)
    /// Valid outcomes that do not satisfy the setup checkpoint.
    case rejected
    case expired
    case cancelled
    /// The approval was signed by a different reviewer than the one tested.
    case decidedByAnotherReviewer
    case unavailable(String)
    /// The decision was recorded but no receipt was: not a success.
    case receiptNotRecorded(String)

    public var succeeded: Bool { if case .succeeded = self { true } else { false } }

    /// Mirrors `request --wait`: 0/10/11/12/13, and 1 for a missing receipt.
    public var exitCode: Int32 {
        switch self {
        case .succeeded: 0
        case .rejected: 10
        case .expired: 11
        case .cancelled: 12
        case .unavailable, .decidedByAnotherReviewer: 13
        case .receiptNotRecorded: 1
        }
    }

    public var description: String {
        switch self {
        case .succeeded: "Setup test passed: the reviewer approved it and the host recorded the no-operation receipt."
        case .rejected: "The reviewer rejected the setup test. The path works, but the test needs an approval to pass."
        case .expired: "The setup test expired before a decision. Nothing was executed."
        case .cancelled: "The setup test was cancelled."
        case .decidedByAnotherReviewer: "Another reviewer answered the setup test, so the selected device was not tested. Nothing was executed."
        case .unavailable(let reason): "The setup test could not complete: \(reason)"
        case .receiptNotRecorded(let reason): "The decision was recorded, but the receipt was not, so the test did not pass: \(reason)"
        }
    }
}

/// The daemon IPC the test uses. Injectable for tests.
public protocol SetupTestAdapter: Sendable {
    func exchange(_ request: IPCRequest, timeout: TimeInterval) async throws -> IPCResponse
}

extension AdapterClient: SetupTestAdapter {
    public func exchange(_ request: IPCRequest, timeout: TimeInterval) async throws -> IPCResponse {
        try await client.exchangeAsync(request, timeout: timeout)
    }
}

public struct SetupReviewTest: Sendable {
    public let adapter: any SetupTestAdapter
    public let admin: any EnrollmentAdministration
    /// How many times an ambiguous exchange is retried with the same message
    /// and request identity before giving up.
    public var ambiguityRetries = 3

    public init(adapter: any SetupTestAdapter, admin: any EnrollmentAdministration = LiveEnrollmentAdministration()) {
        self.adapter = adapter
        self.admin = admin
    }

    /// Checks that `deviceID` is an enrolled reviewer of the selected kind.
    public func validateReviewer(_ reviewer: SetupReviewer, deviceID: String, loaded: LoadedInstallation) async throws -> EnrolledDevice {
        guard let id = ControlID(deviceID.lowercased()) else { throw ManagementError.invalid("--device-id must be a device UUID") }
        let devices = try await admin.devices(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        guard let device = devices.first(where: { $0.deviceID == id.rawValue }) else {
            throw ManagementError.invalid("no enrolled device has id \(id.rawValue); see shell-control status")
        }
        switch reviewer {
        case .iphone where !device.isIPhone: throw ManagementError.invalid("\(id.rawValue) is not an enrolled iPhone")
        case .watch where !device.isWatch: throw ManagementError.invalid("\(id.rawValue) is not an enrolled Watch reviewer")
        default: return device
        }
    }

    /// Publishes the fixture, waits for a decision, and records the no-op
    /// receipt. `progress` receives short status lines.
    public func run(
        reviewer: SetupReviewer,
        deviceID: String,
        waitTimeout: Int = Int(SetupTestFixture.lifetimeSeconds) + 30,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> SetupReviewTestResult {
        guard let reviewerID = ControlID(deviceID.lowercased()) else { throw ManagementError.invalid("--device-id must be a device UUID") }
        let hello = try await send(.hello, capability: nil, body: .object([
            "protocol": .string(ServiceCapabilities.protocolName),
            "adapter": .string(SetupTestFixture.adapter),
            "job_label": .string(SetupTestFixture.jobLabel),
            "capabilities": JSONValue(strings: [ControlFeature.consume]),
            "operation_schemas": JSONValue(strings: [ExecOperation.schema])
        ]), timeout: 8)
        var helloReader = try JSONReader(hello)
        let capability = try helloReader.string("run_capability", maxLength: 128)

        // The request identity is chosen here, so an ambiguous publication is
        // retried as the same request — never a second approval.
        let requestID = ControlID.random()
        guard var body = SetupTestFixture.requestBody(forWatch: reviewer == .watch).objectValue else {
            throw ManagementError.corrupt("setup-test fixture is malformed")
        }
        body["request_id"] = JSONValue(requestID)
        let created = try await send(.approvalRequest, capability: capability, body: .object(body), timeout: 8)
        var createdReader = try JSONReader(created)
        let requestHash = try createdReader.string("request_hash", maxLength: 80)
        progress("Setup test sent. Approve \"\(SetupTestFixture.summary)\" on the \(reviewer == .watch ? "Apple Watch" : "iPhone").")

        let waited: JSONValue
        do {
            waited = try await send(.approvalWait, capability: capability, body: .object([
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash),
                "timeout_seconds": .number(.int(Int64(waitTimeout)))
            ]), timeout: TimeInterval(waitTimeout + 30))
        } catch is CancellationError {
            await withdraw(requestID: requestID, requestHash: requestHash, capability: capability)
            return .cancelled
        } catch let error as SignalCancellation {
            await withdraw(requestID: requestID, requestHash: requestHash, capability: capability)
            throw error
        }
        let outcome = try ApprovalWaitOutcome(json: waited)
        switch outcome {
        case .rejected: return .rejected
        case .expired: return .expired
        case .cancelled: return .cancelled
        case .unavailable(let reason): return .unavailable(reason)
        case .approved(let permit):
            let decidedBy = Self.signer(of: permit.decisionJWS)
            let matches = decidedBy == reviewerID
            // The dispatch implementation records the allowed no-operation
            // result; nothing described by the fixture is executed.
            let receiptBody = JSONWriter.object([
                "result": .string(matches ? ReceiptResult.applied.rawValue : ReceiptResult.notApplied.rawValue),
                "request_id": JSONValue(requestID),
                "decision_id": JSONValue(permit.decisionID),
                "consume_id": JSONValue(permit.consumeID),
                "request_hash": .string(permit.requestHash),
                "reason_code": .string(matches ? SetupTestFixture.receiptReason : "setup_test_other_reviewer")
            ])
            let receipt: JSONValue
            do {
                receipt = try await send(.receipt, capability: capability, body: receiptBody, timeout: 8)
            } catch {
                return .receiptNotRecorded(String(describing: error))
            }
            guard matches else { return .decidedByAnotherReviewer }
            var receiptReader = try JSONReader(receipt)
            guard let receiptID = try? receiptReader.id("receipt_id") else {
                return .receiptNotRecorded("the host returned no receipt identity")
            }
            return .succeeded(receiptID: receiptID)
        }
    }

    /// Sends one IPC message, retransmitting the identical message (same ID
    /// and body) when the exchange is ambiguous, so the daemon's
    /// retransmission record answers instead of acting twice.
    private func send(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let request = IPCRequest(messageID: .random(), type: type, runCapability: capability, body: body)
        var lastError: (any Error)?
        for _ in 0...ambiguityRetries {
            try Task.checkCancellation()
            do {
                let response = try await adapter.exchange(request, timeout: timeout)
                guard response.ok else {
                    throw ManagementError.unavailable(response.errorMessage ?? "\(type.rawValue) was rejected")
                }
                return response.body
            } catch let error as ManagementError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SignalCancellation {
                throw error
            } catch {
                lastError = error
            }
        }
        throw ManagementError.unavailable("\(type.rawValue) did not complete: \(lastError.map { String(describing: $0) } ?? "no response")")
    }

    /// Best-effort withdrawal of an abandoned test, outside the cancelled task.
    private func withdraw(requestID: ControlID, requestHash: String, capability: String) async {
        let adapter = adapter
        await Task.detached {
            _ = try? await adapter.exchange(IPCRequest(messageID: .random(), type: .approvalWithdraw, runCapability: capability, body: .object([
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash)
            ])), timeout: 8)
        }.value
    }

    /// The `kid` of a decision JWS: the device whose registered key the
    /// broker verified it under. Read only to tell which reviewer answered.
    static func signer(of jws: String) -> ControlID? {
        guard let header = jws.split(separator: ".").first,
              let data = Base64URL.decode(String(header)),
              let value = try? JSONValue.parse(data) else { return nil }
        return value["kid"]?.stringValue.flatMap { ControlID($0) }
    }
}
