//
//  ControlHostView.swift
//  shell
//
//  Mac Catalyst only: this Mac as a Control host. Consent, status in the
//  readiness words of docs/specs/agent-relay.md section 18.9, the Tailscale route
//  the user configured outside Shell (19.7), pairing, and enrolled devices.
//  iPhone, iPad, and visionOS never compile it.
//

#if targetEnvironment(macCatalyst)
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The entry row inside the existing Control settings.
struct ControlHostEntrySection: View {
    let lifecycle: ControlHostLifecycle

    var body: some View {
        Section {
            NavigationLink {
                ControlHostView(lifecycle: lifecycle)
            } label: {
                LabeledContent(String(localized: "This Mac as Control host"), value: ControlHostText.title(lifecycle.readiness))
            }
            .themedRow()
        } footer: {
            Text(String(localized: "Review agent requests from this Mac on your iPhone and Apple Watch. Optional; the terminal never needs it."))
        }
        .task { await lifecycle.reconcile() }
    }
}

/// Words for every state, so nothing depends on color.
enum ControlHostText {
    static func title(_ state: ControlReadinessState) -> String {
        switch state {
        case .notEnabled: String(localized: "Off")
        case .approvalRequired: String(localized: "Needs approval")
        case .registeredStarting: String(localized: "Starting")
        case .readyLocal: String(localized: "Running")
        case .routeUnavailable: String(localized: "Running, route not verified")
        case .disabledByUser: String(localized: "Turned off in System Settings")
        case .incompatibleBuild: String(localized: "Incompatible build")
        case .degraded: String(localized: "Unavailable")
        case .legacyConflict: String(localized: "Standalone install in use")
        }
    }

    static func explanation(_ state: ControlReadinessState) -> String {
        switch state {
        case .notEnabled:
            String(localized: "Control is off. Nothing runs in the background.")
        case .approvalRequired:
            String(localized: "macOS needs your approval before Control can run in the background. Allow Shell in Login Items.")
        case .registeredStarting:
            String(localized: "Control is registered and starting. It recovers its records before accepting work.")
        case .readyLocal:
            String(localized: "The host runs on this Mac and its Tailscale route is verified. Approvals are ready only after the safe agent test passes.")
        case .routeUnavailable:
            String(localized: "The host runs on this Mac, but your iPhone cannot reach it until the Tailscale route below is verified.")
        case .disabledByUser:
            String(localized: "Shell's background item was turned off in System Settings. Shell will not turn it back on by itself.")
        case .incompatibleBuild:
            String(localized: "This copy of Shell does not contain a compatible Control host. Update or reinstall Shell.")
        case .degraded:
            String(localized: "The host is registered but not healthy. Details are below.")
        case .legacyConflict:
            String(localized: "A standalone Shell Control installation already runs on this Mac. Only one may be the authority.")
        }
    }

    static func route(_ route: ControlHostRouteStatus) -> String {
        switch route.state {
        case .notConfigured: String(localized: "Not configured")
        case .verified: String(localized: "Verified")
        case .unavailable: String(localized: "Unavailable")
        }
    }
}

struct ControlHostView: View {
    let lifecycle: ControlHostLifecycle

    @State private var showConsent = false
    @State private var routeText = ""
    @State private var confirmDisable = false
    @State private var revoking: ControlHostDevice?

    var body: some View {
        List {
            statusSection
            if let status = lifecycle.hostStatus, lifecycle.hostIsServing {
                routeSection(status)
                pairingSection(status)
                devicesSection
            }
            Section {
                Text(String(localized: "Disabling Control stops the background host and keeps its pairings, keys, and history. Deleting Shell does not delete them."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Control Host"))
        .task { await lifecycle.reconcile() }
        .refreshable { await lifecycle.reconcile() }
        // Foreground activation, including the return from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await lifecycle.reconcile() }
        }
        .sheet(isPresented: $showConsent) {
            ControlHostConsentView {
                showConsent = false
                Task { await lifecycle.enable() }
            } onCancel: {
                showConsent = false
            }
        }
        .confirmationDialog(String(localized: "Disable Control?"), isPresented: $confirmDisable, titleVisibility: .visible) {
            Button(String(localized: "Disable Control"), role: .destructive) { Task { await lifecycle.disable() } }
        } message: {
            Text(String(localized: "The host stops accepting agent requests and is removed from login items. An operation already sent to an agent cannot be taken back."))
        }
        .confirmationDialog(String(localized: "Revoke this device?"), isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }
        ), titleVisibility: .visible, presenting: revoking) { device in
            Button(String(localized: "Revoke \(device.label)"), role: .destructive) { Task { await lifecycle.revoke(device) } }
        } message: { device in
            Text(device.platform == "watchOS"
                 ? String(localized: "This Watch can no longer review requests.")
                 : String(localized: "This iPhone, and every Watch it serves, can no longer review requests."))
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent(String(localized: "Status"), value: ControlHostText.title(lifecycle.readiness))
                .themedRow()
            Text(ControlHostText.explanation(lifecycle.readiness))
                .font(.callout)
                .themedRow()
            if let detail = lifecycle.hostStatus?.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).themedRow()
            }
            if let error = lifecycle.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).themedRow()
            }
            if let notice = lifecycle.notice {
                Text(notice).font(.footnote).themedRow()
            }
            actions
        } header: {
            Text(String(localized: "This Mac"))
        } footer: {
            if let status = lifecycle.hostStatus {
                Text(String(localized: "Host build \(status.hostBuild) · broker 127.0.0.1:\(String(status.brokerPort)) · \(String(status.enrolledDevices)) device(s)"))
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch lifecycle.readiness {
        case .notEnabled:
            Button(String(localized: "Enable Control…")) { showConsent = true }
                .disabled(lifecycle.isWorking)
                .themedRow()
        case .approvalRequired, .disabledByUser:
            Button(String(localized: "Open Login Items Settings")) { lifecycle.openLoginItems() }
                .themedRow()
            Button(String(localized: "Enable Control Again…")) { showConsent = true }
                .disabled(lifecycle.isWorking)
                .themedRow()
        case .legacyConflict, .degraded:
            Button(String(localized: "Check Again")) { Task { await lifecycle.retryHost() } }
                .disabled(lifecycle.isWorking)
                .themedRow()
        case .registeredStarting, .readyLocal, .routeUnavailable, .incompatibleBuild:
            EmptyView()
        }
        if lifecycle.intentEnabled || lifecycle.registration == .enabled {
            Button(String(localized: "Disable Control"), role: .destructive) { confirmDisable = true }
                .disabled(lifecycle.isWorking)
                .themedRow()
        }
    }

    // MARK: Route

    @ViewBuilder
    private func routeSection(_ status: ControlHostStatus) -> some View {
        Section {
            LabeledContent(String(localized: "Route"), value: ControlHostText.route(status.route))
                .themedRow()
            if let url = status.route.url {
                Text(url).font(.footnote.monospaced()).textSelection(.enabled).themedRow()
            }
            if let detail = status.route.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).themedRow()
            }
            TextField(String(localized: "mac-name.tailnet-name.ts.net"), text: $routeText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel(String(localized: "This Mac's MagicDNS name"))
                .onSubmit { submitRoute() }
                .themedRow()
            Button(routeText.isEmpty ? String(localized: "Verify Route Again") : String(localized: "Verify Route")) { submitRoute() }
                .disabled(lifecycle.isWorking || (routeText.isEmpty && status.route.url == nil))
                .themedRow()
        } header: {
            Text(String(localized: "Tailscale route"))
        } footer: {
            Text(String(localized: "Set this up outside Shell: in Terminal, run tailscale serve --bg --https=443 http://127.0.0.1:\(String(status.brokerPort)) — then enter this Mac's MagicDNS name. Shell verifies the route by asking it to prove this Mac's origin key; it never runs tailscale or changes its settings."))
        }
    }

    private func submitRoute() {
        let text = routeText
        Task {
            if text.isEmpty { await lifecycle.verifyRoute() } else { await lifecycle.setRoute(text) }
        }
    }

    // MARK: Pairing

    @ViewBuilder
    private func pairingSection(_ status: ControlHostStatus) -> some View {
        Section {
            if let invitation = lifecycle.invitation {
                ControlHostInvitationView(invitation: invitation)
                    .themedRow()
                Button(String(localized: "Hide QR")) { lifecycle.dismissInvitation() }
                    .themedRow()
            } else {
                Button(String(localized: "Show Pairing QR")) { Task { await lifecycle.mintInvitation() } }
                    .disabled(lifecycle.isWorking || status.route.state != .verified)
                    .themedRow()
            }
            ForEach(lifecycle.pending) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.label).font(.headline)
                    Text(String(localized: "Code \(item.userCode) · \(item.platform)"))
                        .font(.footnote.monospaced())
                    Text(item.keyFingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let gateway = item.gateway {
                        Text(String(localized: "Through \(gateway)")).font(.caption)
                    }
                    HStack {
                        Button(String(localized: "Confirm")) { Task { await lifecycle.confirm(item, approve: true) } }
                        Button(String(localized: "Deny"), role: .destructive) { Task { await lifecycle.confirm(item, approve: false) } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(lifecycle.isWorking)
                }
                .themedRow()
            }
            if !lifecycle.pending.isEmpty || lifecycle.invitation != nil {
                Button(String(localized: "Check for Pairing Requests")) { Task { await lifecycle.refreshLists() } }
                    .themedRow()
            }
        } header: {
            Text(String(localized: "Pair iPhone"))
        } footer: {
            Text(status.route.state == .verified
                 ? String(localized: "Scan the QR in Shell on iPhone, then confirm here only if the code and key fingerprint match what the iPhone shows.")
                 : String(localized: "Pairing needs a verified Tailscale route first."))
        }
    }

    // MARK: Devices

    @ViewBuilder
    private var devicesSection: some View {
        Section {
            if lifecycle.devices.isEmpty {
                Text(String(localized: "No devices are paired.")).foregroundStyle(.secondary).themedRow()
            }
            ForEach(lifecycle.devices) { device in
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(device.label, value: device.platform == "watchOS" ? String(localized: "Apple Watch") : String(localized: "iPhone"))
                    Text(device.keyFingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Toggle(String(localized: "Agent requests"), isOn: Binding(
                        get: { device.agentGrants },
                        set: { enabled in Task { await lifecycle.setAgentGrants(device, enabled: enabled) } }
                    ))
                    .disabled(lifecycle.isWorking)
                    Button(String(localized: "Revoke…"), role: .destructive) { revoking = device }
                        .disabled(lifecycle.isWorking)
                }
                .themedRow()
            }
        } header: {
            Text(String(localized: "Devices"))
        } footer: {
            Text(String(localized: "Agent requests are granted per device and can be removed at any time. Approvals of shell commands need only pairing."))
        }
    }
}

/// Explicit consent before registration (spec 19.4).
struct ControlHostConsentView: View {
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "Control runs a small background host on this Mac so your iPhone and Apple Watch can review requests from Claude Code and Codex."))
                    Label(String(localized: "It keeps running after you quit Shell, and starts again when you log in."), systemImage: "arrow.clockwise")
                    Label(String(localized: "macOS may ask you to allow it in Login Items. You can turn it off there or here at any time."), systemImage: "gearshape")
                    Label(String(localized: "It listens only on this Mac. Your iPhone reaches it through Tailscale Serve, which you configure yourself."), systemImage: "lock")
                    Label(String(localized: "It never approves anything by itself. Every decision is signed on your iPhone or Watch."), systemImage: "hand.raised")
                }
            }
            .navigationTitle(String(localized: "Enable Control?"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Enable Control"), action: onEnable)
                }
            }
        }
    }
}

/// The one-use pairing QR, with what the iPhone must show for comparison.
struct ControlHostInvitationView: View {
    let invitation: ControlHostInvitation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = ControlHostQR.image(invitation.link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .accessibilityLabel(String(localized: "Pairing QR code"))
            }
            Text(String(localized: "Origin fingerprint")).font(.caption)
            Text(invitation.originFingerprint).font(.caption.monospaced()).textSelection(.enabled)
            Text(String(localized: "Expires \(invitation.expiresAt.formatted(date: .omitted, time: .shortened)); one use."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum ControlHostQR {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
