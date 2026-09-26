import Foundation
import Testing

@testable import Shell

/// Pins `SerializableConnectionConfig.SSHConfigSafe.toSSHConfig()` — how a
/// RESTORED session rebuilds its `SSHConfig` after a relaunch.
///
/// The invariant under test is the same one `SSHCommandParser.resolveJumpAuth`
/// enforces for a fresh `ssh -J`, and it has to hold on both paths or a
/// restored tab locks the user out of a bastion that a freshly-typed command
/// connects to fine: the bastion is offered exactly ONE identity, because its
/// `MaxAuthTries` is commonly 6 and a certified key costs two attempts, while
/// the TARGET — a separate SSH connection over the tunnel, with its own budget —
/// keeps its synthesized fallbacks.
///
/// `defaultKeyIDs` is injected. Against a test process's empty default list the
/// target's fallbacks are nil too, so the bastion assertion would pass even with
/// the `fallbackKeyIDs: nil` line deleted — the asymmetry only becomes visible
/// once real defaults exist.
@MainActor
@Suite
final class SerializableConnectionConfigTests {

    private let targetKeyID = UUID()
    private let jumpKeyID = UUID()
    private let otherDefaultA = UUID()
    private let otherDefaultB = UUID()

    /// A key-authenticated target behind a key-authenticated bastion, round
    /// tripped through the password-stripping restoration record.
    private func restored(
        targetAuth: SSHConfig.AuthMethod,
        jumpAuth: SSHConfig.AuthMethod?,
        defaultKeyIDs: [UUID]
    ) -> SSHConfig {
        var live = SSHConfig(host: "target.example.com", port: 22, username: "user")
        live.authMethod = targetAuth
        if let jumpAuth {
            live.jumpHost = SSHConfig.JumpHostConfig(
                host: "bastion.example.com",
                port: 2200,
                username: "admin",
                authMethod: jumpAuth
            )
        }
        return SerializableConnectionConfig.SSHConfigSafe(from: live)
            .toSSHConfig(defaultKeyIDs: defaultKeyIDs)
    }

    // MARK: - The one-credential invariant (KEEP-LIST)

    /// THE INVARIANT: with three defaults configured, the restored TARGET hop
    /// gets the two that are not its own key, and the restored BASTION gets
    /// none.
    ///
    /// Goes red if `toSSHConfig()` starts synthesizing `fallbackKeyIDs` for the
    /// jump host from the default list — the change that would lock a user out
    /// of their bastion on the first hop of a restored session.
    @Test
    func testRestoredBastionGetsNoFallbackIdentitiesWhileTargetKeepsItsOwn() throws {
        let config = restored(
            targetAuth: .key(targetKeyID),
            jumpAuth: .key(jumpKeyID),
            defaultKeyIDs: [targetKeyID, otherDefaultA, otherDefaultB]
        )

        #expect(config.fallbackKeyIDs == [otherDefaultA, otherDefaultB])
        #expect((config.jumpHost?.fallbackKeyIDs) == nil, "a restored bastion must be offered exactly one identity")
    }

    /// The bastion gets no fallbacks even when its own key is one of the
    /// defaults — i.e. the emptiness is not an accident of the key happening to
    /// be absent from the list.
    ///
    /// Goes red if a `defaultKeyIDs.filter { $0 != jumpKeyID }` is copied onto
    /// the jump branch the way it exists on the target branch.
    @Test
    func testRestoredBastionGetsNoFallbacksEvenWhenItsKeyIsADefault() throws {
        let config = restored(
            targetAuth: .key(targetKeyID),
            jumpAuth: .key(jumpKeyID),
            defaultKeyIDs: [jumpKeyID, otherDefaultA, otherDefaultB]
        )

        #expect((config.jumpHost?.fallbackKeyIDs) == nil)
    }

    // MARK: - Target fallback synthesis, unchanged

    /// The target's own key is excluded from its fallbacks — offering it twice
    /// spends two of the server's auth attempts on the credential that just
    /// failed.
    ///
    /// Goes red if the `filter { $0 != keyID }` is dropped.
    @Test
    func testTargetFallbacksExcludeTheTargetsOwnKey() throws {
        let config = restored(
            targetAuth: .key(targetKeyID),
            jumpAuth: nil,
            defaultKeyIDs: [otherDefaultA, targetKeyID, otherDefaultB]
        )

        #expect(config.fallbackKeyIDs == [otherDefaultA, otherDefaultB])
    }

    /// An empty fallback list normalizes to nil, so "no fallbacks" has exactly
    /// one representation. `[]` and `nil` diverging would make every downstream
    /// `fallbackKeyIDs == nil` check — including the bastion assertions above —
    /// answer differently depending on which one it met.
    ///
    /// Goes red if the `.isEmpty ? nil : fallbacks` normalization is removed.
    @Test
    func testEmptyTargetFallbackListNormalizesToNilRatherThanEmptyArray() throws {
        let config = restored(
            targetAuth: .key(targetKeyID),
            jumpAuth: nil,
            defaultKeyIDs: [targetKeyID]
        )

        #expect((config.fallbackKeyIDs) == nil)
    }

    /// Fallbacks are synthesized only for KEY auth. A password-authenticated
    /// target must not silently acquire a list of identities to try.
    ///
    /// Goes red if the `if case .key` guard around the synthesis is widened.
    @Test
    func testPasswordAuthenticatedTargetGetsNoSynthesizedFallbacks() throws {
        let config = restored(
            targetAuth: .password("hunter2"),
            jumpAuth: nil,
            defaultKeyIDs: [otherDefaultA, otherDefaultB]
        )

        #expect((config.fallbackKeyIDs) == nil)
    }

    // MARK: - Secrets never survive the record

    /// The restoration record is written to disk, so no secret may survive it.
    /// A saved password is downgraded to "password required" and comes back
    /// empty; the Keychain is re-read at reconnect.
    ///
    /// Goes red if `safeAuth`/`liveAuth` start round-tripping a password value,
    /// or if `.savedPassword` is preserved as-is — which would let a restored
    /// session skip the Keychain lookup that proves the password is still there.
    @Test
    func testPasswordsAreStrippedOnBothHopsAndComeBackEmpty() throws {
        let config = restored(
            targetAuth: .password("target-secret"),
            jumpAuth: .password("bastion-secret"),
            defaultKeyIDs: []
        )

        #expect(config.authMethod == .password(""))
        #expect(config.jumpHost?.authMethod == .password(""))
    }

    /// A saved-password hop restores as "needs a password", not as
    /// `.savedPassword`.
    ///
    /// Goes red if `safeAuth` stops folding `.savedPassword` into
    /// `.passwordRequired`.
    @Test
    func testSavedPasswordRestoresAsPasswordRequiredNotAsSavedPassword() throws {
        let config = restored(
            targetAuth: .savedPassword,
            jumpAuth: .savedPassword,
            defaultKeyIDs: []
        )

        #expect(config.authMethod == .password(""))
        #expect(config.jumpHost?.authMethod == .password(""))
    }

    /// Key identities and the bastion's own address survive the round trip
    /// intact — the record must not quietly re-point a hop.
    ///
    /// Goes red if the jump host's host/port/username/key is rebuilt from the
    /// target's values.
    @Test
    func testJumpHostIdentityAndAddressSurviveTheRoundTripUnchanged() throws {
        let config = restored(
            targetAuth: .key(targetKeyID),
            jumpAuth: .key(jumpKeyID),
            defaultKeyIDs: []
        )

        #expect(config.host == "target.example.com")
        #expect(config.authMethod == .key(targetKeyID))
        #expect(config.jumpHost?.host == "bastion.example.com")
        #expect(config.jumpHost?.port == 2200)
        #expect(config.jumpHost?.username == "admin")
        #expect(config.jumpHost?.authMethod == .key(jumpKeyID))
    }

    /// The record survives an encode/decode cycle — it is what actually gets
    /// written to disk, and a restored session is rebuilt from the decoded form,
    /// not the in-memory one.
    ///
    /// Goes red if a Codable key is renamed without a migration, which would
    /// drop the jump host (and with it the whole bastion) from every restored
    /// session.
    @Test
    func testRecordSurvivesJSONRoundTripWithTheJumpHopIntact() throws {
        var live = SSHConfig(host: "target.example.com", port: 22, username: "user")
        live.authMethod = .key(targetKeyID)
        live.jumpHost = SSHConfig.JumpHostConfig(
            host: "bastion.example.com",
            port: 2200,
            username: "admin",
            authMethod: .key(jumpKeyID)
        )

        let safe = SerializableConnectionConfig.SSHConfigSafe(from: live)
        let data = try JSONEncoder().encode(safe)
        let decoded = try JSONDecoder().decode(
            SerializableConnectionConfig.SSHConfigSafe.self, from: data
        )

        #expect(decoded == safe)

        let config = decoded.toSSHConfig(defaultKeyIDs: [targetKeyID, otherDefaultA])
        #expect(config.jumpHost?.authMethod == .key(jumpKeyID))
        #expect((config.jumpHost?.fallbackKeyIDs) == nil)
        #expect(config.fallbackKeyIDs == [otherDefaultA])
    }

    /// No secret appears anywhere in the encoded bytes. A structural assertion
    /// on the serialized form, not on any one field — it catches a password
    /// leaking in through a newly-added property too.
    ///
    /// Goes red if any hop's real password reaches the on-disk record.
    @Test
    func testEncodedRecordContainsNoPasswordBytes() throws {
        var live = SSHConfig(host: "target.example.com", port: 22, username: "user")
        live.authMethod = .password("target-secret-9f3a")
        live.jumpHost = SSHConfig.JumpHostConfig(
            host: "bastion.example.com",
            port: 2200,
            username: "admin",
            authMethod: .password("bastion-secret-4c1d")
        )

        let data = try JSONEncoder().encode(SerializableConnectionConfig.SSHConfigSafe(from: live))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!(json.contains("target-secret-9f3a")))
        #expect(!(json.contains("bastion-secret-4c1d")))
    }
}
