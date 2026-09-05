#if !targetEnvironment(macCatalyst)

import Foundation

/// `[[ ... ]]` conditional-expression evaluation.
///
/// Grammar (parsed into a tree first, then evaluated with short-circuiting):
///
///     or      := and ( '||' and )*
///     and     := not ( '&&' not )*
///     not     := '!' not | '(' or ')' | primary
///     primary := UNARY-OP operand
///              | operand BINARY-OP operand
///              | operand                       (true if non-empty)
///
/// Operands expand without field splitting or globbing. For `==`/`!=`/`=~`
/// the right-hand side keeps per-segment quote semantics: quoted segments
/// match literally, unquoted segments act as pattern/regex — so
/// `[[ $f == *".txt" ]]` works like bash.
nonisolated extension ShellInterpreter {

    func executeDoubleBracket(_ tokens: [DoubleBracketToken]) throws -> Int32 {
        var parser = DoubleBracketParser(tokens: tokens)
        do {
            let expr = try parser.parseExpression()
            guard parser.atEnd else {
                throw DoubleBracketError.syntax("unexpected token after expression")
            }
            return try evaluateDB(expr) ? 0 : 1
        } catch let error as DoubleBracketError {
            writeLine("sh: [[: \(error.message)")
            return 2
        }
    }

    private func evaluateDB(_ expr: DBExpr) throws -> Bool {
        try checkCancelled()
        switch expr {
        case .or(let l, let r):
            return try evaluateDB(l) || (try evaluateDB(r))
        case .and(let l, let r):
            return try evaluateDB(l) && (try evaluateDB(r))
        case .not(let e):
            return try !evaluateDB(e)
        case .single(let word):
            return try !dbString(word).isEmpty
        case .unary(let op, let word):
            return try evaluateDBUnary(op, word)
        case .binary(let lhs, let op, let rhs):
            return try evaluateDBBinary(lhs, op, rhs)
        }
    }

    /// Unary operators. The ones `test` implements delegate to it; the rest
    /// are handled here (delegating them would silently return false, and
    /// `-o` would be misread as test's binary OR).
    private func evaluateDBUnary(_ op: String, _ word: ShellWord) throws -> Bool {
        let operand = try dbString(word)
        let fm = FileManager.default

        func fileType(_ path: String) -> FileAttributeType? {
            (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        }
        func permissions(_ path: String) -> Int? {
            (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        }

        switch op {
        case "-v":
            // Operand is a variable NAME; set (even if empty) → true
            return environment.resolveSpecialVariable(operand) != nil
                || environment.getVariable(operand) != nil
        case "-o":
            switch operand {
            case "errexit":  return environment.options.errexit
            case "nounset":  return environment.options.nounset
            case "xtrace":   return environment.options.xtrace
            case "pipefail": return environment.options.pipefail
            default:         return false
            }
        case "-t":
            // The shell's stdio is always attached to the terminal UI except
            // in detached contexts (pipeline stages, background jobs).
            guard let fd = Int32(operand), (0...2).contains(fd) else { return false }
            return !environment.isIsolatedContext
        case "-N":
            // Modified since last read: mtime newer than atime
            var st = stat()
            guard stat(operand, &st) == 0 else { return false }
            let m = st.st_mtimespec, a = st.st_atimespec
            return m.tv_sec > a.tv_sec || (m.tv_sec == a.tv_sec && m.tv_nsec > a.tv_nsec)
        case "-p":
            var st = stat()
            return stat(operand, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO
        case "-S":
            return fileType(operand) == .typeSocket
        case "-b":
            return fileType(operand) == .typeBlockSpecial
        case "-c":
            return fileType(operand) == .typeCharacterSpecial
        case "-g":
            return permissions(operand).map { $0 & 0o2000 != 0 } ?? false
        case "-u":
            return permissions(operand).map { $0 & 0o4000 != 0 } ?? false
        case "-k":
            return permissions(operand).map { $0 & 0o1000 != 0 } ?? false
        case "-O", "-G":
            // Single-user sandbox: everything reachable is ours
            return fm.fileExists(atPath: operand)
        default:
            return ShellBuiltins.evaluateTestExpression([op, operand])
        }
    }

    private func evaluateDBBinary(_ lhs: ShellWord, _ op: String, _ rhs: ShellWord) throws -> Bool {
        switch op {
        case "=", "==":
            return ShellGlob.match(try dbString(lhs), pattern: try dbPattern(rhs))
        case "!=":
            return !ShellGlob.match(try dbString(lhs), pattern: try dbPattern(rhs))
        case "=~":
            let subject = try dbString(lhs)
            let pattern = try dbRegex(rhs)
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                throw DoubleBracketError.syntax("invalid regex: \(pattern)")
            }
            let range = NSRange(subject.startIndex..., in: subject)
            return regex.firstMatch(in: subject, range: range) != nil
        case "<":
            return try dbString(lhs) < (try dbString(rhs))
        case ">":
            return try dbString(lhs) > (try dbString(rhs))
        case "-ef":
            let a = try dbString(lhs), b = try dbString(rhs)
            let fm = FileManager.default
            guard let ai = try? fm.attributesOfItem(atPath: a)[.systemFileNumber] as? Int,
                  let bi = try? fm.attributesOfItem(atPath: b)[.systemFileNumber] as? Int else {
                return false
            }
            return ai == bi
        default:
            // Numeric comparisons, -nt/-ot, and string =/!=: shared with `test`
            return ShellBuiltins.evaluateTestExpression([try dbString(lhs), op, try dbString(rhs)])
        }
    }

    /// Expand an operand to its plain string value (no field split, no glob).
    private func dbString(_ word: ShellWord) throws -> String {
        try environment.expandScalarWord(word, interpreter: self)
    }

    /// Expand an operand as a glob pattern: quoted segments are escaped so
    /// they match literally; unquoted segments keep their glob power. An
    /// unquoted variable's *value* is pattern-active, matching bash.
    private func dbPattern(_ word: ShellWord) throws -> String {
        switch word {
        case .literal(let s):
            return s
        case .singleQuoted(let s):
            return Self.globEscape(s)
        case .doubleQuoted(let parts):
            return Self.globEscape(try parts.map { try dbString($0) }.joined())
        case .concat(let parts):
            return try parts.map { try dbPattern($0) }.joined()
        default:
            return try dbString(word)
        }
    }

    /// Expand an operand as a regex for `=~`: quoted segments escaped, the
    /// rest passed through verbatim.
    private func dbRegex(_ word: ShellWord) throws -> String {
        switch word {
        case .literal(let s):
            return s
        case .singleQuoted(let s):
            return NSRegularExpression.escapedPattern(for: s)
        case .doubleQuoted(let parts):
            return NSRegularExpression.escapedPattern(for: try parts.map { try dbString($0) }.joined())
        case .concat(let parts):
            return try parts.map { try dbRegex($0) }.joined()
        default:
            return try dbString(word)
        }
    }

    private static func globEscape(_ s: String) -> String {
        ShellGlob.escape(s)
    }
}

// MARK: - Expression tree

private nonisolated indirect enum DBExpr {
    case or(DBExpr, DBExpr)
    case and(DBExpr, DBExpr)
    case not(DBExpr)
    case unary(String, ShellWord)
    case binary(ShellWord, String, ShellWord)
    case single(ShellWord)
}

private nonisolated struct DoubleBracketError: Error {
    let message: String
    static func syntax(_ msg: String) -> DoubleBracketError { DoubleBracketError(message: msg) }
}

/// Recursive-descent parser over the classified tokens.
private nonisolated struct DoubleBracketParser {
    let tokens: [DoubleBracketToken]
    var index = 0

    var atEnd: Bool { index >= tokens.count }

    private mutating func peekOp() -> String? {
        guard index < tokens.count, case .op(let o) = tokens[index] else { return nil }
        return o
    }

    private static let unaryOps: Set<String> = [
        "-z", "-n", "-e", "-f", "-d", "-r", "-w", "-x", "-s",
        "-L", "-h", "-p", "-S", "-b", "-c", "-g", "-k", "-u",
        "-O", "-G", "-N", "-t", "-o", "-v",
    ]

    private static let binaryOps: Set<String> = [
        "=", "==", "!=", "=~", "<", ">",
        "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
        "-nt", "-ot", "-ef",
    ]

    mutating func parseExpression() throws -> DBExpr {
        try parseOr()
    }

    private mutating func parseOr() throws -> DBExpr {
        var left = try parseAnd()
        while peekOp() == "||" {
            index += 1
            left = .or(left, try parseAnd())
        }
        return left
    }

    private mutating func parseAnd() throws -> DBExpr {
        var left = try parseNot()
        while peekOp() == "&&" {
            index += 1
            left = .and(left, try parseNot())
        }
        return left
    }

    private mutating func parseNot() throws -> DBExpr {
        if peekOp() == "!" {
            index += 1
            return .not(try parseNot())
        }
        if peekOp() == "(" {
            index += 1
            let inner = try parseOr()
            guard peekOp() == ")" else {
                throw DoubleBracketError.syntax("expected ')'")
            }
            index += 1
            return inner
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> DBExpr {
        guard index < tokens.count else {
            throw DoubleBracketError.syntax("expression expected")
        }

        // Unary operator
        if let op = peekOp() {
            guard Self.unaryOps.contains(op) else {
                throw DoubleBracketError.syntax("unexpected operator '\(op)'")
            }
            index += 1
            guard index < tokens.count, case .operand(let word) = tokens[index] else {
                throw DoubleBracketError.syntax("operand expected after '\(op)'")
            }
            index += 1
            return .unary(op, word)
        }

        guard case .operand(let lhs) = tokens[index] else {
            throw DoubleBracketError.syntax("operand expected")
        }
        index += 1

        // Binary operator?
        if let op = peekOp(), Self.binaryOps.contains(op) {
            index += 1
            guard index < tokens.count, case .operand(let rhs) = tokens[index] else {
                throw DoubleBracketError.syntax("operand expected after '\(op)'")
            }
            index += 1
            return .binary(lhs, op, rhs)
        }

        return .single(lhs)
    }
}

#endif
