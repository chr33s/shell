//
//  SettingsRegistryInventoryTests.swift
//  ShellTests
//
//  An independent record of every setting the app owns, and of the ⌘T tmux
//  preference in particular.
//
//  WHY AN INVENTORY RATHER THAN A COVERAGE RULE
//  ============================================
//  The tempting test here is a *completeness* rule — "every registered setting
//  must be read somewhere". It would not have caught the bug that prompted
//  this file. `TmuxNewTabAction` was removed **coherently**: the `SettingKey`
//  came out of `Settings.Tmux.all` at the same time as its only reader, so a
//  derived rule stays satisfied and the registry simply gets one entry
//  shorter. Nothing is orphaned, so nothing is flagged.
//
//  What catches a coherent removal is a record the sweep does not own. The
//  table below is that record: settings are named by their **UserDefaults
//  string**, never by the `SettingKey` symbol, so deleting
//  `Settings.Tmux.newTabAction` does not delete the expectation that
//  `"tmuxNewTabAction"` is registered — it makes this test go red while still
//  compiling. Removing a setting on purpose means editing this table too,
//  which is a visible line in the diff instead of a silent absence.
//
//  The `configKey` column earns its place separately. It is the name the
//  setting has in the text config file and in the iCloud payload, so it is a
//  **wire format**: renaming one compiles, passes every behavioral test, and
//  silently orphans that setting's value on every other device the user owns.
//  The `policy` column is the same kind of hazard in the other direction —
//  flipping a key from `.deviceOnly` to `.synced` starts pushing it to iCloud.
//

import XCTest

@testable import Shell

@MainActor
final class SettingsRegistryInventoryTests: XCTestCase {

    struct Setting {
        let name: String
        let configKey: String?
        let policy: SyncPolicy

        init(_ name: String, configKey: String?, policy: SyncPolicy) {
            self.name = name
            self.configKey = configKey
            self.policy = policy
        }
    }

    /// Every setting the app is expected to register, by UserDefaults name.
    /// Adding a setting means adding a row; removing one means removing a row.
    static let expected: [Setting] = [
        Setting("ApplePressAndHoldEnabled", configKey: nil, policy: .deviceOnly),
        Setting("appearanceMode", configKey: "appearance-mode", policy: .synced),
        Setting("arrowJoystickMode", configKey: "arrow-joystick-mode", policy: .localByDefault),
        Setting("autoReconnectEnabled", configKey: "auto-reconnect-enabled", policy: .synced),
        Setting("autoReconnectMaxAttempts", configKey: "auto-reconnect-max-attempts", policy: .synced),
        Setting("backgroundBlurRadius", configKey: "background-blur", policy: .localByDefault),
        Setting("backgroundOpacity", configKey: "background-opacity", policy: .localByDefault),
        Setting("backgroundSessionKeepaliveEnabled", configKey: "background-session-keepalive-enabled", policy: .synced),
        Setting("blurEnabled", configKey: "blur-enabled", policy: .localByDefault),
        Setting("blurStyle", configKey: "blur-style", policy: .localByDefault),
        Setting("cellAdjustmentPrefs", configKey: nil, policy: .synced),
        Setting("cloudKitDeviceID", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitLastSyncDate", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitSyncAppSettings", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitSyncEnabled", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitSyncIdentityMetadata", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitSyncKnownHosts", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitSyncProfiles", configKey: nil, policy: .deviceOnly),
        Setting("cloudKitZoneChangeToken", configKey: nil, policy: .deviceOnly),
        Setting("compactPillTabSpacing", configKey: "compact-pill-tab-spacing", policy: .synced),
        Setting("composeAutocorrectEnabled", configKey: "compose-autocorrect-enabled", policy: .synced),
        Setting("copyOnSelect", configKey: "copy-on-select", policy: .synced),
        Setting("cursorBlinkEnabled", configKey: "cursor-style-blink", policy: .synced),
        Setting("cursorBlinkMode", configKey: "cursor-blink-mode", policy: .synced),
        Setting("cursorColor", configKey: "cursor-color", policy: .synced),
        Setting("cursorEffect", configKey: "cursor-effect", policy: .synced),
        Setting("cursorHeight", configKey: "cursor-height", policy: .synced),
        Setting("cursorOpacity", configKey: "cursor-opacity", policy: .synced),
        Setting("cursorStyle", configKey: "cursor-style", policy: .synced),
        Setting("cursorTextColor", configKey: "cursor-text", policy: .synced),
        Setting("cursorThickness", configKey: "cursor-thickness", policy: .synced),
        Setting("defaultSSHKeyIDs", configKey: nil, policy: .deviceOnly),
        Setting("doubleSpaceForPeriod", configKey: "double-space-for-period", policy: .synced),
        Setting("extendUnderHomeIndicator", configKey: "extend-under-home-indicator", policy: .localByDefault),
        Setting("externalGhosttyConfigPath", configKey: nil, policy: .deviceOnly),
        Setting("externalGhosttyConfigPath_bookmark", configKey: nil, policy: .deviceOnly),
        Setting("externalGhosttyConfigPath_originalFilename", configKey: nil, policy: .deviceOnly),
        Setting("fontFamily", configKey: "font-family", policy: .synced),
        Setting("fontFeaturePrefs", configKey: nil, policy: .synced),
        Setting("fontSize", configKey: "font-size", policy: .synced),
        Setting("forceASCIIKeyboard", configKey: "force-ascii-keyboard", policy: .synced),
        Setting("fullScreenModeEnabled", configKey: "full-screen-mode-enabled", policy: .localByDefault),
        Setting("hideWindowTitleBar", configKey: "hide-window-title-bar", policy: .localByDefault),
        Setting("keybindOverrides", configKey: nil, policy: .synced),
        Setting("keyboardToolbarConfig", configKey: nil, policy: .localByDefault),
        Setting("keyboardToolbarCustomKeys", configKey: nil, policy: .localByDefault),
        Setting("keyboardToolbarDeviceIdiom", configKey: nil, policy: .deviceOnly),
        Setting("keyboardToolbarDrawerOpenByDefault", configKey: "keyboard-toolbar-drawer-open-by-default", policy: .localByDefault),
        Setting("keyboardToolbarDrawerToggleMode", configKey: "keyboard-toolbar-drawer-toggle-mode", policy: .localByDefault),
        Setting("lastWindowHasOrigin", configKey: nil, policy: .deviceOnly),
        Setting("lastWindowHeight", configKey: nil, policy: .deviceOnly),
        Setting("lastWindowOriginX", configKey: nil, policy: .deviceOnly),
        Setting("lastWindowOriginY", configKey: nil, policy: .deviceOnly),
        Setting("lastWindowWidth", configKey: nil, policy: .deviceOnly),
        Setting("ligaturesEnabled", configKey: "ligatures-enabled", policy: .synced),
        Setting("lineScrollbackEnabled", configKey: "line-scrollback-enabled", policy: .localByDefault),
        Setting("localShellCommand", configKey: "local-shell-command", policy: .localByDefault),
        Setting("modTapRules", configKey: nil, policy: .synced),
        Setting("optionKeyAsAlt", configKey: "macos-option-as-alt", policy: .synced),
        Setting("persistentToolbar", configKey: "persistent-toolbar", policy: .localByDefault),
        Setting("pinnedSidebarTransparencyEnabled", configKey: "pinned-sidebar-transparency-enabled", policy: .localByDefault),
        Setting("powerAutoSaver", configKey: "power-auto-saver", policy: .localByDefault),
        Setting("powerBatteryRefreshRate", configKey: "power-battery-refresh-rate", policy: .localByDefault),
        Setting("powerMaxRefreshRate", configKey: "power-max-refresh-rate", policy: .localByDefault),
        Setting("promptAddNewline", configKey: "prompt-add-newline", policy: .synced),
        Setting("restoration.consecutiveFailures", configKey: nil, policy: .deviceOnly),
        Setting("restoration.inProgress", configKey: nil, policy: .deviceOnly),
        Setting("restoration.lastFailureTimestamp", configKey: nil, policy: .deviceOnly),
        Setting("rubberBandScrollbackEnabled", configKey: "rubber-band-scrollback-enabled", policy: .localByDefault),
        Setting("scrollModeEnabled", configKey: "scroll-mode-enabled", policy: .localByDefault),
        Setting("scrollbackLimit", configKey: "scrollback-limit", policy: .synced),
        Setting("scrollbackPersistenceEnabled", configKey: "scrollback-persistence-enabled", policy: .synced),
        Setting("selectedTheme", configKey: "theme", policy: .synced),
        Setting("selectionAppearanceMode", configKey: "selection-appearance-mode", policy: .synced),
        Setting("selectionBackgroundHex", configKey: "selection-background", policy: .synced),
        Setting("selectionForegroundHex", configKey: "selection-foreground", policy: .synced),
        Setting("sessionPersistenceEnabled", configKey: "session-persistence-enabled", policy: .synced),
        Setting("showTabScopeMenu", configKey: "show-tab-scope-menu", policy: .synced),
        Setting("showTabShortcutIndicators", configKey: "show-tab-shortcut-indicators", policy: .synced),
        Setting("showToolbarWithHardwareKeyboard", configKey: "show-toolbar-with-hardware-keyboard", policy: .localByDefault),
        Setting("splitFocusBorderColor", configKey: "split-focus-border-color", policy: .synced),
        Setting("splitFocusBorderCustomColor", configKey: "split-focus-border-custom-color", policy: .synced),
        Setting("splitFocusBorderStyle", configKey: "split-focus-border-style", policy: .synced),
        Setting("sshForceIPv4Enabled", configKey: "ssh-force-ipv4-enabled", policy: .synced),
        Setting("sshHealthMonitoringEnabled", configKey: "ssh-health-monitoring-enabled", policy: .synced),
        Setting("sshHealthProbeInterval", configKey: "ssh-health-probe-interval", policy: .synced),
        Setting("sshPasswordDefaultAuthRequirement", configKey: "ssh-password-default-auth-requirement", policy: .synced),
        Setting("sshPasswordDefaultStorageLevel", configKey: "ssh-password-default-storage-level", policy: .synced),
        Setting("sshPasswordLastUsedDates", configKey: nil, policy: .deviceOnly),
        Setting("syncSoftwareSSHKeys", configKey: nil, policy: .deviceOnly),
        Setting("tabBarAnimationsDisabled", configKey: "tab-bar-animations-disabled", policy: .synced),
        Setting("tabBarHidden", configKey: "tab-bar-hidden", policy: .synced),
        Setting("tabsInTitlebarEnabled", configKey: "tabs-in-titlebar-enabled", policy: .localByDefault),
        Setting("terminalTypeLocal", configKey: "terminal-type-local", policy: .localByDefault),
        Setting("terminalTypeRemote", configKey: "terminal-type-remote", policy: .synced),
        Setting("themedUI", configKey: "themed-ui", policy: .synced),
        Setting("titlebarLeadingInset", configKey: nil, policy: .deviceOnly),
        Setting("tmuxDefaultMode", configKey: "tmux-default-mode", policy: .synced),
        Setting("tmuxDiscoveryAttachMode", configKey: "tmux-discovery-attach-mode", policy: .synced),
        Setting("tmuxLastSessionByConnection", configKey: nil, policy: .deviceOnly),
        Setting("tmuxNewTabAction", configKey: "tmux-new-tab-action", policy: .synced),
        Setting("tmuxSessionName", configKey: "tmux-session-name", policy: .synced),
        Setting("tmuxTabCloseAction", configKey: "tmux-close-window-behavior", policy: .synced),
        Setting("topTabStyle", configKey: "top-tab-style", policy: .synced),
        Setting("twoFingerLongPressDuration", configKey: "two-finger-long-press-duration", policy: .synced),
        Setting("useNativeSelectionLoupe", configKey: "use-native-selection-loupe", policy: .synced),
        Setting("useTransientPrompt", configKey: "use-transient-prompt", policy: .synced),
    ]

    private var registry: SettingsRegistry { .shared }

    // MARK: - Inventory

    /// No setting disappears from the registry without its row here being
    /// deleted in the same change.
    ///
    /// This is the assertion that would have caught the `TmuxNewTabAction`
    /// removal: the sweep took the `SettingKey` and its reader together, the
    /// app still built, and nothing else noticed that an iCloud-synced
    /// preference had stopped existing.
    func testEveryRecordedSettingIsStillRegistered() {
        let live = Set(registry.definitions.keys)
        let missing = Self.expected.map(\.name).filter { !live.contains($0) }.sorted()

        XCTAssertEqual(
            missing, [],
            """
            These settings are recorded here but are no longer registered. Each one \
            is a user preference — several are synced to the user's other devices — \
            that has silently stopped existing. If the removal is intentional, delete \
            the matching rows from `SettingsRegistryInventoryTests.expected`; that \
            deletion is the review signal this test exists to force.
            """
        )
    }

    /// The inverse direction: a new setting must be recorded here. This is the
    /// maintenance cost that makes the test above meaningful — an inventory
    /// nobody updates decays into a list of things that used to be true.
    func testEveryRegisteredSettingIsRecordedInTheInventory() {
        let recorded = Set(Self.expected.map(\.name))
        let unrecorded = registry.definitions.keys.filter { !recorded.contains($0) }.sorted()

        XCTAssertEqual(
            unrecorded, [],
            "New settings must be added to `SettingsRegistryInventoryTests.expected`, with their configKey and sync policy."
        )
    }

    /// `configKey` is the setting's name in the text config file and in the
    /// iCloud payload. Renaming one compiles cleanly, passes every behavioral
    /// test, and orphans that setting's value on every other device the user
    /// owns — the old name is simply never read again.
    func testConfigKeyWireNamesAreUnchanged() {
        var drifted: [String] = []
        for setting in Self.expected {
            guard let live = registry.definitions[setting.name] else { continue }  // reported above
            if live.configKey != setting.configKey {
                drifted.append(
                    "\(setting.name): configKey \(setting.configKey ?? "nil") -> \(live.configKey ?? "nil")"
                )
            }
        }

        XCTAssertEqual(
            drifted, [],
            """
            A setting's config-file / iCloud name changed. This is a wire format: \
            the old name stops being read, so the value is orphaned on every other \
            device and in every existing config file. Renaming needs a migration, \
            not just an edit.
            """
        )
    }

    /// Sync policy decides whether a value leaves the device at all. Widening
    /// `.deviceOnly` to `.synced` starts uploading a key that was deliberately
    /// local; narrowing does the reverse and silently stops syncing something
    /// users expect to follow them.
    func testSyncPolicyIsUnchanged() {
        var drifted: [String] = []
        for setting in Self.expected {
            guard let live = registry.definitions[setting.name] else { continue }
            if live.policy != setting.policy {
                drifted.append("\(setting.name): \(setting.policy.rawValue) -> \(live.policy.rawValue)")
            }
        }

        XCTAssertEqual(drifted, [], "A setting's sync policy changed; check whether it should still leave the device.")
    }

    // MARK: - Registry self-consistency
    //
    // Deliberately NOT tested here. `SettingsRegistry.assertInvariants()` runs
    // at launch behind `assertionFailure`, so in the Debug configuration
    // `scripts/test.sh` uses, any violation it reports — a duplicate
    // configKey, a device-only key carrying one, a data blob with a configKey,
    // a volatile launch default disagreeing with the registry — traps the host
    // app before a single test method runs. A test asserting
    // `invariantViolations() == []` therefore cannot fail: the run dies first.
    // Verified by mutation: introducing a duplicate configKey, and separately a
    // drifted volatile default, both crash the host at launch rather than
    // reporting a red test. The invariant is enforced; adding an assertion for
    // it here would only look like coverage.

    // MARK: - The ⌘T tmux preference (defect: coherently removed once already)

    /// Looked up **by string**, on purpose. `registry.definition(for:)` is a
    /// dictionary lookup, so deleting `Settings.Tmux.newTabAction` from
    /// `Settings.Tmux.all` makes this return nil at run time instead of
    /// failing to compile — a red test in CI rather than a symbol that
    /// vanishes with everything that referenced it.
    func testTmuxNewTabActionSettingIsRegisteredWithItsSyncedConfigKey() throws {
        let definition = try XCTUnwrap(
            registry.definition(for: TmuxNewTabAction.storageKey),
            """
            The tmux New Tab Action setting is no longer registered. It has been \
            removed once before, together with its ⌘T reader, leaving the shortcut \
            silently pinned to "always local shell". See shell/Features/Tmux/TmuxNewTabAction.swift.
            """
        )

        XCTAssertEqual(definition.configKey, "tmux-new-tab-action")
        XCTAssertEqual(definition.group, .tmux)
        XCTAssertNotEqual(definition.policy, .deviceOnly, "The preference is meant to follow the user across devices.")
        XCTAssertTrue(registry.isSyncable(TmuxNewTabAction.storageKey))
    }

    /// `storageKey` and the registered `SettingKey` name must stay the same
    /// string. They are declared in different files, and nothing but this
    /// checks that they still agree.
    func testTmuxNewTabActionStorageKeyMatchesTheRegisteredName() {
        XCTAssertEqual(TmuxNewTabAction.storageKey, "tmuxNewTabAction")
        XCTAssertEqual(registry.definitions[TmuxNewTabAction.storageKey]?.name, TmuxNewTabAction.storageKey)
    }

    /// `.current` must actually read the store. A `TmuxNewTabAction.current`
    /// hardcoded to `.localShell` — which is what the removed code effectively
    /// became — passes a default-value check and fails this one.
    ///
    /// Restores the user's value in `defer`, and skips rather than reports a
    /// false pass if the simulator host cannot accept writes.
    func testTmuxNewTabActionCurrentReflectsTheStoredValue() throws {
        try XCTSkipUnless(
            ProtectedDataGuard.isAvailable,
            "SettingsStore drops writes while protected data is unavailable."
        )

        let store = SettingsStore.shared
        let original = store.isUserSet(TmuxNewTabAction.storageKey) ? TmuxNewTabAction.current : nil
        defer {
            if let original {
                store.set(Settings.Tmux.newTabAction, original)
            } else {
                store.reset(Settings.Tmux.newTabAction)
            }
        }

        // Every case, so a `current` wired to the wrong key (or to a constant)
        // cannot pass by matching the default.
        for action in TmuxNewTabAction.allCases {
            store.set(Settings.Tmux.newTabAction, action)
            XCTAssertEqual(
                TmuxNewTabAction.current, action,
                "TmuxNewTabAction.current does not reflect the stored value; ⌘T would ignore the user's choice."
            )
        }
    }

    /// The default is what ⌘T does for a user who never opened Settings, and
    /// it is the historical behavior the setting was added to preserve.
    func testTmuxNewTabActionDefaultsToLocalShell() {
        XCTAssertEqual(registry.definitions[TmuxNewTabAction.storageKey]?.defaultCodable, .string("localShell"))
    }

    /// All three cases must survive a round trip through the store's
    /// `CodableValue` representation. A case that fails validation is silently
    /// rejected on the way in from iCloud or a config file, so the user's
    /// choice reverts on their other devices only.
    func testEveryTmuxNewTabActionCaseSurvivesTheSettingsWireFormat() throws {
        let definition = try XCTUnwrap(registry.definitions[TmuxNewTabAction.storageKey])

        XCTAssertEqual(
            TmuxNewTabAction.allCases.map(\.rawValue), ["localShell", "tmuxTab", "ask"],
            "Raw values are the stored representation; renaming one discards existing users' choices."
        )
        for action in TmuxNewTabAction.allCases {
            XCTAssertTrue(
                definition.validate(.string(action.rawValue)),
                "\(action.rawValue) is rejected by the registry, so it can never arrive from iCloud or a config file."
            )
        }
        XCTAssertFalse(
            definition.validate(.string("notACase")),
            "The registry must reject unknown values rather than storing them."
        )
    }
}
