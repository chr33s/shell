import Foundation
import Testing

@testable import Shell

/// Pins `ConnectionKeyResolver.resolutionHint` — specifically the gate on the
/// identity-metadata-store fallback, and the fail-closed guarantee that a hint
/// can only ever narrow resolution.
///
/// The gate is a TRUST BOUNDARY. `SSHIdentityMetadataStore` now holds records
/// pulled from CloudKit — published by any device on the account, at any time.
/// Consulting it for every profile would silently widen resolution from "the
/// hints this profile carries" to "anything any device ever published", letting
/// a record written elsewhere steer which local identity a connection presents.
/// `carriesExplicitHints` is what keeps the fallback to filling a *gap* in a
/// profile whose author already recorded hints of their own.
///
/// `metadataEntries` is injected so the store's contents are stated by the test
/// rather than inherited from whatever the simulator's app container happens to
/// hold — the gate cannot be exercised at all otherwise.
@MainActor
@Suite
final class ConnectionKeyResolverHintTests {

    private let targetKeyID = UUID()
    private let jumpKeyID = UUID()

    private let metadataFingerprint = "SHA256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978"

    private func metadataEntry(
        for keyID: UUID,
        fingerprint: String? = nil,
        name: String = "Published Elsewhere",
        keyType: SSHKey.KeyType = .ed25519
    ) -> SSHIdentityMetadata {
        SSHIdentityMetadata(
            id: keyID,
            name: name,
            keyType: keyType.rawValue,
            fingerprint: fingerprint ?? metadataFingerprint,
            storageType: "keychain",
            publicKey: nil,
            certificate: nil,
            secureEnclaveDeviceBound: false
        )
    }

    private func hint(fingerprint: String, name: String) -> KeyResolutionHint {
        var hint = KeyResolutionHint()
        hint.fingerprint = fingerprint
        hint.keyName = name
        return hint
    }

    private func config(hints: [String: KeyResolutionHint]? = nil) -> SSHConfig {
        var config = SSHConfig(host: "target.example.com", port: 22, username: "user")
        config.authMethod = .key(targetKeyID)
        config.keyResolutionHints = hints
        return config
    }

    private func jumpConfig(hints: [String: KeyResolutionHint]? = nil) -> SSHConfig.JumpHostConfig {
        SSHConfig.JumpHostConfig(
            host: "bastion.example.com",
            port: 22,
            username: "admin",
            authMethod: .key(jumpKeyID),
            keyResolutionHints: hints
        )
    }

    // MARK: - The gate

    /// THE GATE. A profile carrying NO hints of its own gets nothing from the
    /// metadata store, even when the store holds a perfectly good record for the
    /// exact key being resolved.
    ///
    /// Goes red the moment the `carriesExplicitHints` guard is removed —
    /// "consult the store, it might help" is precisely the change that widens
    /// the trust boundary to every record any device ever published.
    @Test
    func testProfileWithNoHintsOfItsOwnGetsNothingFromTheMetadataStore() throws {
        let resolved = ConnectionKeyResolver.resolutionHint(
            for: targetKeyID,
            config: config(hints: nil),
            metadataEntries: [metadataEntry(for: targetKeyID)]
        )

        #expect((resolved) == nil, "an unhinted profile must not be steered by a record published from another device")
    }

    /// An EMPTY hints dictionary is still "no hints" — presence of the key must
    /// not open the gate.
    ///
    /// Goes red if `carriesExplicitHints` degrades to a nil check and drops the
    /// `!hints.isEmpty` test.
    @Test
    func testEmptyHintsDictionaryDoesNotOpenTheGate() throws {
        let resolved = ConnectionKeyResolver.resolutionHint(
            for: targetKeyID,
            config: config(hints: [:]),
            jumpConfig: jumpConfig(hints: [:]),
            metadataEntries: [metadataEntry(for: targetKeyID)]
        )

        #expect((resolved) == nil)
    }

    /// The case the fallback exists for: a profile that hinted its TARGET key
    /// but was written before jump-host hints were captured. The gap is filled
    /// from the store, and the synthesized hint carries the record's own
    /// fingerprint, name and type.
    ///
    /// Goes red if the fallback stops firing for a partially-hinted profile —
    /// such a profile would report its bastion key as unresolvable on every
    /// device but the one that wrote it.
    @Test
    func testPartiallyHintedProfileFillsTheJumpKeyGapFromTheMetadataStore() throws {
        let hinted = config(hints: [targetKeyID.uuidString: hint(fingerprint: "SHA256:target", name: "Target Key")])

        let resolved = try #require(ConnectionKeyResolver.resolutionHint(
                for: jumpKeyID,
                config: hinted,
                jumpConfig: jumpConfig(hints: nil),
                metadataEntries: [metadataEntry(for: jumpKeyID, name: "Bastion Key", keyType: .rsa)]
            ))

        #expect(resolved.fingerprint == metadataFingerprint)
        #expect(resolved.keyName == "Bastion Key")
        #expect(resolved.keyType == .rsa)
    }

    /// A hint recorded at jump level opens the gate for the profile just as a
    /// config-level one does — the profile author recorded hints either way.
    @Test
    func testJumpLevelHintsAlsoCountAsExplicitHintsForTheGate() throws {
        let resolved = ConnectionKeyResolver.resolutionHint(
            for: targetKeyID,
            config: config(hints: nil),
            jumpConfig: jumpConfig(hints: [jumpKeyID.uuidString: hint(fingerprint: "SHA256:jump", name: "Jump")]),
            metadataEntries: [metadataEntry(for: targetKeyID)]
        )

        #expect(resolved?.fingerprint == metadataFingerprint)
    }

    /// An EMPTY fingerprint is never a usable hint. `findKey(byFingerprint:)`
    /// compares for equality, so an empty fingerprint would match any local key
    /// whose own fingerprint failed to compute — resolving a connection onto an
    /// arbitrary identity.
    ///
    /// Goes red if the `!entry.fingerprint.isEmpty` guard is dropped: the test
    /// would then get a hint back instead of nil.
    @Test
    func testMetadataEntryWithAnEmptyFingerprintIsNeverUsedAsAHint() throws {
        let hinted = config(hints: [targetKeyID.uuidString: hint(fingerprint: "SHA256:target", name: "Target")])

        let resolved = ConnectionKeyResolver.resolutionHint(
            for: jumpKeyID,
            config: hinted,
            jumpConfig: jumpConfig(hints: nil),
            metadataEntries: [metadataEntry(for: jumpKeyID, fingerprint: "")]
        )

        #expect((resolved) == nil)
    }

    /// A store holding no record for this key yields nothing, rather than the
    /// first record it happens to hold.
    ///
    /// Goes red if the `first(where: { $0.id == keyID })` lookup loosens to
    /// `first` or to a name match.
    @Test
    func testMetadataLookupIsKeyedOnTheKeyIDAndNotJustTheFirstRecord() throws {
        let hinted = config(hints: [targetKeyID.uuidString: hint(fingerprint: "SHA256:target", name: "Target")])

        let resolved = ConnectionKeyResolver.resolutionHint(
            for: jumpKeyID,
            config: hinted,
            jumpConfig: jumpConfig(hints: nil),
            metadataEntries: [metadataEntry(for: UUID()), metadataEntry(for: UUID())]
        )

        #expect((resolved) == nil)
    }

    // MARK: - Precedence

    /// A hint the profile recorded itself outranks anything in the store. The
    /// profile's own record is the authority; the store is a last resort.
    ///
    /// Goes red if the metadata lookup is moved ahead of the recorded hints — a
    /// record published from another device would then override what this
    /// profile explicitly states.
    @Test
    func testConfigLevelHintOutranksTheMetadataStore() throws {
        let hinted = config(hints: [
            targetKeyID.uuidString: hint(fingerprint: "SHA256:recorded-by-the-profile", name: "Profile Key")
        ])

        let resolved = try #require(ConnectionKeyResolver.resolutionHint(
                for: targetKeyID,
                config: hinted,
                metadataEntries: [metadataEntry(for: targetKeyID)]
            ))

        #expect(resolved.fingerprint == "SHA256:recorded-by-the-profile")
    }

    /// Config level outranks jump level for the same key id.
    ///
    /// Goes red if the two lookups are swapped.
    @Test
    func testConfigLevelHintOutranksJumpLevelHintForTheSameKey() throws {
        let hinted = config(hints: [
            jumpKeyID.uuidString: hint(fingerprint: "SHA256:from-config", name: "Config")
        ])

        let resolved = try #require(ConnectionKeyResolver.resolutionHint(
                for: jumpKeyID,
                config: hinted,
                jumpConfig: jumpConfig(hints: [
                    jumpKeyID.uuidString: hint(fingerprint: "SHA256:from-jump", name: "Jump")
                ])
            ))

        #expect(resolved.fingerprint == "SHA256:from-config")
    }

    /// Jump level outranks the metadata store.
    ///
    /// Goes red if the store is consulted before the jump host's own dictionary.
    @Test
    func testJumpLevelHintOutranksTheMetadataStore() throws {
        let resolved = try #require(ConnectionKeyResolver.resolutionHint(
                for: jumpKeyID,
                config: config(hints: nil),
                jumpConfig: jumpConfig(hints: [
                    jumpKeyID.uuidString: hint(fingerprint: "SHA256:from-jump", name: "Jump")
                ]),
                metadataEntries: [metadataEntry(for: jumpKeyID)]
            ))

        #expect(resolved.fingerprint == "SHA256:from-jump")
    }

    // MARK: - Fail-closed: a hint narrows resolution, never widens it

    /// A hint whose fingerprint matches nothing on this device resolves to
    /// NOTHING. It never falls through to a default identity and never
    /// downgrades to password auth — the connection is reported unresolvable and
    /// the user is asked, which is the fail-closed outcome.
    ///
    /// Deterministic regardless of what the host device holds: the UUID is fresh
    /// and the fingerprint is synthetic, so neither can match a real key.
    ///
    /// Goes red if `resolveKey(id:hint:)` gains any "close enough" rung — a
    /// default-key fallback, or a match on something weaker than the exact
    /// SHA256 fingerprint.
    @Test
    func testHintThatMatchesNoLocalKeyResolvesToNothingRatherThanASubstitute() throws {
        let unknown = hint(
            fingerprint: "SHA256:ffffffffffffffffffffffffffffffffffffffffffffffff-not-on-device",
            name: "Key From Another Device"
        )

        #expect((SSHKeyManager.shared.resolveKey(id: UUID(), hint: unknown)) == nil)
    }

    /// A hint carrying only a NAME (and type) resolves to nothing. Names are
    /// user-assigned, non-unique and synced — matching on one would let a record
    /// named "work" select whatever local identity happens to share the label.
    ///
    /// Goes red if a name or key-type matching strategy is added to
    /// `resolveKey(id:hint:)`.
    @Test
    func testHintWithoutAFingerprintNeverSelectsAKeyByName() throws {
        var nameOnly = KeyResolutionHint()
        nameOnly.keyName = "id_ed25519"
        nameOnly.keyType = .ed25519

        #expect((SSHKeyManager.shared.resolveKey(id: UUID(), hint: nameOnly)) == nil)
    }

    /// No hint at all and no local key under that UUID resolves to nothing.
    /// Pins the `guard let hint else { return nil }` early exit.
    @Test
    func testAbsentHintResolvesToNothingForAnUnknownKeyID() throws {
        #expect((SSHKeyManager.shared.resolveKey(id: UUID(), hint: nil)) == nil)
    }
}
