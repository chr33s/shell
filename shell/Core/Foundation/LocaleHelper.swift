//
//  LocaleHelper.swift
//
//  Provides locale formatting utilities for SSH and local shell sessions
//
//  iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
//  which don't exist as valid POSIX locales on Linux servers. This helper extracts
//  language and region codes separately to produce clean POSIX-compatible locales.
//

import Foundation

/// Provides locale formatting utilities for SSH and local shell sessions
///
/// iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
/// which don't exist as valid POSIX locales on Linux servers. This helper extracts
/// language and region codes separately to produce clean POSIX-compatible locales.
///
/// All methods are explicitly `nonisolated` since `Locale.current` and `Locale.preferredLanguages`
/// are thread-safe and this helper is used from NIO event loop contexts.
enum LocaleHelper: Sendable {

    // MARK: - Forwarded Locale

    /// The locale forwarded to shells as `LANG`, or nil to leave `LANG` unset.
    ///
    /// The fork always forwards the device's own POSIX locale: there is no
    /// locale override, so every spawn path — the iOS built-in shell, the
    /// Catalyst PTY, the SSH PTY and the Citadel environment request — sends
    /// what `posixLocale` reports.
    nonisolated static var effectiveLocale: String? {
        posixLocale
    }

    /// The `LANGUAGE` value forwarded alongside `effectiveLocale`, or nil when
    /// the device reports no preferred language that maps to a server locale.
    nonisolated static var effectivePreferredLanguages: String? {
        preferredLanguages
    }

    // MARK: - System Locale

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
