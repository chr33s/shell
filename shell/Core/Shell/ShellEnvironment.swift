#if !targetEnvironment(macCatalyst)

import Foundation

/// Variable storage, scope stack, and parameter expansion for the shell interpreter.
///
/// Thread safety: All mutable state is protected by `lock`. The environment is
/// accessed from `commandQueue` (where the interpreter runs), and read from
/// MainActor when displaying prompt-related information. The lock ensures safety.
///
/// Variable lookup order:
/// 1. Top of scope stack (function-local `local` variables)
/// 2. Shell-local `variables` dictionary
/// 3. `ios_getenv()` (process environment)
/// Shell options controlled by the `set` builtin.
nonisolated struct ShellOptions: Sendable {
    var errexit = false    // -e: exit on command failure
    var nounset = false    // -u: error on unset variable expansion
    var xtrace = false     // -x: trace commands before execution
    var pipefail = false   // -o pipefail: pipeline fails if any stage fails

    /// Contents of `$-`.
    var flagString: String {
        var s = ""
        if errexit { s += "e" }
        if nounset { s += "u" }
        if xtrace { s += "x" }
        return s
    }
}

nonisolated final class ShellEnvironment: @unchecked Sendable {
    private let lock = UnfairLock()
    private nonisolated static let processEnvLock = UnfairLock()

    /// Shell-local variables (not exported to process environment).
    private var variables: [String: String] = [:]

    /// Names that have been exported (exist in both shell dict and ios env).
    private var exportedNames: Set<String> = []

    /// Scope stack for function-local variables (`local`).
    /// Each entry maps variable names to values for that scope level.
    private var scopeStack: [[String: String]] = []

    /// Shell function definitions.
    private var functions: [String: ShellCommand] = [:]

    /// Trap handlers that persist with the environment (across interpreter instances).
    let trapRegistry = TrapRegistry()

    /// Exit code of the last executed command.
    private(set) var lastExitCode: Int32 = 0

    /// Shell options (`set -e/-u/-x/-o pipefail`).
    private var shellOptions = ShellOptions()

    /// Positional parameters ($1..$N).
    private var positionalParams: [String] = []

    /// Script name ($0).
    private var scriptName: String = "sh"

    /// Session ID for ios_getenv/ios_setenv calls.
    let sessionID: UUID
    private let allowProcessEnvWrites: Bool

    /// Background jobs (`cmd &`). Shared across isolated copies so `jobs`,
    /// `wait`, and `$!` see the session's jobs from any nesting level.
    let jobTable: ShellJobTable

    /// True for pipeline-stage/background-job copies: `cd` must be logical
    /// (PWD variable only) because the real ios_system session directory is
    /// shared with the foreground shell.
    let isIsolatedContext: Bool

    init(sessionID: UUID, allowProcessEnvWrites: Bool = true,
         jobTable: ShellJobTable = ShellJobTable(),
         isIsolatedContext: Bool = false) {
        self.sessionID = sessionID
        self.allowProcessEnvWrites = allowProcessEnvWrites
        self.jobTable = jobTable
        self.isIsolatedContext = isIsolatedContext
    }

    // MARK: - Exit Code

    func setLastExitCode(_ code: Int32) {
        lock.withLock { lastExitCode = code }
    }

    func getLastExitCode() -> Int32 {
        lock.withLock { lastExitCode }
    }

    // MARK: - Shell Options

    var options: ShellOptions {
        lock.withLock { shellOptions }
    }

    func updateOptions(_ mutate: (inout ShellOptions) -> Void) {
        lock.withLock { mutate(&shellOptions) }
    }

    // MARK: - Variable Access

    /// Get a variable's value. Checks scope stack, then shell variables, then ios_getenv.
    func getVariable(_ name: String) -> String? {
        lock.withLock {
            // Check scope stack (top first)
            for scope in scopeStack.reversed() {
                if let val = scope[name] { return val }
            }

            // Check shell-local variables
            if let val = variables[name] { return val }

            // Check process environment
            return getEnvVar(name)
        }
    }

    /// Set a variable. If exported, also sets in ios env.
    func setVariable(_ name: String, value: String) {
        lock.withLock {
            // If in a function scope and this is a local variable, set in top scope
            if !scopeStack.isEmpty, scopeStack[scopeStack.count - 1].keys.contains(name) {
                scopeStack[scopeStack.count - 1][name] = value
            } else {
                variables[name] = value
            }

            // If this variable was exported, update ios env too
            if exportedNames.contains(name), allowProcessEnvWrites {
                setEnvVar(name, value: value)
            }
        }
    }

    /// Export a variable (make it visible to child commands via ios_setenv).
    func exportVariable(_ name: String, value: String? = nil) {
        lock.withLock {
            if let v = value {
                variables[name] = v
            }
            exportedNames.insert(name)

            // Use provided value, or shell variable, or EXISTING ios_system env value.
            // The ios_system env fallback prevents clobbering inherited vars like PATH
            // when `export PATH` is called without a value.
            let finalValue = value ?? variables[name] ?? getEnvVar(name) ?? ""
            if allowProcessEnvWrites {
                setEnvVar(name, value: finalValue)
            }
        }
    }

    /// Unset a variable from all scopes, shell variables, and ios env.
    func unsetVariable(_ name: String) {
        lock.withLock {
            // Remove from scope stack
            for i in scopeStack.indices {
                scopeStack[i].removeValue(forKey: name)
            }

            // Remove from shell variables
            variables.removeValue(forKey: name)

            // Remove from exported set and ios env
            exportedNames.remove(name)
            if allowProcessEnvWrites {
                unsetEnvVar(name)
            }
        }
    }

    /// Declare a variable as local in the current function scope.
    func declareLocal(_ name: String, value: String?) {
        lock.withLock {
            guard !scopeStack.isEmpty else { return }
            scopeStack[scopeStack.count - 1][name] = value ?? ""
        }
    }

    // MARK: - Function Scope

    /// Push a new scope frame (called on function entry).
    func pushScope() {
        lock.withLock {
            scopeStack.append([:])
        }
    }

    /// Pop the top scope frame (called on function exit).
    func popScope() {
        lock.withLock {
            _ = scopeStack.popLast()
        }
    }

    /// Snapshot the current function-local scope stack.
    func snapshotScopeStack() -> [[String: String]] {
        lock.withLock { scopeStack }
    }

    /// Restore the function-local scope stack from a previous snapshot.
    func restoreScopeStack(_ snapshot: [[String: String]]) {
        lock.withLock { scopeStack = snapshot }
    }

    // MARK: - Functions

    /// Define a shell function.
    func defineFunction(_ name: String, body: ShellCommand) {
        lock.withLock {
            functions[name] = body
        }
    }

    /// Look up a shell function.
    func getFunction(_ name: String) -> ShellCommand? {
        lock.withLock {
            functions[name]
        }
    }

    /// Remove a function definition.
    func unsetFunction(_ name: String) {
        lock.withLock {
            _ = functions.removeValue(forKey: name)
        }
    }

    // MARK: - Positional Parameters

    /// Set positional parameters and script name.
    func setPositionalParams(_ params: [String], scriptName: String) {
        lock.withLock {
            self.positionalParams = params
            self.scriptName = scriptName
        }
    }

    /// Shift positional parameters left by `n`.
    func shiftParams(_ n: Int = 1) {
        lock.withLock {
            let count = min(n, positionalParams.count)
            positionalParams.removeFirst(count)
        }
    }

    /// Get a positional parameter by index (1-based).
    func getPositionalParam(_ index: Int) -> String? {
        lock.withLock {
            guard index >= 1 && index <= positionalParams.count else { return nil }
            return positionalParams[index - 1]
        }
    }

    /// Get all positional parameters.
    func getAllPositionalParams() -> [String] {
        lock.withLock { positionalParams }
    }

    /// Get the count of positional parameters.
    func positionalParamCount() -> Int {
        lock.withLock { positionalParams.count }
    }

    /// Get the script name ($0).
    func getScriptName() -> String {
        lock.withLock { scriptName }
    }

    /// Resolve a path relative to the shell session.
    func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }

        let home = getVariable("HOME")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }

        let pwd = getVariable("PWD") ?? FileManager.default.currentDirectoryPath
        return (pwd as NSString).appendingPathComponent(path)
    }

    // MARK: - Special Variable Resolution

    /// Resolve a special variable by name. Returns nil if not a special variable.
    func resolveSpecialVariable(_ name: String) -> String? {
        switch name {
        case "?":
            return String(getLastExitCode())
        case "#":
            return String(positionalParamCount())
        case "@":
            // Join with the field-separator sentinel so `"$@"` expands to one
            // field per parameter (split in the interpreter's field stage).
            let params = getAllPositionalParams()
            if params.isEmpty { return String(ShellTokenizer.emptyAtMarker) }
            return params.joined(separator: String(ShellTokenizer.fieldSeparator))
        case "*":
            // POSIX: join with the first character of IFS (default space).
            let sep = (getVariable("IFS") ?? " \t\n").first.map(String.init) ?? ""
            return getAllPositionalParams().joined(separator: sep)
        case "$":
            return String(ProcessInfo.processInfo.processIdentifier)
        case "!":
            return String(jobTable.lastBackgroundPid)
        case "-":
            return options.flagString
        case "0":
            return getScriptName()
        case "RANDOM":
            return String(Int.random(in: 0...32767))
        case "LINENO":
            return "0" // TODO: track line numbers during execution
        default:
            // Positional parameter $1-$9+
            if let n = Int(name), n >= 1 {
                return getPositionalParam(n)
            }
            return nil
        }
    }

    // MARK: - Word Expansion

    /// Collapse `$@` sentinels for expansions that don't field-split
    /// (assignments, redirect targets, heredocs, case words, `[[` operands):
    /// field separators become spaces, empty-`$@` markers vanish.
    static func finalizeScalarExpansion(_ s: String) -> String {
        guard s.contains(ShellTokenizer.fieldSeparator)
                || s.contains(ShellTokenizer.emptyAtMarker) else { return s }
        return s
            .replacingOccurrences(of: String(ShellTokenizer.fieldSeparator), with: " ")
            .replacingOccurrences(of: String(ShellTokenizer.emptyAtMarker), with: "")
    }

    /// `expandWord` + sentinel scrub, for single-value (non-field-splitting) contexts.
    func expandScalarWord(_ word: ShellWord, interpreter: ShellInterpreter? = nil) throws -> String {
        Self.finalizeScalarExpansion(try expandWord(word, interpreter: interpreter))
    }

    /// Expand a `ShellWord` into its final string value.
    func expandWord(_ word: ShellWord, interpreter: ShellInterpreter? = nil) throws -> String {
        switch word {
        case .literal(let s):
            return s

        case .singleQuoted(let s):
            return s

        case .doubleQuoted(let parts):
            return try parts.map { try expandWord($0, interpreter: interpreter) }.joined()

        case .variable(let name):
            // Check special variables first, then regular lookup
            if let special = resolveSpecialVariable(name) { return special }
            if let value = getVariable(name) { return value }
            if options.nounset { throw ShellError.undefinedVariable(name) }
            return ""

        case .paramExpansion(let expansion):
            return try expandParam(expansion, interpreter: interpreter)

        case .commandSub(let cmd):
            guard let interp = interpreter else { return "" }
            return try interp.executeCommandSubstitution(cmd)

        case .arithmetic(let expr):
            guard let interp = interpreter else { return "0" }
            let result = try interp.evaluateArithmetic(expr)
            return String(result)

        case .concat(let parts):
            return try parts.map { try expandWord($0, interpreter: interpreter) }.joined()
        }
    }

    /// Expand a strip/replace pattern (`${v#$p}`, `${v/"l"/L}`) with bash
    /// quoting semantics: quoted segments (and `$`-expansions inside double
    /// quotes) match literally — their glob metacharacters are escaped —
    /// while unquoted `$`-expansions stay pattern-active.
    private func expandPatternText(_ pattern: String,
                                   interpreter: ShellInterpreter?) throws -> String {
        // Quotes arrive as PUA sentinels when the pattern came through the
        // tokenizer's word path (`echo ${v/"l"/L}`), and as raw quote chars
        // when parsed from raw text (heredocs). Handle both.
        let sqStart = ShellTokenizer.singleQuoteStart
        let sqEnd = ShellTokenizer.singleQuoteEnd
        let dqStart = ShellTokenizer.doubleQuoteStart
        let dqEnd = ShellTokenizer.doubleQuoteEnd

        guard pattern.contains("$") || pattern.contains("`")
                || pattern.contains("'") || pattern.contains("\"")
                || pattern.contains(sqStart) || pattern.contains(dqStart) else { return pattern }

        func expandFragment(_ s: String) throws -> String {
            guard s.contains("$") || s.contains("`") else { return s }
            let word = ShellParser(tokenizer: ShellTokenizer(source: "")).parseShellWord(from: s)
            return Self.finalizeScalarExpansion(try expandWord(word, interpreter: interpreter))
        }

        var result = ""
        var unquoted = ""
        var i = pattern.startIndex

        func consumeQuoted(until terminator: Character) -> String {
            var content = ""
            while i < pattern.endIndex, pattern[i] != terminator {
                content.append(pattern[i])
                i = pattern.index(after: i)
            }
            if i < pattern.endIndex { i = pattern.index(after: i) } // skip terminator
            return content
        }

        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "'" || c == sqStart {
                result += try expandFragment(unquoted)
                unquoted = ""
                i = pattern.index(after: i)
                result += ShellGlob.escape(consumeQuoted(until: c == "'" ? "'" : sqEnd))
            } else if c == "\"" || c == dqStart {
                result += try expandFragment(unquoted)
                unquoted = ""
                i = pattern.index(after: i)
                let inner = consumeQuoted(until: c == "\"" ? "\"" : dqEnd)
                result += ShellGlob.escape(try expandFragment(inner))
            } else {
                unquoted.append(c)
                i = pattern.index(after: i)
            }
        }
        result += try expandFragment(unquoted)
        return result
    }

    /// Resolve a parameter for the value-transforming expansions (length,
    /// strip, substring, replace): unset + nounset is an error, exactly like
    /// a plain `$VAR` reference.
    private func lookupTransformable(_ name: String) throws -> String {
        if let special = resolveSpecialVariable(name) { return special }
        if let value = getVariable(name) { return value }
        if options.nounset { throw ShellError.undefinedVariable(name) }
        return ""
    }

    /// Expand a parameter expansion form.
    private func expandParam(_ expansion: ParamExpansion,
                              interpreter: ShellInterpreter?) throws -> String {
        switch expansion {
        case .simple(let name):
            if let special = resolveSpecialVariable(name) { return special }
            if let value = getVariable(name) { return value }
            if options.nounset { throw ShellError.undefinedVariable(name) }
            return ""

        case .defaultValue(let name, let word, let checkEmpty):
            let val = resolveSpecialVariable(name) ?? getVariable(name)
            if let v = val, !(checkEmpty && v.isEmpty) { return v }
            return try word.map { try expandWord($0, interpreter: interpreter) }.joined()

        case .assignDefault(let name, let word, let checkEmpty):
            let val = resolveSpecialVariable(name) ?? getVariable(name)
            if let v = val, !(checkEmpty && v.isEmpty) { return v }
            let defaultVal = try word.map { try expandWord($0, interpreter: interpreter) }.joined()
            setVariable(name, value: defaultVal)
            return defaultVal

        case .alternative(let name, let word, let checkEmpty):
            let val = resolveSpecialVariable(name) ?? getVariable(name)
            if let v = val, !(checkEmpty && v.isEmpty) {
                return try word.map { try expandWord($0, interpreter: interpreter) }.joined()
            }
            return ""

        case .errorIfUnset(let name, let word, let checkEmpty):
            let val = resolveSpecialVariable(name) ?? getVariable(name)
            if let v = val, !(checkEmpty && v.isEmpty) { return v }
            let msg = try word.map { try expandWord($0, interpreter: interpreter) }.joined()
            throw ShellError.undefinedVariable(msg.isEmpty ? name : msg)

        case .substring(let name, let offsetExpr, let lengthExpr):
            let val = try lookupTransformable(name)
            guard let interp = interpreter else { return val }
            let chars = Array(val)
            let count = chars.count
            var start = Int(try interp.evaluateArithmetic(offsetExpr))
            if start < 0 { start = max(0, count + start) }
            guard start < count else { return "" }
            var end = count
            if let lengthExpr {
                let length = Int(try interp.evaluateArithmetic(lengthExpr))
                // Negative length stops that many chars short of the end (bash)
                end = length < 0 ? max(start, count + length) : min(count, start + length)
            }
            guard start < end else { return "" }
            return String(chars[start..<end])

        case .replace(let name, let pattern, let replacement, let mode):
            let val = try lookupTransformable(name)
            let repl = try replacement.map { try expandWord($0, interpreter: interpreter) }.joined()
            let pat = try expandPatternText(pattern, interpreter: interpreter)
            return Self.applyReplace(val, pattern: pat, replacement: repl, mode: mode)

        case .bad(let content):
            throw ShellError.badSubstitution(content)

        case .length(let name):
            let val = try lookupTransformable(name)
            return String(val.count)

        case .stripShortPrefix(let name, let pattern):
            let val = try lookupTransformable(name)
            let pat = try expandPatternText(pattern, interpreter: interpreter)
            return shellStripPrefix(val, pattern: pat, greedy: false)

        case .stripLongPrefix(let name, let pattern):
            let val = try lookupTransformable(name)
            let pat = try expandPatternText(pattern, interpreter: interpreter)
            return shellStripPrefix(val, pattern: pat, greedy: true)

        case .stripShortSuffix(let name, let pattern):
            let val = try lookupTransformable(name)
            let pat = try expandPatternText(pattern, interpreter: interpreter)
            return shellStripSuffix(val, pattern: pat, greedy: false)

        case .stripLongSuffix(let name, let pattern):
            let val = try lookupTransformable(name)
            let pat = try expandPatternText(pattern, interpreter: interpreter)
            return shellStripSuffix(val, pattern: pat, greedy: true)
        }
    }

    // MARK: - Pattern Matching Helpers

    /// `${VAR/pat/repl}` family: glob-based replacement.
    /// Unanchored modes use leftmost-longest matching per position.
    static func applyReplace(_ value: String, pattern: String,
                             replacement: String, mode: ReplaceMode) -> String {
        let chars = Array(value)
        let count = chars.count

        switch mode {
        case .prefix:
            // Longest prefix match, replaced once
            for end in (0...count).reversed()
            where ShellGlob.match(String(chars[0..<end]), pattern: pattern) {
                return replacement + String(chars[end...])
            }
            return value

        case .suffix:
            for start in 0...count
            where ShellGlob.match(String(chars[start...]), pattern: pattern) {
                return String(chars[0..<start]) + replacement
            }
            return value

        case .first, .all:
            var result = ""
            var i = 0
            var replaced = false
            while i < count {
                if !replaced || mode == .all {
                    // Longest match starting at i (empty matches are skipped
                    // to guarantee progress)
                    var matchEnd = -1
                    for end in ((i + 1)...count).reversed()
                    where ShellGlob.match(String(chars[i..<end]), pattern: pattern) {
                        matchEnd = end
                        break
                    }
                    if matchEnd > i {
                        result += replacement
                        i = matchEnd
                        replaced = true
                        continue
                    }
                }
                result.append(chars[i])
                i += 1
            }
            return result
        }
    }

    /// Strip prefix matching a glob pattern (true anchored glob semantics).
    private func shellStripPrefix(_ value: String, pattern: String, greedy: Bool) -> String {
        ShellGlob.stripPrefix(value, pattern: pattern, greedy: greedy)
    }

    /// Strip suffix matching a glob pattern (true anchored glob semantics).
    private func shellStripSuffix(_ value: String, pattern: String, greedy: Bool) -> String {
        ShellGlob.stripSuffix(value, pattern: pattern, greedy: greedy)
    }

    // MARK: - Snapshot / Restore (for subshell isolation)

    /// Snapshot all shell-local variables for later restoration.
    func snapshotVariables() -> [String: String] {
        lock.withLock { variables }
    }

    /// Restore shell-local variables from a previous snapshot.
    func restoreVariables(_ snapshot: [String: String]) {
        lock.withLock { variables = snapshot }
    }

    /// Snapshot all function definitions for later restoration.
    func snapshotFunctions() -> [String: ShellCommand] {
        lock.withLock { functions }
    }

    /// Restore function definitions from a previous snapshot.
    func restoreFunctions(_ snapshot: [String: ShellCommand]) {
        lock.withLock { functions = snapshot }
    }

    /// Snapshot the set of exported variable names.
    func snapshotExportedNames() -> Set<String> {
        lock.withLock { exportedNames }
    }

    /// Restore the set of exported variable names.
    func restoreExportedNames(_ snapshot: Set<String>) {
        lock.withLock { exportedNames = snapshot }
    }

    /// Snapshot exported variable names AND their values for full ios_system env restoration.
    ///
    /// In addition to capturing values for all currently exported names, this also
    /// captures the ios_system env values for any shell variables that aren't yet
    /// exported. A subshell may `export` these variables and change them; capturing
    /// their pre-subshell ios_system values ensures we can restore them correctly.
    func snapshotExportedState() -> (names: Set<String>, values: [String: String]) {
        lock.withLock {
            var values: [String: String] = [:]
            // Capture values for all exported names
            for name in exportedNames {
                values[name] = variables[name] ?? getEnvVar(name) ?? ""
            }
            // Also capture ios_system env values for shell variables that might
            // get exported during the subshell (e.g. PATH that only lives in env)
            for name in variables.keys {
                if values[name] == nil, let envVal = getEnvVar(name) {
                    values[name] = envVal
                }
            }
            return (exportedNames, values)
        }
    }

    /// Restore exported variable state, syncing both the tracking set and ios_system env.
    func restoreExportedState(_ snapshot: (names: Set<String>, values: [String: String])) {
        lock.withLock {
            guard allowProcessEnvWrites else {
                exportedNames = snapshot.names
                return
            }

            // Remove vars that were added during subshell
            let added = exportedNames.subtracting(snapshot.names)
            for name in added {
                unsetEnvVar(name)
            }

            // Restore original values for vars that were in the snapshot
            for (name, value) in snapshot.values {
                setEnvVar(name, value: value)
            }

            exportedNames = snapshot.names
        }
    }

    /// Check whether a variable is currently exported.
    func isExported(_ name: String) -> Bool {
        lock.withLock { exportedNames.contains(name) }
    }

    /// Remove a variable from the exported set (but keep it as a shell variable).
    func unexportVariable(_ name: String) {
        lock.withLock {
            exportedNames.remove(name)
            if allowProcessEnvWrites {
                unsetEnvVar(name)
            }
        }
    }

    /// Read the current exported value for a variable from ios_system env.
    func getExportedEnvValue(_ name: String) -> String? {
        lock.withLock { getEnvVar(name) }
    }

    /// Snapshot the environment that should be visible to child external commands.
    func snapshotChildProcessEnvironment() -> [String: String] {
        lock.withLock {
            var values: [String: String] = [:]
            for name in exportedNames {
                values[name] = variables[name] ?? getEnvVar(name) ?? ""
            }
            return values
        }
    }

    /// Temporarily apply exported variables to ios_system env while running `body`.
    func withTemporaryChildProcessEnvironment<T>(
        _ values: [String: String],
        _ body: () throws -> T
    ) rethrows -> T {
        guard allowProcessEnvWrites else { return try body() }

        return try Self.processEnvLock.withLock {
            var previous: [String: String?] = [:]
            for (name, value) in values {
                previous[name] = rawGetEnvVar(name)
                rawSetEnvVar(name, value: value)
            }
            defer {
                for (name, value) in previous {
                    if let value {
                        rawSetEnvVar(name, value: value)
                    } else {
                        rawUnsetEnvVar(name)
                    }
                }
            }
            return try body()
        }
    }

    /// Restore a variable's ios_system env value if this environment is allowed to mutate it.
    func restoreExportedEnvValue(_ name: String, value: String?) {
        lock.withLock {
            guard allowProcessEnvWrites else { return }
            if let value {
                setEnvVar(name, value: value)
            } else {
                unsetEnvVar(name)
            }
        }
    }

    /// Remove a variable from the exported tracking set without modifying ios_system env.
    /// Used by pre-command assignment restoration to avoid destroying inherited env vars.
    func removeFromExportedSet(_ name: String) {
        lock.withLock {
            _ = exportedNames.remove(name)
        }
    }

    /// Create an isolated environment copy for subshell/pipeline stages.
    func makeIsolatedCopy() -> ShellEnvironment {
        let copy = ShellEnvironment(sessionID: sessionID, allowProcessEnvWrites: false,
                                    jobTable: jobTable, isIsolatedContext: true)

        let vars = snapshotVariables()
        let scopes = snapshotScopeStack()
        let funcs = snapshotFunctions()
        let exports = snapshotExportedState()
        let params = getAllPositionalParams()
        let name = getScriptName()
        let lastCode = getLastExitCode()
        let traps = trapRegistry.snapshot()

        copy.restoreVariables(vars)
        copy.restoreScopeStack(scopes)
        copy.restoreFunctions(funcs)
        copy.restoreExportedNames(exports.names)

        // Preserve inherited exported values that may only exist in ios_system env.
        for (exportedName, value) in exports.values where vars[exportedName] == nil {
            copy.setVariable(exportedName, value: value)
        }

        copy.setPositionalParams(params, scriptName: name)
        copy.setLastExitCode(lastCode)
        copy.trapRegistry.restore(traps)
        let opts = options
        copy.updateOptions { $0 = opts }
        return copy
    }

    // MARK: - ios_system Environment Bridge

    private func getEnvVar(_ name: String) -> String? {
        Self.processEnvLock.withLock {
            rawGetEnvVar(name)
        }
    }

    private func rawGetEnvVar(_ name: String) -> String? {
        // Ensure we're in the correct ios_system session context before querying
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        ios_switchSession(sessionPtr)
        guard let ptr = ios_getenv(name) else { return nil }
        // Copy immediately — the pointer may be invalidated by subsequent ios_system calls
        return String(validatingCString: ptr) ?? String(cString: ptr)
    }

    private func setEnvVar(_ name: String, value: String) {
        Self.processEnvLock.withLock {
            rawSetEnvVar(name, value: value)
        }
    }

    private func rawSetEnvVar(_ name: String, value: String) {
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        ios_switchSession(sessionPtr)
        ios_setenv(name, value, 1)
    }

    private func unsetEnvVar(_ name: String) {
        Self.processEnvLock.withLock {
            rawUnsetEnvVar(name)
        }
    }

    private func rawUnsetEnvVar(_ name: String) {
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        ios_switchSession(sessionPtr)
        ios_unsetenv(name)
    }
}

#endif
