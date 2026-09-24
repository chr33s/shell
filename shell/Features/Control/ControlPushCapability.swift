//
//  ControlPushCapability.swift
//  shell
//
//  Optional remote attention: the iPhone trades its APNs token with the
//  stateless Shell Push Relay for a signed push capability and hands that to
//  its Mac over Tailscale. A push is only ever a hint; without a relay the
//  Mac's ledger is simply discovered on the next refresh
//  (spec.iphone-gateway.md section 16).
//
//  Registration runs only under an explicit local "configured" choice for
//  this origin and device: a build-configured relay URL is availability, not
//  consent. Every attempt runs under a policy generation, and a result from
//  an older generation is discarded (spec.control-companion-setup.md 10).
//

import Foundation
import UserNotifications
import ShellControlProtocol
import ShellControlClient
import ShellControlSecurity
#if canImport(UIKit)
import UIKit
#endif

enum ControlPushCapability {
    /// The relay host baked into the build. The `.invalid` placeholder means
    /// no relay: correct, just without prompt remote alerts.
    static var relayURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SHELLControlPushRelayURL") as? String,
              let url = URL(string: text), url.scheme == "https",
              let host = url.host, !host.hasSuffix(".invalid")
        else { return nil }
        return url
    }

    /// Keys written by builds before the explicit policy. Read once, to tell
    /// whether this device already used remote alerts, then removed.
    private static let legacyTokenKey = "dev.chr33s.shell.control.push.token"
    private static let legacyExpiryKey = "dev.chr33s.shell.control.push.capability-expiry"
    private static let legacyDeviceKey = "dev.chr33s.shell.control.push.device"

    /// A cached capability is renewed once it is this close to expiry.
    static let renewalMargin: TimeInterval = 7 * 24 * 60 * 60

    /// The policy for a device record already paired before this build:
    /// prior use is preserved, and otherwise the user is asked once.
    static func migratedPolicy(deviceID: String, defaults: UserDefaults = .standard) -> RemoteAlertPolicy {
        let prior = defaults.string(forKey: legacyDeviceKey) == deviceID && defaults.string(forKey: legacyTokenKey) != nil
        for key in [legacyTokenKey, legacyExpiryKey, legacyDeviceKey] { defaults.removeObject(forKey: key) }
        return .migrated(priorUseEstablished: prior, relayAvailable: relayURL != nil)
    }

    /// Asks for notification permission and an APNs token, only when this
    /// device chose remote alerts and a relay exists. Review never waits on
    /// this prompt.
    @MainActor
    static func requestRegistration(policy: RemoteAlertPolicy) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard relayURL != nil, policy.permitsRegistration else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
        #endif
    }

    /// Whether the user has denied notifications for Shell.
    static func notificationsDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Mints a capability for a new token, device record, relay endpoint, or
    /// one nearing expiry, and publishes it to the Mac. Failures are recorded
    /// as bounded, sanitized states; they never affect review.
    static func publish(deviceToken: Data, gateway: ControlGatewaySession, alerts: RemoteAlertCoordinator) async {
        guard let generation = await alerts.beginRegistration() else { return }
        guard let relayURL else {
            await alerts.recordFailure(.relayUnavailable, generation: generation)
            return
        }
        if await notificationsDenied() {
            await alerts.recordFailure(.permissionDenied, generation: generation)
            return
        }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let topic = Bundle.main.bundleIdentifier ?? "dev.chr33s.shell"
        var candidate = RemoteAlertRegistration(
            relayEndpoint: relayURL.absoluteString, topic: topic, environment: environment.rawValue,
            originID: alerts.originID, deviceID: alerts.deviceID,
            tokenFingerprint: RemoteAlertRegistration.fingerprint(token: token), expiresAt: .distantFuture
        )
        if await alerts.isCurrent(candidate, margin: renewalMargin) { return }
        let capability: String
        do {
            var request = URLRequest(url: relayURL.appendingPathComponent("v1/capabilities"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCanonicalization.canonicalize(.object([
                "apns_token": .string(token),
                "topic": .string(topic),
                "environment": .string(environment.rawValue)
            ]))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else {
                await alerts.recordFailure(.relayRejected, generation: generation)
                return
            }
            var reader = try JSONReader(try JSONValue.parse(data))
            capability = try reader.string("capability", maxLength: 4096)
            let expiresAt = try reader.timestamp("expires_at")
            guard expiresAt.date > Date() else {
                await alerts.recordFailure(.capabilityExpired, generation: generation)
                return
            }
            candidate.expiresAt = expiresAt.date
        } catch is URLError {
            await alerts.recordFailure(.networkFailure, generation: generation)
            return
        } catch {
            await alerts.recordFailure(.relayRejected, generation: generation)
            return
        }
        // The user may have turned alerts off while the relay answered: a
        // capability minted under an older generation is never uploaded.
        guard await alerts.beginRegistration() == generation else { return }
        do {
            try await gateway.authenticatedClient().registerPushCapability(capability)
        } catch {
            await alerts.recordFailure(.macRegistrationPending, generation: generation)
            return
        }
        await alerts.completeRegistration(candidate, generation: generation)
    }

    /// The APNs environment the token was issued for. That follows the
    /// signing profile's `aps-environment`, not the build configuration: a
    /// Release build signed for development still gets a sandbox token.
    static let environment: PushRegistration.Environment = {
        #if targetEnvironment(simulator)
        return .development
        #else
        // App Store and TestFlight builds carry no embedded profile and are
        // always production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        return profileEnvironment(data) ?? .production
        #endif
    }()

    /// Reads `Entitlements.aps-environment` from the plist inside a CMS-signed
    /// provisioning profile.
    static func profileEnvironment(_ profile: Data) -> PushRegistration.Environment? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String
        else { return nil }
        return aps == "development" ? .development : .production
    }

    /// Whether a remote notification is a Shell approval hint (as opposed to
    /// a CloudKit push). Only identifiers are read.
    static func isApprovalHint(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["event"] as? String) == "approval.created" && (userInfo["request_id"] as? String).flatMap(ControlID.init) != nil
    }
}

/// Remote-alert policies in the app's defaults, one per origin and device
/// record. Non-secret: choices, versions, and a token fingerprint only.
final class DefaultsRemoteAlertPolicyStore: RemoteAlertPolicyStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let prefix = "dev.chr33s.shell.control.alerts."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ originID: String, _ deviceID: String) -> String { "\(Self.prefix)\(originID).\(deviceID)" }

    func load(originID: String, deviceID: String) -> RemoteAlertPolicy? {
        guard let data = defaults.data(forKey: key(originID, deviceID)) else { return nil }
        return try? JSONDecoder().decode(RemoteAlertPolicy.self, from: data)
    }

    func save(_ policy: RemoteAlertPolicy, originID: String, deviceID: String) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: key(originID, deviceID))
    }

    func remove(originID: String, deviceID: String) {
        defaults.removeObject(forKey: key(originID, deviceID))
    }

    /// Forgets every policy for an origin (the Mac was forgotten or replaced).
    func removeAll(originID: String) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("\(Self.prefix)\(originID).") {
            defaults.removeObject(forKey: key)
        }
    }
}
