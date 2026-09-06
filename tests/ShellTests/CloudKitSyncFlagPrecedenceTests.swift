import XCTest

@testable import Shell

/// Pins the precedence rules for the three per-record-class CloudKit sync
/// toggles (identity metadata, known hosts, connection profiles).
///
/// The bug this file exists for: the toggles are read with a plain
/// `bool(forKey:)`-shaped question, which cannot tell "the user has never been
/// asked" from "the user explicitly said no". Getting that wrong means a user
/// who turned Sync Profiles OFF and later cycled the master toggle silently got
/// profile sync back — their profiles start uploading again without being
/// asked. The rules are asymmetric on purpose: absent means ON when sync is
/// first enabled, and OFF at launch.
///
/// `setEnabled(true)` itself is unreachable from a test — it awaits
/// `CKContainer.accountStatus()` before it ever reaches the flag logic — so
/// the flag decisions were extracted into `firstEnableFlags` / `launchFlags`,
/// which `setEnabled` and `loadSettings` now call. That extraction is the only
/// production change; the expressions are unchanged.
///
/// Every read goes through an injected throwaway `UserDefaults` suite, so no
/// test here touches the real sync preferences.
@MainActor
final class CloudKitSyncFlagPrecedenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    private static let allKeys = [
        CloudKitSyncSettings.syncIdentityMetadataKey,
        CloudKitSyncSettings.syncHistoryKey,
        CloudKitSyncSettings.syncKnownHostsKey,
        CloudKitSyncSettings.syncProfilesKey,
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "dev.chr33s.shell.tests.sync-flags.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        for key in Self.allKeys {
            // A value leaking in from another domain would make "never chosen"
            // untestable and quietly turn these into passing no-ops.
            XCTAssertNil(defaults.object(forKey: key), "Test suite must start with no sync preferences at all")
        }
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - "never set" vs "set to false"

    /// The distinction the whole feature rests on. `bool(forKey:)` returns
    /// `false` for both an absent key and an explicit `false`; `storedChoice`
    /// must return `nil` for the first and `false` for the second.
    ///
    /// Fails the moment the `object(forKey:) != nil` presence check is dropped
    /// and `storedChoice` degrades to `bool(forKey:)`.
    func testAnUnwrittenPreferenceReadsAsNeverChosenNotAsOff() {
        let key = CloudKitSyncSettings.syncProfilesKey

        XCTAssertNil(CloudKitSyncManager.storedChoice(key, defaults: defaults), "Never written must read as nil")
        XCTAssertFalse(defaults.bool(forKey: key), "…even though bool(forKey:) cannot tell the difference")

        defaults.set(false, forKey: key)
        XCTAssertEqual(CloudKitSyncManager.storedChoice(key, defaults: defaults), false)

        defaults.set(true, forKey: key)
        XCTAssertEqual(CloudKitSyncManager.storedChoice(key, defaults: defaults), true)
    }

    // MARK: - First enable

    /// First enable on a device that has never been asked turns all three
    /// classes on. Fails if any `?? true` in `firstEnableFlags` becomes
    /// `?? false`.
    func testFirstEnableTurnsEveryUnchosenClassOn() {
        let flags = CloudKitSyncManager.firstEnableFlags(defaults: defaults)

        XCTAssertTrue(flags.identityMetadata)
        XCTAssertTrue(flags.knownHosts)
        XCTAssertTrue(flags.profiles)
    }

    /// THE REGRESSION. An explicit "off" survives the master toggle being
    /// cycled, and only the class the user actually turned off is affected.
    ///
    /// Fails if `firstEnableFlags` stops consulting the stored choice — e.g.
    /// goes back to assigning `true` outright — because `profiles` would then
    /// come back on and start uploading the user's connection profiles again.
    func testFirstEnablePreservesAnExplicitOffForThatClassOnly() {
        defaults.set(false, forKey: CloudKitSyncSettings.syncProfilesKey)

        let flags = CloudKitSyncManager.firstEnableFlags(defaults: defaults)

        XCTAssertFalse(flags.profiles, "An explicit 'off' must survive the master toggle being cycled")
        XCTAssertTrue(flags.knownHosts, "…and must not drag the classes the user never touched off with it")
        XCTAssertTrue(flags.identityMetadata)
    }

    /// An explicit "on" is honoured as an explicit choice too, not just
    /// coincidentally matched by the default.
    func testFirstEnableHonoursAnExplicitOnForEveryClass() {
        for key in Self.allKeys { defaults.set(true, forKey: key) }

        let flags = CloudKitSyncManager.firstEnableFlags(defaults: defaults)

        XCTAssertTrue(flags.identityMetadata)
        XCTAssertTrue(flags.knownHosts)
        XCTAssertTrue(flags.profiles)
    }

    // MARK: - Launch

    /// The asymmetry that makes the first-enable defaults safe: at launch an
    /// unwritten preference means OFF, so a device that has never been asked
    /// syncs nothing until it is.
    ///
    /// Fails if `launchFlags`' `?? false` is "harmonised" with the enable
    /// path's `?? true` — which would silently start syncing all three classes
    /// on the next launch of any device whose preferences were never written.
    func testLaunchTreatsAnUnwrittenPreferenceAsOffEvenWithSyncEnabled() {
        let flags = CloudKitSyncManager.launchFlags(syncEnabled: true, defaults: defaults)

        XCTAssertFalse(flags.identityMetadata)
        XCTAssertFalse(flags.knownHosts)
        XCTAssertFalse(flags.profiles)
    }

    /// Launch restores a stored "on" — otherwise the previous paragraph would
    /// be satisfiable by hard-coding `false`.
    func testLaunchRestoresStoredOnChoicesWhenSyncIsEnabled() {
        defaults.set(true, forKey: CloudKitSyncSettings.syncKnownHostsKey)
        defaults.set(false, forKey: CloudKitSyncSettings.syncProfilesKey)

        let flags = CloudKitSyncManager.launchFlags(syncEnabled: true, defaults: defaults)

        XCTAssertTrue(flags.knownHosts)
        XCTAssertFalse(flags.profiles)
    }

    /// While the master toggle is off nothing syncs, whatever the per-class
    /// preferences say. Fails if the `syncEnabled &&` gate is dropped from
    /// `launchFlags`.
    func testLaunchForcesEveryClassOffWhileTheMasterToggleIsOff() {
        for key in Self.allKeys { defaults.set(true, forKey: key) }

        let flags = CloudKitSyncManager.launchFlags(syncEnabled: false, defaults: defaults)

        XCTAssertFalse(flags.identityMetadata)
        XCTAssertFalse(flags.knownHosts)
        XCTAssertFalse(flags.profiles)
    }

    // MARK: - The identity-metadata key's two names

    /// A device that only ever wrote the inherited rootshell name
    /// (`cloudKitSyncHistory`) has made a real choice and must not be read as
    /// "never chosen" — otherwise first enable would flip its identity
    /// metadata back on.
    ///
    /// Fails if the legacy fallback in `storedIdentityMetadataChoice` is
    /// removed.
    func testIdentityMetadataFallsBackToTheLegacyHistoryKey() {
        defaults.set(false, forKey: CloudKitSyncSettings.syncHistoryKey)

        XCTAssertEqual(CloudKitSyncManager.storedIdentityMetadataChoice(defaults: defaults), false)
        XCTAssertFalse(CloudKitSyncManager.firstEnableFlags(defaults: defaults).identityMetadata)
    }

    /// When both names are present the UI-facing key wins, in both directions,
    /// so a stale legacy value can never override what the user last chose in
    /// Settings. Fails if the two `??` operands are swapped.
    func testIdentityMetadataPrefersTheUIKeyOverTheLegacyName() {
        defaults.set(true, forKey: CloudKitSyncSettings.syncIdentityMetadataKey)
        defaults.set(false, forKey: CloudKitSyncSettings.syncHistoryKey)
        XCTAssertEqual(CloudKitSyncManager.storedIdentityMetadataChoice(defaults: defaults), true)

        defaults.set(false, forKey: CloudKitSyncSettings.syncIdentityMetadataKey)
        defaults.set(true, forKey: CloudKitSyncSettings.syncHistoryKey)
        XCTAssertEqual(CloudKitSyncManager.storedIdentityMetadataChoice(defaults: defaults), false)
    }
}
