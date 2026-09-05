#if !targetEnvironment(macCatalyst)

import Foundation

/// Tokens produced by the shell tokenizer.
///
/// Keywords are only recognized in command position (after `;`, `\n`, `then`,
/// `do`, `{`, or at the start of input). In all other positions, a keyword-like
/// string (e.g., "if") is tokenized as a plain `.word`.
nonisolated enum ShellToken: Equatable, Sendable {
    // MARK: - Literals

    /// A plain word (command name, argument, or part of one).
    /// May still contain unexpanded `$VAR` references — expansion happens at execution time.
    case word(String)

    /// A variable assignment: `NAME=VALUE` (detected when `=` appears in command position
    /// before any non-assignment words).
    case assignmentWord(name: String, value: String)

    // MARK: - Operators

    case semicolon          // ;
    case newline            // \n (significant as command terminator)
    case pipe               // |
    case andIf              // &&
    case orIf               // ||
    case ampersand          // & (background — will produce clear error on iOS)
    case lparen             // (
    case rparen             // )
    case dsemi              // ;; (case clause terminator)

    // MARK: - Redirections

    case redirect(Redirection)

    // MARK: - Keywords (only in command position)

    case kw_if
    case kw_then
    case kw_elif
    case kw_else
    case kw_fi
    case kw_for
    case kw_in
    case kw_do
    case kw_done
    case kw_while
    case kw_until
    case kw_case
    case kw_esac
    case kw_function
    case kw_lbrace          // {
    case kw_rbrace          // }
    case kw_bang             // !

    // MARK: - Here-documents

    /// A here-document. `content` is the full body text.
    /// `quoted` means the delimiter was quoted (`<<'EOF'`) — no expansion.
    case heredoc(content: String, quoted: Bool)

    // MARK: - End of input

    case eof
}

/// Redirection operator with target.
nonisolated struct Redirection: Equatable, Sendable {
    let op: RedirectOp
    /// The file descriptor being redirected (default: implicit from op).
    let fd: Int32?
    /// Target filename or file descriptor number (for `>&N`).
    let target: String

    init(op: RedirectOp, fd: Int32? = nil, target: String) {
        self.op = op
        self.fd = fd
        self.target = target
    }
}

/// Types of redirection operators.
nonisolated enum RedirectOp: Equatable, Sendable {
    case inputFrom          // <
    case outputTo           // >
    case appendTo           // >>
    case errorTo            // 2>
    case errorAppendTo      // 2>>
    case duplicateOutput    // >&N  or  &>
    case duplicateInput     // <&N
    case mergeStderrStdout  // 2>&1
    case heredocOp          // <<
    case heredocStripOp     // <<- (strip leading tabs)
}

/// The set of strings that are shell keywords.
/// Used by the tokenizer to decide whether a word in command position is a keyword.
let shellKeywords: Set<String> = [
    "if", "then", "elif", "else", "fi",
    "for", "in", "do", "done",
    "while", "until",
    "case", "esac",
    "function",
    "{", "}",
    "!"
]

#endif
