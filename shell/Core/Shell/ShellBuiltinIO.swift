#if !targetEnvironment(macCatalyst)

import Foundation

/// Where a builtin's stdout or stderr is written while its redirections are
/// in effect.
nonisolated enum BuiltinOutputTarget: Equatable, Sendable {
    /// The interpreter's `writeOutput` sink (terminal, pipe or capture).
    case stdout
    /// The interpreter's `writeErrorOutput` sink.
    case stderr
    /// A file opened for the redirection; owned (and closed) by the command.
    case file(Int32)
    /// `>&-`: output is discarded.
    case closed
}

/// A builtin's redirected stdin: a `< file` or a here-document.
nonisolated enum BuiltinInputSource {
    case fileDescriptor(Int32)
    case text(BuiltinTextInput)

    /// Longest line `read` will buffer from a file, so `read x < /dev/zero`
    /// can't grow without bound.
    static let maxLineBytes = 1 << 20

    /// Read one line without its trailing newline. Returns nil at EOF with
    /// nothing read; a final unterminated line is returned as-is, matching
    /// how pipeline stdin behaves.
    func readLine(cancellation: CancellationToken) -> String? {
        switch self {
        case .text(let input):
            return input.readLine()
        case .fileDescriptor(let fd):
            // Byte at a time, like sh's `read` on an unseekable fd: leaves the
            // descriptor positioned just past the line for the next reader.
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while bytes.count < Self.maxLineBytes, !cancellation.isCancelled {
                let n = read(fd, &byte, 1)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
                if byte == 0x0A { break }
                bytes.append(byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Here-document text consumed line by line, so `eval 'read a; read b' <<EOF`
/// reads successive lines.
nonisolated final class BuiltinTextInput {
    private var remaining: Substring

    init(_ text: String) {
        remaining = Substring(text)
    }

    func readLine() -> String? {
        guard !remaining.isEmpty else { return nil }
        // Scan bytes, not Characters: "\r\n" is one Character and would hide
        // the newline from `firstIndex(of: "\n")`.
        if let newline = remaining.utf8.firstIndex(of: 0x0A) {
            let line = String(decoding: remaining.utf8[..<newline], as: UTF8.self)
            remaining = Substring(remaining.utf8[remaining.utf8.index(after: newline)...])
            return line
        }
        let line = remaining
        remaining = remaining[remaining.endIndex...]
        return String(line)
    }
}

#endif
