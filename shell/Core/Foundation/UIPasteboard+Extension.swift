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

    /// Reports whether the pasteboard likely holds pasteable content, using only the
    /// iOS detection properties (`hasStrings`/`hasURLs`) that DO NOT trigger the
    /// paste-permission prompt.
    ///
    /// Use this for menu enablement (`canPerformAction`, long-press) — UIKit
    /// re-validates those on every app foreground while the terminal is first
    /// responder, so reading actual content there pops the iOS "would like to
    /// paste from X" dialog on every app switch. The paste path itself reads the
    /// real content with `getOpinionatedStringContents()` and branches on nil.
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
                   let s = Self.decodePlainText(data, type: type) {
                    return s
                }
            }
        }

        return nil
    }

    /// Decodes raw pasteboard bytes, choosing the text encoding from the bytes and the
    /// UTI they were registered under rather than probing UTF-8 unconditionally.
    ///
    /// WAS BROKEN: a fixed `.utf8 ?? .utf16 ?? .utf16LittleEndian ?? .utf16BigEndian`
    /// chain was applied to every UTI, including the two UTF-16 ones. BOM-less
    /// UTF-16LE bytes decode *successfully* as UTF-8 — the interleaved 0x00 bytes are
    /// legal U+0000 scalars — so `.utf8` always won the chain and the UTF-16 attempts
    /// were unreachable. A pasted command line arrived NUL-interleaved, looked correct
    /// on screen, and wrote NULs to the shell. Pick the encoding from the UTI, and
    /// reject any decode containing U+0000: pasteable terminal text never holds NUL.
    /// Order is decided by a BOM first, then by NUL-byte parity, and only then by the
    /// UTI, so a producer that mislabels UTF-8 bytes under a UTF-16 UTI (no NUL bytes)
    /// still pastes correctly instead of turning into mojibake.
    private static func decodePlainText(_ data: Data, type: String) -> String? {
        // Byte order implied by the UTI, used only when the bytes themselves are
        // ambiguous: `public.utf16-plain-text` is Apple's native (little-endian) form,
        // `public.utf16-external-plain-text` is the external form (big-endian unmarked).
        let utiUTF16: String.Encoding
        switch type {
        case UTType.utf16PlainText.identifier: utiUTF16 = .utf16LittleEndian
        case UTType.utf16ExternalPlainText.identifier: utiUTF16 = .utf16BigEndian
        default: utiUTF16 = .utf16
        }

        let encodings: [String.Encoding]
        if hasUTF16BOM(data) {
            // A BOM is definitive; `.utf16` honors it and strips it.
            encodings = [.utf16, .utf8]
        } else if let inferred = inferredUTF16ByteOrder(data) {
            encodings = [inferred, utiUTF16, .utf8]
        } else {
            // No NUL bytes, so this cannot be ASCII-range UTF-16 — and it may be UTF-8
            // mislabeled under a UTF-16 UTI. Try UTF-8 before any UTF-16 reading, or a
            // UTF-16 decode would silently succeed and hand back mojibake.
            encodings = [.utf8, utiUTF16, .utf16]
        }

        for encoding in encodings {
            guard let s = String(data: data, encoding: encoding), !s.isEmpty else { continue }
            // Never accept a decode holding U+0000: that is the signature of UTF-16
            // bytes read as UTF-8, and pasteable terminal text never contains NUL.
            if s.unicodeScalars.contains(where: { $0.value == 0 }) { continue }
            return s
        }

        return nil
    }

    /// True when `data` starts with a UTF-16 byte-order mark (FF FE or FE FF).
    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let first = data[data.startIndex]
        let second = data[data.index(after: data.startIndex)]
        return (first == 0xFF && second == 0xFE) || (first == 0xFE && second == 0xFF)
    }

    /// Infers the byte order of BOM-less UTF-16 from where its NUL bytes fall: an
    /// ASCII-range code unit puts its zero byte at an odd offset in little-endian and
    /// at an even offset in big-endian. Returns nil when the data holds no NUL byte
    /// (so it is not ASCII-range UTF-16) or when the split is even (undecidable).
    private static func inferredUTF16ByteOrder(_ data: Data) -> String.Encoding? {
        var evenOffsetZeros = 0
        var oddOffsetZeros = 0
        for (offset, byte) in data.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenOffsetZeros += 1 } else { oddOffsetZeros += 1 }
        }
        if oddOffsetZeros > evenOffsetZeros { return .utf16LittleEndian }
        if evenOffsetZeros > oddOffsetZeros { return .utf16BigEndian }
        return nil
    }
}
