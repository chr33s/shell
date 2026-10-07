import Foundation

/// tmux control-mode wire format: `%`-notifications, `%begin`/`%end`
/// blocks, octal-escaped `%output`, and layout strings.
enum TmuxProtocol {
    /// Splits a byte stream into lines, keeping an incomplete tail.
    struct LineSplitter {
        private var partial: [UInt8] = []
        /// Lines longer than this are cut (a broken stream must not grow
        /// memory without bound).
        static let maxLine = 16 << 20

        mutating func push(_ bytes: [UInt8], _ line: ([UInt8]) -> Void) {
            var start = 0
            for i in bytes.indices where bytes[i] == 0x0A {
                var chunk = partial
                chunk.append(contentsOf: bytes[start ..< i])
                partial.removeAll(keepingCapacity: true)
                if chunk.last == 0x0D {
                    chunk.removeLast()
                }
                line(chunk)
                start = i + 1
            }
            if start < bytes.count {
                partial.append(contentsOf: bytes[start...])
                if partial.count > Self.maxLine {
                    partial.removeAll()
                }
            }
        }

        mutating func reset() {
            partial.removeAll()
        }
    }

    /// Decodes `%output` data: `\ooo` octal escapes for control bytes and
    /// backslash; everything else is literal.
    static func decodeOutput(_ data: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            if b == 0x5C, data.endIndex - i >= 4, let v = octal(data[i + 1], data[i + 2], data[i + 3]) {
                out.append(v)
                i += 4
                continue
            }
            out.append(b)
            i += 1
        }
        return out
    }

    private static func octal(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        let digits = [a, b, c]
        guard digits.allSatisfy({ (0x30 ... 0x37).contains($0) }) else { return nil }
        let v = Int(a - 0x30) << 6 | Int(b - 0x30) << 3 | Int(c - 0x30)
        return v <= 0xFF ? UInt8(v) : nil
    }

    /// `@12` → 12, `%3` → 3, `$0` → 0.
    static func id<S: StringProtocol>(_ s: S, prefix: Character) -> Int? {
        guard s.first == prefix else { return nil }
        return Int(s.dropFirst())
    }

    /// Quotes a string for a tmux command line (ESC and BEL as `\e`, `\a`).
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "\u{1B}", with: "\\e")
            .replacingOccurrences(of: "\u{07}", with: "\\a") + "\""
    }
}

/// One node of a tmux window layout.
final class TmuxLayout {
    enum Kind: UInt32 { case pane = 0, horizontal = 1, vertical = 2 }

    let kind: Kind
    let width: Int, height: Int, x: Int, y: Int
    let paneID: Int
    let children: [TmuxLayout]

    init(kind: Kind, width: Int, height: Int, x: Int, y: Int, paneID: Int, children: [TmuxLayout]) {
        self.kind = kind
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.paneID = paneID
        self.children = children
    }

    /// Parses `csum,WxH,X,Y,ID` / `...{a,b}` / `...[a,b]`, the checksum optional.
    static func parse(_ s: String) -> TmuxLayout? {
        var chars = Array(s.utf8)[...]
        // Drop the leading 4-hex-digit checksum when present.
        if chars.count > 5, chars[chars.startIndex + 4] == 0x2C,
           chars.prefix(4).allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) {
            chars = chars.dropFirst(5)
        }
        guard let node = parseNode(&chars), chars.isEmpty else { return nil }
        return node
    }

    private static func number(_ s: inout ArraySlice<UInt8>) -> Int? {
        var v = 0, n = 0
        while let c = s.first, c >= 0x30, c <= 0x39 {
            v = v * 10 + Int(c - 0x30)
            n += 1
            s = s.dropFirst()
        }
        return n > 0 ? v : nil
    }

    private static func expect(_ s: inout ArraySlice<UInt8>, _ c: UInt8) -> Bool {
        guard s.first == c else { return false }
        s = s.dropFirst()
        return true
    }

    private static func parseNode(_ s: inout ArraySlice<UInt8>) -> TmuxLayout? {
        guard let w = number(&s), expect(&s, 0x78), let h = number(&s), expect(&s, 0x2C),
              let x = number(&s), expect(&s, 0x2C), let y = number(&s) else { return nil }
        if let open = s.first, open == 0x7B || open == 0x5B { // { horizontal, [ vertical
            s = s.dropFirst()
            let close: UInt8 = open == 0x7B ? 0x7D : 0x5D
            var children: [TmuxLayout] = []
            while true {
                guard let child = parseNode(&s) else { return nil }
                children.append(child)
                if expect(&s, 0x2C) { continue }
                guard expect(&s, close) else { return nil }
                break
            }
            return TmuxLayout(kind: open == 0x7B ? .horizontal : .vertical, width: w, height: h, x: x, y: y, paneID: 0, children: children)
        }
        guard expect(&s, 0x2C), let id = number(&s) else { return nil }
        return TmuxLayout(kind: .pane, width: w, height: h, x: x, y: y, paneID: id, children: [])
    }

    /// Leaf panes, left-to-right / top-to-bottom.
    var panes: [TmuxLayout] {
        kind == .pane ? [self] : children.flatMap(\.panes)
    }
}
