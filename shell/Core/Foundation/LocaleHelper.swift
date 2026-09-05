//
//  LocaleHelper.swift
//
//  Provides locale formatting utilities for SSH/Mosh sessions
//
//  iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
//  which don't exist as valid POSIX locales on Linux servers. This helper extracts
//  language and region codes separately to produce clean POSIX-compatible locales.
//

import Foundation

/// Provides locale formatting utilities for SSH/Mosh sessions
///
/// iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
/// which don't exist as valid POSIX locales on Linux servers. This helper extracts
/// language and region codes separately to produce clean POSIX-compatible locales.
///
/// All methods are explicitly `nonisolated` since `Locale.current` and `Locale.preferredLanguages`
/// are thread-safe and this helper is used from NIO event loop contexts.
enum LocaleHelper: Sendable {

    // MARK: - Locale Override Mode

    /// How locale forwarding should behave
    enum LocaleMode: String, Sendable {
        /// Use the iOS system locale (default)
        case auto = "auto"
        /// Don't send any locale to remote servers
        case none = "none"
        /// Use a user-specified custom locale string
        case custom = "custom"
    }

    /// The currently configured locale mode
    nonisolated static var localeMode: LocaleMode {
        SettingsStore.shared.value(Settings.Locale.mode)
    }

    /// The user-specified custom locale string (only used when mode is `.custom`)
    nonisolated static var customLocale: String {
        SettingsStore.shared.value(Settings.Locale.custom)
    }

    // MARK: - Effective Locale (respects override)

    /// Returns the effective locale to send to remote servers, or nil if locale forwarding is disabled.
    ///
    /// - `.auto`: returns the system POSIX locale
    /// - `.none`: returns nil (don't send LANG/LANGUAGE)
    /// - `.custom`: returns the user-specified locale string
    nonisolated static var effectiveLocale: String? {
        switch localeMode {
        case .auto:
            return posixLocale
        case .none:
            return nil
        case .custom:
            let value = customLocale
            return value.isEmpty ? nil : value
        }
    }

    /// Returns the effective LANGUAGE value, or nil when locale is overridden or disabled.
    ///
    /// LANGUAGE is only meaningful when using the system locale (auto mode).
    /// In custom/none modes, we skip it entirely.
    nonisolated static var effectivePreferredLanguages: String? {
        guard localeMode == .auto else { return nil }
        return preferredLanguages
    }

    // MARK: - System Locale (always returns system value)

    /// Returns the system locale in POSIX format (e.g., "en_US.UTF-8")
    ///
    /// Uses the first preferred language from iOS settings, which contains
    /// both language and region as a BCP-47 tag (e.g., "en-US").
    ///
    /// This avoids the bug where `Locale.current.language.languageCode` and
    /// `Locale.current.region` are independent settings - a user with preferred
    /// language "English (US)" but region "Germany" would incorrectly produce
    /// "en_DE.UTF-8" if we mixed them.
    ///
    /// Falls back to "C.UTF-8" if preferred languages cannot be determined.
    ///
    /// The device pair is validated against glibc's supported locales: iOS
    /// happily pairs any language with any region (English + Mexico = en_MX),
    /// but glibc has no data for such combos, so no server can honor them.
    /// Invalid pairs fall back to a same-language locale servers do have.
    nonisolated static var posixLocale: String {
        guard let firstPreferred = Locale.preferredLanguages.first,
              let posix = serverCompatiblePosix(from: firstPreferred) else {
            return "C.UTF-8"
        }
        return posix
    }

    /// The raw device locale when it isn't one any server supports
    /// (e.g. "en_MX", or "zh-Hant-CN" when the script forced a substitute),
    /// or nil when the device locale is sent as-is.
    /// Used by settings UI to explain why a substitute locale is shown.
    nonisolated static var unsupportedDevicePair: String? {
        guard let firstPreferred = Locale.preferredLanguages.first,
              let (lang, script, region) = parseTag(firstPreferred) else {
            return nil
        }
        let naivePair = region.map { "\(lang)_\($0)" } ?? lang
        guard let resolved = serverCompatiblePosix(from: firstPreferred) else {
            return naivePair
        }
        let resolvedBase = String(resolved.prefix { $0 != "." })
        if resolvedBase == naivePair { return nil }
        if let script, let region, GlibcLocales.supportedPairs.contains(naivePair) {
            // The pair itself exists; the script subtag forced the change.
            return "\(lang)-\(script)-\(region)"
        }
        return naivePair
    }

    /// Returns the LANGUAGE environment variable value for gettext
    ///
    /// macOS/iOS has a concept of preferred languages separate from the system locale.
    /// The LANGUAGE env var overrides translations and uses colon-separated priority.
    ///
    /// Example: "en_US.UTF-8:de_DE.UTF-8" means prefer English, fall back to German.
    ///
    /// Returns nil if preferred languages cannot be determined.
    nonisolated static var preferredLanguages: String? {
        let preferred = Locale.preferredLanguages
        guard !preferred.isEmpty else { return nil }

        var seen = Set<String>()
        let formatted = preferred.compactMap { serverCompatiblePosix(from: $0) }
            .filter { seen.insert($0).inserted }
        guard !formatted.isEmpty else { return nil }

        return formatted.joined(separator: ":")
    }

    // MARK: - Validation

    /// Validation result for a custom locale string
    enum LocaleValidation: Equatable, Sendable {
        /// Locale looks valid (e.g. "en_US.UTF-8", "C.UTF-8")
        case valid
        /// Locale is empty
        case empty
        /// Looks like BCP-47 format with hyphens instead of underscores (e.g. "en-US.UTF-8")
        case bcp47Format
        /// Missing .UTF-8 suffix — terminal apps typically need UTF-8
        case missingUTF8
        /// Doesn't match any recognized locale pattern
        case invalidFormat
        /// Well-formed, but the language+region pair isn't in glibc's locale set
        case unknownServerLocale

        var warning: String? {
            switch self {
            case .valid, .empty:
                return nil
            case .bcp47Format:
                return "Use underscores instead of hyphens (e.g. en_US.UTF-8, not en-US.UTF-8)."
            case .missingUTF8:
                return "Missing .UTF-8 suffix. Terminal apps typically require a UTF-8 locale."
            case .invalidFormat:
                return "This doesn't look like a valid POSIX locale. Expected format: en_US.UTF-8"
            case .unknownServerLocale:
                return "Most servers don't have this locale. Consider en_US.UTF-8 or C.UTF-8."
            }
        }
    }

    /// Validates a custom locale string
    ///
    /// Checks for common issues:
    /// - BCP-47 hyphens instead of POSIX underscores
    /// - Missing .UTF-8 (or other codeset) suffix
    /// - Unrecognizable format
    nonisolated static func validate(_ locale: String) -> LocaleValidation {
        let trimmed = locale.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }

        // Special locales: C, C.UTF-8, POSIX
        if trimmed == "C" || trimmed == "POSIX" {
            return .missingUTF8
        }
        if trimmed == "C.UTF-8" {
            return .valid
        }

        // Check for BCP-47 hyphens (e.g. "en-US.UTF-8" or "en-US")
        // A locale with a hyphen between the language and region is BCP-47, not POSIX
        if trimmed.range(of: #"^[a-zA-Z]{2,3}-[a-zA-Z]{2}"#, options: .regularExpression) != nil {
            return .bcp47Format
        }

        // Standard POSIX pattern: lang[_REGION][.codeset][@modifier]
        // lang: 2-3 lowercase letters
        // REGION: 2 uppercase letters or 3 digits
        // codeset: e.g. UTF-8, ISO-8859-1
        let posixPattern = #"^[a-zA-Z]{2,3}(_[a-zA-Z]{2,3})?(\.[a-zA-Z0-9._-]+)?(@[a-zA-Z]+)?$"#
        guard trimmed.range(of: posixPattern, options: .regularExpression) != nil else {
            return .invalidFormat
        }

        // Warn if no codeset suffix (no dot) — terminal apps need UTF-8
        if !trimmed.contains(".") {
            return .missingUTF8
        }

        // Warn when the pair can't exist on servers (glibc has no data for it)
        let base = String(trimmed.prefix { $0 != "." && $0 != "@" })
        if base.contains("_") {
            if !GlibcLocales.supportedPairs.contains(base) {
                return .unknownServerLocale
            }
        } else if !GlibcLocales.languageOnly.contains(base) {
            return .unknownServerLocale
        }

        return .valid
    }

    /// Converts a BCP-47 language tag to a POSIX locale that servers can
    /// actually have, or nil if no glibc locale exists for the language.
    ///
    /// - Parameter tag: BCP-47 tag like "en-US", "en-MX", or "zh-Hans-CN"
    /// - Returns: A UTF-8 POSIX locale from glibc's supported set, preferring
    ///   the device's own region when valid, otherwise a same-language fallback.
    ///   Script subtags are honored: they can steer the region (zh-Hant-US
    ///   becomes zh_TW, not zh_CN) or add a glibc modifier (sr-Latn-RS
    ///   becomes sr_RS.UTF-8@latin).
    nonisolated static func serverCompatiblePosix(from tag: String) -> String? {
        guard let (lang, script, region) = parseTag(tag) else { return nil }
        guard let base = resolveBasePair(lang: lang, script: script, region: region) else {
            return nil
        }
        if let script, let modifier = GlibcLocales.scriptModifier["\(base)-\(script)"] {
            return "\(base).UTF-8@\(modifier)"
        }
        return "\(base).UTF-8"
    }

    /// Picks the glibc "lang_REGION" pair (or bare language) for the parsed tag.
    nonisolated private static func resolveBasePair(
        lang: String, script: String?, region: String?
    ) -> String? {
        // Script splits the language into distinct locale families (Hans/Hant
        // etc.): only regions of the matching family are acceptable.
        if let script, let preferred = GlibcLocales.scriptRegions["\(lang)-\(script)"] {
            if let region, preferred.contains(region),
               GlibcLocales.supportedPairs.contains("\(lang)_\(region)") {
                return "\(lang)_\(region)"
            }
            if let fallback = preferred.first(where: {
                GlibcLocales.supportedPairs.contains("\(lang)_\($0)")
            }) {
                return "\(lang)_\(fallback)"
            }
        }

        if let region, GlibcLocales.supportedPairs.contains("\(lang)_\(region)") {
            return "\(lang)_\(region)"
        }

        // CLDR macro regions (es-419 = Latin America) name a variant family,
        // not a country; map them to their representative glibc locale.
        if let region, let mapped = GlibcLocales.macroRegionPairs["\(lang)_\(region)"] {
            return mapped
        }

        // Device pair doesn't exist in glibc; pick a locale for the same
        // language that servers do ship data for.
        if let fallbackRegion = GlibcLocales.defaultRegion[lang],
           GlibcLocales.supportedPairs.contains("\(lang)_\(fallbackRegion)") {
            return "\(lang)_\(fallbackRegion)"
        }
        let mechanical = "\(lang)_\(lang.uppercased())"
        if GlibcLocales.supportedPairs.contains(mechanical) {
            return mechanical
        }
        if GlibcLocales.languageOnly.contains(lang) {
            return lang
        }
        return GlibcLocales.supportedPairs
            .filter { $0.hasPrefix("\(lang)_") }
            .sorted()
            .first
    }

    /// Extracts (language, script, region) from a BCP-47 tag.
    /// Uses component parsing so the script is never inferred, and
    /// "zh-Hans-CN" parses as zh + Hans + CN, not zh + region "Hans-CN".
    nonisolated private static func parseTag(
        _ tag: String
    ) -> (lang: String, script: String?, region: String?)? {
        let components = Locale.Language.Components(identifier: tag)
        guard let lang = components.languageCode?.identifier, !lang.isEmpty else {
            return nil
        }
        return (
            lang.lowercased(),
            components.script?.identifier,
            components.region?.identifier.uppercased()
        )
    }
}
