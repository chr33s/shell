import Foundation
import Combine
import CoreText
import UIKit
import UniformTypeIdentifiers
import os

/// An OpenType font feature discovered from a font via CoreText
struct FontFeature: Identifiable, Hashable {
    let tag: String           // "ss01", "zero", etc.
    let name: String          // Human-readable name from font name table
    let aatTypeID: Int        // AAT feature type identifier
    let aatSelectorOn: Int    // AAT selector to enable the feature
    let aatSelectorOff: Int   // AAT selector to disable the feature
    var id: String { tag }
}

/// Manages font selection and registration for the app
@MainActor
final class FontManager: ObservableObject {
    static let shared = FontManager()

    /// Per-font cell box adjustments (percentage deltas).
    /// Maps to Ghostty `adjust-cell-width` / `adjust-cell-height` config keys.
    struct CellAdjustments: Codable, Equatable {
        var widthPercent: Int = 0
        var heightPercent: Int = 0

        var isZero: Bool { widthPercent == 0 && heightPercent == 0 }

        static let zero = CellAdjustments()
    }

    /// Sentinel key for cell adjustments stored against the Ghostty default font (nil family).
    static let defaultFontKey = "__default__"

    // A user-imported custom font family with one or more style variants
    // MARK: - Keys

    /// Registered keys this manager reloads from the store; file-backed font lists stay raw.
    private static let ownedKeys: Set<String> = [
        Settings.Font.size.name, Settings.Font.family.name, Settings.Font.ligatures.name,
        Settings.Font.featurePrefs.name, Settings.Font.cellAdjustmentPrefs.name
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    private var isReloading = false

    // MARK: - Published Properties

    /// Currently selected font size
    @Published var currentFontSize: Double {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveFontSize()
            fontSizeDidChange.send(currentFontSize)
        }
    }

    /// Currently selected font family (nil = Ghostty default)
    @Published var currentFontFamily: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveFontFamily()
            fontFamilyDidChange.send(currentFontFamily)
        }
    }

    /// Whether font ligatures are enabled
    @Published var ligaturesEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveLigaturesEnabled()
            ligaturesDidChange.send(ligaturesEnabled)
        }
    }

    /// Per-font enabled feature tags: [fontFamilyName: Set<tag>]
    @Published private(set) var enabledFontFeatures: [String: Set<String>] = [:]

    /// Per-font cell box adjustments. Key is font family configName, or
    /// `defaultFontKey` for the Ghostty default font (nil family).
    @Published private(set) var cellAdjustments: [String: CellAdjustments] = [:]

    // MARK: - Publishers

    let fontSizeDidChange = PassthroughSubject<Double, Never>()
    let fontFamilyDidChange = PassthroughSubject<String?, Never>()
    let ligaturesDidChange = PassthroughSubject<Bool, Never>()
    let fontFeaturesDidChange = PassthroughSubject<Void, Never>()
    let cellAdjustmentsDidChange = PassthroughSubject<Void, Never>()

    private let logger = Logger(subsystem: "dev.chr33s.shell", category: "FontManager")

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared

        // A stored 0 still falls back to the default size
        let savedSize = store.get(Settings.Font.size)
        self.currentFontSize = savedSize > 0 ? savedSize : Settings.Font.size.defaultValue

        // Load saved font family (nil = use Ghostty default)
        self.currentFontFamily = store.get(Settings.Font.family)

        self.ligaturesEnabled = store.get(Settings.Font.ligatures)

        self.enabledFontFeatures = Self.decodeFontFeatures(store.get(Settings.Font.featurePrefs))
        self.cellAdjustments = Self.decodeCellAdjustments(store.get(Settings.Font.cellAdjustmentPrefs))

        // Register the bundled fonts so Ghostty can resolve them. Device-wide
        // font catalog discovery (every family + glyph-advance probes) is not
        // run at launch: nothing in the app consumes a font catalog, and the
        // scan was measurable main-thread time before first paint.
        registerBundledFonts()

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Font.size.name) {
            let savedSize = store.get(Settings.Font.size)
            currentFontSize = savedSize > 0 ? savedSize : Settings.Font.size.defaultValue
        }
        if keys.contains(Settings.Font.family.name) { currentFontFamily = store.get(Settings.Font.family) }
        if keys.contains(Settings.Font.ligatures.name) { ligaturesEnabled = store.get(Settings.Font.ligatures) }
        if keys.contains(Settings.Font.featurePrefs.name) {
            enabledFontFeatures = Self.decodeFontFeatures(store.get(Settings.Font.featurePrefs))
            fontFeaturesDidChange.send()
        }
        if keys.contains(Settings.Font.cellAdjustmentPrefs.name) {
            cellAdjustments = Self.decodeCellAdjustments(store.get(Settings.Font.cellAdjustmentPrefs))
            cellAdjustmentsDidChange.send()
        }
    }

    private static func decodeFontFeatures(_ data: Data?) -> [String: Set<String>] {
        guard let data, let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded.mapValues { Set($0) }
    }

    private static func decodeCellAdjustments(_ data: Data?) -> [String: CellAdjustments] {
        guard let data, let decoded = try? JSONDecoder().decode([String: CellAdjustments].self, from: data) else { return [:] }
        return decoded
    }

    // MARK: - Font Registration

    /// Register all bundled TTF fonts with iOS so they can be discovered by CoreText
    private func registerBundledFonts() {
        guard let fontsURL = findFontsDirectory() else {
            logger.warning("Fonts directory not found in bundle")
            return
        }

        let fileManager = FileManager.default
        var registeredCount = 0

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Failed to create enumerator for fonts directory")
            return
        }

        for case let fileURL as URL in enumerator {
            // Only process TTF and OTF font files
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            let filename = fileURL.lastPathComponent

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                registeredCount += 1
                logger.debug("Registered font: \(filename)")
            } else if let cfError = error?.takeRetainedValue() {
                // Font might already be registered - not necessarily an error
                logger.debug("Font registration note for \(filename): \(cfError)")
            }
        }

        logger.info("Registered \(registeredCount) bundled fonts")
    }

    /// Find the fonts directory in the app bundle
    private func findFontsDirectory() -> URL? {
        let fileManager = FileManager.default

        // Try multiple possible locations (similar to ThemeManager)
        let possiblePaths: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("fonts"),
            Bundle.main.resourceURL?.appendingPathComponent("fonts"),
            Bundle.main.resourceURL?
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("fonts"),
            Bundle.main.bundleURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("fonts")
        ]

        for path in possiblePaths.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: path.path) {
                logger.info("Found fonts directory at: \(path.path)")
                return path
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func saveFontSize() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Font.size, currentFontSize)
    }

    private func saveFontFamily() {
        guard !isReloading else { return }
        if let family = currentFontFamily {
            SettingsStore.shared.set(Settings.Font.family, family)
        } else {
            SettingsStore.shared.reset(Settings.Font.family)
        }
    }

    private func saveLigaturesEnabled() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Font.ligatures, ligaturesEnabled)
    }

    private func saveFontFeaturePrefs() {
        let serializable = enabledFontFeatures.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(serializable) {
            SettingsStore.shared.set(Settings.Font.featurePrefs, data)
        }
    }

    private func saveCellAdjustments() {
        // Drop zeroed entries so the dict stays clean across launches.
        let pruned = cellAdjustments.filter { !$0.value.isZero }
        if let data = try? JSONEncoder().encode(pruned) {
            SettingsStore.shared.set(Settings.Font.cellAdjustmentPrefs, data)
        }
    }

    // MARK: - Config Application

    /// Apply the current font size to a Ghostty configuration
    func applyFontSize(to config: Ghostty.Config) -> Bool {
        return config.setFontSize(Int(currentFontSize))
    }

    /// Apply the current font family to a Ghostty configuration
    func applyFontFamily(to config: Ghostty.Config) -> Bool {
        guard let family = currentFontFamily else {
            // nil = use Ghostty default, nothing to apply
            return true
        }
        return config.setFontFamily(family)
    }

    // MARK: - Font Feature Discovery & Management

    /// AAT type/selector mappings for OpenType stylistic set features.
    /// Type 35 = kStylisticAlternativesType, Type 14 = kTypographicExtrasType.
    private static let aatToOpenType: [(aatTypeID: Int, aatSelectorOn: Int, aatSelectorOff: Int, tag: String)] = [
        (35, 2, 3, "ss01"),
        (35, 4, 5, "ss02"),
        (35, 6, 7, "ss03"),
        (35, 8, 9, "ss04"),
        (35, 10, 11, "ss05"),
        (35, 12, 13, "ss06"),
        (35, 14, 15, "ss07"),
        (35, 16, 17, "ss08"),
        (35, 18, 19, "ss09"),
        (35, 20, 21, "ss10"),
        (35, 22, 23, "ss11"),
        (35, 24, 25, "ss12"),
        (35, 26, 27, "ss13"),
        (35, 28, 29, "ss14"),
        (35, 30, 31, "ss15"),
        (35, 32, 33, "ss16"),
        (35, 34, 35, "ss17"),
        (35, 36, 37, "ss18"),
        (35, 38, 39, "ss19"),
        (35, 40, 41, "ss20"),
        (14, 4, 5, "zero")
    ]

    /// Discover available OpenType font features for the given font family.
    /// Uses CoreText AAT feature tables and maps to OpenType tags.
    func discoverFeatures(for fontFamily: String?) -> [FontFeature] {
        guard let familyName = fontFamily else { return [] }

        // Create a CTFont from the family name
        let ctFont = CTFontCreateWithName(familyName as CFString, 16, nil)

        // Verify we got the right font (CoreText may substitute)
        let resolvedFamily = CTFontCopyFamilyName(ctFont) as String
        guard resolvedFamily == familyName else {
            logger.debug("Font family mismatch: requested '\(familyName)', got '\(resolvedFamily)'")
            return []
        }

        // Get AAT feature tables
        guard let features = CTFontCopyFeatures(ctFont) as? [[String: Any]] else {
            return []
        }

        // Build lookup of available AAT type+selector pairs and their names
        var availableSelectors: [String: String] = [:]  // "typeID:selectorID" -> name
        for feature in features {
            guard let typeID = feature[kCTFontFeatureTypeIdentifierKey as String] as? Int,
                  let selectors = feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] else {
                continue
            }

            for selector in selectors {
                guard let selectorID = selector[kCTFontFeatureSelectorIdentifierKey as String] as? Int else {
                    continue
                }
                let name = selector[kCTFontFeatureSelectorNameKey as String] as? String ?? ""
                let key = "\(typeID):\(selectorID)"
                availableSelectors[key] = name
            }
        }

        // Cross-reference with our mapping table
        var result: [FontFeature] = []
        for mapping in Self.aatToOpenType {
            let onKey = "\(mapping.aatTypeID):\(mapping.aatSelectorOn)"
            guard let name = availableSelectors[onKey] else { continue }

            let displayName = name.isEmpty ? mapping.tag.uppercased() : name
            result.append(FontFeature(
                tag: mapping.tag,
                name: displayName,
                aatTypeID: mapping.aatTypeID,
                aatSelectorOn: mapping.aatSelectorOn,
                aatSelectorOff: mapping.aatSelectorOff
            ))
        }

        return result
    }

    /// Get the set of enabled feature tags for a font family
    func enabledFeatureTags(for fontFamily: String?) -> Set<String> {
        guard let family = fontFamily else { return [] }
        return enabledFontFeatures[family] ?? []
    }

    /// Toggle a font feature on or off for a font family
    func setFeatureEnabled(_ tag: String, enabled: Bool, for fontFamily: String?) {
        guard let family = fontFamily else { return }

        var tags = enabledFontFeatures[family] ?? []
        if enabled {
            tags.insert(tag)
        } else {
            tags.remove(tag)
        }
        enabledFontFeatures[family] = tags

        saveFontFeaturePrefs()
        fontFeaturesDidChange.send()
    }

    /// Return a copy of the font with the user's enabled features applied via AAT attributes.
    func applyEnabledFeatures(to font: UIFont, for fontFamily: String?) -> UIFont {
        guard let family = fontFamily else { return font }
        let enabledTags = enabledFontFeatures[family] ?? []
        guard !enabledTags.isEmpty else { return font }

        var featureSettings: [[UIFontDescriptor.FeatureKey: Int]] = []
        for mapping in Self.aatToOpenType where enabledTags.contains(mapping.tag) {
            featureSettings.append([
                .type: mapping.aatTypeID,
                .selector: mapping.aatSelectorOn
            ])
        }
        guard !featureSettings.isEmpty else { return font }

        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: featureSettings
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Generate Ghostty config lines for the current font's enabled features
    func fontFeatureConfigLines() -> [String] {
        let tags = enabledFeatureTags(for: currentFontFamily)
        return tags.sorted().map { "font-feature = \($0)" }
    }

    // MARK: - Cell Adjustments

    /// Storage key for a given font family (`defaultFontKey` when nil).
    private func cellAdjustmentKey(for fontFamily: String?) -> String {
        fontFamily ?? Self.defaultFontKey
    }

    /// Returns the saved cell adjustments for a font family, or `.zero` if none.
    func cellAdjustments(for fontFamily: String?) -> CellAdjustments {
        cellAdjustments[cellAdjustmentKey(for: fontFamily)] ?? .zero
    }

    /// Replace the cell adjustments for a font family. Persists and notifies.
    func setCellAdjustments(_ adjustments: CellAdjustments, for fontFamily: String?) {
        let key = cellAdjustmentKey(for: fontFamily)
        if adjustments.isZero {
            cellAdjustments.removeValue(forKey: key)
        } else {
            cellAdjustments[key] = adjustments
        }
        saveCellAdjustments()
        cellAdjustmentsDidChange.send()
    }

    /// Update only the width percentage for a font family.
    func setCellWidth(_ percent: Int, for fontFamily: String?) {
        var adj = cellAdjustments(for: fontFamily)
        adj.widthPercent = percent
        setCellAdjustments(adj, for: fontFamily)
    }

    /// Update only the height percentage for a font family.
    func setCellHeight(_ percent: Int, for fontFamily: String?) {
        var adj = cellAdjustments(for: fontFamily)
        adj.heightPercent = percent
        setCellAdjustments(adj, for: fontFamily)
    }

    /// Generate Ghostty config lines for the current font's cell adjustments.
    /// Zero-valued axes are omitted so the config stays minimal.
    func cellAdjustmentConfigLines() -> [String] {
        let adj = cellAdjustments(for: currentFontFamily)
        var lines: [String] = []
        if adj.widthPercent != 0 {
            lines.append("adjust-cell-width = \(adj.widthPercent)%")
        }
        if adj.heightPercent != 0 {
            lines.append("adjust-cell-height = \(adj.heightPercent)%")
        }
        return lines
    }
}
