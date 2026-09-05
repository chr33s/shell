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
class FontManager: ObservableObject {
    static let shared = FontManager()

    /// Information about a bundled font family
    struct FontFamilyInfo: Identifiable, Equatable {
        let id: String
        let displayName: String
        let configName: String  // Name to use in Ghostty config
        let sampleFont: UIFont?  // For preview rendering

        static func == (lhs: FontFamilyInfo, rhs: FontFamilyInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

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

    /// A user-imported custom font family with one or more style variants
    // MARK: - Keys

    private static let nerdFontMigrationKey = "nerdFontFamilyMigrationDone"

    /// Registered keys this manager reloads from the store; file-backed font lists stay raw.
    private static let ownedKeys: Set<String> = [
        Settings.Font.size.name, Settings.Font.family.name, Settings.Font.ligatures.name,
        Settings.Font.featurePrefs.name, Settings.Font.cellAdjustmentPrefs.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    private var isReloading = false

    /// Maps old Nerd Font Mono family names to their unpatched replacements.
    /// Used for one-time migration when users had a nerd font family selected.
    private static let nerdFontFamilyMigration: [String: String] = [
        "GeistMono Nerd Font Mono": "Geist Mono",
    ]

    /// Bundled fonts used only for UI glyph rendering (profile icons, etc.).
    /// Registered with CoreText but never offered as terminal fonts.
    private static let hiddenUtilityFontFamilies: Set<String> = [
        "Symbols Nerd Font Mono",
    ]

    // MARK: - Published Properties

    /// All available bundled font families
    @Published private(set) var availableFamilies: [FontFamilyInfo] = []

    /// User-imported custom font families

    /// System-installed monospace font families (e.g., from Font Case)
    @Published private(set) var systemFontFamilies: [FontFamilyInfo] = []

    /// Bundled font families that have been replaced by custom imports

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
    private var fontRegistrationObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared

        // A stored 0 still falls back to the default size
        let savedSize = store.get(Settings.Font.size)
        self.currentFontSize = savedSize > 0 ? savedSize : Settings.Font.size.defaultValue

        // Load saved font family (nil = use Ghostty default)
        self.currentFontFamily = store.get(Settings.Font.family)

        self.ligaturesEnabled = store.get(Settings.Font.ligatures)

        // Clean up any previously-seeded legacy defaults (from earlier migration code)
        if UserDefaults.standard.bool(forKey: "fontFeatureMigrationV1Done") {
            store.reset(Settings.Font.featurePrefs)
            UserDefaults.standard.removeObject(forKey: "fontFeatureMigrationV1Done")
        }
        self.enabledFontFeatures = Self.decodeFontFeatures(store.get(Settings.Font.featurePrefs))
        self.cellAdjustments = Self.decodeCellAdjustments(store.get(Settings.Font.cellAdjustmentPrefs))

        // One-time migration: map old Nerd Font Mono family names to unpatched equivalents.
        // Skip when protected data is unavailable — bool(forKey:) returns false (not migrated)
        // which would write the migration-done flag to an empty/encrypted plist.
        if ProtectedDataGuard.isAvailable,
           !UserDefaults.standard.bool(forKey: Self.nerdFontMigrationKey) {
            if let current = self.currentFontFamily,
               let migrated = Self.nerdFontFamilyMigration[current] {
                self.currentFontFamily = migrated
                store.set(Settings.Font.family, migrated)
            }
            UserDefaults.standard.set(true, forKey: Self.nerdFontMigrationKey)
        }

        // Register bundled fonts with iOS, then load available families
        registerBundledFonts()

        loadAvailableFamilies()
        loadSystemFonts()
        setupFontRegistrationObserver()

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

    // MARK: - Load Available Families

    /// Scan the fonts directory and build list of available font families
    private func loadAvailableFamilies() {
        guard let fontsURL = findFontsDirectory() else { return }

        let fileManager = FileManager.default
        var familyMap: [String: (displayName: String, configName: String, fontURL: URL)] = [:]

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            let filename = fileURL.lastPathComponent

            // Extract font family name from the font file
            if let (familyName, configName) = extractFontInfo(from: fileURL) {
                // Skip UI-only utility fonts
                guard !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

                // Prefer Regular weight for preview
                let isRegular = filename.contains("Regular")
                if familyMap[familyName] == nil || isRegular {
                    familyMap[familyName] = (familyName, configName, fileURL)
                }
            }
        }

        // Build FontFamilyInfo array
        var families: [FontFamilyInfo] = []
        for (id, info) in familyMap {
            let sampleFont = createFont(from: info.fontURL, size: 16)

            families.append(FontFamilyInfo(
                id: id,
                displayName: info.displayName,
                configName: info.configName,
                sampleFont: sampleFont
            ))
        }

        // Sort alphabetically
        families.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        self.availableFamilies = families
        logger.info("Loaded \(families.count) font families")
    }

    // MARK: - System Font Discovery

    /// Discover monospace fonts installed on the device (e.g., via Font Case)
    private func loadSystemFonts() {
        let bundledConfigNames = Set(availableFamilies.map(\.configName))

        var systemFonts: [FontFamilyInfo] = []
        var seenFamilies = Set<String>()

        // Use UIFontDescriptor matching to discover all monospace fonts system-wide.
        // This finds fonts from UIFont.familyNames AND user-installed fonts (Font Case etc.)
        // when the com.apple.developer.user-fonts entitlement is present.
        let monoDescriptor = UIFontDescriptor(fontAttributes: [
            .traits: [UIFontDescriptor.TraitKey.symbolic: UIFontDescriptor.SymbolicTraits.traitMonoSpace.rawValue]
        ])
        let matchedDescriptors = monoDescriptor.matchingFontDescriptors(withMandatoryKeys: nil)
        let matchCount = matchedDescriptors.count
        logger.info("[SystemFonts] UIFontDescriptor monospace matches: \(matchCount)")

        for descriptor in matchedDescriptors {
            let font = UIFont(descriptor: descriptor, size: 16)
            let familyName = font.familyName

            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleFont: font
            ))
            seenFamilies.insert(familyName)
        }

        let traitCount = systemFonts.count
        logger.info("[SystemFonts] From trait matching: \(traitCount) monospace families")

        // Also check UIFont.familyNames with glyph-advance fallback for fonts that
        // don't set the monospace trait but are actually monospace (e.g., Berkeley Mono)
        for familyName in UIFont.familyNames {
            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

            guard let font = UIFont(name: familyName, size: 16) else { continue }
            guard self.isMonospaceByGlyphAdvance(font) else { continue }

            logger.info("[SystemFonts] Glyph-advance detected mono: '\(familyName)'")
            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleFont: font
            ))
            seenFamilies.insert(familyName)
        }

        // Check CoreText registered font descriptors for user-installed fonts
        // that may not appear in UIFont.familyNames or descriptor matching
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.user, true) as? [CTFontDescriptor] ?? []
        let ctCount = descriptors.count
        logger.info("[SystemFonts] CTFontManager .user scope: \(ctCount) descriptors")

        for descriptor in descriptors {
            guard let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else {
                continue
            }
            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

            let ctFont = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
            let uiFont = ctFont as UIFont
            let traits = uiFont.fontDescriptor.symbolicTraits
            let isMono = traits.contains(.traitMonoSpace) || self.isMonospaceByGlyphAdvance(uiFont)

            logger.info("[SystemFonts] CT user font: '\(familyName)' mono=\(isMono)")
            guard isMono else { continue }

            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleFont: uiFont
            ))
            seenFamilies.insert(familyName)
        }

        systemFonts.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        self.systemFontFamilies = systemFonts
        let totalCount = systemFonts.count
        logger.info("[SystemFonts] Total: \(totalCount) system monospace font families")
        for sf in systemFonts {
            let name = sf.displayName
            logger.info("[SystemFonts]   -> \(name)")
        }
    }

    /// Check if a font is monospace by comparing glyph advance widths.
    /// Some fonts (e.g., Berkeley Mono) don't set the OS/2 isFixedPitch flag,
    /// so UIFontDescriptor.symbolicTraits won't include .traitMonoSpace.
    /// This fallback compares advances of characters with typically extreme width differences.
    private func isMonospaceByGlyphAdvance(_ font: UIFont) -> Bool {
        let ctFont = font as CTFont
        var characters: [UniChar] = [0x004D, 0x0069, 0x0057, 0x002E] // M, i, W, .
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count) else { return false }
        guard glyphs.allSatisfy({ $0 != 0 }) else { return false }
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, characters.count)
        let ref = advances[0].width
        guard ref > 0 else { return false }
        return advances.allSatisfy { abs($0.width - ref) < 0.01 }
    }

    private func setupFontRegistrationObserver() {
        fontRegistrationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadSystemFonts()
            }
        }
    }

    /// Extract font family name and config name from a font file
    private func extractFontInfo(from url: URL) -> (displayName: String, configName: String)? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }

        // Create a CTFont to get the family name
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        let familyName = CTFontCopyFamilyName(ctFont) as String

        // The config name is the font family name as-is
        return (familyName, familyName)
    }

    /// Create a UIFont from a TTF file URL
    private func createFont(from url: URL, size: CGFloat) -> UIFont? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }

        let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        return ctFont as UIFont
    }

    /// Check if a CTFontManager registration error indicates a duplicate/already-registered font
    private func isAlreadyRegisteredError(_ error: Unmanaged<CFError>?) -> Bool {
        guard let cfError = error?.takeUnretainedValue() else { return false }
        let domain = CFErrorGetDomain(cfError) as String
        let code = CFErrorGetCode(cfError)
        // CTFontManagerError codes: .alreadyRegistered = 105, .duplicatedName = 106
        guard domain == kCTFontManagerErrorDomain as String else { return false }
        return code == 105 || code == 106
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

    // MARK: - Helper Properties

    /// Display name for the current font family
    var currentFontFamilyDisplayName: String {
        if let family = currentFontFamily {
            if let bundled = availableFamilies.first(where: { $0.configName == family }) {
                return bundled.displayName
            }
            if let system = systemFontFamilies.first(where: { $0.configName == family }) {
                return system.displayName
            }
            return family
        }
        return "Ghostty Default"
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
        (14, 4, 5, "zero"),
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
