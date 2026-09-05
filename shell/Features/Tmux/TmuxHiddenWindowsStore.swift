//
//  TmuxHiddenWindowsStore.swift
//  shell
//
//  Hidden tmux windows: codec for the `@hidden` session user option, plus a
//  local UserDefaults mirror for instant apply on reattach.
//
//  The wire format follows the established tmux control-mode client
//  convention so the hidden set interoperates with other clients attached to
//  the same session: the option value is "i_" followed by the lowercase hex
//  encoding of the UTF-8 bytes of a comma-separated window-id list (bare
//  integers, no "@" prefix). An un-prefixed value is decoded as the plain
//  comma list (graceful fallback for hand-set options).
//

import Foundation

nonisolated enum TmuxHiddenWindowsCodec {
    /// The convention's marker for a hex-encoded hidden-window list.
    private static let prefix = "i_"

    /// "1,5,8" -> "i_" + hex of the UTF-8 bytes. Empty set -> "i_".
    /// Ids are sorted so the output is deterministic (stable dedup/compare).
    static func encode(_ ids: Set<Int>) -> String {
        let list = ids.sorted().map(String.init).joined(separator: ",")
        let hex = list.utf8.map { String(format: "%02x", $0) }.joined()
        return prefix + hex
    }

    /// Accepts "i_<hex>" (hex-decode then parse) or a plain comma list.
    /// Tolerates CRLF/whitespace (reply bodies arrive CRLF-terminated),
    /// an optional "@" per token, and skips unparseable tokens. Malformed
    /// hex (odd length / non-hex digits) decodes to the empty set.
    static func decode(_ raw: String) -> Set<Int> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let list: String
        if trimmed.hasPrefix(prefix) {
            guard let decoded = hexDecode(String(trimmed.dropFirst(prefix.count))) else { return [] }
            list = decoded
        } else {
            list = trimmed
        }
        var ids: Set<Int> = []
        for token in list.split(separator: ",") {
            var t = token.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("@") { t.removeFirst() }
            if let id = Int(t) { ids.insert(id) }
        }
        return ids
    }

    private static func hexDecode(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(),
                  let h = high.hexDigitValue, let l = low.hexDigitValue
            else { return nil }
            bytes.append(UInt8(h << 4 | l))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Local mirror of each session's hidden-window set, keyed by
/// "connectionKey|$sessionId". Applied synchronously on attach so a hidden
/// window never flashes visible while the authoritative `show ... @hidden`
/// reply is in flight. The server option is the source of truth; the mirror
/// is overwritten by every reply and every local mutation.
@MainActor
enum TmuxHiddenWindowsStore {
    private static let defaultsKey = "tmuxHiddenWindowsBySession"

    private static func key(connectionKey: String, sessionId: Int) -> String {
        "\(connectionKey)|$\(sessionId)"
    }

    static func load(connectionKey: String, sessionId: Int) -> Set<Int> {
        let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Int]]
        return Set(dict?[key(connectionKey: connectionKey, sessionId: sessionId)] ?? [])
    }

    static func save(_ ids: Set<Int>, connectionKey: String, sessionId: Int) {
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Int]]) ?? [:]
        let k = key(connectionKey: connectionKey, sessionId: sessionId)
        if ids.isEmpty {
            guard dict.removeValue(forKey: k) != nil else { return }
        } else {
            let sorted = ids.sorted()
            guard dict[k] != sorted else { return }
            dict[k] = sorted
        }
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
}
