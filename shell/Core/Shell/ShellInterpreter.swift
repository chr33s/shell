#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Walks the shell AST and executes commands.
///
/// Runs entirely on `commandQueue` (never MainActor). Individual external commands
/// are delegated to ios_system via the `executeExternal` callback. Control flow,
/// variables, functions, and builtins are handled natively in Swift.
///
/// Cancellation is checked before every AST node and at every loop iteration.
/// Tight builtin-only loops also yield every 256 iterations.
nonisolated final class ShellInterpreter: @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "ShellInterpreter")

    let environment: ShellEnvironment
    let cancellationToken: CancellationToken

    /// Execute an external command via ios_system. Returns exit code.
    let executeExternal: @Sendable (String) -> Int32

    /// Execute an external command with content piped to its stdin (for here-documents).
    let executeExternalWithStdin: @Sendable (String, String) -> Int32

    /// Execute an external command and capture its stdout. Returns (exit code, captured output).
    /// Used by `$(...)` command substitution.
    let captureExternal: @Sendable (String) -> (Int32, String)

    /// Write output to the terminal (→ OutputBatcher.enqueue).
    let writeOutput: @Sendable (Data) -> Void

    /// Read a line from the terminal for the `read` builtin.
    /// Parameters: prompt string (optional), silent flag (suppresses echo for `read -s`).
    /// Returns the line, or nil on EOF/cancellation.
    let readLine: @Sendable (String?, Bool) -> String?

    /// Execute an external command with streaming I/O for pipeline stages.
    /// Parameters: command string, optional stdin provider, output sink (returns false to stop/SIGPIPE).
    /// Returns exit code. When the sink returns false, the command should be killed.
    let streamExternal: (@Sendable (String, (@Sendable () -> Data?)?, @escaping @Sendable (Data) -> Bool) -> Int32)?

    /// Reports whether a rendered external command can safely participate in a streamed pipeline.
    let canStreamExternalCommand: (@Sendable (String) -> Bool)?

    /// Reports whether a rendered external command must run as its own
    /// pipeline stage rather than being bundled with neighbouring externals.
    /// Defaults to nil (always bundleable). Used for commands whose host
    /// implementation can't honour ios_system's internal pipe handling — e.g.
    /// the WASM runtime, which would otherwise receive the joined-with-`|`
    /// string as its argv and pass `|` through to the wasm process.
    let requiresOwnExternalPipelineStage: (@Sendable (String) -> Bool)?

    /// Streaming executor for background jobs: same shape as `streamExternal`
    /// but with native app-command routing disabled and wasm refused, so a
    /// dynamically-named command (`c=ssh; $c host &`) can never reach an
    /// interactive handler from a detached job. nil = jobs can't run externals.
    let backgroundStreamExternal: (@Sendable (String, (@Sendable () -> Data?)?, @escaping @Sendable (Data) -> Bool) -> Int32)?

    /// Additional stage-local cancellation signal used by concurrent shell-native pipelines.
    let isLocallyCancelled: (@Sendable () -> Bool)?

    /// Trap handlers: shared via the environment so they persist across interpreter instances.
    var trapRegistry: TrapRegistry { environment.trapRegistry }

    /// Reentrancy guard for ERR trap (prevents infinite recursion when trap body fails).
    private var inErrTrap = false

    /// Depth of `set -e`-exempt contexts: if/while/until conditions, the
    /// left arm of `&&`/`||`, and `!`-negated commands. Errexit only fires
    /// at depth zero, matching bash.
    private var errexitSuppressionDepth = 0

    private func withErrexitSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        errexitSuppressionDepth += 1
        defer { errexitSuppressionDepth -= 1 }
        return try body()
    }

    /// Fire `set -e` for a failed leaf command (simple/pipeline/[[ ]]) when
    /// not in an exempt context.
    private func errexitCheck(_ code: Int32) throws {
        if code != 0, errexitSuppressionDepth == 0, environment.options.errexit {
            throw ShellError.exitSignal(code)
        }
    }

    /// Output throttle for flood protection.
    private let outputThrottle = OutputThrottle()

    /// Budget: check cancellation every N builtin-only loop iterations.
    private static let builtinCheckInterval = 256

    /// Cap on items produced by a single top-level brace expansion. Bounds
    /// crafted scripts like `for i in {1..100000000}` from exhausting memory.
    private static let maxBraceExpansionCount = 65_536

    /// Cap on nested `{...}` recursion depth. Defends against pathological
    /// input like `{{{{...}}}}` blowing the stack.
    private static let maxBraceRecursionDepth = 16

    init(environment: ShellEnvironment,
         cancellationToken: CancellationToken,
         executeExternal: @escaping @Sendable (String) -> Int32,
         executeExternalWithStdin: (@Sendable (String, String) -> Int32)? = nil,
         captureExternal: (@Sendable (String) -> (Int32, String))? = nil,
         streamExternal: (@Sendable (String, (@Sendable () -> Data?)?, @escaping @Sendable (Data) -> Bool) -> Int32)? = nil,
         canStreamExternalCommand: (@Sendable (String) -> Bool)? = nil,
         requiresOwnExternalPipelineStage: (@Sendable (String) -> Bool)? = nil,
         backgroundStreamExternal: (@Sendable (String, (@Sendable () -> Data?)?, @escaping @Sendable (Data) -> Bool) -> Int32)? = nil,
         isLocallyCancelled: (@Sendable () -> Bool)? = nil,
         writeOutput: @escaping @Sendable (Data) -> Void,
         readLine: @escaping @Sendable (String?, Bool) -> String?) {
        self.environment = environment
        self.cancellationToken = cancellationToken
        self.executeExternal = executeExternal
        // Default: write stdin content to a temp file and use shell redirection
        self.executeExternalWithStdin = executeExternalWithStdin ?? { command, stdinContent in
            // Fallback: write here-doc to temp file, redirect stdin from it
            let tempFile = NSTemporaryDirectory() + "heredoc_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 0...999999))"
            do {
                try stdinContent.write(toFile: tempFile, atomically: true, encoding: .utf8)
            } catch {
                return 1
            }
            defer { try? FileManager.default.removeItem(atPath: tempFile) }
            let fullCommand = "\(command) < \(tempFile)"
            return executeExternal(fullCommand)
        }
        // Default: fall back to executeExternal (output goes to terminal, returns empty)
        self.captureExternal = captureExternal ?? { command in
            let exitCode = executeExternal(command)
            return (exitCode, "")
        }
        self.streamExternal = streamExternal
        self.canStreamExternalCommand = canStreamExternalCommand
        self.requiresOwnExternalPipelineStage = requiresOwnExternalPipelineStage
        self.backgroundStreamExternal = backgroundStreamExternal
        self.isLocallyCancelled = isLocallyCancelled
        self.writeOutput = writeOutput
        self.readLine = readLine
    }

    // MARK: - Cancellation

    /// Check if the script has been cancelled. Throws `.cancelled` if so.
    func checkCancelled() throws {
        if cancellationToken.isCancelled || (isLocallyCancelled?() ?? false) {
            throw ShellError.cancelled
        }
    }

    // MARK: - Output Helpers

    func writeString(_ s: String) {
        let data = Data(s.utf8)
        writeOutput(data)
        if outputThrottle.recordOutput(bytes: data.count) {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func writeLine(_ s: String) {
        // Pure LF: the terminal-bound writeOutput sink converts lone LF to
        // CRLF at the boundary, so captures/pipes/files receive clean LF.
        writeString(s + "\n")
    }

    // MARK: - Command Substitution

    /// Execute a command and capture its stdout as a string.
    /// Used for `$(cmd)` expansion.
    ///
    /// The substitution command is parsed and executed through the interpreter so
    /// that shell functions, variables, builtins, and compound constructs work
    /// inside `$(...)`.  External commands are routed through `captureExternal`
    /// so their output is also captured into the buffer.
    func executeCommandSubstitution(_ command: String) throws -> String {
        try checkCancelled()

        let tokenizer = ShellTokenizer(source: command)
        let parser = ShellParser(tokenizer: tokenizer)

        let ast: ShellCommand
        do {
            ast = try parser.parse()
        } catch {
            // Fall back to external execution for unparseable commands
            let (exitCode, output) = captureExternal(command)
            environment.setLastExitCode(exitCode)
            var result = normalizeCommandSubstitutionOutput(output)
            while result.hasSuffix("\n") { result.removeLast() }
            return result
        }

        // Only ever touched from this interpreter's own execution thread.
        nonisolated(unsafe) var captured = Data()
        let captureCallback = self.captureExternal

        // Snapshot environment to prevent side-effect leakage (POSIX: command substitution runs in a subshell)
        let savedVars = environment.snapshotVariables()
        let savedFuncs = environment.snapshotFunctions()
        let savedExports = environment.snapshotExportedState()
        let savedParams = environment.getAllPositionalParams()
        let savedName = environment.getScriptName()
        let savedPwd = environment.getVariable("PWD")
        let savedTraps = environment.trapRegistry.snapshot()
        let savedOptions = environment.options

        let subInterp = ShellInterpreter(
            environment: environment,
            cancellationToken: cancellationToken,
            executeExternal: { cmd in
                // Route external commands through capture so output is collected
                let (exitCode, output) = captureCallback(cmd)
                captured.append(Data(output.utf8))
                return exitCode
            },
            captureExternal: captureExternal,
            canStreamExternalCommand: canStreamExternalCommand,
            requiresOwnExternalPipelineStage: requiresOwnExternalPipelineStage,
            writeOutput: { data in captured.append(data) },
            readLine: { _, _ -> String? in nil }
        )

        let exitCode: Int32
        do {
            exitCode = try subInterp.execute(ast)
        } catch {
            // Restore on error too
            environment.restoreVariables(savedVars)
            environment.restoreFunctions(savedFuncs)
            environment.restoreExportedState(savedExports)
            environment.setPositionalParams(savedParams, scriptName: savedName)
            environment.trapRegistry.restore(savedTraps)
            environment.updateOptions { $0 = savedOptions }
            if let pwd = savedPwd, pwd != environment.getVariable("PWD") {
                let sessionPtr = IOSSystemSessionKey.key(for: environment.sessionID)
                ios_switchSession(sessionPtr)
                chdir(pwd)
                environment.setVariable("PWD", value: pwd)
            }
            throw error
        }

        // Restore environment (only keep the exit code from the subshell)
        environment.restoreVariables(savedVars)
        environment.restoreFunctions(savedFuncs)
        environment.restoreExportedState(savedExports)
        environment.setPositionalParams(savedParams, scriptName: savedName)
        environment.trapRegistry.restore(savedTraps)
        environment.updateOptions { $0 = savedOptions }
        if let pwd = savedPwd, pwd != environment.getVariable("PWD") {
            let sessionPtr = IOSSystemSessionKey.key(for: environment.sessionID)
            ios_switchSession(sessionPtr)
            chdir(pwd)
            environment.setVariable("PWD", value: pwd)
        }
        environment.setLastExitCode(exitCode)

        var result = normalizeCommandSubstitutionOutput(String(data: captured, encoding: .utf8) ?? "")
        // POSIX: strip trailing newlines from command substitution
        while result.hasSuffix("\r\n") { result.removeLast(2) }
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    /// Evaluate an arithmetic expression.
    func evaluateArithmetic(_ expr: String) throws -> Int64 {
        try checkCancelled()
        return try ShellArithmeticEvaluator.evaluate(expr, environment: environment)
    }

    // MARK: - Pre-Routing Expansion

    /// Expand a simple command's words into final argv via the full AST path
    /// (`$()`, `$((...))`, backticks, variable/parameter expansion, POSIX
    /// field splitting, pathname expansion). Callers inspect argv[0] to decide
    /// whether it is safe to route the rebuilt command to a native handler,
    /// or whether execution should stay in the interpreter (shell functions,
    /// unknown commands, entries needing shell quoting).
    ///
    /// Returns nil for simple commands that should not be rebuilt (pre-command
    /// assignments, redirections, here-docs, or empty argv) — callers should
    /// fall back to full interpreter execution for those.
    func expandSimpleCommandArgv(_ simple: SimpleCommand) throws -> [String]? {
        guard simple.assignments.isEmpty,
              simple.redirections.isEmpty,
              simple.heredocContent == nil else {
            return nil
        }
        let argv = try expandCommandWords(simple.words)
        guard !argv.isEmpty else { return nil }
        return argv
    }

    // MARK: - Main Execution

    /// Execute an AST node and return its exit code.
    func execute(_ command: ShellCommand) throws -> Int32 {
        try checkCancelled()

        switch command {
        case .simple(let cmd):
            let code = try executeSimple(cmd)
            try errexitCheck(code)
            return code

        case .pipeline(let commands):
            let code = try executePipeline(commands)
            try errexitCheck(code)
            return code

        case .andOr(let left, let op, let right):
            return try executeAndOr(left, op, right)

        case .sequence(let commands):
            return try executeSequence(commands)

        case .ifCmd(let clause):
            return try executeIf(clause)

        case .forCmd(let clause):
            return try executeFor(clause)

        case .whileCmd(let clause):
            return try executeWhile(clause)

        case .untilCmd(let clause):
            return try executeUntil(clause)

        case .caseCmd(let clause):
            return try executeCase(clause)

        case .functionDef(let name, let body):
            environment.defineFunction(name, body: body)
            return 0

        case .subshell(let cmd):
            // On iOS, subshells run in the same process (no fork).
            // Simulate full isolation by snapshotting variables, functions,
            // exported names, traps, positional params, and PWD, then
            // restoring them after the subshell exits.
            let savedVars = environment.snapshotVariables()
            let savedFuncs = environment.snapshotFunctions()
            let savedExports = environment.snapshotExportedState()
            let savedParams = environment.getAllPositionalParams()
            let savedName = environment.getScriptName()
            let savedPwd = environment.getVariable("PWD")
            let savedTraps = environment.trapRegistry.snapshot()
            let savedOptions = environment.options
            environment.pushScope()
            let code: Int32
            do {
                code = try execute(cmd)
            } catch {
                environment.popScope()
                environment.restoreVariables(savedVars)
                environment.restoreFunctions(savedFuncs)
                environment.restoreExportedState(savedExports)
                environment.setPositionalParams(savedParams, scriptName: savedName)
                environment.trapRegistry.restore(savedTraps)
                environment.updateOptions { $0 = savedOptions }
                if let pwd = savedPwd, pwd != environment.getVariable("PWD") {
                    let sessionPtr = IOSSystemSessionKey.key(for: environment.sessionID)
                    ios_switchSession(sessionPtr)
                    chdir(pwd)
                    environment.setVariable("PWD", value: pwd)
                }
                throw error
            }
            environment.popScope()
            environment.restoreVariables(savedVars)
            environment.restoreFunctions(savedFuncs)
            environment.restoreExportedState(savedExports)
            environment.setPositionalParams(savedParams, scriptName: savedName)
            environment.trapRegistry.restore(savedTraps)
            environment.updateOptions { $0 = savedOptions }
            if let pwd = savedPwd, pwd != environment.getVariable("PWD") {
                let sessionPtr = IOSSystemSessionKey.key(for: environment.sessionID)
                ios_switchSession(sessionPtr)
                chdir(pwd)
                environment.setVariable("PWD", value: pwd)
            }
            return code

        case .braceGroup(let cmd):
            return try execute(cmd)

        case .negation(let cmd):
            let code = try withErrexitSuppressed { try execute(cmd) }
            let result: Int32 = code == 0 ? 1 : 0
            environment.setLastExitCode(result)
            return result

        case .doubleBracket(let tokens):
            let code = try executeDoubleBracket(tokens)
            environment.setLastExitCode(code)
            try errexitCheck(code)
            return code

        case .background(let cmd):
            return try launchBackgroundJob(cmd)
        }
    }

    // MARK: - Simple Command Execution

    private func executeSimple(_ cmd: SimpleCommand) throws -> Int32 {
        try checkCancelled()

        // If no words, just process assignments
        if cmd.words.isEmpty {
            for (name, rawValue) in cmd.assignments {
                let value = try environment.expandScalarWord(
                    ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: rawValue),
                    interpreter: self
                )
                environment.setVariable(name, value: value)
            }
            environment.setLastExitCode(0)
            return 0
        }

        let expandedWords = try expandCommandWords(cmd.words)

        guard let commandName = expandedWords.first, !commandName.isEmpty else {
            environment.setLastExitCode(0)
            return 0
        }

        // `set -x` trace
        if environment.options.xtrace {
            writeLine("+ " + expandedWords.joined(separator: " "))
        }

        // Check for shell functions
        if let funcBody = environment.getFunction(commandName) {
            return try executeFunction(commandName,
                                        args: Array(expandedWords.dropFirst()),
                                        body: funcBody)
        }

        // Check for builtins
        if let builtin = ShellBuiltins.lookup(commandName) {
            let args = Array(expandedWords.dropFirst())

            // Pre-command assignments: temporarily set for this command.
            // Save: (name, oldShellValue, wasExported, oldEnvValue)
            // We capture the ios_system env value separately so we can restore
            // inherited env vars (like PATH) that aren't in our exportedNames set.
            var savedVars: [(String, String?, Bool, String?)] = []
            for (name, rawValue) in cmd.assignments {
                let value = try environment.expandScalarWord(
                    ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: rawValue),
                    interpreter: self
                )
                let oldEnvValue = environment.getExportedEnvValue(name)
                savedVars.append((name, environment.getVariable(name), environment.isExported(name), oldEnvValue))
                environment.exportVariable(name, value: value)
            }

            let exitCode: Int32
            do {
                exitCode = try builtin(args, environment, self)
            } catch {
                // Restore pre-command assignments before rethrowing
                for (name, oldValue, wasExported, oldEnvValue) in savedVars {
                    if let old = oldValue {
                        environment.setVariable(name, value: old)
                    } else {
                        environment.unsetVariable(name)
                    }
                    if !wasExported {
                        environment.removeFromExportedSet(name)
                    }
                    if oldEnvValue != nil || !wasExported {
                        environment.restoreExportedEnvValue(name, value: oldEnvValue)
                    }
                }
                throw error
            }

            // Restore pre-command assignments
            for (name, oldValue, wasExported, oldEnvValue) in savedVars {
                if let old = oldValue {
                    environment.setVariable(name, value: old)
                } else {
                    environment.unsetVariable(name)
                }
                if !wasExported {
                    environment.removeFromExportedSet(name)
                }
                if oldEnvValue != nil || !wasExported {
                    environment.restoreExportedEnvValue(name, value: oldEnvValue)
                }
            }

            environment.setLastExitCode(exitCode)

            // Fire ERR trap on non-zero exit from builtins (with reentrancy guard)
            if exitCode != 0, !inErrTrap, let errTrap = trapRegistry.getHandler(for: .err) {
                inErrTrap = true
                _ = try? execute(errTrap)
                inErrTrap = false
            }

            return exitCode
        }

        // Isolated externals (e.g. WASM) with redirections must have their
        // redirections handled at the interpreter level. ios_system can't run
        // the underlying binary, so the usual path — appending `> file` to the
        // command and letting ios_system parse it — fails with "command not
        // found". Open the files here and wire them into `streamExternal`,
        // which the host routes to its in-app runtime.
        if !cmd.redirections.isEmpty,
           let streamExternalImpl = streamExternal,
           let requiresOwnStage = requiresOwnExternalPipelineStage {
            let bareCommand = expandedWords.map { shellEscape($0) }.joined(separator: " ")
            if requiresOwnStage(bareCommand) {
                return try executeIsolatedExternalWithRedirections(
                    bareCommand: bareCommand,
                    assignments: cmd.assignments,
                    redirections: cmd.redirections,
                    heredocContent: cmd.heredocContent,
                    heredocQuoted: cmd.heredocQuoted,
                    streamExternal: streamExternalImpl
                )
            }
        }

        // A logical `cd` in an isolated context (background job, pipeline
        // stage) can't move the child's physical cwd — ios_system's working
        // directory is process-wide, so running the command would silently
        // use the foreground directory. Refuse with a clear error instead.
        if environment.isIsolatedContext,
           let logicalPwd = environment.getVariable("PWD"),
           let physicalNS = ios_getLogicalPWD(IOSSystemSessionKey.key(for: environment.sessionID)),
           (physicalNS as String) != logicalPwd {
            writeLine("sh: \(commandName): external commands cannot run after cd in a background job or pipeline stage (working directory is process-wide on iOS)")
            environment.setLastExitCode(1)
            return 1
        }

        // External command: reconstruct command string with redirections
        var fullCommand = expandedWords.map { shellEscape($0) }.joined(separator: " ")

        // Append redirections (skip heredoc ops — handled via stdin pipe)
        for redir in cmd.redirections {
            if redir.op == .heredocOp || redir.op == .heredocStripOp { continue }
            fullCommand += " " + reconstructRedirection(redir)
        }

        // Pre-command assignments: set temporarily in environment.
        // Save: (name, oldShellValue, wasExported, oldEnvValue)
        // We capture the ios_system env value separately so we can restore
        // inherited env vars (like PATH) that aren't in our exportedNames set.
        var savedVars: [(String, String?, Bool, String?)] = []
        for (name, rawValue) in cmd.assignments {
            let value = try environment.expandScalarWord(
                ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: rawValue),
                interpreter: self
            )
            let oldEnvValue = environment.getExportedEnvValue(name)
            savedVars.append((name, environment.getVariable(name), environment.isExported(name), oldEnvValue))
            environment.exportVariable(name, value: value)
        }

        let childEnvironment = environment.snapshotChildProcessEnvironment()

        // Isolated contexts (pipeline stages, background jobs) can't write
        // the shared process env — withTemporaryChildProcessEnvironment is a
        // no-op there — so the full exported snapshot (which includes the
        // pre-command assignments and any `export` done inside the job) is
        // inlined as a `NAME=value` prefix that ios_system's shell parser
        // applies itself.
        if environment.isIsolatedContext {
            var prefix = ""
            for name in childEnvironment.keys.sorted() {
                guard let value = childEnvironment[name] else { continue }
                prefix += "\(name)=\(shellEscape(value)) "
            }
            fullCommand = prefix + fullCommand
        }

        // If there's here-doc content, pipe it to stdin.
        // Unquoted here-docs (heredocQuoted == false) undergo variable expansion;
        // quoted here-docs are passed through literally (POSIX spec).
        let exitCode: Int32
        if let heredocContent = cmd.heredocContent {
            let expandedContent: String
            if cmd.heredocQuoted == true {
                expandedContent = heredocContent
            } else {
                expandedContent = try expandHeredocContent(heredocContent)
            }
            exitCode = environment.withTemporaryChildProcessEnvironment(childEnvironment) {
                executeExternalWithStdin(fullCommand, expandedContent)
            }
        } else {
            exitCode = environment.withTemporaryChildProcessEnvironment(childEnvironment) {
                executeExternal(fullCommand)
            }
        }

        // Restore pre-command assignments
        for (name, oldValue, wasExported, oldEnvValue) in savedVars {
            if let old = oldValue {
                environment.setVariable(name, value: old)
            } else {
                environment.unsetVariable(name)
            }
            if !wasExported {
                environment.removeFromExportedSet(name)
            }
            if oldEnvValue != nil || !wasExported {
                environment.restoreExportedEnvValue(name, value: oldEnvValue)
            }
        }

        environment.setLastExitCode(exitCode)

        // Fire ERR trap on non-zero exit from external commands (with reentrancy guard)
        if exitCode != 0, !inErrTrap, let errTrap = trapRegistry.getHandler(for: .err) {
            inErrTrap = true
            _ = try? execute(errTrap)
            inErrTrap = false
        }

        return exitCode
    }

    // MARK: - Pipeline Execution

    private enum PipelineStage: Sendable {
        case shell(ShellCommand)
        case external([ShellCommand])
    }

    /// Execute a pipeline of commands connected by `|`.
    ///
    /// Pure shell-native pipelines run concurrently with bounded in-memory pipes.
    /// External-command stages also run concurrently, streaming their stdout into
    /// the same bounded pipes so downstream stages see data as it is produced.
    ///
    /// Non-last stages always run with isolated environments so shell-side
    /// effects do not leak. The final stage inherits the parent environment,
    /// matching shell behavior such as `cmd | while read line; do VAR=val; done`.
    /// Single-shot Sendable wrapper for a heredoc payload feeding stdin
    /// through an `inputProvider` callback. Returns the payload once, then
    /// nil — matching POSIX semantics for a closed stdin after the heredoc.
    private final class HeredocStdinBox: @unchecked Sendable {
        private let lock = UnfairLock()
        private var data: Data?
        init(data: Data) { self.data = data }
        func take() -> Data? {
            lock.withLock {
                let out = data
                data = nil
                return out
            }
        }
    }

    /// Execute an isolated external command (e.g. WASM) whose redirections
    /// must be honoured inside the interpreter — the host's `streamExternal`
    /// callback can't see `> file` in the command string because the
    /// underlying binary isn't run via ios_system. Supports `>`, `>>`, `<`,
    /// and here-doc stdin. Other redirection forms (`2>`, `2>&1`, `>&N`) are
    /// rejected with an error.
    private func executeIsolatedExternalWithRedirections(
        bareCommand: String,
        assignments: [(String, String)],
        redirections: [Redirection],
        heredocContent: String?,
        heredocQuoted: Bool?,
        streamExternal: @Sendable (String, (@Sendable () -> Data?)?, @escaping @Sendable (Data) -> Bool) -> Int32
    ) throws -> Int32 {
        // Apply pre-command assignments temporarily (mirrors the executeExternal path).
        var savedVars: [(String, String?, Bool, String?)] = []
        for (name, rawValue) in assignments {
            let value = try environment.expandScalarWord(
                ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: rawValue),
                interpreter: self
            )
            let oldEnvValue = environment.getExportedEnvValue(name)
            savedVars.append((name, environment.getVariable(name), environment.isExported(name), oldEnvValue))
            environment.exportVariable(name, value: value)
        }
        defer {
            for (name, oldValue, wasExported, oldEnvValue) in savedVars {
                if let old = oldValue {
                    environment.setVariable(name, value: old)
                } else {
                    environment.unsetVariable(name)
                }
                if !wasExported {
                    environment.removeFromExportedSet(name)
                }
                if oldEnvValue != nil || !wasExported {
                    environment.restoreExportedEnvValue(name, value: oldEnvValue)
                }
            }
        }

        // Resolve & open redirection targets.
        var openedFDs: [Int32] = []
        var inputFD: Int32 = -1
        var outputFD: Int32 = -1
        defer { for fd in openedFDs { close(fd) } }

        func expandTarget(_ raw: String) -> String {
            let expanded: String
            do {
                let word = ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: raw)
                expanded = try environment.expandScalarWord(word, interpreter: self)
            } catch {
                expanded = raw
            }
            // Resolve against the session's PWD (tracked in the shell env)
            // rather than the process-global cwd — that cwd can flip between
            // sessions and would let `wasm foo > out` write into the wrong
            // tab's directory.
            return environment.resolvePath(expanded)
        }

        for redir in redirections {
            if redir.op == .heredocOp || redir.op == .heredocStripOp { continue }
            let target = expandTarget(redir.target)
            switch redir.op {
            case .outputTo:
                let fd = open(target, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                guard fd >= 0 else {
                    writeString("sh: \(target): \(String(cString: strerror(errno)))\n")
                    environment.setLastExitCode(1)
                    return 1
                }
                openedFDs.append(fd)
                outputFD = fd
            case .appendTo:
                let fd = open(target, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                guard fd >= 0 else {
                    writeString("sh: \(target): \(String(cString: strerror(errno)))\n")
                    environment.setLastExitCode(1)
                    return 1
                }
                openedFDs.append(fd)
                outputFD = fd
            case .inputFrom:
                let fd = open(target, O_RDONLY)
                guard fd >= 0 else {
                    writeString("sh: \(target): \(String(cString: strerror(errno)))\n")
                    environment.setLastExitCode(1)
                    return 1
                }
                openedFDs.append(fd)
                inputFD = fd
            default:
                writeString("sh: \(bareCommand): unsupported redirection for isolated external\n")
                environment.setLastExitCode(1)
                return 1
            }
        }

        // Build inputProvider: heredoc (single-shot) takes precedence over
        // `<` file redirection, matching the ordering in the existing path.
        let inputProvider: (@Sendable () -> Data?)?
        if let heredocContent {
            let expanded: String
            if heredocQuoted == true {
                expanded = heredocContent
            } else {
                expanded = try expandHeredocContent(heredocContent)
            }
            let pending = HeredocStdinBox(data: Data(expanded.utf8))
            inputProvider = { pending.take() }
        } else if inputFD >= 0 {
            let capturedFD = inputFD
            inputProvider = {
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                    guard let base = bp.baseAddress else { return -1 }
                    return read(capturedFD, base, 8192)
                }
                if n <= 0 { return nil }
                return Data(bytes: buf, count: n)
            }
        } else {
            inputProvider = nil
        }

        // Build outputSink: when `>` / `>>` is present, write straight to the
        // file fd; otherwise hand bytes to the interpreter's own writeOutput
        // (terminal). The fd write loop handles partial writes and EINTR.
        let outputSink: @Sendable (Data) -> Bool
        if outputFD >= 0 {
            let capturedFD = outputFD
            outputSink = { data in
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var written = 0
                    while written < raw.count {
                        let n = write(capturedFD, base.advanced(by: written), raw.count - written)
                        if n > 0 { written += n; continue }
                        if n < 0 && errno == EINTR { continue }
                        return
                    }
                }
                return true
            }
        } else {
            let outerWriteOutput = self.writeOutput
            outputSink = { data in
                outerWriteOutput(data)
                return true
            }
        }

        // Inline the exported env + pre-command assignments as leading
        // `NAME=value` tokens, matching how `renderExternalPipelineSegment`
        // hands env to `streamExternal` for pipeline stages. The host's wasm
        // route can't read the shell's per-session ios_system env via
        // `ProcessInfo`, so this is the only path that gets shell assignments
        // (`FOO=bar wasm tool.wasm > out`) into the wasm process.
        let childEnvironment = environment.snapshotChildProcessEnvironment()
        var renderedCommand = ""
        for name in childEnvironment.keys.sorted() {
            guard let value = childEnvironment[name] else { continue }
            renderedCommand += "\(name)=\(shellEscape(value)) "
        }
        renderedCommand += bareCommand
        let exitCode = environment.withTemporaryChildProcessEnvironment(childEnvironment) {
            streamExternal(renderedCommand, inputProvider, outputSink)
        }
        environment.setLastExitCode(exitCode)

        if exitCode != 0, !inErrTrap, let errTrap = trapRegistry.getHandler(for: .err) {
            inErrTrap = true
            _ = try? execute(errTrap)
            inErrTrap = false
        }
        return exitCode
    }

    private func executePipeline(_ commands: [ShellCommand]) throws -> Int32 {
        try checkCancelled()

        // Fast path: single command, no pipeline
        if commands.count == 1 {
            return try execute(commands[0])
        }

        guard let stages = buildPipelineStages(commands) else {
            throw ShellError.unsupported("pipeline contains a command that cannot participate in a native shell pipeline")
        }

        let hasExternalStages = stages.contains { stage in
            if case .external = stage {
                return true
            }
            return false
        }
        if hasExternalStages, streamExternal == nil {
            throw ShellError.unsupported("pipelines with external commands")
        }

        let lastExitCode = try executeConcurrentPipeline(stages)
        environment.setLastExitCode(lastExitCode)
        return lastExitCode
    }

    private func buildPipelineStages(_ commands: [ShellCommand]) -> [PipelineStage]? {
        var stages: [PipelineStage] = []
        var pendingExternal: [ShellCommand] = []

        func flushPendingExternal() {
            guard !pendingExternal.isEmpty else { return }
            stages.append(.external(pendingExternal))
            pendingExternal.removeAll()
        }

        for command in commands {
            if canRunWithoutExternal(command) {
                flushPendingExternal()
                stages.append(.shell(command))
                continue
            }

            guard canSerializeAsExternalStage(command) else {
                return nil
            }

            // If the host marks this command as needing isolation (e.g. WASM —
            // its rendered string can't be a multi-command `a | b` because the
            // host would pass the joined string as a single argv), flush any
            // pending bundle first and add this command as its own stage.
            if let requiresOwnStage = requiresOwnExternalPipelineStage,
               let rendered = try? renderExternalSimpleCommand(command),
               requiresOwnStage(rendered) {
                flushPendingExternal()
                stages.append(.external([command]))
                continue
            }

            pendingExternal.append(command)
        }

        flushPendingExternal()
        return stages
    }

    private func executeConcurrentPipeline(
        _ stages: [PipelineStage]
    ) throws -> Int32 {
        let stageCount = stages.count
        var pipes: [BlockingPipeBuffer] = []
        for _ in 0..<(stageCount - 1) {
            pipes.append(BlockingPipeBuffer(cancellationToken: cancellationToken))
        }

        // Each stage writes only its own index and group.wait() below is the
        // barrier, so the raw pointer is safe to share across the stage queues.
        nonisolated(unsafe) let exitCodes = UnsafeMutablePointer<Int32>.allocate(capacity: stageCount)
        exitCodes.initialize(repeating: 0, count: stageCount)
        defer { exitCodes.deallocate() }

        let outerExecuteExternal = self.executeExternal
        let outerExecuteExternalWithStdin = self.executeExternalWithStdin
        let outerCaptureExternal = self.captureExternal
        let outerWriteOutput = self.writeOutput
        let outerReadLine = self.readLine
        let env = self.environment
        let token = self.cancellationToken
        let streamExternal = self.streamExternal
        let canStreamExternalCommand = self.canStreamExternalCommand
        let requiresOwnExternalPipelineStage = self.requiresOwnExternalPipelineStage

        let group = DispatchGroup()

        for index in 0..<stageCount {
            let stage = stages[index]
            let isFirst = (index == 0)
            let isLast = (index == stageCount - 1)
            let upstream: BlockingPipeBuffer? = isFirst ? nil : pipes[index - 1]
            let downstream: BlockingPipeBuffer? = isLast ? nil : pipes[index]
            let stageEnvironment = isLast ? env : env.makeIsolatedCopy()
            let stageCancellation = CancellationToken()

            group.enter()
            let stageQueue = DispatchQueue(
                label: "dev.chr33s.shell.pipeline.stage\(index)",
                qos: .userInitiated
            )

            stageQueue.async {
                defer {
                    // Signal pipe ends so peers can unblock
                    downstream?.closeWrite()
                    upstream?.closeRead()
                    group.leave()
                }

                do {
                    switch stage {
                    case .shell(let command):
                        let stageInterp = ShellInterpreter(
                            environment: stageEnvironment,
                            cancellationToken: token,
                            executeExternal: { cmd in outerExecuteExternal(cmd) },
                            executeExternalWithStdin: { cmd, stdinContent in
                                outerExecuteExternalWithStdin(cmd, stdinContent)
                            },
                            captureExternal: outerCaptureExternal,
                            canStreamExternalCommand: canStreamExternalCommand,
                            requiresOwnExternalPipelineStage: requiresOwnExternalPipelineStage,
                            isLocallyCancelled: { stageCancellation.isCancelled },
                            writeOutput: { [downstream] data in
                                if isLast {
                                    outerWriteOutput(data)
                                } else if downstream?.write(data) == false {
                                    stageCancellation.cancel()
                                }
                            },
                            readLine: { [upstream] prompt, silent in
                                if !isFirst, let upstream = upstream {
                                    return upstream.readLine()
                                }
                                return outerReadLine(prompt, silent)
                            }
                        )
                        exitCodes[index] = try stageInterp.execute(command)

                    case .external(let segment):
                        guard let streamExternal else {
                            throw ShellError.unsupported("pipelines with external commands")
                        }

                        let renderer = ShellInterpreter(
                            environment: stageEnvironment,
                            cancellationToken: token,
                            executeExternal: { _ in 1 },
                            executeExternalWithStdin: { _, _ in 1 },
                            captureExternal: { _ in (1, "") },
                            canStreamExternalCommand: canStreamExternalCommand,
                            requiresOwnExternalPipelineStage: requiresOwnExternalPipelineStage,
                            isLocallyCancelled: { stageCancellation.isCancelled },
                            writeOutput: { _ in },
                            readLine: { _, _ -> String? in nil }
                        )
                        let childEnvironment = stageEnvironment.snapshotChildProcessEnvironment()
                        let commandString = try renderer.renderExternalPipelineSegment(
                            segment,
                            inheritedEnvironment: childEnvironment
                        )
                        let inputProvider: (@Sendable () -> Data?)?
                        if let upstream {
                            inputProvider = { upstream.read(upTo: 8192) }
                        } else {
                            inputProvider = nil
                        }
                        exitCodes[index] = streamExternal(commandString, inputProvider) { chunk in
                            if let downstream {
                                if !downstream.write(chunk) {
                                    stageCancellation.cancel()
                                    return false
                                }
                            } else {
                                outerWriteOutput(chunk)
                            }
                            return true
                        }
                    }
                } catch ShellError.cancelled {
                    exitCodes[index] = stageCancellation.isCancelled ? 141 : 130
                } catch {
                    exitCodes[index] = 1
                }
            }
        }

        group.wait()

        var lastExitCode = exitCodes[stageCount - 1]
        if environment.options.pipefail, lastExitCode == 0 {
            for i in (0..<stageCount).reversed() where exitCodes[i] != 0 {
                lastExitCode = exitCodes[i]
                break
            }
        }
        environment.setLastExitCode(lastExitCode)
        return lastExitCode
    }

    private func canSerializeAsExternalStage(_ command: ShellCommand) -> Bool {
        guard case .simple(let simple) = command else { return false }
        guard !simple.words.isEmpty else { return false }
        guard simple.heredocContent == nil else { return false }
        guard simple.assignments.allSatisfy({ rawWordCanRunWithoutExternal($0.1) }) else { return false }
        guard simple.words.allSatisfy(wordCanRunWithoutExternal) else { return false }
        guard simple.redirections.allSatisfy({ $0.op != .heredocOp && $0.op != .heredocStripOp && rawWordCanRunWithoutExternal($0.target) }) else {
            return false
        }
        guard let commandName = ((try? resolvedCommandName(for: simple.words[0])) ?? nil),
              !commandName.isEmpty else {
            return false
        }
        guard ShellBuiltins.lookup(commandName) == nil else { return false }
        guard environment.getFunction(commandName) == nil else { return false }
        if let canStreamExternalCommand {
            do {
                let rendered = try renderExternalSimpleCommand(simple)
                guard canStreamExternalCommand(rendered) else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private func renderExternalPipelineSegment(
        _ commands: [ShellCommand],
        inheritedEnvironment: [String: String] = [:]
    ) throws -> String {
        try commands.map { try renderExternalSimpleCommand($0, inheritedEnvironment: inheritedEnvironment) }
            .joined(separator: " | ")
    }

    // Internal: also used by the background-job gate (ShellJobs.swift).
    func renderExternalSimpleCommand(
        _ command: ShellCommand,
        inheritedEnvironment: [String: String] = [:]
    ) throws -> String {
        guard case .simple(let simple) = command else {
            throw ShellError.unsupported("external pipeline stage")
        }
        return try renderExternalSimpleCommand(simple, inheritedEnvironment: inheritedEnvironment)
    }

    private func renderExternalSimpleCommand(
        _ cmd: SimpleCommand,
        inheritedEnvironment: [String: String] = [:]
    ) throws -> String {
        let expandedWords = try expandCommandWords(cmd.words)
        var parts: [String] = []

        for name in inheritedEnvironment.keys.sorted() {
            guard let value = inheritedEnvironment[name] else { continue }
            parts.append("\(name)=\(shellEscape(value))")
        }

        for (name, rawValue) in cmd.assignments {
            let value = try environment.expandScalarWord(
                ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: rawValue),
                interpreter: self
            )
            parts.append("\(name)=\(shellEscape(value))")
        }

        parts.append(contentsOf: expandedWords.map(shellEscape))

        for redir in cmd.redirections {
            if redir.op == .heredocOp || redir.op == .heredocStripOp { continue }
            parts.append(reconstructRedirection(redir))
        }

        return parts.joined(separator: " ")
    }

    // Internal: also used by the background-job gate (ShellJobs.swift).
    func canRunWithoutExternal(_ command: ShellCommand) -> Bool {
        canRunWithoutExternal(command, visitingFunctions: Set())
    }

    private func canRunWithoutExternal(
        _ command: ShellCommand,
        visitingFunctions: Set<String>
    ) -> Bool {
        switch command {
        case .simple(let simple):
            guard simple.assignments.allSatisfy({ rawWordCanRunWithoutExternal($0.1) }) else { return false }
            if let heredoc = simple.heredocContent, simple.heredocQuoted != true {
                guard !rawWordContainsExternalExpansion(heredoc) else { return false }
            }
            guard let firstWord = simple.words.first, wordCanRunWithoutExternal(firstWord) else {
                return simple.words.isEmpty
            }
            guard simple.words.dropFirst().allSatisfy(wordCanRunWithoutExternal) else { return false }
            guard let commandName = ((try? resolvedCommandName(for: firstWord)) ?? nil),
                  !commandName.isEmpty else {
                return false
            }
            if ShellBuiltins.lookup(commandName) != nil {
                return true
            }
            if let functionBody = environment.getFunction(commandName) {
                guard !visitingFunctions.contains(commandName) else { return false }
                return canRunWithoutExternal(functionBody, visitingFunctions: visitingFunctions.union([commandName]))
            }
            return false
        case .pipeline(let commands):
            return commands.allSatisfy { canRunWithoutExternal($0, visitingFunctions: visitingFunctions) }
        case .andOr(let left, _, let right):
            return canRunWithoutExternal(left, visitingFunctions: visitingFunctions)
                && canRunWithoutExternal(right, visitingFunctions: visitingFunctions)
        case .sequence(let commands):
            return commands.allSatisfy { canRunWithoutExternal($0, visitingFunctions: visitingFunctions) }
        case .ifCmd(let clause):
            return clause.branches.allSatisfy {
                canRunWithoutExternal($0.condition, visitingFunctions: visitingFunctions)
                    && canRunWithoutExternal($0.body, visitingFunctions: visitingFunctions)
            } && (clause.elseBranch.map { canRunWithoutExternal($0, visitingFunctions: visitingFunctions) } ?? true)
        case .forCmd(let clause):
            let wordsAreInternal = clause.wordList?.allSatisfy(wordCanRunWithoutExternal) ?? true
            return wordsAreInternal && canRunWithoutExternal(clause.body, visitingFunctions: visitingFunctions)
        case .whileCmd(let clause):
            return canRunWithoutExternal(clause.condition, visitingFunctions: visitingFunctions)
                && canRunWithoutExternal(clause.body, visitingFunctions: visitingFunctions)
        case .untilCmd(let clause):
            return canRunWithoutExternal(clause.condition, visitingFunctions: visitingFunctions)
                && canRunWithoutExternal(clause.body, visitingFunctions: visitingFunctions)
        case .caseCmd(let clause):
            return wordCanRunWithoutExternal(clause.word)
                && clause.items.allSatisfy { item in
                    item.patterns.allSatisfy(wordCanRunWithoutExternal)
                        && (item.body.map { canRunWithoutExternal($0, visitingFunctions: visitingFunctions) } ?? true)
                }
        case .functionDef(_, let body), .subshell(let body), .braceGroup(let body), .negation(let body),
             .background(let body):
            return canRunWithoutExternal(body, visitingFunctions: visitingFunctions)
        case .doubleBracket:
            return true
        }
    }

    private func rawWordCanRunWithoutExternal(_ text: String) -> Bool {
        !rawWordContainsExternalExpansion(text)
    }

    private func rawWordContainsExternalExpansion(_ text: String) -> Bool {
        text.contains("$(") || text.contains("`")
    }

    private func wordCanRunWithoutExternal(_ word: ShellWord) -> Bool {
        switch word {
        case .literal, .singleQuoted:
            return true
        case .doubleQuoted(let parts), .concat(let parts):
            return parts.allSatisfy(wordCanRunWithoutExternal)
        case .variable, .arithmetic:
            return true
        case .commandSub:
            return false
        case .paramExpansion(let expansion):
            switch expansion {
            case .simple, .length, .stripShortPrefix, .stripLongPrefix, .stripShortSuffix, .stripLongSuffix,
                 .substring, .bad:
                return true
            case .defaultValue(_, let parts, _), .assignDefault(_, let parts, _),
                 .alternative(_, let parts, _), .errorIfUnset(_, let parts, _),
                 .replace(_, _, let parts, _):
                return parts.allSatisfy(wordCanRunWithoutExternal)
            }
        }
    }

    private func staticWordText(_ word: ShellWord) -> String? {
        switch word {
        case .literal(let text), .singleQuoted(let text):
            return text
        case .doubleQuoted(let parts), .concat(let parts):
            var result = ""
            for part in parts {
                guard let text = staticWordText(part) else { return nil }
                result += text
            }
            return result
        case .variable, .paramExpansion, .commandSub, .arithmetic:
            return nil
        }
    }

    private func resolvedCommandName(for word: ShellWord) throws -> String? {
        guard wordCanRunWithoutExternal(word) else { return nil }
        let expanded = try expandCommandWords([word])
        guard let commandName = expanded.first, !commandName.isEmpty else {
            return nil
        }
        return commandName
    }

    /// Run an external command with piped stdin data and capture its stdout.
    /// Writes stdin to a temp file, redirects it into the command, and captures output.
    /// Static so it can be called from `@Sendable` closures without capturing `self`.
    private static func captureExternalWithStdin(
        _ command: String,
        stdinData: String,
        captureExternal: @Sendable (String) -> (Int32, String)
    ) -> (Int32, String) {
        let tempFile = NSTemporaryDirectory()
            + "pipe_stdin_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 0...999999))"
        do {
            try stdinData.write(toFile: tempFile, atomically: true, encoding: .utf8)
        } catch {
            return (1, "")
        }
        defer { try? FileManager.default.removeItem(atPath: tempFile) }
        // Shell-escape the temp file path to handle spaces in NSTemporaryDirectory
        let escaped = "'" + tempFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let redirectedCommand = "\(command) < \(escaped)"
        return captureExternal(redirectedCommand)
    }

    // MARK: - And/Or

    private func executeAndOr(_ left: ShellCommand, _ op: AndOrOp,
                               _ right: ShellCommand) throws -> Int32 {
        // The left arm is errexit-exempt (its failure steers the list);
        // the right arm is the list's final command and stays eligible.
        let leftCode = try withErrexitSuppressed { try execute(left) }
        switch op {
        case .and:
            if leftCode == 0 {
                return try execute(right)
            }
            return leftCode
        case .or:
            if leftCode != 0 {
                return try execute(right)
            }
            return leftCode
        }
    }

    // MARK: - Sequence

    private func executeSequence(_ commands: [ShellCommand]) throws -> Int32 {
        var lastCode: Int32 = 0
        for cmd in commands {
            lastCode = try execute(cmd)
        }
        return lastCode
    }

    // MARK: - If

    private func executeIf(_ clause: IfClause) throws -> Int32 {
        for branch in clause.branches {
            try checkCancelled()
            let condCode = try withErrexitSuppressed { try execute(branch.condition) }
            if condCode == 0 {
                return try execute(branch.body)
            }
        }
        if let elseBranch = clause.elseBranch {
            return try execute(elseBranch)
        }
        return 0
    }

    // MARK: - For

    private func executeFor(_ clause: ForClause) throws -> Int32 {
        try checkCancelled()

        let items: [String]
        if let wordList = clause.wordList {
            items = try expandForLoopWords(wordList)
        } else {
            items = environment.getAllPositionalParams()
        }

        var lastCode: Int32 = 0
        var iterationCount = 0

        for item in items {
            try checkCancelled()

            iterationCount += 1
            if iterationCount % Self.builtinCheckInterval == 0 {
                sched_yield()
            }

            environment.setVariable(clause.variable, value: item)

            do {
                lastCode = try execute(clause.body)
            } catch ShellError.breakSignal(let levels) {
                if levels > 1 { throw ShellError.breakSignal(levels - 1) }
                break
            } catch ShellError.continueSignal(let levels) {
                if levels > 1 { throw ShellError.continueSignal(levels - 1) }
                continue
            }
        }

        environment.setLastExitCode(lastCode)
        return lastCode
    }

    // MARK: - While

    private func executeWhile(_ clause: WhileClause) throws -> Int32 {
        var lastCode: Int32 = 0
        var iterationCount = 0

        while true {
            try checkCancelled()

            iterationCount += 1
            if iterationCount % Self.builtinCheckInterval == 0 {
                sched_yield()
            }

            let condCode = try withErrexitSuppressed { try execute(clause.condition) }
            if condCode != 0 { break }

            do {
                lastCode = try execute(clause.body)
            } catch ShellError.breakSignal(let levels) {
                if levels > 1 { throw ShellError.breakSignal(levels - 1) }
                break
            } catch ShellError.continueSignal(let levels) {
                if levels > 1 { throw ShellError.continueSignal(levels - 1) }
                continue
            }
        }

        environment.setLastExitCode(lastCode)
        return lastCode
    }

    // MARK: - Until

    private func executeUntil(_ clause: UntilClause) throws -> Int32 {
        var lastCode: Int32 = 0
        var iterationCount = 0

        while true {
            try checkCancelled()

            iterationCount += 1
            if iterationCount % Self.builtinCheckInterval == 0 {
                sched_yield()
            }

            let condCode = try withErrexitSuppressed { try execute(clause.condition) }
            if condCode == 0 { break } // until: exit when condition succeeds

            do {
                lastCode = try execute(clause.body)
            } catch ShellError.breakSignal(let levels) {
                if levels > 1 { throw ShellError.breakSignal(levels - 1) }
                break
            } catch ShellError.continueSignal(let levels) {
                if levels > 1 { throw ShellError.continueSignal(levels - 1) }
                continue
            }
        }

        environment.setLastExitCode(lastCode)
        return lastCode
    }

    // MARK: - Case

    private func executeCase(_ clause: CaseClause) throws -> Int32 {
        try checkCancelled()

        let word = try environment.expandScalarWord(clause.word, interpreter: self)

        for item in clause.items {
            for pattern in item.patterns {
                let pat = try environment.expandScalarWord(pattern, interpreter: self)
                if shellGlobMatch(word, pattern: pat) {
                    if let body = item.body {
                        let code = try execute(body)
                        environment.setLastExitCode(code)
                        return code
                    }
                    environment.setLastExitCode(0)
                    return 0
                }
            }
        }

        environment.setLastExitCode(0)
        return 0
    }

    // MARK: - Function Execution

    func executeFunction(_ name: String, args: [String], body: ShellCommand) throws -> Int32 {
        // Save and set positional parameters
        let savedParams = environment.getAllPositionalParams()
        let savedName = environment.getScriptName()
        environment.setPositionalParams(args, scriptName: name)

        // Push scope for local variables
        environment.pushScope()

        let exitCode: Int32
        do {
            exitCode = try execute(body)
        } catch ShellError.returnSignal(let code) {
            environment.popScope()
            environment.setPositionalParams(savedParams, scriptName: savedName)
            environment.setLastExitCode(code)
            return code
        } catch {
            environment.popScope()
            environment.setPositionalParams(savedParams, scriptName: savedName)
            throw error
        }

        environment.popScope()
        environment.setPositionalParams(savedParams, scriptName: savedName)
        environment.setLastExitCode(exitCode)
        return exitCode
    }

    // MARK: - Brace Expansion

    /// Expand brace expressions: `{1..10}`, `{a..z}`, `{a,b,c}`.
    /// Returns the original string in a single-element array if no expansion applies.
    ///
    /// Bounded: total emitted items are capped by `maxBraceExpansionCount` and
    /// recursion depth by `maxBraceRecursionDepth`. Cancellation is checked at
    /// every recursive step so a runaway expansion can be interrupted.
    private func expandBraces(_ s: String) throws -> [String] {
        var produced = 0
        return try expandBracesRecursive(s, depth: 0, produced: &produced)
    }

    private func expandBracesRecursive(
        _ s: String,
        depth: Int,
        produced: inout Int
    ) throws -> [String] {
        try checkCancelled()
        if depth > Self.maxBraceRecursionDepth {
            throw ShellError.unsupported(
                "brace expansion nested too deeply (max \(Self.maxBraceRecursionDepth))"
            )
        }

        // Find outermost { ... }
        guard let openIdx = s.firstIndex(of: "{"),
              let closeIdx = s[s.index(after: openIdx)...].lastIndex(of: "}") else {
            try noteBraceLeaf(produced: &produced)
            return [s]
        }

        let prefix = String(s[s.startIndex..<openIdx])
        let suffix = String(s[s.index(after: closeIdx)...])
        let inner = String(s[s.index(after: openIdx)..<closeIdx])

        // Range expansion: {N..M} or {N..M..STEP}
        if inner.contains("..") {
            let parts = inner.split(separator: ".", omittingEmptySubsequences: false)
                .filter { !$0.isEmpty }

            // Integer range: {1..10} or {1..10..2}
            if parts.count >= 2, let start = Int(parts[0]), let end = Int(parts[1]) {
                // Derive a positive step without trapping. `abs(Int.min)`
                // overflows, so reject `Int.min` (and zero) explicitly.
                let step: Int
                if parts.count >= 3 {
                    guard let rawStep = Int(parts[2]), rawStep != 0, rawStep != .min else {
                        // Treat the malformed range as a literal — but still
                        // account for it so it cannot bypass the cap when
                        // wrapped in a larger expansion (e.g.
                        // `{{1..2..0},{1..2..0},...}`).
                        try noteBraceLeaf(produced: &produced)
                        return [s]
                    }
                    step = rawStep < 0 ? -rawStep : rawStep
                } else {
                    step = 1
                }

                // Compute |end - start| as UInt64 without overflowing signed
                // math: `Int.max - Int.min` does not fit in Int64. Convert
                // each endpoint to its UInt64 bit pattern and use wrap-around
                // subtraction, which yields the correct unsigned distance.
                let lo = UInt64(bitPattern: Int64(min(start, end)))
                let hi = UInt64(bitPattern: Int64(max(start, end)))
                let span = hi &- lo
                let chunks = span / UInt64(step)
                // The actual range count is `chunks + 1`. Compare via
                // `chunks >= cap` so the `+ 1` cannot overflow on extreme
                // inputs like `{Int.min..Int.max}` (where chunks == UInt64.max).
                if chunks >= UInt64(Self.maxBraceExpansionCount) {
                    throw ShellError.unsupported(
                        "brace expansion exceeded \(Self.maxBraceExpansionCount) items"
                    )
                }
                let chunkCount = Int(chunks) + 1

                var result: [String] = []
                result.reserveCapacity(chunkCount)
                let ascending = start <= end
                var i = start
                for _ in 0..<chunkCount {
                    try checkCancelled()
                    let sub = try expandBracesRecursive(
                        prefix + String(i) + suffix,
                        depth: depth + 1,
                        produced: &produced
                    )
                    result.append(contentsOf: sub)
                    // Use wrap-around so the final, unused increment cannot
                    // trap when `i` sits at an Int extremum (e.g. end == Int.max).
                    if ascending {
                        i = i &+ step
                    } else {
                        i = i &- step
                    }
                }
                if result.isEmpty {
                    try noteBraceLeaf(produced: &produced)
                    return [s]
                }
                return result
            }

            // Character range: {a..z}
            if parts.count == 2,
               parts[0].count == 1, parts[1].count == 1,
               let startVal = parts[0].first?.asciiValue,
               let endVal = parts[1].first?.asciiValue {
                let count = (startVal <= endVal)
                    ? Int(endVal - startVal) + 1
                    : Int(startVal - endVal) + 1
                if count > Self.maxBraceExpansionCount {
                    throw ShellError.unsupported(
                        "brace expansion exceeded \(Self.maxBraceExpansionCount) items"
                    )
                }

                var result: [String] = []
                result.reserveCapacity(count)
                let values: [UInt8] = (startVal <= endVal)
                    ? Array(startVal...endVal)
                    : Array(stride(from: startVal, through: endVal, by: -1))
                for v in values {
                    try checkCancelled()
                    let sub = try expandBracesRecursive(
                        prefix + String(Character(UnicodeScalar(v))) + suffix,
                        depth: depth + 1,
                        produced: &produced
                    )
                    result.append(contentsOf: sub)
                }
                if result.isEmpty {
                    try noteBraceLeaf(produced: &produced)
                    return [s]
                }
                return result
            }
        }

        // Comma expansion: {a,b,c}
        if inner.contains(",") {
            // Pre-count commas before `split` allocates a Substring array.
            // Without this, `{a,a,a,...}` with millions of commas would
            // allocate a giant array up-front, before any leaf check fires.
            var commaCount = 0
            for byte in inner.utf8 where byte == 0x2C {
                commaCount += 1
                if commaCount >= Self.maxBraceExpansionCount {
                    throw ShellError.unsupported(
                        "brace expansion exceeded \(Self.maxBraceExpansionCount) items"
                    )
                }
            }

            let alternatives = inner.split(separator: ",", omittingEmptySubsequences: false)
            var result: [String] = []
            // `reserveCapacity` is now naturally bounded by the comma cap
            // above; clamp defensively in case the bound ever changes.
            result.reserveCapacity(min(alternatives.count, Self.maxBraceExpansionCount))
            for alt in alternatives {
                try checkCancelled()
                let sub = try expandBracesRecursive(
                    prefix + String(alt) + suffix,
                    depth: depth + 1,
                    produced: &produced
                )
                result.append(contentsOf: sub)
            }
            if result.isEmpty {
                try noteBraceLeaf(produced: &produced)
                return [s]
            }
            return result
        }

        // No expansion applied — count as a single leaf.
        try noteBraceLeaf(produced: &produced)
        return [s]
    }

    private func noteBraceLeaf(produced: inout Int) throws {
        produced += 1
        if produced > Self.maxBraceExpansionCount {
            throw ShellError.unsupported(
                "brace expansion exceeded \(Self.maxBraceExpansionCount) items"
            )
        }
    }

    // MARK: - Glob Expansion

    private func expandGlob(_ pattern: String) -> [String] {
        // Use POSIX glob for file expansion
        var gt = glob_t()
        let flags = GLOB_TILDE | GLOB_MARK
        let result = glob(pattern, flags, nil, &gt)

        defer { globfree(&gt) }

        guard result == 0 else { return [] }

        var matches: [String] = []
        for i in 0..<gt.gl_matchc {
            if let path = gt.gl_pathv[Int(i)] {
                matches.append(String(cString: path))
            }
        }
        return matches
    }

    // MARK: - Shell Glob Pattern Matching

    /// Match a string against a shell glob pattern (*, ?, [...]).
    func shellGlobMatch(_ string: String, pattern: String) -> Bool {
        ShellGlob.match(string, pattern: pattern)
    }

    // MARK: - Here-document Expansion

    /// Expand variables, command substitutions, and arithmetic in unquoted here-doc content.
    /// Each line is processed through the shell word parser for `$VAR`, `${...}`,
    /// `$(cmd)`, `$((expr))`, and backtick expansions.
    ///
    /// Before expansion, heredoc-specific backslash escapes are processed:
    /// `\$` → literal `$`, `` \` `` → literal `` ` ``, `\\` → literal `\`.
    /// These are replaced with PUA placeholders so `parseShellWord` doesn't
    /// interpret them, then restored after expansion.
    private func expandHeredocContent(_ content: String) throws -> String {
        let parser = ShellParser(tokenizer: ShellTokenizer(source: ""))
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var expanded: [String] = []
        for line in lines {
            let processed = preprocessHeredocEscapes(String(line))
            let word = parser.parseShellWord(from: processed)
            let expandedLine = try environment.expandScalarWord(word, interpreter: self)
            let final = postprocessHeredocEscapes(expandedLine)
            expanded.append(final)
        }
        return expanded.joined(separator: "\n")
    }

    /// Replace heredoc-specific backslash escapes with Unicode PUA placeholders
    /// so that `parseShellWord` does not interpret them as shell syntax.
    private func preprocessHeredocEscapes(_ line: String) -> String {
        var result = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "\\" && line.index(after: i) < line.endIndex {
                let next = line[line.index(after: i)]
                switch next {
                case "$":
                    result.append("\u{E010}") // placeholder for literal $
                    i = line.index(i, offsetBy: 2)
                case "`":
                    result.append("\u{E011}") // placeholder for literal `
                    i = line.index(i, offsetBy: 2)
                case "\\":
                    result.append("\u{E012}") // placeholder for literal \
                    i = line.index(i, offsetBy: 2)
                default:
                    result.append(line[i])
                    i = line.index(after: i)
                }
            } else {
                result.append(line[i])
                i = line.index(after: i)
            }
        }
        return result
    }

    /// Restore PUA placeholders back to their original literal characters.
    private func postprocessHeredocEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{E010}", with: "$")
            .replacingOccurrences(of: "\u{E011}", with: "`")
            .replacingOccurrences(of: "\u{E012}", with: "\\")
    }

    // MARK: - Helpers

    /// Escape a string for safe inclusion in a command passed to ios_system.
    private func shellEscape(_ s: String) -> String {
        // If the string contains no special characters, return as-is
        let specials = CharacterSet(charactersIn: " \t\n\"'\\|&;<>()$`!{}*?[]#~")
        if s.unicodeScalars.allSatisfy({ !specials.contains($0) }) {
            return s
        }
        // For name=value words where name is a valid identifier, only quote the
        // value part. ios_system's alias parser requires '=' to appear outside
        // quotes — wrapping the whole string as 'name=value' breaks alias
        // definitions because ios_system replaces '=' with space before unquoting.
        if let eqIdx = s.firstIndex(of: "=") {
            let name = String(s[s.startIndex..<eqIdx])
            let value = String(s[s.index(after: eqIdx)...])
            if isValidShellIdentifier(name) {
                let escapedValue = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
                return name + "=" + escapedValue
            }
        }
        // Wrap in single quotes, escaping any internal single quotes
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Check if a string is a valid POSIX shell identifier (letters, digits, underscores;
    /// must start with letter or underscore).
    private func isValidShellIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        guard first == "_" || (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") else {
            return false
        }
        return s.unicodeScalars.dropFirst().allSatisfy { c in
            c == "_" || (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
        }
    }

    /// Reconstruct a redirection for inclusion in a command string.
    /// The target is expanded through `parseShellWord` so that `> "$file"` and
    /// `> $dir/out.txt` resolve variable references correctly while preserving
    /// quoting semantics.
    private func reconstructRedirection(_ redir: Redirection) -> String {
        let fdPrefix: String
        if let fd = redir.fd {
            fdPrefix = String(fd)
        } else {
            fdPrefix = ""
        }

        // Expand the target through the shell word parser so that $VAR, ${VAR},
        // and quoted strings in redirect targets are handled correctly.
        let expandedTarget: String
        do {
            let word = ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: redir.target)
            expandedTarget = try environment.expandScalarWord(word, interpreter: self)
        } catch {
            expandedTarget = redir.target
        }
        let escaped = shellEscape(expandedTarget)

        switch redir.op {
        case .inputFrom:       return "\(fdPrefix)< \(escaped)"
        case .outputTo:        return "\(fdPrefix)> \(escaped)"
        case .appendTo:        return "\(fdPrefix)>> \(escaped)"
        case .errorTo:         return "2> \(escaped)"
        case .errorAppendTo:   return "2>> \(escaped)"
        case .duplicateOutput: return "\(fdPrefix)>&\(expandedTarget)"
        case .duplicateInput:  return "\(fdPrefix)<&\(expandedTarget)"
        case .mergeStderrStdout: return "2>&1"
        case .heredocOp:       return "<<\(redir.target)"
        case .heredocStripOp:  return "<<-\(redir.target)"
        }
    }

    /// Check whether a `ShellWord` contains any quoted regions (single or double).
    /// Words with quoted parts must not undergo glob expansion.
    private func wordContainsQuotedParts(_ word: ShellWord) -> Bool {
        switch word {
        case .singleQuoted:
            return true
        case .doubleQuoted:
            return true
        case .concat(let parts):
            return parts.contains { wordContainsQuotedParts($0) }
        case .literal, .variable, .paramExpansion, .commandSub, .arithmetic:
            return false
        }
    }

    /// Command substitution should see logical shell newlines rather than the
    /// CRLF-expanded stream format used for terminal rendering.
    private func normalizeCommandSubstitutionOutput(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Apply shell field splitting for an unquoted expansion using IFS.
    ///
    /// This is intentionally scoped to the common POSIX behavior we need for
    /// script execution: the default IFS of space/tab/newline collapses runs of
    /// whitespace and trims leading/trailing separators, which lets unquoted
    /// command substitutions expand into multiple loop items and arguments.
    private func splitFields(_ text: String) -> [String] {
        let ifs = environment.getVariable("IFS") ?? " \t\n"
        guard !ifs.isEmpty, !text.isEmpty else { return ifs.isEmpty ? [text] : [] }

        let whitespaceDelimiters = Set(ifs.filter { $0 == " " || $0 == "\t" || $0 == "\n" })
        let otherDelimiters = Set(ifs.filter { !whitespaceDelimiters.contains($0) })

        if otherDelimiters.isEmpty {
            return text.split(whereSeparator: { whitespaceDelimiters.contains($0) }).map(String.init)
        }

        var fields: [String] = []
        var current = ""
        var index = text.startIndex

        while index < text.endIndex, whitespaceDelimiters.contains(text[index]) {
            index = text.index(after: index)
        }

        while index < text.endIndex {
            let character = text[index]

            if whitespaceDelimiters.contains(character) {
                if !current.isEmpty {
                    fields.append(current)
                    current = ""
                }
                repeat {
                    index = text.index(after: index)
                } while index < text.endIndex && whitespaceDelimiters.contains(text[index])
                continue
            }

            if otherDelimiters.contains(character) {
                fields.append(current)
                current = ""
                index = text.index(after: index)
                while index < text.endIndex && whitespaceDelimiters.contains(text[index]) {
                    index = text.index(after: index)
                }
                continue
            }

            current.append(character)
            index = text.index(after: index)
        }

        if !current.isEmpty {
            fields.append(current)
        }

        return fields
    }

    /// Split an expanded word into fields, honoring `$@` sentinels.
    /// Field separators break fields even inside quoted words (that's the
    /// whole point of `"$@"`); the empty-`$@` marker deletes a field that
    /// consisted of nothing else, and vanishes from mixed content.
    private func splitExpandedWord(_ expanded: String, isQuoted: Bool) -> [String] {
        guard expanded.contains(ShellTokenizer.fieldSeparator)
                || expanded.contains(ShellTokenizer.emptyAtMarker) else {
            return isQuoted ? [expanded] : splitFields(expanded)
        }

        var fields: [String] = []
        let segments = expanded.split(separator: ShellTokenizer.fieldSeparator,
                                      omittingEmptySubsequences: false)
        for segment in segments {
            // A segment that is nothing but empty-$@ markers vanishes:
            // `"$@"` with zero params yields zero fields, not one empty one.
            if !segment.isEmpty && segment.allSatisfy({ $0 == ShellTokenizer.emptyAtMarker }) {
                continue
            }
            let cleaned = String(segment).replacingOccurrences(
                of: String(ShellTokenizer.emptyAtMarker), with: "")
            if isQuoted {
                fields.append(cleaned)
            } else {
                fields.append(contentsOf: splitFields(cleaned))
            }
        }
        return fields
    }

    private func splitForLoopLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func bareCommandSubstitutionText(in word: ShellWord) -> String? {
        switch word {
        case .commandSub(let command):
            return command
        case .concat(let parts) where parts.count == 1:
            return bareCommandSubstitutionText(in: parts[0])
        default:
            return nil
        }
    }

    private func expandPathnamePatterns(_ fields: [String], quoted: Bool) -> [String] {
        var expandedWords: [String] = []
        for field in fields {
            if !quoted,
               field.contains("*") || field.contains("?") || field.contains("[") {
                let globbed = expandGlob(field)
                if !globbed.isEmpty {
                    expandedWords.append(contentsOf: globbed)
                    continue
                }
            }
            expandedWords.append(field)
        }
        return expandedWords
    }

    private func expandForLoopWords(_ words: [ShellWord]) throws -> [String] {
        var expandedWords: [String] = []

        for word in words {
            let isQuoted = wordContainsQuotedParts(word)

            if !isQuoted,
               environment.getVariable("IFS") == nil,
               bareCommandSubstitutionText(in: word) != nil {
                let expanded = try environment.expandWord(word, interpreter: self)
                let fields = splitForLoopLines(expanded)
                expandedWords.append(
                    contentsOf: try expandPathnamePatterns(fields, quoted: false).flatMap(expandBraces)
                )
                continue
            }

            let expanded = try environment.expandWord(word, interpreter: self)
            let fields = splitExpandedWord(expanded, isQuoted: isQuoted)
            expandedWords.append(
                contentsOf: try expandPathnamePatterns(fields, quoted: isQuoted).flatMap(expandBraces)
            )
        }

        return expandedWords
    }

    private func expandCommandWords(_ words: [ShellWord]) throws -> [String] {
        var expandedWords: [String] = []
        for word in words {
            let expanded = try environment.expandWord(word, interpreter: self)
            let isQuoted = wordContainsQuotedParts(word)
            let fields = splitExpandedWord(expanded, isQuoted: isQuoted)
            // Brace expansion applies to unquoted words only (same rule as
            // for-loop words) so quoted literals like `rg 'x{2,3}'` survive.
            if isQuoted {
                expandedWords.append(contentsOf: expandPathnamePatterns(fields, quoted: true))
            } else {
                let braced = try fields.flatMap(expandBraces)
                expandedWords.append(contentsOf: expandPathnamePatterns(braced, quoted: false))
            }
        }
        return expandedWords
    }
}

// MARK: - Blocking Pipe Buffer

/// Thread-safe bounded buffer connecting pipeline stages, mimicking Unix pipes.
///
/// Provides backpressure (writer blocks when full) and EOF/SIGPIPE signaling
/// (reader gets nil at EOF, writer gets false when read end is closed).
/// Uses polling with short timeouts to support `CancellationToken` interrupts.
private nonisolated final class BlockingPipeBuffer: @unchecked Sendable {
    private let lock = UnfairLock()
    private var buffer = Data()
    private let capacity: Int
    private var writeClosed = false
    private var readClosed = false
    private let cancellationToken: CancellationToken

    /// Semaphores for blocking coordination. Signaled under lock changes,
    /// waited on with short timeouts for cancellation responsiveness.
    private let dataAvailable = DispatchSemaphore(value: 0)
    private let spaceAvailable = DispatchSemaphore(value: 0)

    init(capacity: Int = 65_536, cancellationToken: CancellationToken) {
        self.capacity = capacity
        self.cancellationToken = cancellationToken
    }

    /// Write data to the buffer. Blocks if buffer is full.
    /// Returns `false` if the read end was closed (SIGPIPE) or cancelled.
    func write(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        var offset = 0
        while offset < data.count {
            if cancellationToken.isCancelled { return false }

            let accepted: Int = lock.withLock {
                if readClosed { return -1 }
                let available = capacity - buffer.count
                if available <= 0 { return 0 }
                let chunk = min(available, data.count - offset)
                buffer.append(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: offset + chunk)])
                return chunk
            }

            if accepted == -1 { return false } // read end closed
            if accepted > 0 {
                offset += accepted
                dataAvailable.signal()
            } else {
                // Buffer full — wait for space
                _ = spaceAvailable.wait(timeout: .now() + .milliseconds(10))
            }
        }
        return true
    }

    /// Read up to `maxBytes` from the buffer. Blocks when empty.
    /// Returns `nil` at EOF (write end closed and buffer drained) or on cancellation.
    func read(upTo maxBytes: Int) -> Data? {
        while true {
            if cancellationToken.isCancelled { return nil }

            let result: Data? = lock.withLock {
                if !buffer.isEmpty {
                    let count = min(maxBytes, buffer.count)
                    let chunk = buffer.prefix(count)
                    buffer.removeFirst(count)
                    return Data(chunk)
                }
                if writeClosed { return nil }
                return Data() // sentinel: empty but not nil = keep waiting
            }

            if let data = result {
                if data.isEmpty {
                    // Buffer empty, writer still open — wait for data
                    _ = dataAvailable.wait(timeout: .now() + .milliseconds(10))
                    continue
                }
                spaceAvailable.signal()
                return data
            }
            return nil // EOF
        }
    }

    /// Consume one line (up to `\n`) from the buffer. Blocks if needed.
    /// Returns `nil` at EOF or on cancellation.
    func readLine() -> String? {
        var accumulated = Data()
        while true {
            if cancellationToken.isCancelled { return nil }

            let result: ReadLineResult = lock.withLock {
                if let nlIdx = buffer.firstIndex(of: 0x0A) {
                    // Found newline — consume up to and including it
                    let lineData = buffer[buffer.startIndex..<nlIdx]
                    buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: buffer.index(after: nlIdx)))
                    return .line(Data(lineData))
                }
                if writeClosed {
                    // No newline, writer done — return remaining buffer
                    if buffer.isEmpty && accumulated.isEmpty { return .eof }
                    let remaining = buffer
                    buffer = Data()
                    return .line(remaining)
                }
                // No newline yet, writer still open — drain buffer and wait
                if !buffer.isEmpty {
                    let partial = buffer
                    buffer = Data()
                    return .partial(partial)
                }
                return .wait
            }

            switch result {
            case .eof:
                return nil
            case .line(let data):
                spaceAvailable.signal()
                accumulated.append(data)
                return String(data: accumulated, encoding: .utf8) ?? ""
            case .partial(let data):
                spaceAvailable.signal()
                accumulated.append(data)
                // Continue reading for the newline
            case .wait:
                _ = dataAvailable.wait(timeout: .now() + .milliseconds(10))
            }
        }
    }

    /// Signal EOF to readers. Called when the upstream stage finishes.
    func closeWrite() {
        lock.withLock { writeClosed = true }
        dataAvailable.signal()
    }

    /// Signal SIGPIPE to writers. Called when the downstream stage finishes.
    func closeRead() {
        lock.withLock { readClosed = true }
        spaceAvailable.signal()
    }

    /// Internal result type for readLine state machine.
    private enum ReadLineResult {
        case eof
        case line(Data)
        case partial(Data)
        case wait
    }
}

// MARK: - Trap Registry

/// Manages trap handlers registered by the `trap` builtin.
nonisolated final class TrapRegistry: @unchecked Sendable {
    enum Signal: Hashable, Sendable {
        case int     // SIGINT (CTRL-C)
        case exit    // Script exit
        case err     // Command failure (non-zero exit)
    }

    private let lock = UnfairLock()
    private var handlers: [Signal: ShellCommand] = [:]

    func register(signal: Signal, action: ShellCommand?) {
        lock.withLock {
            if let action {
                handlers[signal] = action
            } else {
                handlers.removeValue(forKey: signal)
            }
        }
    }

    func getHandler(for signal: Signal) -> ShellCommand? {
        lock.withLock { handlers[signal] }
    }

    static func parseSignal(_ name: String) -> Signal? {
        switch name.uppercased() {
        case "INT", "SIGINT", "2":  return .int
        case "EXIT", "0":          return .exit
        case "ERR":                return .err
        default:                   return nil
        }
    }

    /// Snapshot all trap handlers for later restoration (subshell/command substitution isolation).
    func snapshot() -> [Signal: ShellCommand] {
        lock.withLock { handlers }
    }

    /// Restore trap handlers from a previous snapshot.
    func restore(_ snapshot: [Signal: ShellCommand]) {
        lock.withLock { handlers = snapshot }
    }
}

// MARK: - Output Throttle

/// Tracks output volume and signals when the interpreter should yield.
nonisolated final class OutputThrottle: @unchecked Sendable {
    private let lock = UnfairLock()
    private var bytesInWindow: Int = 0
    private var windowStart: UInt64 = 0
    private let windowNanos: UInt64 = 100_000_000  // 100ms
    private let byteLimit: Int = 65_536            // 64KB per window

    /// Record output bytes. Returns true if the interpreter should yield.
    nonisolated func recordOutput(bytes: Int) -> Bool {
        lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            if windowStart == 0 || (now - windowStart) > windowNanos {
                bytesInWindow = bytes
                windowStart = now
                return false
            }
            bytesInWindow += bytes
            return bytesInWindow > byteLimit
        }
    }

    nonisolated func reset() {
        lock.withLock {
            bytesInWindow = 0
            windowStart = 0
        }
    }
}

// MARK: - Arithmetic Evaluator

/// Full recursive-descent arithmetic evaluator supporting C-like operators
/// with correct precedence, variable references, assignment, and integer literals.
nonisolated enum ShellArithmeticEvaluator {
    static func evaluate(_ expr: String, environment: ShellEnvironment) throws -> Int64 {
        var parser = ArithParser(expr: expr, environment: environment)
        let result = try parser.parseComma()
        parser.skipWS()
        if parser.peek() != nil {
            let remaining = String(parser.chars[parser.pos...])
            throw ShellError.arithmeticError("unexpected character in arithmetic expression: \(remaining)")
        }
        return result
    }

    // MARK: - Recursive-Descent Parser

    private struct ArithParser {
        let chars: [Character]
        var pos: Int = 0
        let environment: ShellEnvironment
        /// When true, parse syntax but don't evaluate side effects (variable
        /// lookups return 0 and assignments are no-ops). Used for short-circuit
        /// evaluation of `||`, `&&`, and ternary `?:` operators.
        var skipEval = false

        init(expr: String, environment: ShellEnvironment) {
            self.chars = Array(expr)
            self.environment = environment
        }

        // MARK: Helpers

        mutating func skipWS() {
            while pos < chars.count, chars[pos].isWhitespace {
                pos += 1
            }
        }

        func peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }

        /// Peek at the character at offset `n` ahead of the current position.
        func peekAt(_ n: Int) -> Character? {
            let idx = pos + n
            return idx < chars.count ? chars[idx] : nil
        }

        @discardableResult
        mutating func advance() -> Character? {
            guard pos < chars.count else { return nil }
            let ch = chars[pos]
            pos += 1
            return ch
        }

        /// Check if the upcoming characters match `s` and consume them.
        mutating func match(_ s: String) -> Bool {
            let sChars = Array(s)
            guard pos + sChars.count <= chars.count else { return false }
            for i in 0..<sChars.count {
                if chars[pos + i] != sChars[i] { return false }
            }
            pos += sChars.count
            return true
        }

        /// Try to read an identifier (variable name) at the current position.
        /// Returns nil if the current character is not a valid identifier start.
        mutating func readIdentifier() -> String? {
            skipWS()
            guard let ch = peek(), ch == "_" || ch.isLetter else { return nil }
            let start = pos
            while pos < chars.count {
                let c = chars[pos]
                if c == "_" || c.isLetter || c.isNumber {
                    pos += 1
                } else {
                    break
                }
            }
            return String(chars[start..<pos])
        }

        /// For `++$i` / `++i` targets: skip an optional `$` then read the name.
        mutating func readIdentifierAfterOptionalDollar() -> String? {
            skipWS()
            if peek() == "$" { advance() }
            return readIdentifier()
        }

        // MARK: Number Parsing

        mutating func parseNumber() throws -> Int64 {
            skipWS()
            guard let ch = peek() else {
                throw ShellError.arithmeticError("expected number")
            }
            if ch == "0" {
                // Could be hex (0x), octal (0...), or just 0
                if peekAt(1) == "x" || peekAt(1) == "X" {
                    // Hex
                    pos += 2
                    let start = pos
                    while pos < chars.count, chars[pos].isHexDigit {
                        pos += 1
                    }
                    if pos == start {
                        throw ShellError.arithmeticError("invalid hex literal")
                    }
                    let hexStr = String(chars[start..<pos])
                    guard let val = Int64(hexStr, radix: 16) else {
                        throw ShellError.arithmeticError("invalid hex literal: 0x\(hexStr)")
                    }
                    return val
                } else if let next = peekAt(1), next >= "0", next <= "7" {
                    // Octal
                    pos += 1
                    let start = pos
                    while pos < chars.count, chars[pos] >= "0", chars[pos] <= "7" {
                        pos += 1
                    }
                    let octStr = String(chars[start..<pos])
                    guard let val = Int64(octStr, radix: 8) else {
                        throw ShellError.arithmeticError("invalid octal literal: 0\(octStr)")
                    }
                    return val
                } else {
                    // Just 0
                    pos += 1
                    return 0
                }
            }
            // Decimal
            let start = pos
            while pos < chars.count, chars[pos].isNumber {
                pos += 1
            }
            if pos == start {
                throw ShellError.arithmeticError("expected number near '\(ch)'")
            }
            let numStr = String(chars[start..<pos])
            guard let val = Int64(numStr) else {
                throw ShellError.arithmeticError("invalid number: \(numStr)")
            }
            return val
        }

        // MARK: Precedence Levels (lowest to highest)

        /// Comma: `expr, expr` — evaluates both, returns last.
        mutating func parseComma() throws -> Int64 {
            var result = try parseAssignment()
            while true {
                skipWS()
                guard peek() == "," else { break }
                advance()
                result = try parseAssignment()
            }
            return result
        }

        /// Assignment: `name = expr`, `name += expr`, etc.
        /// Assignment is right-associative.
        mutating func parseAssignment() throws -> Int64 {
            skipWS()
            let savedPos = pos

            // Try to read an identifier for potential assignment
            if let name = readIdentifier() {
                skipWS()

                // Check for compound assignment operators (longer ones first to avoid
                // prefix conflicts, e.g. `<<=` must be checked before `<=`).
                let assignOps: [(String, ((Int64, Int64) -> Int64)?)] = [
                    ("<<=", { $0 << $1 }),
                    (">>=", { $0 >> $1 }),
                    ("+=", { $0 + $1 }),
                    ("-=", { $0 - $1 }),
                    ("*=", { $0 * $1 }),
                    ("/=", nil),  // special: division by zero check
                    ("%=", nil),  // special: division by zero check
                    ("&=", { $0 & $1 }),
                    ("|=", { $0 | $1 }),
                    ("^=", { $0 ^ $1 }),
                ]

                for (opStr, opFunc) in assignOps {
                    let beforeOp = pos
                    if match(opStr) {
                        let rhs = try parseAssignment()
                        if skipEval { return 0 }
                        let currentVal = resolveVariable(name)
                        let newVal: Int64
                        if let op = opFunc {
                            newVal = op(currentVal, rhs)
                        } else if opStr == "/=" {
                            guard rhs != 0 else { throw ShellError.divisionByZero }
                            newVal = currentVal / rhs
                        } else {
                            // %=
                            guard rhs != 0 else { throw ShellError.divisionByZero }
                            newVal = currentVal % rhs
                        }
                        environment.setVariable(name, value: String(newVal))
                        return newVal
                    }
                    pos = beforeOp
                }

                // Plain assignment: `name = expr` but NOT `name == expr`
                if peek() == "=", peekAt(1) != "=" {
                    advance() // consume '='
                    let rhs = try parseAssignment()
                    if !skipEval {
                        environment.setVariable(name, value: String(rhs))
                    }
                    return skipEval ? 0 : rhs
                }

                // Not an assignment — backtrack
                pos = savedPos
            } else {
                pos = savedPos
            }

            return try parseTernary()
        }

        /// Ternary: `cond ? true_expr : false_expr`
        mutating func parseTernary() throws -> Int64 {
            var result = try parseLogicalOr()
            skipWS()
            if peek() == "?" {
                advance()
                if result != 0 {
                    // Condition true: evaluate true branch, skip false branch
                    let trueVal = try parseAssignment()
                    skipWS()
                    guard peek() == ":" else {
                        throw ShellError.arithmeticError("expected ':' in ternary expression")
                    }
                    advance()
                    let savedSkip = skipEval
                    skipEval = true
                    _ = try parseAssignment()
                    skipEval = savedSkip
                    result = trueVal
                } else {
                    // Condition false: skip true branch, evaluate false branch
                    let savedSkip = skipEval
                    skipEval = true
                    _ = try parseAssignment()
                    skipEval = savedSkip
                    skipWS()
                    guard peek() == ":" else {
                        throw ShellError.arithmeticError("expected ':' in ternary expression")
                    }
                    advance()
                    result = try parseAssignment()
                }
            }
            return result
        }

        /// Logical OR: `a || b` with short-circuit evaluation.
        mutating func parseLogicalOr() throws -> Int64 {
            var result = try parseLogicalAnd()
            while true {
                skipWS()
                let saved = pos
                if match("||") {
                    if result != 0 {
                        // Short-circuit: left is truthy, skip right operand
                        let savedSkip = skipEval
                        skipEval = true
                        _ = try parseLogicalAnd()
                        skipEval = savedSkip
                        // result stays 1 (truthy)
                        result = 1
                    } else {
                        let rhs = try parseLogicalAnd()
                        result = (rhs != 0) ? 1 : 0
                    }
                } else {
                    pos = saved
                    break
                }
            }
            return result
        }

        /// Logical AND: `a && b` with short-circuit evaluation.
        mutating func parseLogicalAnd() throws -> Int64 {
            var result = try parseBitwiseOr()
            while true {
                skipWS()
                let saved = pos
                if match("&&") {
                    if result == 0 {
                        // Short-circuit: left is falsy, skip right operand
                        let savedSkip = skipEval
                        skipEval = true
                        _ = try parseBitwiseOr()
                        skipEval = savedSkip
                        // result stays 0 (falsy)
                    } else {
                        let rhs = try parseBitwiseOr()
                        result = (rhs != 0) ? 1 : 0
                    }
                } else {
                    pos = saved
                    break
                }
            }
            return result
        }

        /// Bitwise OR: `a | b` (but not `||` or `|=`)
        mutating func parseBitwiseOr() throws -> Int64 {
            var result = try parseBitwiseXor()
            while true {
                skipWS()
                if peek() == "|", peekAt(1) != "|", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseBitwiseXor()
                    result = result | rhs
                } else {
                    break
                }
            }
            return result
        }

        /// Bitwise XOR: `a ^ b` (but not `^=`)
        mutating func parseBitwiseXor() throws -> Int64 {
            var result = try parseBitwiseAnd()
            while true {
                skipWS()
                if peek() == "^", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseBitwiseAnd()
                    result = result ^ rhs
                } else {
                    break
                }
            }
            return result
        }

        /// Bitwise AND: `a & b` (but not `&&` or `&=`)
        mutating func parseBitwiseAnd() throws -> Int64 {
            var result = try parseEquality()
            while true {
                skipWS()
                if peek() == "&", peekAt(1) != "&", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseEquality()
                    result = result & rhs
                } else {
                    break
                }
            }
            return result
        }

        /// Equality: `a == b`, `a != b`
        mutating func parseEquality() throws -> Int64 {
            var result = try parseRelational()
            while true {
                skipWS()
                let saved = pos
                if match("==") {
                    let rhs = try parseRelational()
                    result = result == rhs ? 1 : 0
                } else if match("!=") {
                    let rhs = try parseRelational()
                    result = result != rhs ? 1 : 0
                } else {
                    pos = saved
                    break
                }
            }
            return result
        }

        /// Relational: `<`, `>`, `<=`, `>=`
        mutating func parseRelational() throws -> Int64 {
            var result = try parseShift()
            while true {
                skipWS()
                let saved = pos
                if match("<=") {
                    let rhs = try parseShift()
                    result = result <= rhs ? 1 : 0
                } else if match(">=") {
                    let rhs = try parseShift()
                    result = result >= rhs ? 1 : 0
                } else if peek() == "<", peekAt(1) != "<" {
                    advance()
                    let rhs = try parseShift()
                    result = result < rhs ? 1 : 0
                } else if peek() == ">", peekAt(1) != ">" {
                    advance()
                    let rhs = try parseShift()
                    result = result > rhs ? 1 : 0
                } else {
                    pos = saved
                    break
                }
            }
            return result
        }

        /// Shift: `a << b`, `a >> b` (but not `<<=` or `>>=`)
        mutating func parseShift() throws -> Int64 {
            var result = try parseAdditive()
            while true {
                skipWS()
                let saved = pos
                if match("<<") {
                    // Make sure it's not <<=
                    if peek() == "=" {
                        pos = saved
                        break
                    }
                    let rhs = try parseAdditive()
                    result = result << rhs
                } else if match(">>") {
                    if peek() == "=" {
                        pos = saved
                        break
                    }
                    let rhs = try parseAdditive()
                    result = result >> rhs
                } else {
                    pos = saved
                    break
                }
            }
            return result
        }

        /// Additive: `a + b`, `a - b`
        mutating func parseAdditive() throws -> Int64 {
            var result = try parseMultiplicative()
            while true {
                skipWS()
                if peek() == "+", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseMultiplicative()
                    result = result + rhs
                } else if peek() == "-", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseMultiplicative()
                    result = result - rhs
                } else {
                    break
                }
            }
            return result
        }

        /// Multiplicative: `a * b`, `a / b`, `a % b`
        mutating func parseMultiplicative() throws -> Int64 {
            var result = try parseUnary()
            while true {
                skipWS()
                if peek() == "*", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseUnary()
                    result = result * rhs
                } else if peek() == "/", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseUnary()
                    guard rhs != 0 else { throw ShellError.divisionByZero }
                    result = result / rhs
                } else if peek() == "%", peekAt(1) != "=" {
                    advance()
                    let rhs = try parseUnary()
                    guard rhs != 0 else { throw ShellError.divisionByZero }
                    result = result % rhs
                } else {
                    break
                }
            }
            return result
        }

        /// Unary prefix: `+expr`, `-expr`, `!expr`, `~expr`
        mutating func parseUnary() throws -> Int64 {
            skipWS()
            // Prefix increment/decrement: ++VAR / --VAR
            if peek() == "+", peekAt(1) == "+" {
                advance(); advance()
                skipWS()
                guard let name = readIdentifierAfterOptionalDollar() else {
                    throw ShellError.arithmeticError("expected variable after '++'")
                }
                if skipEval { return 0 }
                let newVal = resolveVariable(name) + 1
                environment.setVariable(name, value: String(newVal))
                return newVal
            }
            if peek() == "-", peekAt(1) == "-" {
                advance(); advance()
                skipWS()
                guard let name = readIdentifierAfterOptionalDollar() else {
                    throw ShellError.arithmeticError("expected variable after '--'")
                }
                if skipEval { return 0 }
                let newVal = resolveVariable(name) - 1
                environment.setVariable(name, value: String(newVal))
                return newVal
            }
            if peek() == "+", peekAt(1) != "=" {
                advance()
                return try parseUnary()
            }
            if peek() == "-", peekAt(1) != "=" {
                advance()
                return -(try parseUnary())
            }
            if peek() == "!", peekAt(1) != "=" {
                advance()
                let val = try parseUnary()
                return val == 0 ? 1 : 0
            }
            if peek() == "~" {
                advance()
                let val = try parseUnary()
                return ~val
            }
            return try parsePrimary()
        }

        /// Primary: number literal, variable reference, or parenthesized expression.
        mutating func parsePrimary() throws -> Int64 {
            skipWS()
            guard let ch = peek() else {
                throw ShellError.arithmeticError("unexpected end of arithmetic expression")
            }

            // Parenthesized expression
            if ch == "(" {
                advance()
                let val = try parseComma()
                skipWS()
                guard peek() == ")" else {
                    throw ShellError.arithmeticError("expected ')' in arithmetic expression")
                }
                advance()
                return val
            }

            // Number literal
            if ch.isNumber {
                return try parseNumber()
            }

            // Variable reference (identifier), with postfix ++/--
            if ch == "_" || ch.isLetter {
                let name = readIdentifier()!
                skipWS()
                if peek() == "+", peekAt(1) == "+" {
                    advance(); advance()
                    if skipEval { return 0 }
                    let val = resolveVariable(name)
                    environment.setVariable(name, value: String(val + 1))
                    return val
                }
                if peek() == "-", peekAt(1) == "-" {
                    advance(); advance()
                    if skipEval { return 0 }
                    let val = resolveVariable(name)
                    environment.setVariable(name, value: String(val - 1))
                    return val
                }
                if skipEval { return 0 }
                return resolveVariable(name)
            }

            // `$NAME` / `$N` references — common inside `$(( $i + 1 ))` and
            // required for `${v:$i:2}` substring offsets.
            if ch == "$" {
                advance()
                var name = readIdentifier() ?? ""
                if name.isEmpty {
                    while let d = peek(), d.isNumber {
                        name.append(d)
                        advance()
                    }
                }
                guard !name.isEmpty else {
                    throw ShellError.arithmeticError("expected variable name after '$'")
                }
                if skipEval { return 0 }
                if let special = environment.resolveSpecialVariable(name) {
                    return Int64(special) ?? 0
                }
                return resolveVariable(name)
            }

            throw ShellError.arithmeticError("unexpected character '\(ch)' in arithmetic expression")
        }

        /// Resolve a variable name to an Int64 value. Unset or non-numeric variables default to 0.
        func resolveVariable(_ name: String) -> Int64 {
            guard let val = environment.getVariable(name) else { return 0 }
            return Int64(val) ?? 0
        }
    }
}

#endif
