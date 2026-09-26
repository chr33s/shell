import Foundation
import Testing

@testable import Shell

/// Pins how a known SSH host is matched.
///
/// THE REGRESSION THIS EXISTS FOR: the lookup key was the raw
/// `"\(hostname):\(port)"` string, so it was case-sensitive and kept a trailing
/// root dot. DNS names are neither. Reaching a host the user had already
/// trusted under a different spelling — `Example.com`, `example.com.` — missed
/// the stored entry entirely, so a *changed* host key was presented as the
/// gentle "Do you want to trust this host?" prompt instead of the
/// man-in-the-middle warning, and "Connect Once" approvals leaked the same way.
///
/// `KnownHost.legacyId` deliberately keeps its exact spelling: it is the
/// CloudKit record name, and renormalising it would orphan synced records.
@MainActor
@Suite
final class KnownHostIdentityTests {
    @Test
    func testIdentityIsCaseInsensitive() throws {
        #expect(KnownHostsManager.identity(hostname: "Example.COM", port: 22) == KnownHostsManager.identity(hostname: "example.com", port: 22))
    }

    @Test
    func testIdentityDropsTheTrailingRootDot() throws {
        #expect(KnownHostsManager.identity(hostname: "example.com.", port: 22) == KnownHostsManager.identity(hostname: "example.com", port: 22))
    }

    @Test
    func testIdentityUnwrapsABracketedIPv6Literal() throws {
        #expect(KnownHostsManager.identity(hostname: "[::1]", port: 22) == KnownHostsManager.identity(hostname: "::1", port: 22))
    }

    @Test
    func testIdentityStillSeparatesDifferentHostsAndPorts() throws {
        #expect(KnownHostsManager.identity(hostname: "example.com", port: 22) != KnownHostsManager.identity(hostname: "example.com", port: 2222))
        #expect(KnownHostsManager.identity(hostname: "a.example.com", port: 22) != KnownHostsManager.identity(hostname: "b.example.com", port: 22))
    }

    @Test
    func testSessionApprovalMatchesAcrossSpellingsOfTheSameHost() throws {
        let store = SessionApprovedHostKeys.shared
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAI\(UUID().uuidString)"
        let host = "Approve-\(UUID().uuidString).example.com"

        store.remember(hostname: host, port: 22, publicKeyData: blob)

        #expect(store.matches(hostname: host.lowercased(), port: 22, publicKeyData: blob))
        #expect(store.matches(hostname: "\(host).", port: 22, publicKeyData: blob))
        #expect(!(store.matches(hostname: host, port: 22, publicKeyData: "different")))
        #expect(!(store.matches(hostname: host, port: 2222, publicKeyData: blob)))
    }
}
