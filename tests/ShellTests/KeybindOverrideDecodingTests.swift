import XCTest

@testable import Shell

/// Pins the tolerance of `KeybindManager.decodeUserOverrides` — the
/// `LenientKeybind` wrapper — and the on-disk shape of the override array.
///
/// The bug this file exists for: `[Keybind]` was decoded strictly, so a single
/// persisted override naming an action a later build had removed threw, the
/// `catch` reset `userOverrides` to `[]`, and the user's ENTIRE set of custom
/// shortcuts vanished. Because the override blob is an iCloud-synced setting,
/// the empty set was then written back and the loss propagated to every device.
///
/// `decodeUserOverrides` is a pure extraction of the body of the private
/// `loadUserOverrides`, added so this can be exercised against a `Data` value
/// instead of by writing the live synced setting from a test.
@MainActor
final class KeybindOverrideDecodingTests: XCTestCase {
    /// THE REGRESSION. One unusable entry drops; every other override survives,
    /// in order.
    ///
    /// Fails if `LenientKeybind`'s `try?` becomes a `try`, if the wrapper is
    /// removed, or if the outer `catch` is reached at all for an element-level
    /// failure — any of which takes the surviving count to 0.
    func testAnOverrideNamingARemovedActionDropsOnlyItselfAndKeepsTheRest() throws {
        let kept = Keybind(key: .t, modifiers: .command, action: .new_tab, isUserOverride: true, source: .userOverride)
        let doomed = Keybind(key: .k, modifiers: .command, action: .clear_screen, isUserOverride: true, source: .userOverride)
        let alsoKept = Keybind(key: .w, modifiers: .command, action: .close_tab, isUserOverride: true, source: .userOverride)

        let data = try encode([kept, doomed, alsoKept]) { entries in
            entries[1]["action"] = "an_action_removed_in_a_later_build"
        }

        let decoded = KeybindManager.decodeUserOverrides(data)

        XCTAssertEqual(decoded.count, 2, "One unknown action must not discard the whole override set")
        XCTAssertEqual(decoded.map(\.action), [.new_tab, .close_tab], "Survivors must keep their order")
        XCTAssertEqual(decoded, [kept, alsoKept], "Survivors must decode back to exactly what was saved")
    }

    /// Leniency is per-entry, not per-field: an override whose *trigger* no
    /// longer decodes drops the same way. Fails if the wrapper is narrowed to
    /// catch only unknown `action` values.
    func testAnOverrideNamingARemovedKeyCodeDropsOnlyItself() throws {
        let kept = Keybind(key: .t, modifiers: .command, action: .new_tab, isUserOverride: true, source: .userOverride)
        let doomed = Keybind(key: .k, modifiers: .command, action: .clear_screen, isUserOverride: true, source: .userOverride)

        let data = try encode([doomed, kept]) { entries in
            var sequence = try XCTUnwrap(entries[0]["sequence"] as? [String: Any])
            var triggers = try XCTUnwrap(sequence["triggers"] as? [[String: Any]])
            triggers[0]["key"] = "a_key_removed_in_a_later_build"
            sequence["triggers"] = triggers
            entries[0]["sequence"] = sequence
        }

        XCTAssertEqual(KeybindManager.decodeUserOverrides(data), [kept])
    }

    /// A blob that is not an override array at all (a truncated or corrupted
    /// iCloud write) yields no overrides rather than throwing out of
    /// `loadUserOverrides` or trapping. Fails if the outer `do/catch` becomes
    /// a `try!`.
    func testAStructurallyInvalidBlobYieldsNoOverridesRatherThanTrapping() {
        let notAnArray = Data(#"{"overrides": "corrupted"}"#.utf8)

        XCTAssertEqual(KeybindManager.decodeUserOverrides(notAnArray), [])
    }

    /// Nothing valid is lost on the way through the lenient wrapper. Fails if a
    /// future shape change makes real entries decode to `nil` — which would be
    /// silent, because dropping is exactly what the wrapper is supposed to do.
    func testEveryValidOverrideSurvivesTheLenientDecoderUnchanged() throws {
        let overrides = [
            Keybind(key: .t, modifiers: .command, action: .new_tab, isUserOverride: true, source: .userOverride),
            Keybind(key: .d, modifiers: [.command, .shift], action: .split_down, isUserOverride: true, source: .userOverride),
            Keybind(
                key: .p,
                modifiers: .command,
                action: .increase_font_size,
                actionParameter: "2",
                isUserOverride: true,
                source: .userOverride
            ),
        ]

        let data = try JSONEncoder().encode(overrides)

        XCTAssertEqual(KeybindManager.decodeUserOverrides(data), overrides)
    }

    /// The persisted format did not change when leniency was added: the wrapper
    /// is decode-only and never appears on the wire. Fails if anyone "fixes"
    /// tolerance by giving `Keybind` a custom `encode(to:)`, or renames a
    /// stored property, or changes a persisted raw value — all of which would
    /// make already-saved overrides unreadable on the next launch.
    func testEncodedOverrideShapeIsUnchanged() throws {
        let keybind = Keybind(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
            sequence: KeySequence(key: .t, modifiers: .command),
            action: .new_tab,
            actionParameter: nil,
            isUserOverride: true,
            source: .userOverride
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode([keybind]), as: UTF8.self)

        XCTAssertEqual(
            json,
            #"[{"action":"new_tab","id":"00000000-0000-0000-0000-0000000000AB","isUserOverride":true,"sequence":{"triggers":[{"key":"t","modifiers":8}]},"source":"user_override"}]"#
        )
    }

    // MARK: - Helpers

    /// Encode real `Keybind` values, then reach into the resulting JSON to
    /// corrupt one entry. Going through the encoder rather than hand-writing
    /// the JSON keeps these tests honest about the shape actually persisted.
    private func encode(
        _ keybinds: [Keybind],
        corrupt: (inout [[String: Any]]) throws -> Void
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(keybinds)
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        try corrupt(&entries)
        return try JSONSerialization.data(withJSONObject: entries)
    }
}
