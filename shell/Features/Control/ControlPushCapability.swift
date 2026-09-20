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

    private static let lastTokenKey = "dev.chr33s.shell.control.push.token"
    private static let expiryKey = "dev.chr33s.shell.control.push.capability-expiry"
    /// The Mac's device record the capability was handed to. Signing out,
    /// revocation, and re-pairing all create a new record, which needs its
    /// own copy even when the token is unchanged.
    private static let deviceKey = "dev.chr33s.shell.control.push.device"

    /// Asks for remote notifications once paired and a relay exists.
    @MainActor
    static func registerIfConfigured() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard relayURL != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
        #endif
    }

    /// Mints a capability for a new token, a new device record, or one nearing
    /// expiry, and publishes it to the Mac. Failure costs only prompt
    /// notification.
    static func publish(deviceToken: Data, gateway: ControlGatewaySession, defaults: UserDefaults = .standard) async {
        guard let relayURL else { return }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let expiry = defaults.object(forKey: expiryKey) as? Date ?? .distantPast
        guard let deviceID = await gateway.deviceSession?.deviceID.rawValue else { return }
        if defaults.string(forKey: lastTokenKey) == token,
           defaults.string(forKey: deviceKey) == deviceID,
           expiry.timeIntervalSinceNow > 7 * 24 * 60 * 60 { return }
        do {
            var request = URLRequest(url: relayURL.appendingPathComponent("v1/capabilities"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCanonicalization.canonicalize(.object([
                "apns_token": .string(token),
                "topic": .string(Bundle.main.bundleIdentifier ?? "dev.chr33s.shell"),
                "environment": .string(environment.rawValue)
            ]))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else { return }
            var reader = try JSONReader(try JSONValue.parse(data))
            let capability = try reader.string("capability", maxLength: 4096)
            let expiresAt = try reader.timestamp("expires_at")
            try await gateway.authenticatedClient().registerPushCapability(capability)
            defaults.set(token, forKey: lastTokenKey)
            defaults.set(expiresAt.date, forKey: expiryKey)
            defaults.set(deviceID, forKey: deviceKey)
        } catch {
            // The ledger on the Mac is still discovered on the next refresh.
        }
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastTokenKey)
        defaults.removeObject(forKey: expiryKey)
        defaults.removeObject(forKey: deviceKey)
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
