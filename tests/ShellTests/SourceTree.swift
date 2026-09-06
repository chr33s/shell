//
//  SourceTree.swift
//  ShellTests
//
//  Test-support: read the app's own Swift sources from disk.
//
//  Why a test reads source text at all
//  ===================================
//  Most of this target asserts on *runtime* behavior, which is the right
//  default. Four files here deliberately do not, because the bug class they
//  guard against cannot be caught any other way.
//
//  The failure this session kept hitting was **coherent removal**: a feature
//  deleted completely — declaration AND every caller — so the compiler stayed
//  happy and behavior silently vanished. A test that names the deleted symbol
//  is deleted by the same sweep that removes the symbol (it would not compile
//  otherwise), so it protects nothing. The only guards that survive a coherent
//  removal are ones whose reference to the feature is **late-bound**: a string
//  key, an ObjC selector looked up by name, or the source text itself.
//
//  So the suite uses, in order of preference:
//    1. Runtime + late-bound  — `MenuCommandChainTests` drives real ObjC
//       selectors by string and observes real notifications by raw name.
//       Genuine behavioral tests that cannot be swept away.
//    2. Runtime + string-keyed — `SettingsRegistryInventoryTests` looks
//       settings up in the registry by their UserDefaults name.
//    3. Source-text tripwires — `CoherentRemovalTripwireTests` and the scan in
//       `NotificationWiringTests`, for wiring that lives inside a SwiftUI
//       `View` body or `Commands` block and is not reachable at runtime.
//
//  Tier 3 is a lint wearing a test's clothes, and it is labelled that way in
//  the test names. It is not a substitute for a behavioral test; it is what is
//  available when the wiring sits somewhere a unit test cannot reach.
//
//  This works because the tests run in the iOS **Simulator**, which reads the
//  host Mac's filesystem directly, so `#filePath` still resolves at run time.
//  On a physical device the sources are absent and these tests skip rather
//  than fail — `scripts/test.sh` always uses the simulator.
//

import Foundation
import XCTest

enum SourceTree {
    /// Repository root, derived from this file's own compile-time path
    /// (`<root>/tests/ShellTests/SourceTree.swift`).
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ShellTests
        .deletingLastPathComponent()  // tests
        .deletingLastPathComponent()  // <root>

    /// The app target's source directory.
    static var appSources: URL { root.appendingPathComponent("shell") }

    static var isAvailable: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: appSources.path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    /// Skips the calling test when the checkout is not reachable (physical
    /// device, or a build artifact run detached from its source tree).
    static func requireSources() throws {
        try XCTSkipUnless(
            isAvailable,
            """
            App sources are not readable at \(appSources.path). Source-text \
            tripwires only run against a checkout — use scripts/test.sh, which \
            targets the iOS Simulator.
            """
        )
    }

    /// Every `.swift` file under `shell/`, sorted for deterministic output.
    static func swiftFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: appSources, includingPropertiesForKeys: nil
        ) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// Concatenation of every app source file. Used by tripwires that assert a
    /// call site still exists *somewhere*, so that moving code between files
    /// does not fail the test — only deleting it does.
    static func allAppSource() -> String {
        swiftFiles().compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// App source with the named files left out. Used where a symbol also
    /// appears inside its own implementation: searching everything would find
    /// the interpreter passing the callback down its own recursion and pass
    /// even after the only production *supplier* was removed.
    static func allAppSource(excludingFilesNamed excluded: Set<String>) -> String {
        swiftFiles()
            .filter { !excluded.contains($0.lastPathComponent) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    static func path(of file: URL) -> String {
        file.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
