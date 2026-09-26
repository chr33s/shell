import Foundation
import ShellControlProtocol

// Portable diagnostic models shared by the Mac CLI and the iPhone and Watch
// presentation layers (docs/specs/control-setup.md section 9).
//
// A diagnostic snapshot is evidence for display, never authorization: a
// green check does not let anything decide, and a stale or failed one does
// not revoke anything. Actual review always runs the live protocol checks.

public enum DiagnosticState: String, Sendable, Hashable, CaseIterable {
    case pass, warn, fail, unknown
    case notConfigured = "not_configured"
    case disabled
}

public enum DiagnosticSeverity: String, Sendable, Hashable, CaseIterable {
    case info, warning, error
}

/// Which device made the observation. One vantage never claims to have
/// inspected another device's private state.
public enum DiagnosticVantage: String, Sendable, Hashable, CaseIterable {
    case mac, iphone, watch
}

/// The independently-ready capabilities a check can gate.
public enum DiagnosticFeature: String, Sendable, Hashable, CaseIterable {
    /// The Mac's own services and private route.
    case host
    case iphoneReview = "iphone_review"
    case watchReview = "watch_review"
    case remoteAlerts = "remote_alerts"
}

/// Stable check codes. Unknown causes stay unknown: there is no code for a
/// guess.
public enum DiagnosticCode: String, Sendable, Hashable, CaseIterable {
    // Mac
    case installationPresent = "installation_present"
    case installationMissing = "installation_missing"
    case installationUnreadable = "installation_unreadable"
    case bundleVerified = "bundle_verified"
    case bundleUnverified = "bundle_unverified"
    case tailscaleConnected = "tailscale_connected"
    case tailscaleMissing = "tailscale_missing"
    case tailscaleNotConnected = "tailscale_not_connected"
    case tailscaleStatusUnknown = "tailscale_status_unknown"
    case routeConfigured = "route_configured"
    case routeConfigurationIncomplete = "route_configuration_incomplete"
    case loopbackOnly = "loopback_only"
    case serveActive = "serve_active"
    case serveConflict = "serve_conflict"
    case servePublicExposure = "serve_public_exposure"
    case serveStatusUnknown = "serve_status_unknown"
    case hostRunning = "host_running"
    case hostStoppedByUser = "host_stopped_by_user"
    case managementOperationIncomplete = "management_operation_incomplete"
    case brokerReady = "broker_ready"
    case brokerUnavailable = "broker_unavailable"
    case daemonReady = "daemon_ready"
    case daemonUnavailable = "daemon_unavailable"
    case originKeyPresent = "origin_key_present"
    case originKeyMissing = "origin_key_missing"
    case originKeyMismatch = "origin_key_mismatch"
    case iphoneEnrolled = "iphone_enrolled"
    case iphoneNotEnrolled = "iphone_not_enrolled"
    case iphoneEnrollmentPending = "iphone_enrollment_pending"
    case enrollmentUnknown = "enrollment_unknown"
    case watchEnrolled = "watch_enrolled"
    case watchNotConfigured = "watch_not_configured"
    case alertsConfigured = "alerts_configured"
    case alertsNotConfigured = "alerts_not_configured"
    case alertsDirectAPNs = "alerts_direct_apns"
    // iPhone and Watch
    case notPaired = "not_paired"
    case originVerified = "origin_verified"
    case routeReachable = "route_reachable"
    case routeUnreachable = "route_unreachable"
    case reviewerReady = "reviewer_ready"
    case reviewerRevoked = "reviewer_revoked"
    case notChecked = "not_checked"
    case watchPending = "watch_pending"
    case watchReady = "watch_ready"
    case watchGatewayUnreachable = "watch_gateway_unreachable"
    case watchAppNotInstalled = "watch_app_not_installed"
    case alertsDisabledByUser = "alerts_disabled_by_user"
    case notificationDisablePending = "notification_disable_pending"
    case notificationDisableNeedsHostUpdate = "notification_disable_needs_host_update"
    case notificationRegistrationFailed = "notification_registration_failed"
    case notificationRegistrationPending = "notification_registration_pending"
    case notificationPermissionDenied = "notification_permission_denied"
    case alertsRelayUnavailable = "alerts_relay_unavailable"
}

/// Corrective actions are local, allowlisted identifiers — never a command
/// string supplied by another device. Diagnostics never run them; they are
/// offered for the user to choose.
public enum DiagnosticAction: String, Sendable, Hashable, CaseIterable {
    case installTailscale = "install_tailscale"
    case connectTailscale = "connect_tailscale"
    case enableMagicDNS = "enable_magicdns"
    case runSetup = "run_setup"
    case startServices = "start_services"
    case viewLogs = "view_logs"
    case restartServices = "restart_services"
    case disableFunnel = "disable_funnel"
    case resolveServeConflict = "resolve_serve_conflict"
    case recoverOriginIdentity = "recover_origin_identity"
    case confirmEnrollment = "confirm_enrollment"
    case pairIPhone = "pair_iphone"
    case pairAgain = "pair_again"
    case checkConnection = "check_connection"
    case checkTailscaleOnIPhone = "check_tailscale_on_iphone"
    case addWatch = "add_watch"
    case openWatchApp = "open_watch_app"
    case retryAlertDisable = "retry_alert_disable"
    case updateHost = "update_host"
    case openNotificationSettings = "open_notification_settings"
    case testReview = "test_review"

    /// What the Mac CLI prints for this action. Fixed text, chosen here.
    public var macCommand: String? {
        switch self {
        case .installTailscale: "install Tailscale from https://tailscale.com/download/mac, then shell-control setup --guided"
        case .connectTailscale: "tailscale up"
        case .enableMagicDNS: "enable MagicDNS and HTTPS in the Tailscale admin console"
        case .runSetup: "shell-control setup --guided"
        case .startServices: "shell-control up"
        case .viewLogs: "shell-control logs"
        case .restartServices: "shell-control restart all"
        case .disableFunnel: "tailscale funnel 443 off"
        case .resolveServeConflict: "tailscale serve status  (move the other app's HTTPS 443 handler, then rerun setup)"
        case .recoverOriginIdentity: "shell-control setup --reset-origin-key  (every device must pair again)"
        case .confirmEnrollment: "shell-control pair --watch"
        case .pairIPhone: "shell-control pair"
        case .pairAgain: "shell-control pair"
        case .testReview: "shell-control test-review --reviewer iphone --device-id <ID>"
        case .addWatch: "open Shell on the Apple Watch, then shell-control pair --watch"
        case .updateHost: "update the Shell Control host tools, then shell-control setup"
        case .checkConnection, .checkTailscaleOnIPhone, .openWatchApp, .retryAlertDisable, .openNotificationSettings: nil
        }
    }
}

public struct DiagnosticCheck: Sendable, Hashable, Identifiable {
    public let id: String
    public let code: DiagnosticCode
    public let state: DiagnosticState
    public let severity: DiagnosticSeverity
    public let requiredFor: [DiagnosticFeature]
    /// How the evidence was obtained, e.g. `authenticated_origin_proof`.
    public let source: String
    /// When the evidence was observed; nil when nothing was observed.
    public let observedAt: ControlTimestamp?
    /// A sanitized explanation. Never a token, key, or approval content.
    public let summary: String
    public let action: DiagnosticAction?

    public init(
        id: String,
        code: DiagnosticCode,
        state: DiagnosticState,
        severity: DiagnosticSeverity? = nil,
        requiredFor: [DiagnosticFeature] = [],
        source: String,
        observedAt: ControlTimestamp?,
        summary: String,
        action: DiagnosticAction? = nil
    ) {
        self.id = id
        self.code = code
        self.state = state
        self.severity = severity ?? Self.defaultSeverity(state, required: !requiredFor.isEmpty)
        self.requiredFor = requiredFor
        self.source = source
        self.observedAt = observedAt
        self.summary = DisplaySanitizer.sanitize(summary, maxScalars: 400).text
        self.action = action
    }

    static func defaultSeverity(_ state: DiagnosticState, required: Bool) -> DiagnosticSeverity {
        switch state {
        case .pass, .notConfigured, .disabled: .info
        case .warn: .warning
        case .unknown: required ? .warning : .info
        case .fail: required ? .error : .warning
        }
    }

    /// Connectivity evidence older than this is shown as "Last checked"
    /// rather than as current (docs/specs/control-setup.md 9.3).
    public static let freshness: TimeInterval = 30

    public func isFresh(at now: Date, maxAge: TimeInterval = DiagnosticCheck.freshness) -> Bool {
        guard let observedAt else { return false }
        return now.timeIntervalSince(observedAt.date) <= maxAge
    }

    public var json: JSONValue {
        .object([
            "id": .string(id),
            "code": .string(code.rawValue),
            "state": .string(state.rawValue),
            "severity": .string(severity.rawValue),
            "required_for": JSONValue(strings: requiredFor.map(\.rawValue)),
            "source": .string(source),
            "observed_at": observedAt.map { JSONValue($0) } ?? .null,
            "summary": .string(summary),
            "action": action.map { .string($0.rawValue) } ?? .null
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        id = try reader.string("id", maxLength: 64)
        let codeText = try reader.string("code", maxLength: 64)
        guard let code = DiagnosticCode(rawValue: codeText) else { throw ValidationError.unsupported("code \(codeText)") }
        self.code = code
        let stateText = try reader.string("state", maxLength: 32)
        guard let state = DiagnosticState(rawValue: stateText) else { throw ValidationError.unsupported("state \(stateText)") }
        self.state = state
        let severityText = try reader.string("severity", maxLength: 16)
        guard let severity = DiagnosticSeverity(rawValue: severityText) else { throw ValidationError.unsupported("severity \(severityText)") }
        self.severity = severity
        requiredFor = try reader.stringArray("required_for", maxCount: 8, maxLength: 32).map { text in
            guard let feature = DiagnosticFeature(rawValue: text) else { throw ValidationError.unsupported("feature \(text)") }
            return feature
        }
        source = try reader.string("source", maxLength: 64)
        observedAt = reader.optionalValue("observed_at")?.stringValue.flatMap { ControlTimestamp(rfc3339: $0) }
        summary = try reader.string("summary", maxLength: 1024)
        let actionValue = reader.optionalValue("action")
        if let text = actionValue?.stringValue {
            guard let action = DiagnosticAction(rawValue: text) else { throw ValidationError.unsupported("action \(text)") }
            self.action = action
        } else {
            action = nil
        }
        try reader.rejectUnknownMembers()
    }
}

/// `shell-control-diagnostics/1`: every check one vantage made in one pass.
public struct DiagnosticReport: Sendable, Hashable {
    public static let schema = "shell-control-diagnostics/1"

    public let generatedAt: ControlTimestamp
    public let vantage: DiagnosticVantage
    public let checks: [DiagnosticCheck]

    public init(generatedAt: ControlTimestamp, vantage: DiagnosticVantage, checks: [DiagnosticCheck]) {
        self.generatedAt = generatedAt
        self.vantage = vantage
        self.checks = checks
    }

    public func check(_ id: String) -> DiagnosticCheck? { checks.first { $0.id == id } }

    /// A feature is ready only when every check it requires passed. Missing
    /// evidence is `unknown`, never a pass; a failure outranks it.
    public func readiness(for feature: DiagnosticFeature) -> DiagnosticState {
        let required = checks.filter { $0.requiredFor.contains(feature) }
        guard !required.isEmpty else { return .unknown }
        if required.contains(where: { $0.state == .fail }) { return .fail }
        if required.contains(where: { $0.state == .notConfigured }) { return .notConfigured }
        if required.contains(where: { $0.state == .disabled }) { return .disabled }
        if required.contains(where: { $0.state == .unknown }) { return .unknown }
        if required.contains(where: { $0.state == .warn }) { return .warn }
        return .pass
    }

    /// Whether every check required for `feature` passed with evidence no
    /// older than `maxAge` — what `doctor --check` exits on.
    public func isReady(_ feature: DiagnosticFeature, at now: Date, maxAge: TimeInterval) -> Bool {
        let required = checks.filter { $0.requiredFor.contains(feature) }
        return !required.isEmpty && required.allSatisfy { $0.state == .pass && $0.isFresh(at: now, maxAge: maxAge) }
    }

    public var json: JSONValue {
        .object([
            "schema": .string(Self.schema),
            "generated_at": JSONValue(generatedAt),
            "vantage": .string(vantage.rawValue),
            "checks": .array(checks.map(\.json))
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.string("schema", maxLength: 64) == Self.schema else {
            throw ValidationError.unsupported("diagnostics schema")
        }
        generatedAt = try reader.timestamp("generated_at")
        let vantageText = try reader.string("vantage", maxLength: 16)
        guard let vantage = DiagnosticVantage(rawValue: vantageText) else { throw ValidationError.unsupported("vantage \(vantageText)") }
        self.vantage = vantage
        guard let items = try reader.value("checks").arrayValue, items.count <= 64 else {
            throw ValidationError.invalid("checks", "must be a bounded array")
        }
        checks = try items.map(DiagnosticCheck.init(json:))
        try reader.rejectUnknownMembers()
    }
}

// MARK: - Export

/// Removes secrets, content, and identifying names from diagnostic text
/// before it leaves the device (docs/specs/control-setup.md section 10).
///
/// It is deliberately aggressive: a redacted export that loses a detail is
/// fine, a leaked token is not. Identifiers are pseudonymised consistently
/// within one export so correlated rows still line up.
public final class DiagnosticRedactor: @unchecked Sendable {
    private var pseudonyms: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    private static let rules: [(NSRegularExpression, String)] = {
        func rule(_ pattern: String, _ replacement: String) -> (NSRegularExpression, String) {
            // The patterns are literals; a bad one is a programming error.
            (DiagnosticRedactor.regex(pattern, options: [.caseInsensitive]), replacement)
        }
        return [
            // Links of any scheme, including shell-control:// pairing links.
            rule(#"\b[a-z][a-z0-9+.\-]*://[^\s"'<>]+"#, "<url>"),
            rule(#"\bAuthorization:\s*\S+(\s+\S+)?"#, "Authorization: <redacted>"),
            rule(#"\b(Bearer|Admin|Origin)\s+[A-Za-z0-9._~+/=:\-]+"#, "$1 <redacted>"),
            rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<account>"),
            rule(#"\b[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.ts\.net\b"#, "<tailnet-host>"),
            // Any absolute path of two or more segments: state directories,
            // temporary folders, volumes, and home directories alike.
            rule(#"(?<![A-Za-z0-9_.:~\-])/(?:[^\s/"'<>]+/)+[^\s/"'<>]*"#, "<path>"),
            rule(#"-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----"#, "<key>"),
            rule(#"SHA256:[A-Za-z0-9+/=_\-]+"#, "SHA256:<fingerprint>"),
            // Display fingerprints and user codes.
            rule(#"\b[0-9A-Z]{4}(-[0-9A-Z]{4}){1,}\b"#, "<code>"),
            // Long opaque tokens: base64url/hex runs containing both letters
            // and digits. Check codes (letters and underscores) survive.
            rule(#"(?<![A-Za-z0-9_\-])(?=[A-Za-z0-9_\-]*[0-9])(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}(?![A-Za-z0-9_\-])"#, "<redacted>")
        ]
    }()

    private static let uuid = regex(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, options: [])

    /// A literal pattern that does not compile is a programmer mistake.
    private static func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("invalid diagnostic redaction pattern: \(pattern)")
        }
        return expression
    }

    /// A stable per-export stand-in for an identifier.
    public func pseudonym(_ identifier: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = identifier.lowercased()
        if let existing = pseudonyms[key] { return existing }
        let next = "id-\(pseudonyms.count + 1)"
        pseudonyms[key] = next
        return next
    }

    public func redact(_ text: String) -> String {
        var result = text
        // Identifiers first, so a UUID is pseudonymised rather than caught by
        // a broader rule.
        let range = NSRange(result.startIndex..., in: result)
        let matches = Self.uuid.matches(in: result, range: range).reversed()
        for match in matches {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: pseudonym(String(result[swiftRange])))
        }
        for (expression, replacement) in Self.rules {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement
            )
        }
        return result
    }
}

/// An explicit, local diagnostic export: allowlisted structured fields only,
/// no raw logs, and nothing is uploaded (docs/specs/control-setup.md 10).
public enum DiagnosticExport {
    public static let schema = "shell-control-diagnostics-export/1"

    public static func document(
        reports: [DiagnosticReport],
        applicationVersion: String,
        osVersion: String,
        redactor: DiagnosticRedactor = DiagnosticRedactor()
    ) -> JSONValue {
        .object([
            "schema": .string(schema),
            "application_version": .string(redactor.redact(String(applicationVersion.prefix(64)))),
            "os_version": .string(redactor.redact(String(osVersion.prefix(64)))),
            "reports": .array(reports.map { report in
                .object([
                    "vantage": .string(report.vantage.rawValue),
                    "generated_at": JSONValue(report.generatedAt),
                    "checks": .array(report.checks.map { check in
                        .object([
                            "id": .string(check.id),
                            "code": .string(check.code.rawValue),
                            "state": .string(check.state.rawValue),
                            "severity": .string(check.severity.rawValue),
                            "required_for": JSONValue(strings: check.requiredFor.map(\.rawValue)),
                            "observed_at": check.observedAt.map { JSONValue($0) } ?? .null,
                            "summary": .string(redactor.redact(check.summary)),
                            "action": check.action.map { .string($0.rawValue) } ?? .null
                        ])
                    })
                ])
            })
        ])
    }

    /// Pretty, stable bytes for a file the user saves and can read first.
    public static func data(
        reports: [DiagnosticReport],
        applicationVersion: String,
        osVersion: String
    ) throws -> Data {
        let value = document(reports: reports, applicationVersion: applicationVersion, osVersion: osVersion)
        let object = try JSONSerialization.jsonObject(with: try JSONCanonicalization.canonicalize(value))
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: - Bounded passes

/// Runs one diagnostic pass at a time: a second request while one is in
/// flight joins it instead of starting duplicate probes, and the whole pass
/// is bounded (docs/specs/control-setup.md section 9.3). There is no
/// loop here; passes run on screen open, explicit refresh, and after setup
/// steps only.
public actor DiagnosticPassCoordinator {
    /// The default user-visible budget for one pass.
    public static let passBudget: Duration = .seconds(20)

    private var inFlight: Task<DiagnosticReport, Never>?
    private var generation = 0

    public init() {}

    public func run(
        budget: Duration = DiagnosticPassCoordinator.passBudget,
        _ pass: @escaping @Sendable () async -> DiagnosticReport,
        timedOut: @escaping @Sendable () -> DiagnosticReport
    ) async -> DiagnosticReport {
        if let inFlight { return await inFlight.value }
        generation += 1
        let mine = generation
        let task = Task<DiagnosticReport, Never> {
            await withProbeDeadline(budget, pass) ?? timedOut()
        }
        inFlight = task
        let report = await task.value
        if generation == mine { inFlight = nil }
        return report
    }

    /// Abandons an in-flight pass whose screen went away.
    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
    }
}

/// Runs one probe with its own deadline. A probe that does not answer in
/// time is `nil` — the caller records `unknown`, not a guessed result. The
/// deadline holds even for a probe that ignores cancellation: the probe is
/// cancelled and abandoned, never awaited past the deadline.
public func withProbeDeadline<T: Sendable>(
    _ deadline: Duration,
    _ probe: @escaping @Sendable () async -> T
) async -> T? {
    let gate = ProbeGate<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let work = Task { gate.resume(await probe()) }
            gate.install(continuation, work: work)
            Task {
                try? await Task.sleep(for: deadline)
                gate.resume(nil)
            }
        }
    } onCancel: {
        gate.resume(nil)
    }
}

/// Resumes one continuation exactly once, with whichever of the result,
/// the deadline, or cancellation comes first. A lost probe is cancelled.
private final class ProbeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var work: Task<Void, Never>?
    private var outcome: T??

    func install(_ continuation: CheckedContinuation<T?, Never>, work: Task<Void, Never>) {
        let early: T?? = lock.withLock {
            self.work = work
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let early {
            if early == nil { work.cancel() }
            continuation.resume(returning: early)
        }
    }

    func resume(_ value: T?) {
        let (continuation, work): (CheckedContinuation<T?, Never>?, Task<Void, Never>?) = lock.withLock {
            guard outcome == nil else { return (nil, nil) }
            outcome = .some(value)
            defer { self.continuation = nil }
            return (self.continuation, value == nil ? self.work : nil)
        }
        work?.cancel()
        continuation?.resume(returning: value)
    }
}
