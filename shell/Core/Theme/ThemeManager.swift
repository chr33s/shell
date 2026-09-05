import Foundation
import Combine
import SwiftUI
import os

/// Manages theme selection and application across the app.
///
/// Migrated from `ObservableObject + @Published` to `@Observable`. SwiftUI now
/// tracks per-property reads, so views that only read `currentThemeInfo` no
/// longer invalidate when the (cold-path) `availableThemes` array reloads.
@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    /// The one theme the fork ships as its default (spec section 2.1).
    nonisolated static let defaultThemeName = "Blackboard Dark"

    /// Information about a theme.
    ///
    /// Boxed as a `final class` rather than a struct: previous (struct) builds
    /// caught the main thread inside `swift_cvw_initWithCopy` →
    /// `initializeWithCopy for ThemeManager.ThemeInfo` →
    /// `Array.subscript.read` during a scene-update transaction. Each
    /// `availableThemes[i]` access copied the
    /// struct (URL + ThemeColors with palette array). Reference semantics
    /// reduce per-access cost to a refcount op and remove the bridging
    /// `_ContiguousArrayStorage` paths the crash log captured. All properties
    /// remain `let`, so behavioral semantics are unchanged.
    final class ThemeInfo: Identifiable, Equatable, @unchecked Sendable {
        let id: String  // same as name
        let name: String
        let displayName: String
        let family: String
        let filePath: URL
        let colors: ThemeColors
        let isLight: Bool  // Pre-computed based on background luminance
        let isCustom: Bool

        /// The stored properties and memberwise init are `nonisolated` so the
        /// background theme parse can build these off the main thread. The
        /// computed accent helpers below stay main-actor isolated.
        struct ThemeColors: Equatable, Sendable {
            let background: String
            let foreground: String
            let cursor: String
            let palette: [String]  // 16 palette colors (ANSI 0-15)

            nonisolated init(background: String, foreground: String, cursor: String, palette: [String]) {
                self.background = background
                self.foreground = foreground
                self.cursor = cursor
                self.palette = palette
            }

            nonisolated static let `default` = ThemeColors(
                background: "#1e1e2e",
                foreground: "#cdd6f4",
                cursor: "#f5e0dc",
                palette: []
            )

            /// Returns a vibrant accent color suitable for UI tinting.
            /// If the cursor color is saturated enough (>= 0.20), uses it directly.
            /// Otherwise, picks from palette indices 1-6. When the background has
            /// appreciable hue (saturation > 0.10), prefers palette colors whose hue
            /// harmonizes with the background (within ±90°) to avoid clashing accents
            /// on chromatic backgrounds like dark teal or dark purple.
            var vibrantAccentColor: Color? {
                if let cursorColor = Color(hex: cursor), cursorColor.saturation >= 0.20 {
                    return cursorColor
                }
                // Pick from palette indices 1-6 (skip 0=black, 7=white)
                let candidates = palette.enumerated()
                    .filter { $0.offset >= 1 && $0.offset <= 6 }
                    .compactMap { (offset, hex) -> (Color, CGFloat)? in
                        guard let color = Color(hex: hex), color.saturation >= 0.20 else { return nil }
                        return (color, color.saturation)
                    }
                guard !candidates.isEmpty else { return nil }

                // If background is chromatic, prefer palette colors that harmonize with its hue
                if let bgColor = Color(hex: background), bgColor.saturation > 0.10 {
                    let harmonious = candidates.filter { $0.0.hueDifference(from: bgColor.hue) <= 0.25 }
                    if let best = harmonious.max(by: { $0.1 < $1.1 }) {
                        return best.0
                    }
                }

                // Default: most saturated
                return candidates.max(by: { $0.1 < $1.1 })?.0
            }

            /// Returns a sheet-safe accent color that preserves the theme hue
            /// but softens saturation and brightness against the sheet background.
            func sheetTintColor(for background: Color) -> Color? {
                vibrantAccentColor?.adjustedSheetTint(on: background)
            }
        }

        /// `nonisolated`: built off the main thread by the background theme parse.
        nonisolated init(name: String, filePath: URL, colors: ThemeColors, isCustom: Bool = false) {
            self.id = name
            self.name = name
            self.displayName = name
            self.family = ThemeInfo.extractFamily(from: name)
            self.filePath = filePath
            self.colors = colors
            self.isCustom = isCustom
            // Compute isLight based on background luminance (threshold 0.5)
            self.isLight = Color(hex: colors.background)?.luminance ?? 0 > 0.5
        }

        /// Extract theme family from name
        /// Examples: "Blackboard Dark" -> "Blackboard", "Dracula" -> "Dracula"
        nonisolated static func extractFamily(from name: String) -> String {
            // Common patterns for theme families
            let components = name.split(separator: " ")

            // If only one word, that's the family
            if components.count == 1 {
                return name
            }

            // For multi-word names, use first word as family
            // This handles: "Blackboard Dark", "Blackboard Light", etc.
            return String(components[0])
        }

        static func == (lhs: ThemeInfo, rhs: ThemeInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// True while `reload(keys:)` re-assigns `currentTheme` from the store.
    @ObservationIgnored private var isReloading = false

    /// All available themes. Empty until the background load lands; no launch
    /// path reads it, and the views that do read it observe this manager.
    private(set) var availableThemes: [ThemeInfo] = []

    /// Name → theme. Before the background load lands this holds only the themes
    /// actually asked for; afterwards it is the complete index. Internal cache —
    /// excluded from observation so refilling it doesn't invalidate views that
    /// only read the `current*` properties.
    @ObservationIgnored private var themesByName: [String: ThemeInfo] = [:]

    /// Names with no resolvable theme file. Negative-cached because
    /// `MainView+TabBarStyling` calls `themeInfo(for:)` per body evaluation.
    @ObservationIgnored private var unresolvableThemeNames: Set<String> = []

    /// Built-in themes from the background load, retained so `reloadThemes()`
    /// can re-merge custom themes without re-parsing the whole bundle. `nil`
    /// until that load lands.
    @ObservationIgnored private var builtInThemes: [ThemeInfo]?

    /// The in-flight (or finished) off-main-thread parse. Retained so cold paths
    /// can await it instead of re-parsing the bundle on the main actor.
    @ObservationIgnored private var builtInLoad: Task<[ThemeInfo], Never>?

    /// Bundled themes directory, resolved once at init.
    @ObservationIgnored private let themesDirectory: URL?

    /// Cached ThemeInfo for `currentTheme`. Updated when either the theme
    /// selection or the available themes change. This cache exists to avoid
    /// the O(n) scan + value-type copy that used to run in every body
    /// evaluation of MainView's tab bar.
    private(set) var currentThemeInfo: ThemeInfo?

    /// Currently selected theme name. `@Observable`'s synthesized accessors
    /// handle change notification — the previous manual `objectWillChange.send()`
    /// in `willSet` is no longer needed.
    var currentTheme: String {
        didSet {
            guard oldValue != currentTheme else { return }
            // Must go through the lazy path: DayNightThemeManager writes this
            // during launch, long before the full catalog lands.
            currentThemeInfo = themeInfo(for: currentTheme)
            guard ProtectedDataGuard.isAvailable else { return }
            saveTheme()
            themeDidChange.send(currentTheme)
        }
    }

    /// Publisher that emits when theme changes
    @ObservationIgnored let themeDidChange = PassthroughSubject<String, Never>()

    private init() {
        self.currentTheme = SettingsStore.shared.get(Settings.Theme.selected)

        self.themesDirectory = Self.locateThemesDirectory()

        // Parse exactly one theme file at launch. This init runs inside
        // Ghostty.App.init() — i.e. before RootShellApp.init()'s body — so the
        // full catalog (450+ files) is built off the main thread instead.
        self.currentThemeInfo = themeInfo(for: currentTheme)
        startBackgroundLoad()

        SettingsRefreshHub.shared.register(keys: [Settings.Theme.selected.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Save current theme through the settings store
    private func saveTheme() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Theme.selected, currentTheme)
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Theme.selected.name) {
            currentTheme = SettingsStore.shared.get(Settings.Theme.selected)
        }
    }

    /// Get ThemeInfo for a specific theme name, parsing the single backing file
    /// on a miss. The theme name is the file name, so the path is derivable
    /// without enumerating the whole directory.
    func themeInfo(for name: String) -> ThemeInfo? {
        if let cached = themesByName[name] { return cached }
        guard !unresolvableThemeNames.contains(name) else { return nil }

        guard let url = builtInThemeURL(for: name),
              let colors = Self.parseThemeFile(at: url) else {
            unresolvableThemeNames.insert(name)
            return nil
        }

        let info = ThemeInfo(name: name, filePath: url, colors: colors)
        themesByName[name] = info
        return info
    }

    /// Path for a bundled theme. Names reach us from persisted UserDefaults
    /// (tab/window overrides), so reject path traversal.
    private func builtInThemeURL(for name: String) -> URL? {
        guard let themesDirectory, !name.isEmpty, name != "..",
              !name.contains("/"), !name.contains("\\") else { return nil }
        return themesDirectory.appendingPathComponent(name)
    }

    /// Whether a bundled theme file with this name exists. One `stat`, so callers
    /// that only need an existence answer don't have to wait for the catalog.
    func builtInThemeExists(named name: String) -> Bool {
        guard let url = builtInThemeURL(for: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Await the full catalog. Only the views that render the entire theme list
    /// need this; everything else resolves single names via `themeInfo(for:)`.
    /// Awaits the existing background parse rather than redoing it on the main
    /// actor, and is a no-op once that parse has landed.
    func ensureThemesLoaded() async {
        guard builtInThemes == nil, let builtInLoad else { return }
        applyLoadedThemes(await builtInLoad.value)
    }

    /// Reload the built-in theme catalog.
    func reloadThemes() {
        // Drop the lazy caches so renamed/edited custom themes aren't served stale.
        themesByName.removeAll()
        unresolvableThemeNames.removeAll()
        guard builtInThemes != nil else {
            // Still parsing; that load will merge the new custom themes when it lands.
            Task { await ensureThemesLoaded() }
            return
        }
        rebuildCatalog()
    }

    // MARK: - Theme Loading

    /// Locate the bundled themes directory. Called once from `init`.
    nonisolated private static func locateThemesDirectory() -> URL? {
        let fileManager = FileManager.default

        // Try multiple possible locations for themes directory
        let possiblePaths: [URL?] = [
            // Direct in bundle (based on Ghostty's log output)
            Bundle.main.bundleURL.appendingPathComponent("themes"),

            // In resources directory
            Bundle.main.resourceURL?.appendingPathComponent("themes"),

            // In Resources/ghostty subdirectory
            Bundle.main.resourceURL?
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("themes"),

            // In bundle root's Resources/ghostty
            Bundle.main.bundleURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("themes")
        ]

        for path in possiblePaths.compactMap({ $0 }) where fileManager.fileExists(atPath: path.path) {
            Ghostty.logger.info("✓ Found themes directory at: \(path.path)")
            return path
        }

        Ghostty.logger.error("Failed to find themes directory in bundle. Checked paths:")
        for path in possiblePaths.compactMap({ $0 }) {
            Ghostty.logger.error("  - \(path.path)")
        }
        return nil
    }

    /// Parse every bundled theme file. Runs off the main thread.
    nonisolated private static func loadBuiltInThemes(from directory: URL) -> [ThemeInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            Ghostty.logger.error("Failed to enumerate themes at: \(directory.path)")
            return []
        }

        var themes: [ThemeInfo] = []
        themes.reserveCapacity(files.count)
        for fileURL in files {
            // `contentsOfDirectory` already prefetched this — no extra stat.
            guard (try? fileURL.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            // The file name is the theme name.
            let colors = parseThemeFile(at: fileURL) ?? .default
            themes.append(ThemeInfo(name: fileURL.lastPathComponent, filePath: fileURL, colors: colors))
        }
        return themes
    }

    /// Kick off the full catalog build. Only `currentTheme` is resolved
    /// synchronously at launch; `availableThemes` lands whenever this finishes.
    private func startBackgroundLoad() {
        guard let themesDirectory else { return }
        let load = Task.detached(priority: .utility) {
            ThemeManager.loadBuiltInThemes(from: themesDirectory)
        }
        builtInLoad = load
        Task { [weak self] in
            let themes = await load.value
            self?.applyLoadedThemes(themes)
        }
    }

    private func applyLoadedThemes(_ themes: [ThemeInfo]) {
        // `ensureThemesLoaded()` may have applied these already.
        guard builtInThemes == nil else { return }
        builtInThemes = themes
        rebuildCatalog()
    }

    /// Merge custom themes over the built-ins and publish the result.
    private func rebuildCatalog() {
        guard let builtIn = builtInThemes else { return }

        var themes = builtIn
        themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Reuse instances the lazy path already handed out, so landing the full
        // catalog doesn't churn `currentThemeInfo`'s identity and re-render the
        // tab bar for an identical theme.
        themes = themes.map { themesByName[$0.name] ?? $0 }

        var index: [String: ThemeInfo] = [:]
        index.reserveCapacity(themes.count)
        for theme in themes {
            index[theme.name] = theme
        }
        themesByName = index
        unresolvableThemeNames.removeAll()

        if currentThemeInfo !== index[currentTheme] {
            currentThemeInfo = index[currentTheme]
        }
        availableThemes = themes

        Ghostty.logger.info("Loaded \(themes.count) themes")
    }

    /// Returns `nil` when the file can't be read, which is how `themeInfo(for:)`
    /// tells an unknown theme name from a parsed one.
    nonisolated private static func parseThemeFile(at url: URL) -> ThemeInfo.ThemeColors? {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)

            var background = "#1e1e2e"
            var foreground = "#cdd6f4"
            var cursor = "#f5e0dc"
            var palette: [String] = []
            var paletteEntries: [Int: String] = [:]

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Skip empty lines and comments
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

                // Parse key = value (split on first "=" only to handle palette = 0=#hex)
                guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

                switch key {
                case "background":
                    background = value
                case "foreground":
                    foreground = value
                case "cursor-color":
                    cursor = value
                case "palette":
                    // Format: "N=#hex" e.g. "0=#45475a"
                    if let eqIdx = value.firstIndex(of: "=") {
                        let indexStr = value[value.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
                        let hex = value[value.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                        if let index = Int(indexStr) {
                            paletteEntries[index] = hex
                        }
                    }
                default:
                    break
                }
            }

            // Convert palette dict to ordered array (ANSI 0-15)
            palette = (0..<16).compactMap { paletteEntries[$0] }

            // Resolve Ghostty keyword values (e.g. "cell-foreground") to concrete hex
            cursor = Color.resolveKeywordColor(cursor, foreground: foreground, background: background)

            return ThemeInfo.ThemeColors(
                background: background,
                foreground: foreground,
                cursor: cursor,
                palette: palette
            )

        } catch {
            Ghostty.logger.error("Failed to parse theme file \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
