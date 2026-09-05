#if !targetEnvironment(macCatalyst)

import Foundation

/// Character-by-character lexer that produces `ShellToken`s from shell source text.
///
/// The tokenizer handles:
/// - Single quotes (literal, no expansion)
/// - Double quotes (preserves `$VAR`, `$(cmd)`, `$((expr))` markers for the parser)
/// - Backslash escaping
/// - Keyword recognition in command position
/// - `VAR=value` assignment detection in command position
/// - Here-document tracking (`<<EOF` / `<<'EOF'`)
/// - Comments (`#` to end of line)
/// - All shell operators and redirections
///
/// The tokenizer is `nonisolated` and `Sendable` — it runs on commandQueue.
nonisolated final class ShellTokenizer: @unchecked Sendable {
    // Unicode Private Use Area markers for preserving quoting context.
    // These are embedded into word text so the parser can reconstruct
    // .singleQuoted / .doubleQuoted ShellWord nodes.
    static let singleQuoteStart: Character = "\u{E001}"
    static let singleQuoteEnd:   Character = "\u{E002}"
    static let doubleQuoteStart: Character = "\u{E003}"
    static let doubleQuoteEnd:   Character = "\u{E004}"

    // `$@` expansion markers (interpreter-side): `fieldSeparator` joins the
    // positional params and forces a field break even inside double quotes —
    // that's what makes `"$@"` produce one field per parameter. `emptyAtMarker`
    // is what `$@` expands to with zero params, so a word that was solely
    // `"$@"` can vanish instead of yielding one empty field. Both are scrubbed
    // from any expansion that doesn't field-split (see finalizeScalarExpansion).
    static let fieldSeparator: Character = "\u{E005}"
    static let emptyAtMarker:  Character = "\u{E006}"

    private let source: String
    private var chars: String.UnicodeScalarView
    private var index: String.UnicodeScalarView.Index
    private var line: Int = 1

    /// Whether the next word should be checked for keyword status.
    /// True at start of input, after `;`, `\n`, `&&`, `||`, `|`, `then`, `do`, etc.
    private var inCommandPosition = true

    /// Whether the current simple command has seen any non-assignment words yet.
    /// Assignment words (`VAR=val`) are only valid before the first non-assignment word.
    private var seenNonAssignment = false

    /// Pending here-document specs: after tokenizing a `<<DELIM`, we need to
    /// collect the here-doc body after the next newline.
    private var pendingHeredocs: [HeredocSpec] = []

    /// Collected here-doc contents in order, for the parser to retrieve.
    /// Each entry stores (delimiter, content, quoted). Uses an array (not a dict)
    /// so repeated delimiters like two <<EOF blocks don't collide.
    private var collectedHeredocs: [(delimiter: String, content: String, quoted: Bool)] = []

    /// Token that has been peeked but not yet consumed.
    private var peekedToken: ShellToken?

    init(source: String) {
        self.source = source
        self.chars = source.unicodeScalars
        self.index = self.chars.startIndex
    }

    // MARK: - Public API

    /// Returns the next token without consuming it.
    func peek() -> ShellToken {
        if let t = peekedToken { return t }
        let t = readNextToken()
        peekedToken = t
        return t
    }

    /// Consumes and returns the next token.
    func next() -> ShellToken {
        if let t = peekedToken {
            peekedToken = nil
            return t
        }
        return readNextToken()
    }

    /// Current line number (for error messages).
    var currentLine: Int { line }

    // MARK: - Character Helpers

    private var isAtEnd: Bool { index >= chars.endIndex }

    private func currentChar() -> UnicodeScalar? {
        guard !isAtEnd else { return nil }
        return chars[index]
    }

    private func peekChar() -> UnicodeScalar? {
        guard !isAtEnd else { return nil }
        let next = chars.index(after: index)
        guard next < chars.endIndex else { return nil }
        return chars[next]
    }

    @discardableResult
    private func advance() -> UnicodeScalar? {
        guard !isAtEnd else { return nil }
        let c = chars[index]
        index = chars.index(after: index)
        if c == "\n" { line += 1 }
        return c
    }

    private func advanceIf(_ c: UnicodeScalar) -> Bool {
        if currentChar() == c {
            advance()
            return true
        }
        return false
    }

    // MARK: - Main Tokenizer Loop

    private func readNextToken() -> ShellToken {
        skipSpacesAndTabs()

        // Collect pending here-document bodies after a newline
        // (handled inside readNewline)

        guard let c = currentChar() else {
            return .eof
        }

        // Line continuation between tokens: backslash followed by newline.
        // Consume both and re-enter so the next token comes from the
        // following line (without an intervening newline token).
        if c == "\\", let next = peekChar(), next == "\n" {
            advance() // consume `\`
            advance() // consume `\n`
            return readNextToken()
        }

        // Comment: # to end of line (only when not inside a word)
        if c == "#" {
            skipComment()
            return readNextToken()
        }

        // Newline
        if c == "\n" {
            return readNewline()
        }

        // bash `[[ … ]]` test expression — has its own parsing rules
        // (regex `=~`, parens around regex groups, `&&`/`||` between
        // conditions, etc.), none of which compose with our word/operator
        // tokenizer. Slurp until the matching `]]` and emit as one word so
        // the parser treats it as an opaque condition.
        if c == "[", let next = peekChar(), next == "[" {
            if let word = tryReadDoubleBracket() {
                return word
            }
        }

        // Arithmetic command `(( expr ))` — only in command position, so
        // `$((...))` (handled in word scanning) and nested subshells written
        // with a space (`( (cmd) )`) are unaffected.
        if inCommandPosition, c == "(", let next = peekChar(), next == "(" {
            if let word = tryReadDoubleParen() {
                return word
            }
        }

        // Operators
        if let op = tryReadOperator() {
            return op
        }

        // Word (may be a keyword, assignment, or plain word)
        return readWord()
    }

    private func skipSpacesAndTabs() {
        while let c = currentChar(), c == " " || c == "\t" {
            advance()
        }
    }

    private func skipComment() {
        // # to end of line
        while let c = currentChar(), c != "\n" {
            advance()
        }
    }

    /// Slurp a command-position `(( expr ))` arithmetic command into one word
    /// (`((expr))`), balancing inner parens. Returns nil (falling back to
    /// subshell tokenization) if no matching `))` is found.
    private func tryReadDoubleParen() -> ShellToken? {
        let savedIndex = index
        var content = "(("
        advance() // first (
        advance() // second (

        var depth = 0
        while let ch = currentChar() {
            if ch == "(" {
                depth += 1
                content.append("(")
                advance()
                continue
            }
            if ch == ")" {
                if depth > 0 {
                    depth -= 1
                    content.append(")")
                    advance()
                    continue
                }
                if let p = peekChar(), p == ")" {
                    content.append("))")
                    advance(); advance()
                    seenNonAssignment = true
                    inCommandPosition = false
                    return .word(content)
                }
                // Lone `)` at depth 0 without a partner: not an arithmetic
                // command (e.g. `((cmd); echo)` nested subshell)
                break
            }
            content.append(Character(ch))
            advance()
        }

        index = savedIndex
        return nil
    }

    /// Try to slurp a `[[ … ]]` test expression as a single word token.
    /// Tracks single/double quotes so a `]]` inside a string doesn't terminate
    /// early. Returns nil (so the caller can fall through to readWord) if the
    /// `[[` isn't followed by whitespace — which means it's not actually the
    /// test operator.
    private func tryReadDoubleBracket() -> ShellToken? {
        let savedIndex = index
        // Confirm this is `[[` followed by whitespace (true bash test
        // operator). Without that, fall through to normal word tokenization.
        let i1 = chars.index(after: index)
        guard i1 < chars.endIndex, chars[i1] == "[" else { return nil }
        let i2 = chars.index(after: i1)
        guard i2 < chars.endIndex else { return nil }
        let third = chars[i2]
        guard third == " " || third == "\t" || third == "\n" else { return nil }

        var content = "[["
        advance() // first `[`
        advance() // second `[`

        var bracketDepth = 0

        // Quoted regions are encoded with the same PUA sentinels as readWord,
        // so the parser can split the interior on unquoted whitespace and
        // hand operands to parseShellWord with real quote semantics.
        while let ch = currentChar() {
            if ch == "'" {
                content += String(Self.singleQuoteStart) + readSingleQuotedRaw() + String(Self.singleQuoteEnd)
                continue
            }
            if ch == "\"" {
                content += String(Self.doubleQuoteStart) + readDoubleQuotedRaw() + String(Self.doubleQuoteEnd)
                continue
            }
            if ch == "\\" {
                advance()
                guard let next = currentChar() else { continue }
                if next == "\n" {
                    advance() // line continuation
                    continue
                }
                // Escaped char becomes a literal (quoted) single character:
                // keeps `\ ` from splitting and `\*` from glob-matching.
                content += String(Self.singleQuoteStart) + String(advance()!) + String(Self.singleQuoteEnd)
                continue
            }
            if ch == "[", let p = peekChar(), p == "[" {
                bracketDepth += 1
                content.append("[[")
                advance(); advance()
                continue
            }
            if ch == "]", let p = peekChar(), p == "]" {
                if bracketDepth > 0 {
                    bracketDepth -= 1
                    content.append("]]")
                    advance(); advance()
                    continue
                }
                content.append("]]")
                advance(); advance()
                seenNonAssignment = true
                inCommandPosition = false
                return .word(content)
            }
            content.append(Character(ch))
            advance()
        }

        // Reached EOF without `]]` — abandon and let normal tokenizer try.
        index = savedIndex
        return nil
    }

    // MARK: - Newline and Here-document Collection

    private func readNewline() -> ShellToken {
        advance() // consume \n

        // Collect any pending here-document bodies
        collectPendingHeredocs()

        inCommandPosition = true
        seenNonAssignment = false
        return .newline
    }

    private func collectPendingHeredocs() {
        guard !pendingHeredocs.isEmpty else { return }

        let specs = pendingHeredocs
        pendingHeredocs.removeAll()

        for spec in specs {
            let content = collectHeredocBody(delimiter: spec.delimiter, stripTabs: spec.stripTabs)
            spec.collectedContent = content
            collectedHeredocs.append((delimiter: spec.delimiter, content: content, quoted: spec.quoted))
        }
    }

    /// Retrieve and consume the next collected here-document matching a delimiter.
    /// Consumes the first match so repeated delimiters return different bodies.
    func getHeredocContent(delimiter: String) -> (content: String, quoted: Bool)? {
        guard let idx = collectedHeredocs.firstIndex(where: { $0.delimiter == delimiter }) else {
            return nil
        }
        let entry = collectedHeredocs[idx]
        collectedHeredocs.remove(at: idx)
        return (content: entry.content, quoted: entry.quoted)
    }

    private func collectHeredocBody(delimiter: String, stripTabs: Bool) -> String {
        var body = ""
        while !isAtEnd {
            // Read one line
            var lineText = ""
            while let c = currentChar(), c != "\n" {
                lineText.append(String(advance()!))
            }
            // Consume the newline
            if currentChar() == "\n" {
                advance()
            }

            // Check if this line is the delimiter
            let checkLine = stripTabs ? lineText.drop(while: { $0 == "\t" }) : lineText[...]
            if checkLine == delimiter {
                return body
            }

            if stripTabs {
                lineText = String(lineText.drop(while: { $0 == "\t" }))
            }
            body += lineText + "\n"
        }
        // Hit EOF without finding delimiter — return what we have
        return body
    }

    // MARK: - Operators

    private func tryReadOperator() -> ShellToken? {
        guard let c = currentChar() else { return nil }

        switch c {
        case ";":
            advance()
            if advanceIf(";") {
                inCommandPosition = true
                seenNonAssignment = false
                return .dsemi
            }
            inCommandPosition = true
            seenNonAssignment = false
            return .semicolon

        case "|":
            advance()
            if advanceIf("|") {
                inCommandPosition = true
                seenNonAssignment = false
                return .orIf
            }
            inCommandPosition = true
            seenNonAssignment = false
            return .pipe

        case "&":
            advance()
            if advanceIf("&") {
                inCommandPosition = true
                seenNonAssignment = false
                return .andIf
            }
            // Check for &> (redirect stdout+stderr)
            if let next = currentChar(), next == ">" {
                advance()
                let target = readRedirectTarget()
                return .redirect(Redirection(op: .duplicateOutput, target: target))
            }
            inCommandPosition = true
            seenNonAssignment = false
            return .ampersand

        case "(":
            advance()
            inCommandPosition = true
            seenNonAssignment = false
            return .lparen

        case ")":
            advance()
            // After `)`, the next token is in command position again:
            // function bodies (`name() { … }`), subshells preceding a separator
            // or pipe, and `case` pattern bodies all expect a fresh command.
            // Without this, `name() { … }` tokenizes the `{` as a plain word
            // and the brace group fails to parse (Homebrew install.sh line 12
            // crash repro).
            inCommandPosition = true
            seenNonAssignment = false
            return .rparen

        case "<":
            return readInputRedirect()

        case ">":
            return readOutputRedirect()

        default:
            // Check for 2> or 2>> (stderr redirect)
            if c == "2", let next = peekChar(), next == ">" {
                advance() // consume '2'
                advance() // consume '>'
                if advanceIf(">") {
                    let target = readRedirectTarget()
                    return .redirect(Redirection(op: .errorAppendTo, fd: 2, target: target))
                }
                if advanceIf("&") {
                    let target = readRedirectTarget()
                    return .redirect(Redirection(op: .mergeStderrStdout, fd: 2, target: target))
                }
                let target = readRedirectTarget()
                return .redirect(Redirection(op: .errorTo, fd: 2, target: target))
            }
            return nil
        }
    }

    private func readInputRedirect() -> ShellToken {
        advance() // consume '<'

        if advanceIf("<") {
            // Here-document: << or <<-
            let stripTabs = advanceIf("-")
            skipSpacesAndTabs()

            // Read delimiter (may be quoted)
            let (delimiter, quoted) = readHeredocDelimiter()
            let spec = HeredocSpec(delimiter: delimiter, quoted: quoted, stripTabs: stripTabs)
            pendingHeredocs.append(spec)

            return .redirect(Redirection(op: stripTabs ? .heredocStripOp : .heredocOp, target: delimiter))
        }

        if advanceIf("&") {
            let target = readRedirectTarget()
            return .redirect(Redirection(op: .duplicateInput, target: target))
        }

        let target = readRedirectTarget()
        return .redirect(Redirection(op: .inputFrom, target: target))
    }

    private func readOutputRedirect() -> ShellToken {
        advance() // consume '>'

        if advanceIf(">") {
            let target = readRedirectTarget()
            return .redirect(Redirection(op: .appendTo, target: target))
        }

        if advanceIf("&") {
            let target = readRedirectTarget()
            return .redirect(Redirection(op: .duplicateOutput, target: target))
        }

        let target = readRedirectTarget()
        return .redirect(Redirection(op: .outputTo, target: target))
    }

    private func readRedirectTarget() -> String {
        skipSpacesAndTabs()
        var result = ""

        // bash process substitution as a redirect target: `< <(cmd)` or
        // `> >(cmd)`. Consume the whole `<(…)` or `>(…)` (with matching
        // parens) so the parser doesn't misread `<` as another redirection.
        if let first = currentChar(),
           (first == "<" || first == ">"),
           let next = peekChar(), next == "(" {
            result.append(String(advance()!))  // `<` or `>`
            result.append(String(advance()!))  // `(`
            var depth = 1
            while let c = currentChar(), depth > 0 {
                if c == "(" { depth += 1 }
                else if c == ")" {
                    depth -= 1
                    if depth == 0 {
                        result.append(String(advance()!))
                        break
                    }
                }
                result.append(String(advance()!))
            }
            return result
        }

        while let c = currentChar(),
              c != " " && c != "\t" && c != "\n" && c != ";" && c != "|" &&
              c != "&" && c != ">" && c != "<" && c != ")" {
            if c == "\\" {
                advance()
                if let escaped = advance() {
                    result.append(String(escaped))
                }
            } else if c == "'" {
                result += String(Self.singleQuoteStart) + readSingleQuotedRaw() + String(Self.singleQuoteEnd)
            } else if c == "\"" {
                result += String(Self.doubleQuoteStart) + readDoubleQuotedRaw() + String(Self.doubleQuoteEnd)
            } else if c == "$" {
                if let next = peekChar(), next == "(" {
                    result += readDollarParen()
                } else {
                    result.append(String(advance()!))
                }
            } else if c == "`" {
                result += readBacktickSubstitution()
            } else {
                result.append(String(advance()!))
            }
        }
        return result
    }

    private func readHeredocDelimiter() -> (String, Bool) {
        var delimiter = ""
        var quoted = false

        guard let c = currentChar() else { return ("EOF", false) }

        if c == "'" {
            // Quoted delimiter: <<'EOF'
            advance()
            while let ch = currentChar(), ch != "'" {
                delimiter.append(String(advance()!))
            }
            _ = advanceIf("'")
            quoted = true
        } else if c == "\"" {
            // Double-quoted delimiter: <<"EOF"
            advance()
            while let ch = currentChar(), ch != "\"" {
                delimiter.append(String(advance()!))
            }
            _ = advanceIf("\"")
            quoted = true
        } else {
            // Unquoted delimiter
            while let ch = currentChar(),
                  ch != " " && ch != "\t" && ch != "\n" && ch != ";" {
                delimiter.append(String(advance()!))
            }
        }

        return (delimiter, quoted)
    }

    // MARK: - Word Reading

    private func readWord() -> ShellToken {
        var parts: [String] = []
        var currentPart = ""

        func flushPart() {
            if !currentPart.isEmpty {
                parts.append(currentPart)
                currentPart = ""
            }
        }

        while let c = currentChar() {
            // Word terminators (but NOT inside $(...) or backticks)
            // Note: # is NOT a word terminator — it only starts a comment at the
            // beginning of a token (handled in readNextToken after skipSpacesAndTabs).
            // Mid-word # is literal: echo foo#bar, URLs, filenames with #.
            if c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" ||
               c == "&" {
                break
            }

            // ( and ) are word terminators only at the top level of a word,
            // NOT after $ (which starts command substitution or arithmetic)
            if c == "(" || c == ")" {
                break
            }

            // Check for redirection operators that end a word
            if c == ">" || c == "<" {
                break
            }

            // Check for 2> pattern at start of a new token
            if currentPart.isEmpty && parts.isEmpty && c == "2" {
                if let next = peekChar(), next == ">" {
                    break
                }
            }

            if c == "\\" {
                // Backslash escape
                advance()
                if let escaped = currentChar() {
                    if escaped == "\n" {
                        // Line continuation: backslash-newline
                        advance()
                        continue
                    }
                    currentPart.append(String(advance()!))
                }
            } else if c == "'" {
                // Single-quoted string — wrap in PUA markers so the parser
                // can reconstruct a .singleQuoted ShellWord node.
                currentPart += String(Self.singleQuoteStart) + readSingleQuotedRaw() + String(Self.singleQuoteEnd)
            } else if c == "\"" {
                // Double-quoted string — wrap in PUA markers for the parser.
                currentPart += String(Self.doubleQuoteStart) + readDoubleQuotedRaw() + String(Self.doubleQuoteEnd)
            } else if c == "$" {
                // Check for $(...) command substitution or $((...)) arithmetic
                if let next = peekChar(), next == "(" {
                    currentPart += readDollarParen()
                } else {
                    // Plain $ or $VAR — just append the character
                    currentPart.append(String(advance()!))
                }
            } else if c == "`" {
                // Backtick command substitution — read until matching backtick
                currentPart += readBacktickSubstitution()
            } else {
                currentPart.append(String(advance()!))
            }
        }

        flushPart()
        let word = parts.joined()

        guard !word.isEmpty else {
            // Shouldn't happen, but safety
            return .eof
        }

        // Check for keyword in command position
        if inCommandPosition && !seenNonAssignment {
            if let kwToken = keywordToken(for: word) {
                updateCommandPositionForKeyword(kwToken)
                return kwToken
            }
        }

        // Check for assignment word (VAR=value) in command position
        if inCommandPosition && !seenNonAssignment {
            if let (name, value) = parseAssignment(word) {
                return .assignmentWord(name: name, value: value)
            }
        }

        // Plain word — next words in this command are not in command position
        seenNonAssignment = true
        inCommandPosition = false
        return .word(word)
    }

    /// Read `$(...)` or `$((...))` as a complete unit, balancing parentheses.
    /// Returns the full text including the `$( )` delimiters.
    private func readDollarParen() -> String {
        var result = ""
        result.append(String(advance()!)) // consume $
        result.append(String(advance()!)) // consume (

        // Check for $(( — arithmetic
        let isArithmetic = currentChar() == "("
        if isArithmetic {
            result.append(String(advance()!)) // consume second (
        }

        var depth = isArithmetic ? 2 : 1
        while !isAtEnd && depth > 0 {
            let c = currentChar()!
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
            } else if c == "'" {
                // Single-quoted string inside substitution
                result.append(String(advance()!)) // opening '
                while let ch = currentChar(), ch != "'" {
                    result.append(String(advance()!))
                }
                if currentChar() == "'" {
                    result.append(String(advance()!)) // closing '
                }
                continue
            } else if c == "\"" {
                // Double-quoted string inside substitution
                result.append(String(advance()!)) // opening "
                while let ch = currentChar(), ch != "\"" {
                    if ch == "\\" {
                        result.append(String(advance()!))
                        if currentChar() != nil {
                            result.append(String(advance()!))
                        }
                        continue
                    }
                    result.append(String(advance()!))
                }
                if currentChar() == "\"" {
                    result.append(String(advance()!)) // closing "
                }
                continue
            } else if c == "`" {
                // Backtick substitution inside $(...) — skip entire contents
                result.append(String(advance()!)) // opening `
                while let ch = currentChar(), ch != "`" {
                    if ch == "\\" {
                        result.append(String(advance()!))
                        if currentChar() != nil {
                            result.append(String(advance()!))
                        }
                    } else {
                        result.append(String(advance()!))
                    }
                }
                if currentChar() == "`" {
                    result.append(String(advance()!)) // closing `
                }
                continue
            } else if c == "\\" {
                result.append(String(advance()!))
                if currentChar() != nil {
                    result.append(String(advance()!))
                }
                continue
            }
            result.append(String(advance()!))
        }
        return result
    }

    /// Read a backtick command substitution as a complete unit.
    /// Returns the full text including the backtick delimiters.
    private func readBacktickSubstitution() -> String {
        var result = ""
        result.append(String(advance()!)) // consume opening `
        while let c = currentChar(), c != "`" {
            if c == "\\" {
                result.append(String(advance()!))
                if currentChar() != nil {
                    result.append(String(advance()!))
                }
            } else {
                result.append(String(advance()!))
            }
        }
        if currentChar() == "`" {
            result.append(String(advance()!)) // consume closing `
        }
        return result
    }

    /// Read the raw text of a single-quoted string (including the quotes).
    /// Returns the content without the surrounding quotes.
    private func readSingleQuotedRaw() -> String {
        advance() // opening '
        var content = ""
        while let c = currentChar(), c != "'" {
            content.append(String(advance()!))
        }
        _ = advanceIf("'") // closing '
        return content
    }

    /// Read the raw text of a double-quoted string (including the quotes).
    /// Backslash escapes are processed for: $ ` " \ newline
    /// Everything else (including $VAR) is preserved literally for later expansion.
    private func readDoubleQuotedRaw() -> String {
        advance() // opening "
        var content = ""
        while let c = currentChar(), c != "\"" {
            if c == "\\" {
                advance()
                if let next = currentChar() {
                    switch next {
                    case "$", "`", "\"", "\\":
                        content.append(String(advance()!))
                    case "\n":
                        advance() // line continuation
                    default:
                        content.append("\\")
                        content.append(String(advance()!))
                    }
                } else {
                    content.append("\\")
                }
            } else {
                content.append(String(advance()!))
            }
        }
        _ = advanceIf("\"") // closing "
        return content
    }

    // MARK: - Assignment Detection

    /// Check if a word is an assignment: `NAME=VALUE`.
    /// NAME must be a valid shell identifier (letters, digits, underscore, starting with non-digit).
    private func parseAssignment(_ word: String) -> (String, String)? {
        guard let eqIdx = word.firstIndex(of: "=") else { return nil }

        let name = String(word[word.startIndex..<eqIdx])

        // Validate name is a valid identifier
        guard !name.isEmpty else { return nil }
        let first = name.unicodeScalars.first!
        guard first == "_" || (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") else {
            return nil
        }
        for scalar in name.unicodeScalars.dropFirst() {
            guard scalar == "_" || (scalar >= "A" && scalar <= "Z") ||
                  (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") else {
                return nil
            }
        }

        let value = String(word[word.index(after: eqIdx)...])
        return (name, value)
    }

    // MARK: - Keyword Mapping

    private func keywordToken(for word: String) -> ShellToken? {
        switch word {
        case "if":       return .kw_if
        case "then":     return .kw_then
        case "elif":     return .kw_elif
        case "else":     return .kw_else
        case "fi":       return .kw_fi
        case "for":      return .kw_for
        case "in":       return .kw_in
        case "do":       return .kw_do
        case "done":     return .kw_done
        case "while":    return .kw_while
        case "until":    return .kw_until
        case "case":     return .kw_case
        case "esac":     return .kw_esac
        case "function": return .kw_function
        case "{":        return .kw_lbrace
        case "}":        return .kw_rbrace
        case "!":        return .kw_bang
        default:         return nil
        }
    }

    private func updateCommandPositionForKeyword(_ token: ShellToken) {
        switch token {
        case .kw_then, .kw_else, .kw_elif, .kw_do, .kw_lbrace, .kw_bang:
            // After these keywords, next word is in command position
            inCommandPosition = true
            seenNonAssignment = false
        case .kw_if, .kw_while, .kw_until:
            // Condition starts in command position
            inCommandPosition = true
            seenNonAssignment = false
        case .kw_for:
            // After `for`, the variable name is NOT a command
            inCommandPosition = false
            seenNonAssignment = false
        case .kw_case:
            // After `case`, the word is not a command
            inCommandPosition = false
            seenNonAssignment = false
        case .kw_in:
            // After `in`, words are the iteration list (not commands)
            inCommandPosition = false
            seenNonAssignment = false
        case .kw_fi, .kw_done, .kw_esac, .kw_rbrace:
            // After closing keywords, next is command position
            inCommandPosition = true
            seenNonAssignment = false
        default:
            inCommandPosition = false
            seenNonAssignment = false
        }
    }
}

// MARK: - Here-document Spec

/// Tracks a pending here-document that needs its body collected after the next newline.
nonisolated final class HeredocSpec: @unchecked Sendable {
    let delimiter: String
    let quoted: Bool
    let stripTabs: Bool
    var collectedContent: String?

    init(delimiter: String, quoted: Bool, stripTabs: Bool) {
        self.delimiter = delimiter
        self.quoted = quoted
        self.stripTabs = stripTabs
    }
}

#endif
