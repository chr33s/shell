import UIKit
import XCTest

@testable import Shell

/// Pins the tolerance of `ToolbarLayoutConfig.init(from:)` — the
/// `LenientKeySlot` wrapper — plus the drawer-row invariant and the on-disk
/// shape of a saved layout.
///
/// The bug this file exists for: a saved toolbar layout naming a `KeyID` a
/// later build no longer defines used to fail the whole decode, and the caller
/// fell back to `defaultConfig`. One removed key silently reset the user's
/// entire customised keyboard toolbar. The fix drops the single unusable slot
/// and keeps the layout.
@MainActor
final class ToolbarLayoutDecodingTests: XCTestCase {
    /// THE REGRESSION, main row. Fails if `LenientKeySlot`'s `try?` becomes a
    /// `try`, or the wrapper is removed from the `mainRow` decode — either way
    /// the decode throws and the caller resets to defaults.
    func testARemovedKeyInTheMainRowDropsOneSlotAndKeepsTheLayout() throws {
        let saved = customConfig()
        let data = try encode(saved) { json in
            var mainRow = try XCTUnwrap(json["mainRow"] as? [[String: Any]])
            mainRow.insert(try Self.unknownBuiltInSlot(like: mainRow[0]), at: 1)
            json["mainRow"] = mainRow
        }

        let decoded = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)

        XCTAssertEqual(decoded.mainRow, saved.mainRow, "Only the unusable slot may be dropped")
        XCTAssertEqual(decoded.drawerRows, saved.drawerRows)
        XCTAssertEqual(decoded.hiddenKeys, saved.hiddenKeys)
        XCTAssertNotEqual(
            decoded,
            ToolbarLayoutConfig.defaultConfig(for: .phone),
            "A layout with one removed key must not collapse back to the shipped defaults"
        )
        XCTAssertNotEqual(decoded, ToolbarLayoutConfig.defaultConfig(for: .pad))
    }

    /// THE REGRESSION, drawer rows. Covered separately because `drawerRows`
    /// goes through its own `decodeIfPresent` path; a leniency fix applied only
    /// to `mainRow` would leave this one throwing.
    func testARemovedKeyInADrawerRowDropsOneSlotAndKeepsEveryRow() throws {
        let saved = customConfig()
        let data = try encode(saved) { json in
            var rows = try XCTUnwrap(json["drawerRows"] as? [[[String: Any]]])
            rows[1].append(try Self.unknownBuiltInSlot(like: rows[0][0]))
            json["drawerRows"] = rows
        }

        let decoded = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)

        XCTAssertEqual(decoded.drawerRows, saved.drawerRows)
        XCTAssertEqual(decoded.mainRow, saved.mainRow)
    }

    /// A hidden-key entry naming a removed `KeyID` drops without failing the
    /// decode. Fails if the `compactMap(KeyID.init(rawValue:))` becomes a
    /// `map`/`decode` that throws on an unknown raw value.
    func testARemovedHiddenKeyDropsWithoutFailingTheDecode() throws {
        let saved = customConfig()
        let data = try encode(saved) { json in
            var hidden = try XCTUnwrap(json["hiddenKeys"] as? [String])
            hidden.append("a_key_removed_in_a_later_build")
            json["hiddenKeys"] = hidden
        }

        let decoded = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)

        XCTAssertEqual(decoded.hiddenKeys, saved.hiddenKeys)
    }

    /// The documented invariant: `drawerRows` is never empty. A layout saved
    /// before drawer rows existed has no `drawerRows` key at all and must
    /// decode to exactly one empty row, because the layout code indexes
    /// `drawerRows[0]` unconditionally (`migrate` does too).
    ///
    /// Fails if `?? [[]]` becomes `?? []`.
    func testALayoutSavedWithoutDrawerRowsDecodesToOneEmptyRow() throws {
        let data = try encode(customConfig()) { json in
            json.removeValue(forKey: "drawerRows")
        }

        let decoded = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)

        XCTAssertEqual(decoded.drawerRows, [[]])
    }

    /// Same invariant from the other direction: a persisted empty array is
    /// normalised to one empty row. Fails if the
    /// `rows.isEmpty ? [[]] : rows` normalisation is dropped.
    func testAnEmptyPersistedDrawerRowsArrayDecodesToOneEmptyRow() throws {
        let data = try encode(customConfig()) { json in
            json["drawerRows"] = [[String: Any]]()
        }

        let decoded = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)

        XCTAssertEqual(decoded.drawerRows, [[]])
    }

    /// Nothing valid is lost on the way through the lenient wrapper — the
    /// shipped defaults, the largest real layout there is, round-trip exactly.
    /// Fails if a shape change makes real slots decode to `nil`, which would
    /// otherwise be silent because dropping is the wrapper's whole job.
    func testTheShippedDefaultLayoutsRoundTripUnchanged() throws {
        for config in [ToolbarLayoutConfig.defaultConfig(for: .phone), ToolbarLayoutConfig.defaultConfig(for: .pad)] {
            let data = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data), config)
        }
    }

    /// The persisted format did not change when leniency was added: `encode`
    /// writes plain `KeySlot`s, never the lenient wrapper. Fails if anyone
    /// makes the wrapper symmetrical, renames a coding key, or changes a
    /// `KeyID` raw value — all of which strand already-saved layouts.
    ///
    /// `hiddenKeys` is a `Set`, so exactly one entry is used here; more would
    /// encode in an unspecified order.
    func testEncodedLayoutShapeIsUnchanged() throws {
        let config = ToolbarLayoutConfig(
            version: 13,
            mainRow: [.builtIn(.esc), .custom(UUID(uuidString: "00000000-0000-0000-0000-0000000000CD")!)],
            drawerRows: [[.builtIn(.ctrl)]],
            hiddenKeys: [.paste]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(config), as: UTF8.self)

        XCTAssertEqual(
            json,
            #"{"drawerRows":[[{"builtIn":{"_0":"ctrl"}}]],"hiddenKeys":["paste"],"mainRow":[{"builtIn":{"_0":"esc"}},{"custom":{"_0":"00000000-0000-0000-0000-0000000000CD"}}],"version":13}"#
        )
    }

    // MARK: - Helpers

    /// A layout that is nobody's default, so "did not reset to defaults" is a
    /// meaningful assertion.
    private func customConfig() -> ToolbarLayoutConfig {
        ToolbarLayoutConfig(
            version: ToolbarLayoutConfig.currentVersion,
            mainRow: [.builtIn(.esc), .builtIn(.tab), .builtIn(.drawerToggle)],
            drawerRows: [[.builtIn(.ctrl), .builtIn(.alt)], [.builtIn(.pipe)]],
            hiddenKeys: [.paste]
        )
    }

    /// Build a `builtIn` slot naming a `KeyID` this build does not define, by
    /// copying the shape of a real encoded slot rather than hard-coding it.
    private static func unknownBuiltInSlot(like real: [String: Any]) throws -> [String: Any] {
        var slot = real
        var payload = try XCTUnwrap(slot["builtIn"] as? [String: Any])
        payload["_0"] = "a_key_removed_in_a_later_build"
        slot["builtIn"] = payload
        return slot
    }

    private func encode(
        _ config: ToolbarLayoutConfig,
        corrupt: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(config)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        try corrupt(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }
}
