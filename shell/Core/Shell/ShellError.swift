#if !targetEnvironment(macCatalyst)

import Foundation

/// Errors produced by the shell interpreter.
///
/// Control flow signals (break, continue, return, exit) use Swift's throw
/// mechanism to unwind through arbitrary nesting depths. The interpreter's
/// loop/function/top-level executors catch and handle these appropriately.
enum ShellError: Error {
    /// Script was interrupted by CTRL-C (cancellation token set).
    case cancelled

    /// Syntax error during parsing.
    case syntaxError(line: Int, _ message: String)

    /// `break [N]` — caught by the innermost loop executor, decremented per level.
    case breakSignal(Int)

    /// `continue [N]` — caught by the innermost loop executor, decremented per level.
    case continueSignal(Int)

    /// `return [N]` — caught by the function executor.
    case returnSignal(Int32)

    /// `exit [N]` — caught by the top-level runScript().
    case exitSignal(Int32)

    /// `${VAR:?message}` when VAR is unset or empty.
    case undefinedVariable(String)

    /// Division by zero in arithmetic expression.
    case divisionByZero

    /// General arithmetic expression error.
    case arithmeticError(String)

    /// CTRL-D during `read` builtin.
    case readEOF

    /// `${VAR<junk>}` — unrecognized parameter-expansion operator.
    case badSubstitution(String)

    /// Feature not yet implemented — gives a clear error message.
    case unsupported(String)

    /// I/O error (pipe creation failed, file not found, etc.)
    case ioError(String)
}

extension ShellError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Interrupted"
        case .syntaxError(let line, let message):
            return "syntax error near line \(line): \(message)"
        case .breakSignal:
            return "break: not in a loop"
        case .continueSignal:
            return "continue: not in a loop"
        case .returnSignal:
            return "return: not in a function"
        case .exitSignal(let code):
            return "exit \(code)"
        case .undefinedVariable(let name):
            return "\(name): parameter not set"
        case .divisionByZero:
            return "division by zero"
        case .arithmeticError(let message):
            return message
        case .readEOF:
            return "read: EOF"
        case .badSubstitution(let content):
            return "${\(content)}: bad substitution"
        case .unsupported(let feature):
            return "not supported: \(feature)"
        case .ioError(let message):
            return message
        }
    }
}

/// Thread-safe cancellation token using os_unfair_lock (matches project's UnfairLock pattern).
///
/// Checked at every loop iteration, before every command execution, and every N
/// iterations in tight builtin-only loops. The cost of checking is a single
/// os_unfair_lock round-trip (~nanoseconds, uncontended).
nonisolated final class CancellationToken: @unchecked Sendable {
    private let lock = UnfairLock()
    private var _cancelled = false

    nonisolated var isCancelled: Bool {
        lock.withLock { _cancelled }
    }

    nonisolated func cancel() {
        lock.withLock { _cancelled = true }
    }

    nonisolated func reset() {
        lock.withLock { _cancelled = false }
    }
}

#endif
