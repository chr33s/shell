//
//  UIPasteboard+Extension.swift
//  shell
//
//  Provides opinionated clipboard reading for iOS terminals.
//

import UIKit
import UniformTypeIdentifiers

extension UIPasteboard {
    /// Gets clipboard contents with terminal-paste semantics:
    /// 1. URLs first — file URLs become shell-escaped absolute paths, other URLs
    ///    become their absoluteString. Matches upstream Ghostty macOS so that
    ///    copying a file from Finder pastes the full path, not just the filename.
    /// 2. Falls back to strictly-read plain-text UTIs (avoids Mac Catalyst's
    ///    `.string` bridge, which can surface HTML/RTF bytes when a source
    ///    registers only rich types).
    func getOpinionatedStringContents() -> String? {
        if let urls = self.urls, !urls.isEmpty {
            return urls
                .map { url -> String in
                    if url.isFileURL {
                        return Ghostty.Shell.escape(url.path)
                    } else {
                        return url.absoluteString
                    }
                }
                .joined(separator: " ")
        }

        if let text = strictPlainText(), !text.isEmpty {
            return text
        }

        return nil
    }

    /// Returns true if the pasteboard contains content suitable for pasting into a terminal.
    /// Mirrors `strictPlainText()` exactly (same keys, same exact-match semantics) so that
    /// menu enablement stays in sync with what the reader will actually accept.
    var hasPasteableContent: Bool {
        if hasURLs { return true }
        for item in self.items {
            for type in Self.plainTextPasteboardTypes where item[type] != nil {
                return true
            }
        }
        return false
    }

    /// Like `hasPasteableContent`, but uses only the iOS detection properties
    /// (`hasStrings`/`hasURLs`) that DO NOT trigger the paste-permission prompt.
    ///
    /// Use this for menu enablement (`canPerformAction`, long-press) — UIKit
    /// re-validates those on every app foreground while the terminal is first
    /// responder, so reading actual content there pops the iOS "would like to
    /// paste from X" dialog on every app switch. Use `hasPasteableContent` only
    /// at the moment the user actually invokes paste.
    var hasPasteableContentWithoutPrompt: Bool {
        hasStrings || hasURLs
    }

    /// UTIs we treat as plain text, in preference order. UTF-8 first, then UTF-16 variants,
    /// then the generic `public.plain-text` parent type for legacy sources.
    private static let plainTextPasteboardTypes: [String] = [
        UTType.utf8PlainText.identifier,
        UTType.utf16PlainText.identifier,
        UTType.utf16ExternalPlainText.identifier,
        UTType.plainText.identifier,
    ]

    /// Reads plain text from the pasteboard, accepting ONLY values registered under
    /// plain-text UTIs. Returns nil if the pasteboard has only HTML/RTF/rich content.
    /// Falls back to later items if the first has no plain-text UTI.
    private func strictPlainText() -> String? {
        for item in self.items {
            for type in Self.plainTextPasteboardTypes {
                if let s = item[type] as? String, !s.isEmpty {
                    return s
                }
                if let data = item[type] as? Data,
                   let s = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .utf16)
                        ?? String(data: data, encoding: .utf16LittleEndian)
                        ?? String(data: data, encoding: .utf16BigEndian),
                   !s.isEmpty {
                    return s
                }
            }
        }

        return nil
    }
}
