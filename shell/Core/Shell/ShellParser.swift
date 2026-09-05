#if !targetEnvironment(macCatalyst)

import Foundation

/// Recursive-descent parser that produces a `ShellCommand` AST from tokens.
///
/// Follows the POSIX shell grammar:
/// ```
/// complete_command : list
/// list             : and_or ((';' | '\n') and_or)* (';' | '\n')?
/// and_or           : pipeline (('&&' | '||') pipeline)*
/// pipeline         : '!'? command ('|' command)*
/// command          : simple_command | compound_command | function_def
/// compound_command : if_clause | for_clause | while_clause | until_clause
///                  | case_clause | brace_group | subshell
/// simple_command   : (assignment)* word+ (redirection)*
/// ```
///
/// The parser is `nonisolated` and `Sendable` — it can run on any thread.
nonisolated final class ShellParser: @unchecked Sendable {
    private let tokenizer: ShellTokenizer

    init(tokenizer: ShellTokenizer) {
        self.tokenizer = tokenizer
    }

    /// Parse the entire input and return the top-level command.
    func parse() throws -> ShellCommand {
        skipNewlines()
        let cmd = try parseList()
        let tok = tokenizer.peek()
        if tok != .eof {
            throw ShellError.syntaxError(line: tokenizer.currentLine, "unexpected token: \(tok)")
        }
        return cmd
    }

    // MARK: - List (sequence of and_or separated by ; or newline)

    /// list : and_or ((';' | '&' | '\n') and_or)* (';' | '&' | '\n')?
    /// A `&` separator wraps the preceding and_or in `.background`.
    private func parseList() throws -> ShellCommand {
        var commands: [ShellCommand] = []

        commands.append(try parseAndOr())

        while true {
            let tok = tokenizer.peek()
            if tok == .ampersand {
                _ = tokenizer.next()
                skipNewlines()
                commands[commands.count - 1] = .background(commands[commands.count - 1])
                if isListTerminator(tokenizer.peek()) {
                    break
                }
                commands.append(try parseAndOr())
            } else if tok == .semicolon || tok == .newline {
                _ = tokenizer.next()
                skipNewlines()

                // Check if we've hit a terminator (fi, done, esac, }, ), elif, else, eof)
                if isListTerminator(tokenizer.peek()) {
                    break
                }

                commands.append(try parseAndOr())
            } else {
                break
            }
        }

        if commands.count == 1 {
            return commands[0]
        }
        return .sequence(commands)
    }

    // MARK: - And/Or

    /// and_or : pipeline (('&&' | '||') pipeline)*
    private func parseAndOr() throws -> ShellCommand {
        var left = try parsePipeline()

        while true {
            let tok = tokenizer.peek()
            if tok == .andIf {
                _ = tokenizer.next()
                skipNewlines()
                let right = try parsePipeline()
                left = .andOr(left, .and, right)
            } else if tok == .orIf {
                _ = tokenizer.next()
                skipNewlines()
                let right = try parsePipeline()
                left = .andOr(left, .or, right)
            } else {
                break
            }
        }

        return left
    }

    // MARK: - Pipeline

    /// pipeline : '!'? command ('|' command)*
    private func parsePipeline() throws -> ShellCommand {
        let negated = tokenizer.peek() == .kw_bang
        if negated { _ = tokenizer.next() }

        var commands: [ShellCommand] = []
        commands.append(try parseCommand())

        while tokenizer.peek() == .pipe {
            _ = tokenizer.next()
            skipNewlines()
            commands.append(try parseCommand())
        }

        var result: ShellCommand
        if commands.count == 1 {
            result = commands[0]
        } else {
            result = .pipeline(commands)
        }

        if negated {
            result = .negation(result)
        }

        return result
    }

    // MARK: - Command

    /// command : compound_command | function_def | simple_command
    private func parseCommand() throws -> ShellCommand {
        let tok = tokenizer.peek()

        // Compound commands (while…done < file, if…fi > out, etc.) can carry
        // trailing redirections that bash applies to the whole construct.
        // We don't yet thread them into the AST; just drain so the outer
        // parser doesn't trip over the redirect token.
        func swallowTrailingRedirects() {
            while case .redirect = tokenizer.peek() {
                _ = tokenizer.next()
            }
        }

        switch tok {
        case .kw_if:
            let cmd = try parseIf()
            swallowTrailingRedirects()
            return cmd
        case .kw_for:
            let cmd = try parseFor()
            swallowTrailingRedirects()
            return cmd
        case .kw_while:
            let cmd = try parseWhile()
            swallowTrailingRedirects()
            return cmd
        case .kw_until:
            let cmd = try parseUntil()
            swallowTrailingRedirects()
            return cmd
        case .kw_case:
            let cmd = try parseCase()
            swallowTrailingRedirects()
            return cmd
        case .kw_lbrace:
            let cmd = try parseBraceGroup()
            swallowTrailingRedirects()
            return cmd
        case .lparen:
            let cmd = try parseSubshell()
            swallowTrailingRedirects()
            return cmd
        case .kw_function:
            return try parseFunctionDef()
        default:
            // Check for function definition: name() { ... }
            if case .word(let name) = tok {
                // `[[ expression ]]` arrives from the tokenizer as one slurped
                // word ("[[" + whitespace guaranteed by tryReadDoubleBracket).
                if Self.isDoubleBracketWord(name) {
                    _ = tokenizer.next()
                    return try parseDoubleBracket(name)
                }
                // `(( expr ))` arithmetic command — same semantics as `let`:
                // exit 0 when the expression is nonzero.
                if name.hasPrefix("(("), name.hasSuffix("))"), name.count >= 5 {
                    _ = tokenizer.next()
                    let expr = String(name.dropFirst(2).dropLast(2))
                    return .simple(SimpleCommand(words: [.literal("let"), .singleQuoted(expr)]))
                }
                // Save position — peek ahead for ()
                let saved = tokenizer.next() // consume the word
                // Only treat `word ( ...` as a function def when `word` is a
                // valid identifier (POSIX: letters, digits, underscore, not
                // starting with a digit). Otherwise the `(` may belong to an
                // array assignment append like `arr+=(elem)` or a subshell.
                if Self.isValidFunctionName(name),
                   tokenizer.peek() == .lparen {
                    _ = tokenizer.next() // consume (
                    let rp = tokenizer.next()
                    guard rp == .rparen else {
                        throw ShellError.syntaxError(line: tokenizer.currentLine,
                                                     "expected ')' in function definition")
                    }
                    skipNewlines()
                    let body = try parseCommand()
                    return .functionDef(name: name, body: body)
                }
                // Not a function def — parse as simple command starting with this word
                return try parseSimpleCommandStartingWith(saved)
            }
            return try parseSimpleCommand()
        }
    }

    private static func isValidFunctionName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard first == "_" || (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") else {
            return false
        }
        for s in name.unicodeScalars.dropFirst() {
            guard s == "_" || (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9") else {
                return false
            }
        }
        return true
    }

    // MARK: - Simple Command

    /// simple_command : (assignment)* word+ (redirection)*
    private func parseSimpleCommand() throws -> ShellCommand {
        var assignments: [(String, String)] = []
        var words: [ShellWord] = []
        var redirections: [Redirection] = []
        var seenWord = false

        loop: while true {
            let tok = tokenizer.peek()

            switch tok {
            case .assignmentWord(let name, let value):
                _ = tokenizer.next()
                let finalValue = consumeArrayAssignmentSuffix(initialValue: value)
                if !seenWord {
                    assignments.append((name, finalValue))
                } else {
                    // Assignment after first word is treated as a plain word argument
                    // (e.g., `local SUDO=(…)`, `declare -a NAME=(…)`).
                    words.append(parseShellWord(from: "\(name)=\(finalValue)"))
                }

            case .word(let text):
                _ = tokenizer.next()
                seenWord = true
                let merged = mergeArraySuffixIntoWord(text)
                words.append(parseShellWord(from: merged))

            case .redirect(let redir):
                _ = tokenizer.next()
                redirections.append(redir)

            default:
                break loop
            }
        }

        if assignments.isEmpty && words.isEmpty && redirections.isEmpty {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected command, got \(tokenizer.peek())")
        }

        let heredocInfo = extractHeredocInfo(from: redirections)
        return .simple(SimpleCommand(assignments: assignments, words: words,
                                      redirections: redirections,
                                      heredocContent: heredocInfo?.content,
                                      heredocQuoted: heredocInfo?.quoted))
    }

    /// Parse a simple command when we've already consumed the first token (a word).
    private func parseSimpleCommandStartingWith(_ firstToken: ShellToken) throws -> ShellCommand {
        var assignments: [(String, String)] = []
        var words: [ShellWord] = []
        var redirections: [Redirection] = []

        // Process the already-consumed first token
        switch firstToken {
        case .word(let text):
            words.append(parseShellWord(from: mergeArraySuffixIntoWord(text)))
        case .assignmentWord(let name, let value):
            let finalValue = consumeArrayAssignmentSuffix(initialValue: value)
            assignments.append((name, finalValue))
        default:
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "unexpected token: \(firstToken)")
        }

        loop: while true {
            let tok = tokenizer.peek()

            switch tok {
            case .assignmentWord(let name, let value):
                _ = tokenizer.next()
                let finalValue = consumeArrayAssignmentSuffix(initialValue: value)
                if words.isEmpty {
                    assignments.append((name, finalValue))
                } else {
                    words.append(parseShellWord(from: "\(name)=\(finalValue)"))
                }

            case .word(let text):
                _ = tokenizer.next()
                words.append(parseShellWord(from: mergeArraySuffixIntoWord(text)))

            case .redirect(let redir):
                _ = tokenizer.next()
                redirections.append(redir)

            default:
                break loop
            }
        }

        let heredocInfo = extractHeredocInfo(from: redirections)
        return .simple(SimpleCommand(assignments: assignments, words: words,
                                      redirections: redirections,
                                      heredocContent: heredocInfo?.content,
                                      heredocQuoted: heredocInfo?.quoted))
    }

    /// If `text` ends in `=` and is followed by `(`, consume the bash array
    /// literal and merge it onto the word as `name=(elem1 elem2 …)`. Handles
    /// commands like `local -a NAME=(…)` and `declare NAME=(…)` where
    /// `NAME=` arrives as a plain word (not `assignmentWord`) because the
    /// tokenizer has already left command position.
    private func mergeArraySuffixIntoWord(_ text: String) -> String {
        guard text.hasSuffix("="), tokenizer.peek() == .lparen else { return text }
        let suffix = consumeArrayAssignmentSuffix(initialValue: "")
        return text + suffix
    }

    /// If the just-consumed `assignmentWord` is followed by `(`, swallow the
    /// matching `)`-terminated bash array literal and reconstruct it into
    /// `(elem1 elem2 …)` form so the interpreter receives a single string
    /// value. The interpreter doesn't yet evaluate arrays, but parsing the
    /// syntax keeps scripts that *use* arrays (Homebrew install.sh) from
    /// erroring out.
    private func consumeArrayAssignmentSuffix(initialValue: String) -> String {
        guard tokenizer.peek() == .lparen else { return initialValue }
        _ = tokenizer.next() // consume `(`
        var elements: [String] = []
        while true {
            // Skip newlines inside the array literal
            while tokenizer.peek() == .newline { _ = tokenizer.next() }
            switch tokenizer.peek() {
            case .rparen:
                _ = tokenizer.next()
                return "(" + elements.joined(separator: " ") + ")"
            case .eof:
                return "(" + elements.joined(separator: " ") + ")"
            case .word(let text):
                _ = tokenizer.next()
                elements.append(text)
            case .assignmentWord(let name, let value):
                // Inside an array literal, `key=value` is just a string element
                // (e.g., `args=("-key=value")`); preserve as-is.
                _ = tokenizer.next()
                elements.append("\(name)=\(value)")
            default:
                _ = tokenizer.next() // skip unexpected separators
            }
        }
    }

    /// Extract here-document content and quoted flag from redirections (collected by the tokenizer).
    private func extractHeredocInfo(from redirections: [Redirection]) -> (content: String, quoted: Bool)? {
        for redir in redirections {
            if redir.op == .heredocOp || redir.op == .heredocStripOp {
                return tokenizer.getHeredocContent(delimiter: redir.target)
            }
        }
        return nil
    }

    // MARK: - Compound Commands

    /// if_clause : 'if' list 'then' list ('elif' list 'then' list)* ('else' list)? 'fi'
    private func parseIf() throws -> ShellCommand {
        try expect(.kw_if)

        var branches: [(condition: ShellCommand, body: ShellCommand)] = []
        var elseBranch: ShellCommand?

        // Primary if
        let condition = try parseList()
        try expectOne(of: [.kw_then])
        skipNewlines()
        let body = try parseList()
        branches.append((condition: condition, body: body))

        // elif branches
        while tokenizer.peek() == .kw_elif {
            _ = tokenizer.next()
            let elifCondition = try parseList()
            try expectOne(of: [.kw_then])
            skipNewlines()
            let elifBody = try parseList()
            branches.append((condition: elifCondition, body: elifBody))
        }

        // else branch
        if tokenizer.peek() == .kw_else {
            _ = tokenizer.next()
            skipNewlines()
            elseBranch = try parseList()
        }

        try expect(.kw_fi)

        return .ifCmd(IfClause(branches: branches, elseBranch: elseBranch))
    }

    /// for_clause : 'for' NAME ('in' word*)? (';'|'\n') 'do' list 'done'
    private func parseFor() throws -> ShellCommand {
        try expect(.kw_for)

        // Variable name — may be tokenized as a keyword if it matches (e.g., `for in in ...`)
        let varName: String
        let varTok = tokenizer.next()
        switch varTok {
        case .word(let name):
            varName = name
        default:
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected variable name after 'for'")
        }

        // Optional word list
        // Note: 'in', 'do', 'done' may be tokenized as plain words rather than
        // keywords because the tokenizer doesn't track for-loop context.
        var wordList: [ShellWord]?
        skipNewlines()

        if isKeywordOrWord("in", tokenizer.peek()) {
            _ = tokenizer.next()
            var words: [ShellWord] = []
            while true {
                let tok = tokenizer.peek()
                if tok == .semicolon || tok == .newline || isKeywordOrWord("do", tok) {
                    break
                }
                if case .word(let text) = tok {
                    _ = tokenizer.next()
                    words.append(parseShellWord(from: text))
                } else {
                    break
                }
            }
            wordList = words
        }

        // Consume separator
        if tokenizer.peek() == .semicolon || tokenizer.peek() == .newline {
            _ = tokenizer.next()
        }
        skipNewlines()

        try expectKeywordOrWord("do")
        skipNewlines()
        let body = try parseList()
        try expectKeywordOrWord("done")

        return .forCmd(ForClause(variable: varName, wordList: wordList, body: body))
    }

    /// while_clause : 'while' list 'do' list 'done'
    private func parseWhile() throws -> ShellCommand {
        try expect(.kw_while)
        let condition = try parseList()
        try expect(.kw_do)
        skipNewlines()
        let body = try parseList()
        try expect(.kw_done)
        return .whileCmd(WhileClause(condition: condition, body: body))
    }

    /// until_clause : 'until' list 'do' list 'done'
    private func parseUntil() throws -> ShellCommand {
        try expect(.kw_until)
        let condition = try parseList()
        try expect(.kw_do)
        skipNewlines()
        let body = try parseList()
        try expect(.kw_done)
        return .untilCmd(UntilClause(condition: condition, body: body))
    }

    /// case_clause : 'case' WORD 'in' (case_item)* 'esac'
    private func parseCase() throws -> ShellCommand {
        try expect(.kw_case)

        guard case .word(let wordText) = tokenizer.next() else {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected word after 'case'")
        }
        let word = parseShellWord(from: wordText)

        // Expect 'in' — may be preceded by newlines. The tokenizer only emits
        // `kw_in` in command position; after consuming the case word, we're
        // not in command position, so `in` arrives as `.word("in")`. Match
        // either form (same handling as `parseFor`).
        skipNewlines()
        if isKeywordOrWord("in", tokenizer.peek()) {
            _ = tokenizer.next()
        } else {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected 'in' after 'case' word")
        }
        skipNewlines()

        var items: [CaseItem] = []

        while tokenizer.peek() != .kw_esac && tokenizer.peek() != .eof {
            skipNewlines()
            if tokenizer.peek() == .kw_esac { break }
            items.append(try parseCaseItem())
        }

        try expect(.kw_esac)

        return .caseCmd(CaseClause(word: word, items: items))
    }

    /// case_item : pattern ('|' pattern)* ')' list? ';;'
    private func parseCaseItem() throws -> CaseItem {
        // Optional leading (
        if tokenizer.peek() == .lparen {
            _ = tokenizer.next()
        }

        var patterns: [ShellWord] = []

        // First pattern
        guard case .word(let firstPattern) = tokenizer.next() else {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected pattern in 'case'")
        }
        patterns.append(parseShellWord(from: firstPattern))

        // Additional patterns separated by |
        while tokenizer.peek() == .pipe {
            _ = tokenizer.next()
            guard case .word(let pattern) = tokenizer.next() else {
                throw ShellError.syntaxError(line: tokenizer.currentLine,
                                             "expected pattern after '|'")
            }
            patterns.append(parseShellWord(from: pattern))
        }

        // Expect )
        let rp = tokenizer.next()
        guard rp == .rparen else {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected ')' after case pattern")
        }
        skipNewlines()

        // Body (may be empty before ;;)
        var body: ShellCommand?
        if tokenizer.peek() != .dsemi && tokenizer.peek() != .kw_esac {
            body = try parseList()
        }

        // Expect ;; or esac
        if tokenizer.peek() == .dsemi {
            _ = tokenizer.next()
        }
        skipNewlines()

        return CaseItem(patterns: patterns, body: body)
    }

    /// brace_group : '{' list '}'
    private func parseBraceGroup() throws -> ShellCommand {
        try expect(.kw_lbrace)
        skipNewlines()
        let body = try parseList()
        try expect(.kw_rbrace)
        return .braceGroup(body)
    }

    /// subshell : '(' list ')'
    private func parseSubshell() throws -> ShellCommand {
        let lp = tokenizer.next()
        guard lp == .lparen else {
            throw ShellError.syntaxError(line: tokenizer.currentLine, "expected '('")
        }
        skipNewlines()
        let body = try parseList()
        let rp = tokenizer.next()
        guard rp == .rparen else {
            throw ShellError.syntaxError(line: tokenizer.currentLine, "expected ')'")
        }
        return .subshell(body)
    }

    /// function_def : 'function' NAME ('(' ')')? compound_command
    private func parseFunctionDef() throws -> ShellCommand {
        try expect(.kw_function)

        guard case .word(let name) = tokenizer.next() else {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected function name after 'function'")
        }

        // Optional ()
        if tokenizer.peek() == .lparen {
            _ = tokenizer.next()
            let rp = tokenizer.next()
            guard rp == .rparen else {
                throw ShellError.syntaxError(line: tokenizer.currentLine,
                                             "expected ')' in function definition")
            }
        }

        skipNewlines()
        let body = try parseCommand()

        return .functionDef(name: name, body: body)
    }

    // MARK: - Shell Word Parsing (text → ShellWord with expansion markers)

    /// Parse a raw text string into a `ShellWord`, detecting PUA quote markers
    /// (from the tokenizer) and `$VAR`, `${...}`, `$(cmd)`, `$((expr))` expansion
    /// points.
    ///
    /// PUA markers:
    /// - `\u{E001}...\u{E002}` → `.singleQuoted(content)` — no expansion inside
    /// - `\u{E003}...\u{E004}` → `.doubleQuoted(parts)` — `$` expansions parsed inside, but no glob
    /// - Unquoted text → `.literal` with `$` expansions parsed normally
    func parseShellWord(from text: String) -> ShellWord {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return .literal("") }

        let sqStart = ShellTokenizer.singleQuoteStart.unicodeScalars.first!
        let sqEnd   = ShellTokenizer.singleQuoteEnd.unicodeScalars.first!
        let dqStart = ShellTokenizer.doubleQuoteStart.unicodeScalars.first!
        let dqEnd   = ShellTokenizer.doubleQuoteEnd.unicodeScalars.first!

        var parts: [ShellWord] = []
        var literal = ""
        var i = 0

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
        }

        while i < scalars.count {
            let c = scalars[i]

            // Single-quote region: collect raw content, no expansion
            if c == sqStart {
                flushLiteral()
                i += 1
                var content = ""
                while i < scalars.count && scalars[i] != sqEnd {
                    content.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { i += 1 } // skip sqEnd
                parts.append(.singleQuoted(content))
                continue
            }

            // Double-quote region: scan for $ expansions but mark as doubleQuoted
            if c == dqStart {
                flushLiteral()
                i += 1
                // Collect the raw content between dqStart and dqEnd
                var dqContent: [UnicodeScalar] = []
                while i < scalars.count && scalars[i] != dqEnd {
                    dqContent.append(scalars[i])
                    i += 1
                }
                if i < scalars.count { i += 1 } // skip dqEnd
                // Parse the interior for $ expansions (but the result is wrapped in .doubleQuoted)
                let innerParts = parseExpansions(in: dqContent)
                parts.append(.doubleQuoted(innerParts))
                continue
            }

            // Unquoted region: scan for $ expansions and backticks
            if c == "$" && i + 1 < scalars.count {
                if let (word, newI) = tryParseDollarExpansion(scalars, at: i) {
                    flushLiteral()
                    parts.append(word)
                    i = newI
                    continue
                }
            }

            if c == "`" {
                // Backtick command substitution
                flushLiteral()
                i += 1
                var cmd = ""
                while i < scalars.count && scalars[i] != "`" {
                    if scalars[i] == "\\" && i + 1 < scalars.count {
                        let escaped = scalars[i + 1]
                        if escaped == "`" || escaped == "\\" || escaped == "$" {
                            cmd.append(String(escaped))
                            i += 2
                            continue
                        }
                    }
                    cmd.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { i += 1 } // skip closing `
                parts.append(.commandSub(cmd))
                continue
            }

            literal.append(String(c))
            i += 1
        }

        flushLiteral()

        if parts.isEmpty { return .literal("") }
        if parts.count == 1 { return parts[0] }
        return .concat(parts)
    }

    /// Parse `$`-expansion sequences from a scalar array (used for both unquoted
    /// and double-quoted regions).
    private func parseExpansions(in scalars: [UnicodeScalar]) -> [ShellWord] {
        var parts: [ShellWord] = []
        var literal = ""
        var i = 0

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
        }

        while i < scalars.count {
            let c = scalars[i]

            if c == "$" && i + 1 < scalars.count {
                if let (word, newI) = tryParseDollarExpansion(scalars, at: i) {
                    flushLiteral()
                    parts.append(word)
                    i = newI
                    continue
                }
            }

            if c == "`" {
                flushLiteral()
                i += 1
                var cmd = ""
                while i < scalars.count && scalars[i] != "`" {
                    if scalars[i] == "\\" && i + 1 < scalars.count {
                        let escaped = scalars[i + 1]
                        if escaped == "`" || escaped == "\\" || escaped == "$" {
                            cmd.append(String(escaped))
                            i += 2
                            continue
                        }
                    }
                    cmd.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { i += 1 }
                parts.append(.commandSub(cmd))
                continue
            }

            literal.append(String(c))
            i += 1
        }

        flushLiteral()
        return parts
    }

    /// Try to parse a `$`-prefixed expansion starting at position `i`.
    /// Returns the parsed `ShellWord` and the new index after the expansion,
    /// or `nil` if this isn't a valid expansion.
    private func tryParseDollarExpansion(_ scalars: [UnicodeScalar], at i: Int) -> (ShellWord, Int)? {
        guard i + 1 < scalars.count else { return nil }
        let next = scalars[i + 1]

        if next == "(" {
            // $(( )) arithmetic or $( ) command substitution
            if i + 2 < scalars.count && scalars[i + 2] == "(" {
                // $((expr))
                let (expr, end) = extractBalanced(scalars, from: i + 2, open: "(", close: ")")
                let inner = expr.hasPrefix("(") && expr.hasSuffix(")")
                    ? String(expr.dropFirst().dropLast())
                    : expr
                var newI = end + 1
                if newI < scalars.count && scalars[newI] == ")" { newI += 1 }
                return (.arithmetic(inner), newI)
            } else {
                // $(cmd) — start AFTER the opening `(` so `extractBalanced`'s
                // depth counter begins at 0 inside the content. Passing `i + 1`
                // (the `(` itself) makes the first unnested `)` fail to match
                // as the terminator, greedily swallowing subsequent content —
                // e.g. `$(date) $(uname -a)` would collapse into a single
                // substitution with body `(date) $(uname -a)`.
                let (cmd, end) = extractBalanced(scalars, from: i + 2, open: "(", close: ")")
                return (.commandSub(cmd), end + 1)
            }
        }

        if next == "{" {
            // ${...} parameter expansion
            let (content, end) = extractUntil(scalars, from: i + 2, terminator: "}")
            return (parseParamExpansion(content), end + 1)
        }

        // $VAR or $N or $? or $@ etc.
        if isVarStartChar(next) || next == "?" || next == "@" ||
           next == "*" || next == "#" || next == "$" || next == "!" ||
           next == "-" || (next >= "0" && next <= "9") {
            var varName = String(next)
            var newI = i + 2

            // Special single-char variables: $?, $@, $*, $#, $$, $!, $-, $0-$9
            if next == "?" || next == "@" || next == "*" || next == "#" ||
               next == "$" || next == "!" || next == "-" ||
               (next >= "0" && next <= "9") {
                return (.variable(varName), newI)
            }

            // Multi-char variable name
            while newI < scalars.count && isVarChar(scalars[newI]) {
                varName.append(String(scalars[newI]))
                newI += 1
            }
            return (.variable(varName), newI)
        }

        return nil
    }

    // MARK: - Parameter Expansion Parsing

    private func parseParamExpansion(_ content: String) -> ShellWord {
        let scalars = Array(content.unicodeScalars)
        guard !scalars.isEmpty else { return .paramExpansion(.simple("")) }

        // ${#VAR} — length
        if scalars[0] == "#" && scalars.count > 1 {
            return .paramExpansion(.length(String(content.dropFirst())))
        }

        // Find the operator position
        var nameEnd = 0
        while nameEnd < scalars.count && isVarChar(scalars[nameEnd]) {
            nameEnd += 1
        }
        let name = String(String.UnicodeScalarView(scalars[0..<nameEnd]))

        guard nameEnd < scalars.count else {
            // Simple ${VAR}
            return .paramExpansion(.simple(name))
        }

        // Special parameters (`${@}`, `${?}`, `${*}`, `${!}`, ...) have no
        // identifier chars; keep the legacy simple-expansion behavior for
        // them (operator forms on specials, like `${@:2}`, aren't modeled).
        if nameEnd == 0 {
            return .paramExpansion(.simple(content))
        }

        let rest = String(String.UnicodeScalarView(scalars[nameEnd...]))

        // Check for colon-operators: :-, :=, :+, :? (empty counts as unset)
        if rest.hasPrefix(":-") {
            let word = parseShellWord(from: String(rest.dropFirst(2)))
            return .paramExpansion(.defaultValue(name: name, word: [word], checkEmpty: true))
        }
        if rest.hasPrefix(":=") {
            let word = parseShellWord(from: String(rest.dropFirst(2)))
            return .paramExpansion(.assignDefault(name: name, word: [word], checkEmpty: true))
        }
        if rest.hasPrefix(":+") {
            let word = parseShellWord(from: String(rest.dropFirst(2)))
            return .paramExpansion(.alternative(name: name, word: [word], checkEmpty: true))
        }
        if rest.hasPrefix(":?") {
            let word = parseShellWord(from: String(rest.dropFirst(2)))
            return .paramExpansion(.errorIfUnset(name: name, word: [word], checkEmpty: true))
        }

        // `${VAR:offset[:length]}` substring — a `:` not followed by an
        // operator char. Offset/length stay raw for arithmetic evaluation
        // (supports `${v:$i:2}` and `${v: -3}`).
        if rest.hasPrefix(":") {
            let spec = String(rest.dropFirst())
            let parts = Self.splitSubstringSpec(spec)
            return .paramExpansion(.substring(name: name, offset: parts.0, length: parts.1))
        }

        // Non-colon versions (only check unset, not empty)
        if rest.hasPrefix("-") {
            let word = parseShellWord(from: String(rest.dropFirst()))
            return .paramExpansion(.defaultValue(name: name, word: [word], checkEmpty: false))
        }
        if rest.hasPrefix("=") {
            let word = parseShellWord(from: String(rest.dropFirst()))
            return .paramExpansion(.assignDefault(name: name, word: [word], checkEmpty: false))
        }
        if rest.hasPrefix("+") {
            let word = parseShellWord(from: String(rest.dropFirst()))
            return .paramExpansion(.alternative(name: name, word: [word], checkEmpty: false))
        }
        if rest.hasPrefix("?") {
            let word = parseShellWord(from: String(rest.dropFirst()))
            return .paramExpansion(.errorIfUnset(name: name, word: [word], checkEmpty: false))
        }

        // Prefix/suffix stripping
        if rest.hasPrefix("##") {
            return .paramExpansion(.stripLongPrefix(name: name, pattern: String(rest.dropFirst(2))))
        }
        if rest.hasPrefix("#") {
            return .paramExpansion(.stripShortPrefix(name: name, pattern: String(rest.dropFirst())))
        }
        if rest.hasPrefix("%%") {
            return .paramExpansion(.stripLongSuffix(name: name, pattern: String(rest.dropFirst(2))))
        }
        if rest.hasPrefix("%") {
            return .paramExpansion(.stripShortSuffix(name: name, pattern: String(rest.dropFirst())))
        }

        // `${VAR/pat/repl}` family
        if rest.hasPrefix("/") {
            var spec = String(rest.dropFirst())
            let mode: ReplaceMode
            if spec.hasPrefix("/") { mode = .all; spec.removeFirst() }
            else if spec.hasPrefix("#") { mode = .prefix; spec.removeFirst() }
            else if spec.hasPrefix("%") { mode = .suffix; spec.removeFirst() }
            else { mode = .first }
            let (pattern, replacement) = Self.splitReplaceSpec(spec)
            let replWord = parseShellWord(from: replacement)
            return .paramExpansion(.replace(name: name, pattern: pattern,
                                            replacement: [replWord], mode: mode))
        }

        // Unrecognized operator — surface an error at expansion time rather
        // than silently mis-expanding.
        return .paramExpansion(.bad(content))
    }

    /// Split `offset[:length]` on the first `:` that isn't inside `(...)`
    /// (protects `${v:$((i+1)):2}` and ternaries).
    private static func splitSubstringSpec(_ spec: String) -> (String, String?) {
        var depth = 0
        var index = spec.startIndex
        while index < spec.endIndex {
            let c = spec[index]
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1 }
            else if c == ":" && depth == 0 {
                return (String(spec[..<index]), String(spec[spec.index(after: index)...]))
            }
            index = spec.index(after: index)
        }
        return (spec, nil)
    }

    /// Split `pattern/replacement` on the first unescaped `/`.
    /// No `/` means an empty replacement (deletion), matching bash.
    private static func splitReplaceSpec(_ spec: String) -> (String, String) {
        // A `/` inside quotes is part of the pattern (`${v/"a/b"/X}`).
        // Quotes appear as PUA sentinels (tokenizer word path) or raw quote
        // chars (raw text path) — track both.
        var pattern = ""
        var index = spec.startIndex
        var quoteTerminator: Character?
        while index < spec.endIndex {
            let c = spec[index]

            if let terminator = quoteTerminator {
                pattern.append(c)
                if c == terminator { quoteTerminator = nil }
                index = spec.index(after: index)
                continue
            }

            switch c {
            case "\\" where spec.index(after: index) < spec.endIndex:
                pattern.append(c)
                index = spec.index(after: index)
                pattern.append(spec[index])
            case "'":
                quoteTerminator = "'"
                pattern.append(c)
            case "\"":
                quoteTerminator = "\""
                pattern.append(c)
            case ShellTokenizer.singleQuoteStart:
                quoteTerminator = ShellTokenizer.singleQuoteEnd
                pattern.append(c)
            case ShellTokenizer.doubleQuoteStart:
                quoteTerminator = ShellTokenizer.doubleQuoteEnd
                pattern.append(c)
            case "/":
                return (pattern, String(spec[spec.index(after: index)...]))
            default:
                pattern.append(c)
            }
            index = spec.index(after: index)
        }
        return (pattern, "")
    }

    // MARK: - Helper Functions

    private func isVarStartChar(_ c: UnicodeScalar) -> Bool {
        c == "_" || (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
    }

    private func isVarChar(_ c: UnicodeScalar) -> Bool {
        isVarStartChar(c) || (c >= "0" && c <= "9")
    }

    /// Extract text between balanced open/close delimiters, respecting quotes.
    /// Quoted regions (single-quotes, double-quotes, PUA markers) are skipped
    /// so that `)` inside `$(printf ')')` doesn't terminate early.
    private func extractBalanced(_ scalars: [UnicodeScalar], from start: Int,
                                  open: UnicodeScalar, close: UnicodeScalar) -> (String, Int) {
        var depth = 0
        var i = start
        var result = ""

        let sqStart = ShellTokenizer.singleQuoteStart.unicodeScalars.first!
        let sqEnd = ShellTokenizer.singleQuoteEnd.unicodeScalars.first!
        let dqStart = ShellTokenizer.doubleQuoteStart.unicodeScalars.first!
        let dqEnd = ShellTokenizer.doubleQuoteEnd.unicodeScalars.first!

        while i < scalars.count {
            let c = scalars[i]

            // Skip PUA-marked single-quoted regions
            if c == sqStart {
                result.append(String(c))
                i += 1
                while i < scalars.count && scalars[i] != sqEnd {
                    result.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { result.append(String(scalars[i])); i += 1 }
                continue
            }

            // Skip PUA-marked double-quoted regions
            if c == dqStart {
                result.append(String(c))
                i += 1
                while i < scalars.count && scalars[i] != dqEnd {
                    result.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { result.append(String(scalars[i])); i += 1 }
                continue
            }

            // Skip single-quoted strings (raw quotes in substitution text)
            if c == "'" {
                result.append(String(c))
                i += 1
                while i < scalars.count && scalars[i] != "'" {
                    result.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { result.append(String(scalars[i])); i += 1 }
                continue
            }

            // Skip double-quoted strings (raw quotes in substitution text)
            if c == "\"" {
                result.append(String(c))
                i += 1
                while i < scalars.count && scalars[i] != "\"" {
                    if scalars[i] == "\\" && i + 1 < scalars.count {
                        result.append(String(scalars[i]))
                        i += 1
                        result.append(String(scalars[i]))
                        i += 1
                        continue
                    }
                    result.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { result.append(String(scalars[i])); i += 1 }
                continue
            }

            // Skip backtick substitutions
            if c == "`" {
                result.append(String(c))
                i += 1
                while i < scalars.count && scalars[i] != "`" {
                    if scalars[i] == "\\" && i + 1 < scalars.count {
                        result.append(String(scalars[i]))
                        i += 1
                        result.append(String(scalars[i]))
                        i += 1
                        continue
                    }
                    result.append(String(scalars[i]))
                    i += 1
                }
                if i < scalars.count { result.append(String(scalars[i])); i += 1 }
                continue
            }

            // Backslash escaping
            if c == "\\" && i + 1 < scalars.count {
                result.append(String(scalars[i]))
                i += 1
                result.append(String(scalars[i]))
                i += 1
                continue
            }

            if c == open {
                depth += 1
                if depth > 0 { result.append(String(c)) }
            } else if c == close {
                if depth == 0 {
                    return (result, i)
                }
                depth -= 1
                if depth >= 0 { result.append(String(c)) }
            } else {
                result.append(String(c))
            }
            i += 1
        }
        return (result, i)
    }

    /// Extract text until a terminator character.
    private func extractUntil(_ scalars: [UnicodeScalar], from start: Int,
                               terminator: UnicodeScalar) -> (String, Int) {
        var i = start
        var result = ""
        while i < scalars.count && scalars[i] != terminator {
            result.append(String(scalars[i]))
            i += 1
        }
        return (result, i)
    }

    /// Consume a specific expected token, or throw a syntax error.
    private func expect(_ expected: ShellToken) throws {
        let tok = tokenizer.next()
        if tok != expected {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "expected \(expected), got \(tok)")
        }
    }

    /// Consume one of the expected tokens, throwing on mismatch.
    @discardableResult
    private func expectOne(of expected: [ShellToken]) throws -> ShellToken {
        let tok = tokenizer.next()
        for e in expected {
            if tok == e { return tok }
        }
        let expectedStr = expected.map { "\($0)" }.joined(separator: " or ")
        throw ShellError.syntaxError(line: tokenizer.currentLine,
                                     "expected \(expectedStr), got \(tok)")
    }

    /// Check if a token is a specific keyword OR a plain word with that keyword's text.
    /// Needed because the tokenizer doesn't always recognize keywords in context
    /// (e.g., `in`/`do`/`done` after `for VAR`).
    private func isKeywordOrWord(_ keyword: String, _ tok: ShellToken) -> Bool {
        switch (keyword, tok) {
        case ("in", .kw_in), ("do", .kw_do), ("done", .kw_done),
             ("then", .kw_then), ("fi", .kw_fi), ("else", .kw_else),
             ("elif", .kw_elif), ("esac", .kw_esac):
            return true
        case (_, .word(let text)):
            return text == keyword
        default:
            return false
        }
    }

    /// Consume a token that should be a keyword but may have been tokenized as a word.
    private func expectKeywordOrWord(_ keyword: String) throws {
        let tok = tokenizer.next()
        if isKeywordOrWord(keyword, tok) { return }
        throw ShellError.syntaxError(line: tokenizer.currentLine,
                                     "expected '\(keyword)', got \(tok)")
    }

    /// Skip any newline tokens.
    private func skipNewlines() {
        while tokenizer.peek() == .newline {
            _ = tokenizer.next()
        }
    }

    /// Check if a token terminates a list (used to detect end of compound command bodies).
    private func isListTerminator(_ tok: ShellToken) -> Bool {
        switch tok {
        case .kw_fi, .kw_done, .kw_esac, .kw_rbrace, .rparen,
             .kw_elif, .kw_else, .kw_then, .kw_do,
             .dsemi, .eof:
            return true
        case .word(let text):
            // Keywords may be tokenized as plain words in certain contexts
            let terminators: Set<String> = ["fi", "done", "esac", "elif", "else", "then", "do"]
            return terminators.contains(text)
        default:
            return false
        }
    }

    // MARK: - Static Utility

    /// Try to parse the input. Returns `.complete(ast)` if it parses fully,
    /// `.incomplete` if it looks like a valid start but needs more input (hit EOF
    /// while expecting a keyword like `done`, `fi`, `then`, etc.),
    /// or `.error(message)` for a genuine syntax error.
    enum ParseResult {
        case complete(ShellCommand)
        case incomplete
        case error(String)
    }

    func tryParse() -> ParseResult {
        do {
            let cmd = try parse()
            return .complete(cmd)
        } catch ShellError.syntaxError(_, let message) {
            // If the error mentions EOF, the input is likely incomplete
            if message.contains("eof") || message.contains("EOF") {
                return .incomplete
            }
            return .error(message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Detect an unquoted background `&` (not `&&`, not `>&`/`<&` fd-dup).
    private static func containsBackgroundAmpersand(_ command: String) -> Bool {
        let chars = Array(command)
        var inSingle = false
        var inDouble = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && !inSingle {
                i += 2
                continue
            }
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == "&" && !inSingle && !inDouble {
                let prev = i > 0 ? chars[i - 1] : " "
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == "&" || next == ">" {
                    i += 2 // && or &> — not a background separator
                    continue
                }
                if prev == ">" || prev == "<" || prev == "&" {
                    i += 1 // >& / <& fd-dup, or second char of &&
                    continue
                }
                return true
            }
            i += 1
        }
        return false
    }

    // MARK: - Double Bracket ([[ ... ]])

    /// True when a slurped word token is a `[[ expression ]]` conditional.
    /// The tokenizer only slurps when `[[` is followed by whitespace, so a
    /// plain word like `[[x]]` never matches.
    static func isDoubleBracketWord(_ text: String) -> Bool {
        guard text.count >= 6, text.hasPrefix("[["), text.hasSuffix("]]") else { return false }
        let third = text[text.index(text.startIndex, offsetBy: 2)]
        return third == " " || third == "\t" || third == "\n"
    }

    /// Lexical operators recognized inside `[[ ... ]]` (only when unquoted).
    static let doubleBracketOperators: Set<String> = [
        "!", "(", ")", "&&", "||",
        "=", "==", "!=", "=~", "<", ">",
        "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
        "-nt", "-ot", "-ef",
        "-z", "-n", "-e", "-f", "-d", "-r", "-w", "-x", "-s",
        "-L", "-h", "-p", "-S", "-b", "-c", "-g", "-k", "-u",
        "-O", "-G", "-N", "-t", "-o", "-v",
    ]

    /// Parse a slurped `[[ ... ]]` word into classified tokens. The interior
    /// carries PUA quote sentinels from the tokenizer; splitting happens on
    /// whitespace outside quoted regions, and operands go through
    /// `parseShellWord` so they keep full quote/expansion semantics.
    private func parseDoubleBracket(_ text: String) throws -> ShellCommand {
        let inner = String(text.dropFirst(2).dropLast(2))
        let rawTokens = Self.splitDoubleBracketTokens(inner)
        guard !rawTokens.isEmpty else {
            throw ShellError.syntaxError(line: tokenizer.currentLine,
                                         "[[: expression expected")
        }

        let quoteMarkers = CharacterSet(charactersIn:
            String(ShellTokenizer.singleQuoteStart) + String(ShellTokenizer.singleQuoteEnd) +
            String(ShellTokenizer.doubleQuoteStart) + String(ShellTokenizer.doubleQuoteEnd))

        var tokens: [DoubleBracketToken] = []
        for raw in rawTokens {
            let hasQuoting = raw.unicodeScalars.contains { quoteMarkers.contains($0) }
            if !hasQuoting && Self.doubleBracketOperators.contains(raw) {
                tokens.append(.op(raw))
            } else {
                tokens.append(.operand(parseShellWord(from: raw)))
            }
        }
        return .doubleBracket(tokens)
    }

    /// Split the `[[ ... ]]` interior on whitespace outside PUA-quoted regions.
    private static func splitDoubleBracketTokens(_ text: String) -> [String] {
        let sqStart = ShellTokenizer.singleQuoteStart
        let sqEnd = ShellTokenizer.singleQuoteEnd
        let dqStart = ShellTokenizer.doubleQuoteStart
        let dqEnd = ShellTokenizer.doubleQuoteEnd

        var tokens: [String] = []
        var current = ""
        var quoteDepth = 0

        for ch in text {
            if ch == sqStart || ch == dqStart {
                quoteDepth += 1
                current.append(ch)
            } else if ch == sqEnd || ch == dqEnd {
                quoteDepth = max(0, quoteDepth - 1)
                current.append(ch)
            } else if quoteDepth == 0 && (ch == " " || ch == "\t" || ch == "\n") {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Quick check whether a command string contains shell constructs that need
    /// the interpreter (as opposed to a simple command for ios_system).
    static func isCompoundCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        // `[[ ... ]]` conditionals and `(( ... ))` arithmetic commands
        // need the interpreter
        if trimmed.hasPrefix("[[ ") || trimmed.hasPrefix("! [[ ") { return true }
        if trimmed.hasPrefix("((") { return true }

        // Background jobs (`cmd &`) need the interpreter's job machinery.
        // Scan for an unquoted `&` that isn't `&&` or a `>&`/`<&` fd-dup.
        if containsBackgroundAmpersand(trimmed) { return true }

        // Check for keywords at the start
        let compoundKeywords = ["if ", "for ", "while ", "until ", "case ", "function "]
        for kw in compoundKeywords {
            if lower.hasPrefix(kw) { return true }
        }

        // Check for function definition pattern: word()
        if let parenIdx = trimmed.firstIndex(of: "(") {
            let beforeParen = trimmed[trimmed.startIndex..<parenIdx]
            if !beforeParen.isEmpty && !beforeParen.contains(" ") &&
               trimmed.index(after: parenIdx) < trimmed.endIndex &&
               trimmed[trimmed.index(after: parenIdx)] == ")" {
                return true
            }
        }

        // Check for compound constructs embedded after ; or &&/||
        // e.g., "echo hello; for i in 1 2 3; do echo $i; done"
        let embeddedPatterns = ["; if ", "; for ", "; while ", "; until ", "; case ",
                                "&& if ", "&& for ", "&& while ",
                                "|| if ", "|| for ", "|| while "]
        for pattern in embeddedPatterns {
            if lower.contains(pattern) { return true }
        }

        return false
    }
}

#endif
