import Foundation
import ShellControlClient
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

/// `shell-control doctor`: read-only evidence about this Mac's side of Shell
/// Control (spec.control-companion-setup.md sections 12 and 13).
///
/// The Mac observes installation, local services, and Serve configuration.
/// It never claims an iPhone or Watch can reach it: enrolled is not reachable,
/// and a configured relay is not a delivered notification. Nothing here
/// creates requests, enrolls devices, or changes state.
extension LifecycleCoordinator {
    public func diagnose(enrollment admin: any EnrollmentAdministration = LiveEnrollmentAdministration()) async -> DiagnosticReport {
        let now = ControlTimestamp(Date())
        func check(_ id: String, _ code: DiagnosticCode, _ state: DiagnosticState, _ requiredFor: [DiagnosticFeature],
                   source: String, _ summary: String, action: DiagnosticAction? = nil, observed: Bool = true) -> DiagnosticCheck {
            DiagnosticCheck(id: id, code: code, state: state, requiredFor: requiredFor, source: source,
                            observedAt: observed ? now : nil, summary: summary, action: action)
        }
        let host: [DiagnosticFeature] = [.host]

        guard store.exists() else {
            return DiagnosticReport(generatedAt: now, vantage: .mac, checks: [
                check("installation", .installationMissing, .notConfigured, host + [.iphoneReview],
                      source: "installation_state", "Shell Control is not set up on this Mac. Terminal, SSH, and tmux do not need it.",
                      action: .runSetup)
            ])
        }
        let loaded: LoadedInstallation
        do { loaded = try store.load() } catch {
            return DiagnosticReport(generatedAt: now, vantage: .mac, checks: [
                check("installation", .installationUnreadable, .fail, host, source: "installation_state",
                      "The installation state could not be read: \(error)", action: .runSetup)
            ])
        }
        var checks: [DiagnosticCheck] = [
            check("installation", .installationPresent, .pass, host, source: "installation_state",
                  "Installed in \(loaded.installation.addressMode.rawValue) mode.")
        ]

        // The invoking CLI's bundle. Not required: a development build has no
        // release manifest, and the installed services do not depend on it.
        do {
            let manifest = try installer.validateBundle()
            checks.append(manifest.releaseID == loaded.installation.releaseID
                ? check("bundle", .bundleVerified, .pass, [], source: "release_manifest", "This CLI matches the installed release.")
                : check("bundle", .bundleUnverified, .warn, [], source: "release_manifest",
                        "This CLI is a different release from the installed services.", action: .runSetup))
        } catch {
            checks.append(check("bundle", .bundleUnverified, .warn, [], source: "release_manifest",
                                "This CLI is not a verified release bundle: \(error)", action: .runSetup))
        }

        let stopped = loaded.installation.desiredState == .stopped
        checks.append(stopped
            ? check("host_intent", .hostStoppedByUser, .disabled, host, source: "persisted_intent",
                    "Control services are stopped because you stopped them. They stay stopped until you start them.",
                    action: .startServices)
            : check("host_intent", .hostRunning, .pass, host, source: "persisted_intent", "Control services are set to run."))
        if let operation = loaded.runtime.operation {
            checks.append(check("management_operation", .managementOperationIncomplete, .warn, [], source: "runtime_state",
                                "An interrupted \(operation.command) operation will be reconciled by the next setup or up.",
                                action: .runSetup))
        }

        let status = await status(loaded: loaded)
        for component in Component.allCases {
            let observation = status.components[component.rawValue]
            let ready = observation?.state == "ready"
            let code: DiagnosticCode = component == .broker
                ? (ready ? .brokerReady : .brokerUnavailable)
                : (ready ? .daemonReady : .daemonUnavailable)
            let state: DiagnosticState = ready ? .pass : (stopped ? .disabled : .fail)
            let detail = observation?.reason.map { ": \($0)" } ?? ""
            let summary = ready ? "The \(component.rawValue) answered its local health probe."
                : (stopped ? "The \(component.rawValue) is stopped by your choice."
                   : "The \(component.rawValue) did not answer its local health probe\(detail).")
            checks.append(check(component.rawValue, code, state, host, source: "local_health_probe", summary,
                                action: ready ? nil : (stopped ? .startServices : .viewLogs)))
        }

        checks.append(originCheck(loaded, now: now))
        if loaded.installation.addressMode == .tailscale {
            checks.append(contentsOf: await tailnetChecks(loaded, now: now))
        } else {
            checks.append(check("route", .loopbackOnly, .warn, [], source: "installation_state",
                                "Loopback mode is for the simulator: physical devices cannot reach this Mac."))
        }

        let brokerReady = status.components["broker"]?.state == "ready"
        let enrolled: [EnrolledDevice]?
        let pending: [PendingEnrollment]?
        if brokerReady {
            enrolled = try? await admin.devices(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
            pending = try? await admin.pending(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        } else {
            enrolled = nil
            pending = nil
        }
        checks.append(contentsOf: enrollmentChecks(enrolled: enrolled, pending: pending, now: now))
        checks.append(alertCheck(loaded.installation.push, enrolled: enrolled, now: now))
        return DiagnosticReport(generatedAt: now, vantage: .mac, checks: checks)
    }

    private func originCheck(_ loaded: LoadedInstallation, now: ControlTimestamp) -> DiagnosticCheck {
        let required: [DiagnosticFeature] = [.host, .iphoneReview, .watchReview]
        let keyURL = loaded.paths.originKey
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            let summary = loaded.secrets.originKeyFingerprint == nil
                ? "No origin signing key exists yet; setup creates it."
                : "The origin signing key is missing. Shell will not silently mint a new identity."
            return DiagnosticCheck(id: "origin_key", code: .originKeyMissing, state: .fail, requiredFor: required,
                                   source: "origin_key_file", observedAt: now, summary: summary,
                                   action: loaded.secrets.originKeyFingerprint == nil ? .runSetup : .recoverOriginIdentity)
        }
        do {
            let fingerprint = OriginIdentity.fingerprint(of: try OriginKeyFile.load(keyURL).publicJWK)
            if let recorded = loaded.secrets.originKeyFingerprint, recorded != fingerprint {
                return DiagnosticCheck(id: "origin_key", code: .originKeyMismatch, state: .fail, requiredFor: required,
                                       source: "origin_key_file", observedAt: now,
                                       summary: "The origin signing key does not match the identity devices pinned.",
                                       action: .recoverOriginIdentity)
            }
            return DiagnosticCheck(id: "origin_key", code: .originKeyPresent, state: .pass, requiredFor: required,
                                   source: "origin_key_file", observedAt: now,
                                   summary: "The origin signing key matches the pinned identity \(fingerprint).")
        } catch {
            return DiagnosticCheck(id: "origin_key", code: .originKeyMismatch, state: .fail, requiredFor: required,
                                   source: "origin_key_file", observedAt: now,
                                   summary: "The origin signing key is unreadable: \(error)", action: .recoverOriginIdentity)
        }
    }

    private func tailnetChecks(_ loaded: LoadedInstallation, now: ControlTimestamp) async -> [DiagnosticCheck] {
        guard let path = try? tailscalePath(loaded.installation) else {
            return [DiagnosticCheck(id: "tailscale", code: .tailscaleMissing, state: .fail, requiredFor: [.host],
                                    source: "tailscale_cli", observedAt: now,
                                    summary: "The Tailscale CLI was not found at the recorded path.", action: .installTailscale)]
        }
        return await tailnetEvidence(
            tailscale: path,
            recordedHost: loaded.installation.publicURL.flatMap { URL(string: $0)?.host },
            ownedPorts: loaded.installation.ownedServePorts,
            brokerPort: loaded.installation.port,
            expectServing: true,
            stopped: loaded.installation.desiredState == .stopped,
            now: now
        )
    }

    /// Tailscale, private-route, and Serve evidence. Guided preflight and
    /// `doctor` share it, so the same Mac never passes one and fails the
    /// other. `expectServing` is false before setup has configured Serve:
    /// an absent handler then means "free for Shell", not a failure.
    func tailnetEvidence(tailscale path: String, recordedHost: String?, ownedPorts: Set<Int>, brokerPort: Int,
                         expectServing: Bool, stopped: Bool, now: ControlTimestamp) async -> [DiagnosticCheck] {
        func check(_ id: String, _ code: DiagnosticCode, _ state: DiagnosticState, source: String,
                   _ summary: String, action: DiagnosticAction? = nil) -> DiagnosticCheck {
            DiagnosticCheck(id: id, code: code, state: state, requiredFor: [.host], source: source,
                            observedAt: state == .unknown ? nil : now, summary: summary, action: action)
        }
        let status: TailnetStatus
        do {
            status = try await tailnet.status(tailscale: path)
        } catch {
            return [check("tailscale", .tailscaleStatusUnknown, .unknown, source: "tailscale_cli",
                          "Tailscale did not report its state: \(error)", action: .connectTailscale)]
        }
        guard status.isConnected else {
            return [check("tailscale", .tailscaleNotConnected, .fail, source: "tailscale_cli",
                          "Tailscale reports \(DisplaySanitizer.sanitize(status.backendState, maxScalars: 40).text). Sign in and connect.",
                          action: .connectTailscale)]
        }
        var checks = [check("tailscale", .tailscaleConnected, .pass, source: "tailscale_cli", "Tailscale is connected on this Mac.")]

        let dnsName = status.dnsName.flatMap { status.magicDNSEnabled && OriginRoute.isTailnetHost($0) ? $0 : nil }
        if dnsName == nil {
            checks.append(check("route", .routeConfigurationIncomplete, .fail, source: "tailscale_cli",
                                "MagicDNS is not available for this Mac, so it has no private HTTPS name.", action: .enableMagicDNS))
        } else if expectServing, recordedHost == nil {
            checks.append(check("route", .routeConfigurationIncomplete, .fail, source: "installation_state",
                                "No private route is recorded yet.", action: .startServices))
        } else if let recordedHost, recordedHost != dnsName {
            checks.append(check("route", .routeConfigurationIncomplete, .warn, source: "tailscale_cli",
                                "The Mac's Tailscale name changed; start the services to adopt it. Pairing is unaffected.",
                                action: .startServices))
        } else {
            checks.append(check("route", .routeConfigured, .pass, source: "tailscale_cli",
                                "The private HTTPS name is available and matches the recorded route."))
        }

        guard let name = recordedHost ?? dnsName else { return checks }
        do {
            let serve = try await tailnet.serveStatus(tailscale: path)
            if serve.isFunnelled(host: name) {
                checks.append(check("serve", .servePublicExposure, .fail, source: "tailscale_serve_status",
                                    "Tailscale Funnel exposes the Shell endpoint publicly. Control is not ready until it is private.",
                                    action: .disableFunnel))
            } else if case .conflict(let reason) = serve.ownership(host: name, ownedPorts: ownedPorts) {
                checks.append(check("serve", .serveConflict, .fail, source: "tailscale_serve_status",
                                    "\(reason). Shell did not change it.", action: .resolveServeConflict))
            } else if serve.servesBroker(host: name, port: brokerPort) {
                checks.append(check("serve", .serveActive, .pass, source: "tailscale_serve_status",
                                    "Tailscale Serve privately proxies HTTPS to the loopback broker."))
            } else if expectServing {
                checks.append(check("serve", .routeConfigurationIncomplete, .fail, source: "tailscale_serve_status",
                                    "Tailscale Serve does not point HTTPS 443 at the broker.",
                                    action: stopped ? .startServices : .runSetup))
            } else {
                checks.append(check("serve", .serveActive, .pass, source: "tailscale_serve_status",
                                    "HTTPS 443 on this name is free for Shell or already Shell's."))
            }
        } catch {
            checks.append(check("serve", .serveStatusUnknown, .unknown, source: "tailscale_serve_status",
                                "Tailscale Serve status could not be read; an unknown configuration is not proof of privacy."))
        }
        return checks
    }

    private func enrollmentChecks(enrolled: [EnrolledDevice]?, pending: [PendingEnrollment]?, now: ControlTimestamp) -> [DiagnosticCheck] {
        guard let enrolled else {
            return [
                DiagnosticCheck(id: "iphone_enrollment", code: .enrollmentUnknown, state: .unknown, requiredFor: [.iphoneReview],
                                source: "broker_admin_api", observedAt: nil,
                                summary: "Enrolled devices are unknown while the broker is unavailable."),
                DiagnosticCheck(id: "watch_enrollment", code: .enrollmentUnknown, state: .unknown, requiredFor: [.watchReview],
                                source: "broker_admin_api", observedAt: nil,
                                summary: "Enrolled devices are unknown while the broker is unavailable.")
            ]
        }
        let iphones = enrolled.filter(\.isIPhone), watches = enrolled.filter(\.isWatch)
        var checks: [DiagnosticCheck] = []
        if !iphones.isEmpty {
            checks.append(DiagnosticCheck(id: "iphone_enrollment", code: .iphoneEnrolled, state: .pass, requiredFor: [.iphoneReview],
                                          source: "broker_admin_api", observedAt: now,
                                          summary: "\(iphones.count) iPhone(s) enrolled. Enrollment does not show the iPhone can reach this Mac now; check on the iPhone.",
                                          action: .testReview))
        } else if pending?.contains(where: { !$0.isWatch }) == true {
            checks.append(DiagnosticCheck(id: "iphone_enrollment", code: .iphoneEnrollmentPending, state: .warn, requiredFor: [.iphoneReview],
                                          source: "broker_admin_api", observedAt: now,
                                          summary: "An iPhone is waiting for confirmation on this Mac.", action: .confirmEnrollment))
        } else {
            checks.append(DiagnosticCheck(id: "iphone_enrollment", code: .iphoneNotEnrolled, state: .notConfigured, requiredFor: [.iphoneReview],
                                          source: "broker_admin_api", observedAt: now,
                                          summary: "No iPhone is paired yet.", action: .pairIPhone))
        }
        checks.append(watches.isEmpty
            ? DiagnosticCheck(id: "watch_enrollment", code: .watchNotConfigured, state: .notConfigured, requiredFor: [.watchReview],
                              source: "broker_admin_api", observedAt: now,
                              summary: "No Apple Watch is set up. This is optional.", action: .addWatch)
            : DiagnosticCheck(id: "watch_enrollment", code: .watchEnrolled, state: .pass, requiredFor: [.watchReview],
                              source: "broker_admin_api", observedAt: now,
                              summary: "\(watches.count) Watch reviewer(s) enrolled through an iPhone. Reachability depends on that iPhone."))
        return checks
    }

    private func alertCheck(_ push: PushConfiguration, enrolled: [EnrolledDevice]?, now: ControlTimestamp) -> DiagnosticCheck {
        let iphones = enrolled?.filter(\.isIPhone) ?? []
        let on = iphones.filter { $0.alertsEnabled != false && $0.push }.count
        let perDevice = enrolled == nil ? "" : " \(on) of \(iphones.count) iPhone(s) have delivery registered."
        if push.enabled, push.relayURL != nil {
            return DiagnosticCheck(id: "remote_alerts", code: .alertsConfigured, state: .pass, requiredFor: [.remoteAlerts],
                                   source: "installation_state", observedAt: now,
                                   summary: "A push relay is configured; this does not prove delivery.\(perDevice)")
        }
        if push.usesDirectAPNs {
            return DiagnosticCheck(id: "remote_alerts", code: .alertsDirectAPNs, state: .pass, requiredFor: [.remoteAlerts],
                                   source: "installation_state", observedAt: now,
                                   summary: "Advanced direct-APNs credentials are configured (not a shared relay); this does not prove delivery.\(perDevice)")
        }
        return DiagnosticCheck(id: "remote_alerts", code: .alertsNotConfigured, state: .disabled, requiredFor: [.remoteAlerts],
                               source: "installation_state", observedAt: now,
                               summary: "Remote alerts are off. Open Control and refresh to check for requests. Live review still requires a connection to your Mac.")
    }
}

/// Human-readable `doctor` output.
public enum DoctorText {
    public static func render(_ report: DiagnosticReport) -> String {
        var lines = ["Shell Control host diagnostics (\(report.generatedAt.rfc3339))", ""]
        for check in report.checks {
            let mark = switch check.state {
            case .pass: "ok"
            case .warn: "warn"
            case .fail: "FAIL"
            case .unknown: "?"
            case .notConfigured: "not configured"
            case .disabled: "off"
            }
            lines.append("\(check.id.padding(toLength: 18, withPad: " ", startingAt: 0))\(mark.padding(toLength: 16, withPad: " ", startingAt: 0))\(check.summary)")
            if check.state != .pass, let command = check.action?.macCommand {
                lines.append(String(repeating: " ", count: 34) + "→ \(command)")
            }
        }
        lines.append("")
        lines.append("host          \(title(report.readiness(for: .host)))")
        lines.append("iPhone review \(title(report.readiness(for: .iphoneReview))) (enrollment only)")
        lines.append("Apple Watch   \(title(report.readiness(for: .watchReview)))")
        lines.append("remote alerts \(title(report.readiness(for: .remoteAlerts)))")
        lines.append("")
        lines.append("This checks the host only, not whether an iPhone or Watch can reach it now.")
        lines.append("On the iPhone: Settings → Control → Check connection.")
        return lines.joined(separator: "\n") + "\n"
    }

    static func title(_ state: DiagnosticState) -> String {
        switch state {
        case .pass: "ready"
        case .warn: "ready with warnings"
        case .fail: "not ready"
        case .unknown: "unknown"
        case .notConfigured: "not configured"
        case .disabled: "off"
        }
    }
}
