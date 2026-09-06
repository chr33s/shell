// LocalShellSession RC file support - .shellrc startup dotfile
#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

// MARK: - RC File Health Tracker

/// Detects when .shellrc causes hangs/crashes via a launch checkpoint pattern.
///
/// 1. Set "rc in progress" flag + timestamp before executing
/// 2. Clear flag after successful completion
/// 3. On next launch, if flag is still set → previous run hung/crashed → increment failure count
/// 4. After 2 consecutive failures, skip rc execution until user explicitly runs `source`
@MainActor
final class RCFileHealthTracker {
    static let shared = RCFileHealthTracker()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "RCFileHealth")

    private let failureThreshold = 2
    private let failureWindowSeconds: TimeInterval = 3600  // 1 hour

    private enum Keys {
        static let inProgress = "rcfile.inProgress"
        static let consecutiveFailures = "rcfile.consecutiveFailures"
        static let lastFailureTimestamp = "rcfile.lastFailureTimestamp"
    }

    private(set) var shouldSkip = false
    private var checked = false

    private init() {}

    /// Check on launch whether previous rc execution completed. Call once before first executeRCFile().
    func checkHealth() {
        guard !checked else { return }
        checked = true

        let defaults = UserDefaults.standard
        let wasInProgress = defaults.bool(forKey: Keys.inProgress)

        if wasInProgress {
            Self.logger.warning("Previous .shellrc execution did not complete")
            let current = defaults.integer(forKey: Keys.consecutiveFailures)
            let newCount = current + 1
            defaults.set(newCount, forKey: Keys.consecutiveFailures)
            defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastFailureTimestamp)
            defaults.set(false, forKey: Keys.inProgress)
            Self.logger.warning("RC failure count: \(newCount)/\(self.failureThreshold)")
        }

        // Reset stale failures
        let lastTs = defaults.double(forKey: Keys.lastFailureTimestamp)
        if lastTs > 0, Date().timeIntervalSince1970 - lastTs > failureWindowSeconds {
            Self.logger.info("RC failure count is stale, resetting")
            resetFailures()
            return
        }

        let failures = defaults.integer(forKey: Keys.consecutiveFailures)
        if failures >= failureThreshold {
            Self.logger.warning("Skipping .shellrc — \(failures) consecutive failures")
            shouldSkip = true
        }
    }

    /// Mark rc execution starting. Must be called before sourcing the file.
    func markStarted() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Keys.inProgress)
        defaults.synchronize()
    }

    /// Mark rc execution completed successfully.
    func markCompleted() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Keys.inProgress)
        resetFailures()
    }

    /// Reset after user explicitly runs `source` (clears skip state for next launch).
    func resetFailures() {
        let defaults = UserDefaults.standard
        defaults.set(0, forKey: Keys.consecutiveFailures)
        defaults.removeObject(forKey: Keys.lastFailureTimestamp)
        shouldSkip = false
    }
}

// MARK: - LocalShellSession RC File Extension

extension LocalShellSession {

    // MARK: - RC File Constants

    static let rcFileName = ".shellrc"

    private static let defaultRCContent = """
    # shell startup configuration (~/.shellrc)
    # This file is sourced when a new shell tab opens.
    # Lines starting with # are comments.
    #
    # Set environment variables:
    #   export EDITOR=vim
    #   export LANG=en_US.UTF-8
    #   setenv MY_VAR my_value
    #
    # Create command aliases:
    #   alias ll='ls -la'
    #   alias la='ls -A'
    #   alias grep='grep --color=auto'
    #
    # Run commands at startup:
    #   echo "Welcome back!"
    #
    # Re-source this file anytime with: source
    # Edit this file with: editrc

    """

    // MARK: - RC File Path

    var rcFilePath: String {
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].path
        return (documentsPath as NSString).appendingPathComponent(Self.rcFileName)
    }

    // MARK: - RC File Execution

    /// Execute the rc file at startup. Returns true if any active lines were executed.
    @discardableResult
    func executeRCFile() -> Bool {
        let path = rcFilePath

        if !FileManager.default.fileExists(atPath: path) {
            createDefaultRCFile(at: path)
            return false
        }

        // Check if previous rc execution caused a hang/crash
        let healthTracker = RCFileHealthTracker.shared
        healthTracker.checkHealth()

        if healthTracker.shouldSkip {
            Self.logger.warning("Skipping .shellrc — safe mode after repeated hangs")
            onOutput?(normalizeLineEndings(
                ".shellrc skipped (caused hang on previous launch). Fix it with: editrc\n" +
                "Then run: source\n"
            ))
            return false
        }

        // Mark in-progress before execution — if app is force-quit during this,
        // next launch will detect the incomplete execution
        healthTracker.markStarted()
        let result = sourceFile(at: path)
        healthTracker.markCompleted()

        return result
    }

    /// Source (execute) a file using the shell interpreter with fallback to line-by-line.
    @discardableResult
    func sourceFile(at path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            Self.logger.warning("Failed to read file: \(path)")
            return false
        }

        // Try interpreter-based execution for full shell syntax support
        let tokenizer = ShellTokenizer(source: content)
        let parser = ShellParser(tokenizer: tokenizer)

        guard let ast = try? parser.parse() else {
            Self.logger.info("RC file parse failed, falling back to line-by-line execution")
            return sourceFileLegacy(at: path, content: content)
        }

        // Use the shared session environment so variables, functions, and traps
        // defined in .shellrc persist to the interactive shell.
        let environment = sharedShellEnvironment

        // RC file timeout: 30 seconds
        let rcLFNormalizer = LFNormalizer()
        let rcToken = CancellationToken()
        let deadline = DispatchTime.now() + 30.0
        DispatchQueue.global().asyncAfter(deadline: deadline) { rcToken.cancel() }

        let interpreter = ShellInterpreter(
            environment: environment,
            cancellationToken: rcToken,
            executeExternal: { [weak self] command -> Int32 in
                guard let self else { return 127 }
                return self.executeRCExternalCommand(command)
            },
            captureExternal: { [weak self] command -> (Int32, String) in
                guard let self else { return (127, "") }
                return self.captureCommandOutput(command)
            },
            // Without `streamExternal` the interpreter throws
            // `unsupported("pipelines with external commands")` for ANY
            // foreground pipeline containing an external stage (`ls | grep x`),
            // which unwinds `execute(ast)` and abandons every remaining line of
            // the rc file. `allowAppCommandRouting: false` matches
            // `executeRCExternalCommand`: the rc file must never reach an
            // interactive app handler.
            streamExternal: { [weak self] command, inputProvider, outputSink -> Int32 in
                guard let self else { return 127 }
                return self.streamExternalCommand(command, inputProvider: inputProvider,
                                                  allowAppCommandRouting: false,
                                                  outputSink: outputSink)
            },
            canStreamExternalCommand: { [weak self] command -> Bool in
                guard let self else { return false }
                return self.canStreamExternalPipelineCommand(command)
            },
            backgroundStreamExternal: makeBackgroundStreamExternal(),
            writeOutput: { [weak self] data in
                guard let self else { return }
                self.outputSink.emit(rcLFNormalizer.normalize(data))
            },
            readLine: { _, _ in nil } // No interactive read during RC file
        )

        do {
            _ = try interpreter.execute(ast)
            return true
        } catch ShellError.cancelled {
            Self.logger.warning("RC file timed out after 30 seconds")
            onOutput?(normalizeLineEndings("warning: .shellrc timed out\n"))
            return false
        } catch ShellError.exitSignal(let code) {
            // Deliberate termination (`exit`, or `set -e` aborting) — done.
            Self.logger.info("RC file exited with status \(code)")
            return true
        } catch {
            // Runtime errors must NOT replay the file through the legacy
            // executor — earlier lines already ran and would repeat their
            // side effects. Legacy fallback is only for parse failures
            // (handled above, before execution starts).
            Self.logger.warning("RC file interpreter error: \(error.localizedDescription)")
            onOutput?(normalizeLineEndings("sh: .shellrc: \(error.localizedDescription)\n"))
            return true
        }
    }

    /// Legacy line-by-line execution (fallback when parser fails).
    @discardableResult
    private func sourceFileLegacy(at path: String, content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        var executedAny = false

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            executeRCLine(line, lineNumber: index + 1, filePath: path)
            executedAny = true
        }

        return executedAny
    }

    /// ios_system execution for RC file commands, built on `streamExternalCommand`
    /// so output is drained while the command runs — the previous synchronous
    /// `ios_system` + read-after-return version deadlocked launch forever once
    /// a command emitted more than the 64KB pipe buffer.
    nonisolated private func executeRCExternalCommand(_ command: String) -> Int32 {
        let sink = outputSink
        return streamExternalCommand(command, inputProvider: nil,
                                     allowAppCommandRouting: false) { chunk in
            sink.emit(chunk)
            return true
        }
    }

    /// Execute a single rc file line using tiered dispatch.
    private func executeRCLine(_ line: String, lineNumber: Int, filePath: String) {
        // Tier 1: export VAR=value → ios_setenv directly
        if line.hasPrefix("export ") {
            handleRCExport(line)
            return
        }

        // Tier 1: setenv VAR value → ios_setenv directly
        if line.hasPrefix("setenv ") {
            handleRCSetenv(line)
            return
        }

        // Tier 2+3: Everything else (alias, cd, echo, curl, etc.) → ios_system
        // alias is a fast builtin; other commands run synchronously with output capture
        executeRCCommand(line, lineNumber: lineNumber, filePath: filePath)
    }

    // MARK: - Tier 1: Native env var handling

    private func handleRCExport(_ line: String) {
        let rest = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)

        guard let equalsIndex = rest.firstIndex(of: "=") else {
            Self.logger.debug("RC: invalid export (no =): \(line)")
            return
        }

        let varName = String(rest[rest.startIndex..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        var value = String(rest[rest.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
        value = Self.stripQuotes(value)

        guard !varName.isEmpty else { return }
        ios_setenv(varName, value, 1)
    }

    private func handleRCSetenv(_ line: String) {
        let components = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2 else { return }

        let varName = String(components[1])
        let value = components.count >= 3 ? Self.stripQuotes(String(components[2])) : ""

        ios_setenv(varName, value, 1)
    }

    private static func stripQuotes(_ s: String) -> String {
        var result = s
        if (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
           (result.hasPrefix("'") && result.hasSuffix("'")) {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    // MARK: - Tier 2+3: ios_system execution with output capture

    private func executeRCCommand(_ command: String, lineNumber: Int, filePath: String) {
        // Streams while the command runs (no 64KB pipe-buffer deadlock);
        // stderr reaches the terminal via streamExternalCommand's sink.
        let (exitCode, output) = captureCommandOutput(command)

        if !output.isEmpty {
            onOutput?(normalizeLineEndings(output))
        }

        if exitCode != 0 {
            let fileName = (filePath as NSString).lastPathComponent
            Self.logger.debug("RC: \(fileName):\(lineNumber): '\(command)' exited \(exitCode)")
        }
    }

    // MARK: - Default RC File Creation

    private func createDefaultRCFile(at path: String) {
        do {
            try Self.defaultRCContent.write(toFile: path, atomically: true, encoding: .utf8)
            Self.logger.info("Created default \(Self.rcFileName)")
        } catch {
            Self.logger.warning("Failed to create default rc file: \(error)")
        }
    }

    // MARK: - Source Built-in Command

    func handleSourceCommand(_ command: String) {
        let components = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)

        let filePath: String
        if components.count >= 2 {
            let rawPath = String(components[1]).trimmingCharacters(in: .whitespaces)
            if rawPath.hasPrefix("~/") {
                let home = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                )[0].path
                filePath = (home as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
            } else if rawPath.hasPrefix("/") {
                filePath = rawPath
            } else {
                filePath = (sessionCurrentDirectory as NSString).appendingPathComponent(rawPath)
            }
        } else {
            filePath = rcFilePath
        }

        guard FileManager.default.fileExists(atPath: filePath) else {
            let fileName = (filePath as NSString).lastPathComponent
            onOutput?(normalizeLineEndings("source: \(fileName): No such file\n"))
            displayPrompt()
            return
        }

        // User explicitly sourcing clears safe mode for next launch
        RCFileHealthTracker.shared.resetFailures()

        sourceFile(at: filePath)
        displayPrompt()
    }

    // MARK: - Editrc Built-in Command

    func handleEditRCCommand() {
        // Ensure rc file exists before editing
        if !FileManager.default.fileExists(atPath: rcFilePath) {
            createDefaultRCFile(at: rcFilePath)
        }

        // Use $EDITOR if set, fall back to vim
        let editor: String
        if let envEditor = ios_getenv("EDITOR"), let editorStr = String(validatingCString: envEditor), !editorStr.isEmpty {
            editor = editorStr
        } else {
            editor = "vim"
        }

        handleCommandSubmission("\(editor) \(rcFilePath)")
    }

    // MARK: - Reloadconfig Built-in Command

    func handleReloadConfigCommand(_ command: String) {
        let args = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for arg in args.dropFirst() {
            if arg == "-h" || arg == "--help" {
                displayReloadConfigHelp()
                return
            }
        }

        if args.count > 1 {
            onOutput?(normalizeLineEndings("reloadconfig: too many arguments\n"))
            displayPrompt()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Keybinds reload when an external config has been imported.
            if KeybindManager.shared.externalConfigPath != nil {
                KeybindManager.shared.reloadExternalConfig()
                let count = KeybindManager.shared.externalConfigBindings.count
                let suffix = count == 1 ? "" : "s"
                let message = "Reloaded \(KeybindManager.shared.externalConfigShellPath) (\(count) keybind\(suffix) loaded)\n"
                self.onOutput?(self.normalizeLineEndings(message))
            } else {
                self.onOutput?(self.normalizeLineEndings("reloadconfig: no imported keybind config\n"))
            }
            self.displayPrompt()
        }
    }
}

#endif
