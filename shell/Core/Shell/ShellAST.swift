#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - AST Node Types

/// A complete shell command — the top-level AST node.
///
/// The AST is `indirect` because compound commands (if, for, while, etc.)
/// contain nested command lists, and pipelines/sequences contain arrays
/// of commands.
nonisolated indirect enum ShellCommand: Sendable {
    /// A simple command: optional assignments, words (command + args), redirections.
    case simple(SimpleCommand)

    /// A pipeline: `cmd1 | cmd2 | cmd3`.
    /// The exit code is that of the last command (unless `!` negation is applied).
    case pipeline([ShellCommand])

    /// Logical AND or OR: `cmd1 && cmd2` or `cmd1 || cmd2`.
    case andOr(ShellCommand, AndOrOp, ShellCommand)

    /// A sequence of commands: `cmd1; cmd2; cmd3` or `cmd1\ncmd2`.
    case sequence([ShellCommand])

    /// `if` / `elif` / `else` / `fi`.
    case ifCmd(IfClause)

    /// `for VAR in WORDS; do BODY; done`.
    case forCmd(ForClause)

    /// `while CONDITION; do BODY; done`.
    case whileCmd(WhileClause)

    /// `until CONDITION; do BODY; done`.
    case untilCmd(UntilClause)

    /// `case WORD in PATTERN) BODY;; ... esac`.
    case caseCmd(CaseClause)

    /// Function definition: `name() { body; }`.
    case functionDef(name: String, body: ShellCommand)

    /// Subshell: `( commands )`.
    case subshell(ShellCommand)

    /// Brace group: `{ commands; }`.
    case braceGroup(ShellCommand)

    /// Negation: `! command` — inverts exit code.
    case negation(ShellCommand)

    /// Conditional expression: `[[ expression ]]`.
    case doubleBracket([DoubleBracketToken])

    /// Background job: `command &`.
    case background(ShellCommand)
}

/// One token inside `[[ ... ]]`: a lexical operator, or an operand that is
/// expanded (without field splitting or globbing) at evaluation time.
/// Classification happens at parse time — an operand that merely *expands*
/// to an operator string is still an operand, matching bash.
nonisolated enum DoubleBracketToken: Sendable {
    case op(String)
    case operand(ShellWord)
}

// MARK: - Simple Command

/// A simple command with optional pre-assignments, words, and redirections.
///
/// Examples:
/// - `echo hello world` → assignments=[], words=["echo","hello","world"]
/// - `VAR=val cmd` → assignments=[("VAR","val")], words=["cmd"]
/// - `VAR=val` → assignments=[("VAR","val")], words=[] (assignment only)
/// - `echo hello > file` → words=["echo","hello"], redirections=[> file]
nonisolated struct SimpleCommand: Sendable {
    var assignments: [(String, String)]
    var words: [ShellWord]
    var redirections: [Redirection]
    /// Here-document content to feed to stdin (collected by tokenizer, attached by parser).
    var heredocContent: String?
    /// Whether the here-document delimiter was quoted (no expansion if true).
    var heredocQuoted: Bool?

    init(assignments: [(String, String)] = [],
         words: [ShellWord] = [],
         redirections: [Redirection] = [],
         heredocContent: String? = nil,
         heredocQuoted: Bool? = nil) {
        self.assignments = assignments
        self.words = words
        self.redirections = redirections
        self.heredocContent = heredocContent
        self.heredocQuoted = heredocQuoted
    }
}

// MARK: - Shell Word (with expansion markers)

/// A word that may contain embedded expansion points.
///
/// During parsing, text is decomposed into `ShellWord` parts that preserve
/// quoting context and mark where expansion should happen at execution time.
/// The interpreter's `expandWord()` walks these to produce final strings.
nonisolated indirect enum ShellWord: Sendable, Equatable {
    /// Literal text (no expansion needed). From unquoted or escaped text.
    case literal(String)

    /// Single-quoted string: completely literal, no expansion.
    case singleQuoted(String)

    /// Double-quoted string: may contain nested expansions.
    case doubleQuoted([ShellWord])

    /// Variable reference: `$VAR` or `$N`.
    case variable(String)

    /// Parameter expansion: `${VAR}`, `${VAR:-default}`, `${#VAR}`, etc.
    case paramExpansion(ParamExpansion)

    /// Command substitution: `$(cmd)` or `` `cmd` ``.
    /// The string is the raw command text — parsed lazily at execution time.
    case commandSub(String)

    /// Arithmetic expansion: `$((expr))`.
    /// The string is the raw expression — evaluated at execution time.
    case arithmetic(String)

    /// Concatenation of adjacent word parts (e.g., `"hello "$name`).
    case concat([ShellWord])
}

// MARK: - Parameter Expansion

/// Represents `${...}` parameter expansion forms.
nonisolated enum ParamExpansion: Sendable, Equatable {
    /// `${VAR}` — simple expansion (same as `$VAR` but allows `${VAR}text`).
    case simple(String)

    /// `${VAR:-word}` / `${VAR-word}` — use `word` if VAR is unset
    /// (`checkEmpty` adds the set-but-empty case, i.e. the `:` forms).
    case defaultValue(name: String, word: [ShellWord], checkEmpty: Bool)

    /// `${VAR:=word}` / `${VAR=word}` — assign `word` if VAR is unset (or empty with `:`).
    case assignDefault(name: String, word: [ShellWord], checkEmpty: Bool)

    /// `${VAR:+word}` / `${VAR+word}` — use `word` if VAR is set (and non-empty with `:`).
    case alternative(name: String, word: [ShellWord], checkEmpty: Bool)

    /// `${VAR:?word}` / `${VAR?word}` — error with `word` if VAR is unset (or empty with `:`).
    case errorIfUnset(name: String, word: [ShellWord], checkEmpty: Bool)

    /// `${VAR:offset}` / `${VAR:offset:length}` — substring. Offset/length are
    /// raw arithmetic expressions evaluated at expansion time (negative offset
    /// counts from the end; negative length stops short of the end).
    case substring(name: String, offset: String, length: String?)

    /// `${VAR/pat/repl}` (first), `${VAR//pat/repl}` (all),
    /// `${VAR/#pat/repl}` (prefix), `${VAR/%pat/repl}` (suffix).
    case replace(name: String, pattern: String, replacement: [ShellWord], mode: ReplaceMode)

    /// `${VAR<junk>}` — unrecognized operator; reported at expansion time
    /// instead of silently mis-expanding.
    case bad(String)

    /// `${#VAR}` — length of VAR's value.
    case length(String)

    /// `${VAR#pattern}` — remove shortest prefix match.
    case stripShortPrefix(name: String, pattern: String)

    /// `${VAR##pattern}` — remove longest prefix match.
    case stripLongPrefix(name: String, pattern: String)

    /// `${VAR%pattern}` — remove shortest suffix match.
    case stripShortSuffix(name: String, pattern: String)

    /// `${VAR%%pattern}` — remove longest suffix match.
    case stripLongSuffix(name: String, pattern: String)
}

/// Scope of a `${VAR/pat/repl}` replacement.
nonisolated enum ReplaceMode: Sendable, Equatable {
    case first    // ${VAR/pat/repl}
    case all      // ${VAR//pat/repl}
    case prefix   // ${VAR/#pat/repl}
    case suffix   // ${VAR/%pat/repl}
}

// MARK: - Operators

nonisolated enum AndOrOp: Sendable {
    case and    // &&
    case or     // ||
}

// MARK: - Compound Command Clauses

nonisolated struct IfClause: Sendable {
    /// The primary `if CONDITION; then BODY` and any `elif CONDITION; then BODY`.
    let branches: [(condition: ShellCommand, body: ShellCommand)]
    /// The `else BODY` (nil if no else clause).
    let elseBranch: ShellCommand?
}

nonisolated struct ForClause: Sendable {
    let variable: String
    /// The word list to iterate over. `nil` means `"$@"` (positional params).
    let wordList: [ShellWord]?
    let body: ShellCommand
}

nonisolated struct WhileClause: Sendable {
    let condition: ShellCommand
    let body: ShellCommand
}

nonisolated struct UntilClause: Sendable {
    let condition: ShellCommand
    let body: ShellCommand
}

nonisolated struct CaseClause: Sendable {
    let word: ShellWord
    let items: [CaseItem]
}

nonisolated struct CaseItem: Sendable {
    /// Patterns to match against (separated by `|` in source).
    let patterns: [ShellWord]
    /// Body to execute if any pattern matches.
    let body: ShellCommand?
}

#endif
