#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

// MARK: - Shell Interpreter Integration

extension LocalShellSession {

    // MARK: - Script Execution Entry Points

    /// Execute a shell script file through the interpreter.
    func executeScript(at path: String, arguments: [String] = []) {
        let resolvedPath = resolveScriptPath(path)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            onOutput?(normalizeLineEndings("sh: \(path): No such file or directory\n"))
            displayPrompt()
            return
        }

        guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            onOutput?(normalizeLineEndings("sh: \(path): Permission denied\n"))
            displayPrompt()
            return
        }

        let truncated = String((resolvedPath as NSString).lastPathComponent.prefix(30))
        onTitleChange?(truncated)

        sessionMode = .scriptRunning
        commandQueue.async { [weak self] in
            self?.runScript(content, name: resolvedPath, arguments: arguments)
        }
    }

    /// Execute a compound command string through the interpreter.
    /// Uses the shared session environment so variables/functions persist.
    func executeInteractiveScript(_ command: String, scriptName: String = "sh", arguments: [String] = []) {
        let truncated = String(command.prefix(30))
        onTitleChange?(truncated)

        sessionMode = .scriptRunning
        commandQueue.async { [weak self] in
            self?.runScript(command, name: scriptName, arguments: arguments, useSharedEnvironment: true)
        }
    }

    // MARK: - Script Runner (runs on commandQueue)

    /// Parse and execute a shell script. Runs on commandQueue (blocking).
    /// When `useSharedEnvironment` is true, the shared session environment is used
    /// so variables, functions, and traps persist across interactive commands.
    /// Script files (`sh script.sh`) use a fresh environment (POSIX correct).
    nonisolated func runScript(_ source: String, name: String, arguments: [String],
                               useSharedEnvironment: Bool = false) {
        // A script queued behind teardown must not start (its token reset
        // below would erase stop()'s cancellation and resurrect the session)
        guard !hasStopped else { return }

        // Parse
        let tokenizer = ShellTokenizer(source: source)
        let parser = ShellParser(tokenizer: tokenizer)

        let ast: ShellCommand
        do {
            ast = try parser.parse()
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onOutput?(self.normalizeLineEndings("sh: \(error.localizedDescription)\n"))
                self.recoverFromScriptExecution()
            }
            return
        }

        // Create or reuse environment
        let environment: ShellEnvironment
        if useSharedEnvironment {
            environment = sharedShellEnvironment
        } else {
            environment = ShellEnvironment(sessionID: sessionID)
        }
        environment.setPositionalParams(arguments, scriptName: name)

        // Re-check: stop() may have landed while parsing — resetting the
        // token now would erase its cancellation. The interpreter also polls
        // the stop flag via isLocallyCancelled as a backstop for the
        // unavoidable window between this check and the reset.
        guard !hasStopped else { return }

        // Reset cancellation token
        scriptCancellationToken.reset()

        // Interpreter output is pure LF; convert at the terminal boundary
        let lfNormalizer = LFNormalizer()

        // Create interpreter with wired callbacks
        let interpreter = ShellInterpreter(
            environment: environment,
            cancellationToken: scriptCancellationToken,
            executeExternal: { [weak self] command -> Int32 in
                guard let self else { return 127 }
                return self.runScriptExternalCommand(command)
            },
            captureExternal: { [weak self] command -> (Int32, String) in
                guard let self else { return (127, "") }
                return self.captureCommandOutput(command)
            },
            streamExternal: { [weak self] command, inputProvider, outputSink -> Int32 in
                guard let self else { return 127 }
                return self.streamExternalCommand(command, inputProvider: inputProvider, outputSink: outputSink)
            },
            canStreamExternalCommand: { [weak self] command -> Bool in
                guard let self else { return false }
                return self.canStreamExternalPipelineCommand(command)
            },
            requiresOwnExternalPipelineStage: { [weak self] command -> Bool in
                guard let self else { return false }
                return self.requiresOwnExternalPipelineStage(command)
            },
            backgroundStreamExternal: makeBackgroundStreamExternal(),
            isLocallyCancelled: { [weak self] in
                self?.hasStopped ?? true
            },
            writeOutput: { [weak self] data in
                guard let self else { return }
                self.outputBatcher.enqueue(lfNormalizer.normalize(data))
            },
            readLine: { [weak self] prompt, silent -> String? in
                guard let self else { return nil }
                return self.blockingReadFromTerminal(prompt: prompt, silent: silent)
            }
        )

        // Store interpreter reference for cancellation (via MainActor)
        Task { @MainActor [weak self] in
            self?.activeShellInterpreter = interpreter
        }

        // Execute
        do {
            let exitCode = try interpreter.execute(ast)

            // Run EXIT trap if registered
            if let exitTrap = interpreter.trapRegistry.getHandler(for: TrapRegistry.Signal.exit) {
                // Fresh token so trap can complete
                let trapToken = CancellationToken()
                let trapInterp = ShellInterpreter(
                    environment: environment,
                    cancellationToken: trapToken,
                    executeExternal: interpreter.executeExternal,
                    captureExternal: interpreter.captureExternal,
                    // Trap bodies can contain pipelines. Without streamExternal,
                    // executePipeline throws .unsupported("pipelines with external
                    // commands") and the `try?` below swallows it, so the trap
                    // silently never ran. Forward the parent's streaming executor.
                    streamExternal: interpreter.streamExternal,
                    canStreamExternalCommand: { [weak self] command -> Bool in
                        guard let self else { return false }
                        return self.canStreamExternalPipelineCommand(command)
                    },
                    writeOutput: interpreter.writeOutput,
                    readLine: { _, _ in nil }
                )
                // 5-second timeout
                let deadline = DispatchTime.now() + 5.0
                DispatchQueue.global().asyncAfter(deadline: deadline) { trapToken.cancel() }
                _ = try? trapInterp.execute(exitTrap)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastCommandSucceeded = (exitCode == 0)
                self.recoverFromScriptExecution()
            }
        } catch ShellError.cancelled {
            // Run INT trap if registered
            if let intTrap = interpreter.trapRegistry.getHandler(for: TrapRegistry.Signal.int) {
                let trapToken = CancellationToken()
                let trapInterp = ShellInterpreter(
                    environment: environment,
                    cancellationToken: trapToken,
                    executeExternal: interpreter.executeExternal,
                    captureExternal: interpreter.captureExternal,
                    // Trap bodies can contain pipelines. Without streamExternal,
                    // executePipeline throws .unsupported("pipelines with external
                    // commands") and the `try?` below swallows it, so the trap
                    // silently never ran. Forward the parent's streaming executor.
                    streamExternal: interpreter.streamExternal,
                    canStreamExternalCommand: { [weak self] command -> Bool in
                        guard let self else { return false }
                        return self.canStreamExternalPipelineCommand(command)
                    },
                    writeOutput: interpreter.writeOutput,
                    readLine: { _, _ in nil }
                )
                let deadline = DispatchTime.now() + 5.0
                DispatchQueue.global().asyncAfter(deadline: deadline) { trapToken.cancel() }
                _ = try? trapInterp.execute(intTrap)
            }

            // Run EXIT trap
            if let exitTrap = interpreter.trapRegistry.getHandler(for: TrapRegistry.Signal.exit) {
                let trapToken = CancellationToken()
                let trapInterp = ShellInterpreter(
                    environment: environment,
                    cancellationToken: trapToken,
                    executeExternal: interpreter.executeExternal,
                    captureExternal: interpreter.captureExternal,
                    // Trap bodies can contain pipelines. Without streamExternal,
                    // executePipeline throws .unsupported("pipelines with external
                    // commands") and the `try?` below swallows it, so the trap
                    // silently never ran. Forward the parent's streaming executor.
                    streamExternal: interpreter.streamExternal,
                    canStreamExternalCommand: { [weak self] command -> Bool in
                        guard let self else { return false }
                        return self.canStreamExternalPipelineCommand(command)
                    },
                    writeOutput: interpreter.writeOutput,
                    readLine: { _, _ in nil }
                )
                let deadline = DispatchTime.now() + 5.0
                DispatchQueue.global().asyncAfter(deadline: deadline) { trapToken.cancel() }
                _ = try? trapInterp.execute(exitTrap)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastCommandSucceeded = false
                self.scriptCommandExitCode = 130
                self.recoverFromScriptExecution()
            }
        } catch ShellError.exitSignal(let code) {
            // Run EXIT trap
            if let exitTrap = interpreter.trapRegistry.getHandler(for: TrapRegistry.Signal.exit) {
                let trapToken = CancellationToken()
                let trapInterp = ShellInterpreter(
                    environment: environment,
                    cancellationToken: trapToken,
                    executeExternal: interpreter.executeExternal,
                    captureExternal: interpreter.captureExternal,
                    // Trap bodies can contain pipelines. Without streamExternal,
                    // executePipeline throws .unsupported("pipelines with external
                    // commands") and the `try?` below swallows it, so the trap
                    // silently never ran. Forward the parent's streaming executor.
                    streamExternal: interpreter.streamExternal,
                    canStreamExternalCommand: { [weak self] command -> Bool in
                        guard let self else { return false }
                        return self.canStreamExternalPipelineCommand(command)
                    },
                    writeOutput: interpreter.writeOutput,
                    readLine: { _, _ in nil }
                )
                let deadline = DispatchTime.now() + 5.0
                DispatchQueue.global().asyncAfter(deadline: deadline) { trapToken.cancel() }
                _ = try? trapInterp.execute(exitTrap)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastCommandSucceeded = (code == 0)
                self.recoverFromScriptExecution()
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastCommandSucceeded = false
                self.scriptCommandExitCode = 1
                self.onOutput?(self.normalizeLineEndings("sh: \(error.localizedDescription)\n"))
                self.recoverFromScriptExecution()
            }
        }
    }

    // MARK: - App Command Routing for Scripts

    private enum InterceptedAppCommand: Sendable {
        case interactive(name: String, description: String)
        case ssh
        case reset
    }

    nonisolated private func commandNameForScriptRouting(in command: String) -> String? {
        let tokenizer = ShellTokenizer(source: command)

        while true {
            switch tokenizer.next() {
            case .assignmentWord(_, _), .redirect(_), .heredoc(_, _):
                continue
            case .word(let word):
                return word.lowercased()
            case .eof, .newline, .semicolon, .pipe, .andIf, .orIf, .ampersand,
                 .lparen, .rparen, .dsemi:
                return nil
            default:
                return nil
            }
        }
    }

    nonisolated private func interceptedAppCommand(in command: String) -> InterceptedAppCommand? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cmdName = commandNameForScriptRouting(in: trimmed) else {
            return nil
        }

        switch cmdName {
        case "mosh", "roam":
            return .interactive(name: cmdName, description: "interactive command")
        case "tssh", "trzsz":
            return .interactive(name: cmdName, description: "interactive command")
        case "hx":
            return .interactive(name: cmdName, description: "interactive editor")
        case "ssh":
            return .ssh
        case "reset":
            return .reset
        default:
            return nil
        }
    }

    nonisolated func canStreamExternalPipelineCommand(_ command: String) -> Bool {
        // Every intercepted handler writes straight to the terminal display
        // and can't honour pipe semantics, so they bail out of streaming.
        interceptedAppCommand(in: command) == nil
    }

    /// True when a command must be its own pipeline stage rather than being
    /// bundled with neighbouring externals into a single rendered-with-`|`
    /// command string. Nothing this fork intercepts needs that.
    nonisolated func requiresOwnExternalPipelineStage(_ command: String) -> Bool {
        false
    }

    /// Check if a command is a Swift-native app command and execute it synchronously.
    /// Returns the exit code if handled, or nil to fall through to ios_system.
    ///
    /// Commands that require interactive terminal control (mosh, hx, trzsz)
    /// return an error instead. Commands that can run non-interactively are dispatched
    /// to MainActor via semaphore bridging.
    nonisolated func routeAppCommand(_ command: String) -> Int32? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch interceptedAppCommand(in: trimmed) {
        case .interactive(let name, let description):
            outputSink.emitString("sh: \(name): \(description), not available in scripts\r\n")
            return 1
        case .ssh:
            return bridgeToMainActor { self.handleSSHCommand(trimmed) }
        case .reset:
            return bridgeToMainActor { self.handleResetCommand(trimmed) }
        case nil:
            return nil
        }
    }

    /// Bridge a MainActor-isolated command handler to run synchronously from commandQueue.
    /// Waits for the command to complete (displayPrompt signals completion) before returning.
    ///
    /// All app command handlers eventually call `displayPrompt()` when they finish —
    /// whether immediately (error/help cases) or after an async operation (SSH session
    /// exit, ping completion, etc.). We intercept `displayPrompt()` to signal the
    /// semaphore instead of showing the prompt.
    ///
    /// IMPORTANT: We must NOT try to detect synchronous completion by checking
    /// `sessionMode == .localShell` after the handler returns. Many handlers
    /// (SSH, ping, mtr) are async — they return immediately while the operation
    /// runs on a different thread/task. The session mode changes later.
    nonisolated private func bridgeToMainActor(_ handler: @escaping @MainActor () -> Void) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }

            // Install completion callback. displayPrompt() will call this when
            // the command finishes, then set scriptCommandCompletion to nil.
            self.lastCommandSucceeded = true
            self.scriptCommandExitCode = nil
            self.scriptCommandCompletion = {
                semaphore.signal()
            }

            handler()

            // Do NOT signal here — wait for displayPrompt() to fire.
            // Handlers are async (SSH connects, ping probes, etc.) and return
            // before the operation completes. displayPrompt() is the only
            // reliable signal that the command is truly done.
        }

        // Wait for completion, checking cancellation periodically
        var waitedTenths = 0
        while true {
            let result = semaphore.wait(timeout: .now() + 0.1)
            if result == .success { break }
            waitedTenths += 1
            if waitedTenths == 300 {
                // Diagnostic breadcrumb for handlers that never reach
                // displayPrompt() — no timeout (long SSH sessions are valid)
                Self.logger.warning("bridgeToMainActor: still waiting on a handler after 30s")
            }
            if scriptCancellationToken.isCancelled {
                // Cancel the running command
                Task { @MainActor [weak self] in
                    self?.interrupt()
                }
                _ = semaphore.wait(timeout: .now() + 2.0) // Give it time to clean up
                return 130
            }
        }

        let statusSemaphore = DispatchSemaphore(value: 0)
        // The semaphore is the happens-before edge for these hand-offs.
        nonisolated(unsafe) var exitCode: Int32 = 0
        Task { @MainActor [weak self] in
            if let explicit = self?.scriptCommandExitCode {
                exitCode = explicit
            } else {
                exitCode = (self?.lastCommandSucceeded ?? true) ? 0 : 1
            }
            self?.scriptCommandCompletion = nil
            self?.scriptCommandExitCode = nil
            statusSemaphore.signal()
        }
        statusSemaphore.wait()
        return exitCode
    }

    // MARK: - Synchronous External Command Execution

    /// Detect unquoted redirection, pipe, sequencing, or logical operators in
    /// a reconstructed command string. Used to decide whether to bypass native
    /// app-command interception (which can't implement these operators) and
    /// hand execution to ios_system instead.
    nonisolated static func commandContainsUnquotedShellOperator(_ command: String) -> Bool {
        commandContainsUnquotedOperator(command)
    }

    nonisolated private static func commandContainsUnquotedOperator(_ command: String) -> Bool {
        let scalars = Array(command.unicodeScalars)
        var i = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\" && !inSingleQuote {
                i += (i + 1 < scalars.count) ? 2 : 1
                continue
            }
            if c == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                i += 1
                continue
            }
            if c == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                i += 1
                continue
            }
            if inSingleQuote || inDoubleQuote {
                i += 1
                continue
            }
            switch c {
            case ">", "<", "|", ";", "&":
                return true
            default:
                break
            }
            i += 1
        }
        return false
    }

    /// Execute a single command via ios_system synchronously (for use by the interpreter).
    /// Simpler than `runExternalCommand()`: no async handle, output goes through batcher.
    nonisolated func runScriptExternalCommand(_ command: String) -> Int32 {
        // Check cancellation before starting
        guard !scriptCancellationToken.isCancelled else { return 130 }

        // Skip native-handler interception when the reconstructed command carries
        // shell redirection / pipeline / sequencing syntax. Handlers like
        // `handleBssidCommand` write straight to the terminal and can't honour
        // `>`, `<`, `|`, `;`, `&&`, `||`, or `&`; ios_system parses these
        // natively. Matches the top-level routing behaviour in
        // `handleCommandSubmission`, where `bssid`, `whatismyip`, `mtr --report`,
        // and the non-intercepted git path are dispatched through ios_system
        // specifically for pipe/redirect support.
        if !Self.commandContainsUnquotedShellOperator(command),
           let exitCode = routeAppCommand(command) {
            return exitCode
        }

        // Reset output normalization for each command in the script.
        // Without this, a command that emits escape sequences (triggering the
        // ScreenControlDetector) would disable LF→CRLF normalization for all
        // subsequent commands, causing intermittent staircasing.
        outputNormalizationLock.withLock { shouldNormalizeOutput = true }
        interactiveLock.withLock { isCurrentCommandInteractive = false }
        fullScreenLock.withLock { isFullScreenCommand = false }

        let sessionPtr = IOSSystemSessionKey.key(for: self.sessionID)
        ios_switchSession(sessionPtr)

        // Create pipes for output capture
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var stdinPipe: [Int32] = [-1, -1]

        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0, pipe(&stdinPipe) == 0 else {
            return 1
        }

        guard let stdinFile = fdopen(stdinPipe[0], "r"),
              let stdoutFile = fdopen(stdoutPipe[1], "w"),
              let stderrFile = fdopen(stderrPipe[1], "w") else {
            close(stdinPipe[0]); close(stdinPipe[1])
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            return 1
        }

        setvbuf(stdinFile, nil, _IONBF, 0)
        setvbuf(stdoutFile, nil, _IONBF, 0)
        setvbuf(stderrFile, nil, _IONBF, 0)

        // Store stdin write FD for forwarding input during command execution
        stdinLock.withLock {
            commandStdinWriteFd = stdinPipe[1]
            inputMode = .commandStdin
        }

        // Monitor output pipe on background thread
        let stdoutReadFd = stdoutPipe[0]
        let stderrReadFd = stderrPipe[0]

        // Set non-blocking for output monitoring
        _ = fcntl(stdoutReadFd, F_SETFL, fcntl(stdoutReadFd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderrReadFd, F_SETFL, fcntl(stderrReadFd, F_GETFL) | O_NONBLOCK)

        let monitorGroup = DispatchGroup()
        let batcher = outputBatcher

        let stdoutSource = makePipeReadSource(fd: stdoutReadFd, name: "script-stdout",
                                               group: monitorGroup, batcher: batcher)
        let stderrSource = makePipeReadSource(fd: stderrReadFd, name: "script-stderr",
                                               group: monitorGroup, batcher: batcher)

        // Set streams for ios_system
        ios_setStreams(stdinFile, stdoutFile, stderrFile)

        // Create TTY for proper shell behavior
        let ttyFd = dup(fileno(stdinFile))
        let tty = fdopen(ttyFd, "rb")
        if tty != nil {
            ios_settty(tty)
        }

        // Configure async execution
        var options = ios_async_default_options()
        options.input = stdinFile
        options.output = stdoutFile
        options.error = stderrFile
        options.session = UnsafeMutableRawPointer(mutating: sessionPtr)
        options.timeout_ms = -1

        // Execute
        let cmdHandle = ios_system_async(command, &options)

        // Store for interruption support
        pidLock.withLock {
            currentCommand = cmdHandle
            if let handle = cmdHandle {
                currentPid = ios_command_get_pid(handle)
            }
        }

        // Wait for completion
        var result: Int32 = -1
        if let handle = cmdHandle {
            result = ios_command_wait(handle)

            pidLock.withLock {
                currentCommand = nil
                currentPid = nil
                forceKillScheduled = false
            }

            ios_command_release(handle)
        }

        // Clean up stdin forwarding state
        let stdinWriteFd = stdinLock.withLock {
            let fd = commandStdinWriteFd
            commandStdinWriteFd = -1
            inputMode = .lineEditor
            return fd
        }

        // Close stdin write end
        if stdinWriteFd >= 0 {
            close(stdinWriteFd)
        }

        // Clean up TTY
        if tty != nil {
            fclose(tty)
            ios_settty(nil)
        }

        // Reset streams
        ios_setStreams(stdin, stdout, stderr)

        // Close command's FILE* streams
        fflush(stdoutFile)
        fflush(stderrFile)
        fclose(stdinFile)
        fclose(stdoutFile)
        fclose(stderrFile)

        // Wait for output monitoring to drain
        stdoutSource.cancel()
        stderrSource.cancel()
        monitorGroup.wait()

        return result
    }

    // MARK: - Command Output Capture (for $(...) substitution)

    /// Execute a command via ios_system and capture its stdout as a string.
    /// Unlike `runScriptExternalCommand`, output is collected into a buffer
    /// instead of being sent to the terminal output batcher.
    ///
    /// Built on `streamExternalCommand`: output is drained concurrently while
    /// the command runs (the old synchronous-`ios_system` version deadlocked
    /// once output exceeded the 64KB pipe buffer), the handle is registered
    /// for Ctrl-C kill, stdin is immediate-EOF so `$(cat)` can't wedge, and
    /// stderr goes to the terminal per POSIX substitution semantics.
    nonisolated func captureCommandOutput(_ command: String) -> (Int32, String) {
        // captureLock is what serializes access; the compiler can't see that.
        nonisolated(unsafe) var captured = Data()
        let captureLock = UnfairLock()
        let exitCode = streamExternalCommand(command, inputProvider: nil,
                                             allowAppCommandRouting: false) { chunk in
            captureLock.withLock { captured.append(chunk) }
            return true
        }
        let output = captureLock.withLock { String(data: captured, encoding: .utf8) ?? "" }
        return (exitCode, output)
    }

    // MARK: - Streaming Command Output (for pipeline stages)

    /// Execute a command via ios_system with streaming output for pipeline stages.
    /// Instead of buffering all output, each chunk of stdout is passed to `outputSink`.
    /// If `outputSink` returns `false`, the command is killed (SIGPIPE equivalent).
    /// Optionally pulls stdin chunks from `inputProvider`.
    /// `allowAppCommandRouting: false` skips the native app-command handlers
    /// (they write to the terminal, not the pipe) and lets ios_system serve
    /// the command instead — used by `$(...)` capture, where e.g. `$(ssh ...)`
    /// must capture ssh_cmd's stdout rather than launch the interactive
    /// native SSH path.
    nonisolated func streamExternalCommand(
        _ command: String,
        inputProvider: (@Sendable () -> Data?)?,
        allowAppCommandRouting: Bool = true,
        outputSink: @escaping @Sendable (Data) -> Bool
    ) -> Int32 {
        guard !scriptCancellationToken.isCancelled else { return 130 }

        // Intercepted commands aren't pipe-aware, so they stay on the
        // `routeAppCommand` path as a safety net (the streaming gate already
        // rejects them).
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if interceptedAppCommand(in: trimmed) != nil,
           allowAppCommandRouting,
           let exitCode = routeAppCommand(trimmed) {
            return exitCode
        }

        outputNormalizationLock.withLock { shouldNormalizeOutput = true }
        interactiveLock.withLock { isCurrentCommandInteractive = false }
        fullScreenLock.withLock { isFullScreenCommand = false }

        let sessionPtr = IOSSystemSessionKey.key(for: self.sessionID)
        ios_switchSession(sessionPtr)

        // Create pipes
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var stdinPipe: [Int32] = [-1, -1]

        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0, pipe(&stdinPipe) == 0 else {
            return 1
        }

        guard let stdinFile = fdopen(stdinPipe[0], "r"),
              let stdoutFile = fdopen(stdoutPipe[1], "w"),
              let stderrFile = fdopen(stderrPipe[1], "w") else {
            close(stdinPipe[0]); close(stdinPipe[1])
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            return 1
        }

        setvbuf(stdinFile, nil, _IONBF, 0)
        setvbuf(stdoutFile, nil, _IONBF, 0)
        setvbuf(stderrFile, nil, _IONBF, 0)

        let stdinWriteFd = stdinPipe[1]
        let stdoutReadFd = stdoutPipe[0]
        let stderrReadFd = stderrPipe[0]
        _ = fcntl(stdinWriteFd, F_SETNOSIGPIPE, 1)
        let cancellationToken = scriptCancellationToken
        let terminalOutputSink = self.outputSink
        let writerGroup = DispatchGroup()
        var filesClosed = false
        var readEndsClosed = false
        var releasedHandle: OpaquePointer?

        func closeCommandFilesIfNeeded() {
            guard !filesClosed else { return }
            filesClosed = true
            fflush(stdoutFile)
            fflush(stderrFile)
            fclose(stdinFile)
            fclose(stdoutFile)
            fclose(stderrFile)
        }

        func closeReadEndsIfNeeded() {
            guard !readEndsClosed else { return }
            readEndsClosed = true
            close(stdoutReadFd)
            close(stderrReadFd)
        }

        defer {
            closeReadEndsIfNeeded()
            closeCommandFilesIfNeeded()
            if let releasedHandle {
                pidLock.withLock {
                    activeScriptCommandHandles.removeAll { $0 == releasedHandle }
                }
                ios_command_release(releasedHandle)
            }
            _ = writerGroup.wait(timeout: .now() + 1.0)
        }

        // Configure async execution
        var options = ios_async_default_options()
        options.input = stdinFile
        options.output = stdoutFile
        options.error = stderrFile
        options.session = UnsafeMutableRawPointer(mutating: sessionPtr)
        options.timeout_ms = -1

        guard let cmdHandle = ios_system_async(command, &options) else {
            close(stdinWriteFd)
            return 1
        }
        releasedHandle = cmdHandle

        // Stream stdout to sink
        _ = fcntl(stdoutReadFd, F_SETFL, fcntl(stdoutReadFd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderrReadFd, F_SETFL, fcntl(stderrReadFd, F_GETFL) | O_NONBLOCK)
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        defer { readBuf.deallocate() }

        pidLock.withLock {
            activeScriptCommandHandles.append(cmdHandle)
        }

        if let inputProvider {
            writerGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    close(stdinWriteFd)
                    writerGroup.leave()
                }

                while !cancellationToken.isCancelled, let chunk = inputProvider(), !chunk.isEmpty {
                    let writeResult = chunk.withUnsafeBytes { rawBuffer -> Bool in
                        guard let baseAddress = rawBuffer.baseAddress else { return true }
                        var remaining = rawBuffer.count
                        var offset = 0
                        while remaining > 0 {
                            let written = Darwin.write(stdinWriteFd, baseAddress.advanced(by: offset), remaining)
                            if written > 0 {
                                offset += written
                                remaining -= written
                                continue
                            }
                            if written == -1 && errno == EINTR {
                                continue
                            }
                            return false
                        }
                        return true
                    }

                    if !writeResult {
                        return
                    }
                }
            }
        } else {
            close(stdinWriteFd)
        }

        var sinkClosed = false
        var wasCancelled = false
        var stdoutEOF = false
        var stderrEOF = false

        func drain(_ fd: Int32, sink: ((Data) -> Bool)? = nil, eofFlag: inout Bool) -> Bool {
            var didRead = false
            while true {
                let bytesRead = read(fd, readBuf, 8192)
                if bytesRead > 0 {
                    didRead = true
                    if let sink {
                        let chunk = Data(bytes: readBuf, count: bytesRead)
                        if !sink(chunk) {
                            sinkClosed = true
                            ios_command_kill(cmdHandle)
                            return true
                        }
                    }
                    continue
                }

                if bytesRead == 0 {
                    eofFlag = true
                    return didRead
                }

                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    return didRead
                }
                if err == EINTR {
                    continue
                }
                eofFlag = true
                return didRead
            }
        }

        while true {
            var didWork = false

            if !stdoutEOF {
                didWork = drain(stdoutReadFd, sink: outputSink, eofFlag: &stdoutEOF) || didWork
            }
            if !stderrEOF {
                didWork = drain(stderrReadFd, sink: { chunk in
                    terminalOutputSink.emit(chunk)
                    return true
                }, eofFlag: &stderrEOF) || didWork
            }

            if cancellationToken.isCancelled && !wasCancelled {
                wasCancelled = true
                ios_command_kill(cmdHandle)
            }

            if ios_command_try_wait(cmdHandle, nil) {
                closeCommandFilesIfNeeded()
            }

            if filesClosed && stdoutEOF && stderrEOF {
                break
            }

            if !didWork {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // Wait for command completion
        let result = ios_command_wait(cmdHandle)
        return wasCancelled ? 130 : (sinkClosed ? 141 : result)  // 141 = 128 + SIGPIPE(13)
    }

    /// Streaming executor for background jobs: routing to native app-command
    /// handlers is disabled (they own the prompt/session lifecycle and can't
    /// run detached — the command falls through to ios_system instead), and
    /// wasm is refused (single-process runtime tied to session mode). This is
    /// the execution-time backstop behind the static launch gate, catching
    /// dynamically-named commands like `c=ssh; $c host &`.
    nonisolated func makeBackgroundStreamExternal()
        -> @Sendable (String, (@Sendable () -> Data?)?, @escaping @Sendable (Data) -> Bool) -> Int32 {
        { [weak self] command, inputProvider, outputSink in
            guard let self else { return 127 }
            if self.requiresOwnExternalPipelineStage(command) {
                self.outputSink.emitString("sh: cannot background wasm programs\r\n")
                return 127
            }
            return self.streamExternalCommand(command, inputProvider: inputProvider,
                                              allowAppCommandRouting: false,
                                              outputSink: outputSink)
        }
    }

    // MARK: - Blocking Read from Terminal

    /// Block commandQueue until user types a line (for `read` builtin).
    /// When `silent` is true, character echo is suppressed (for `read -s`).
    nonisolated func blockingReadFromTerminal(prompt: String?, silent: Bool = false) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        // The semaphore is the happens-before edge for the hand-off.
        nonisolated(unsafe) var result: String?

        Task { @MainActor [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }

            if let prompt {
                self.onOutput?(prompt)
            }

            self.scriptReadBuffer = ""
            self.scriptReadSilent = silent
            self.readLineContinuation = { line in
                result = line
                semaphore.signal()
            }
            self.sessionMode = .scriptReadPrompt
        }

        // Poll with cancellation check
        while true {
            let waitResult = semaphore.wait(timeout: .now() + 0.1)
            if waitResult == .success {
                return result
            }
            // Check cancellation
            if scriptCancellationToken.isCancelled {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.readLineContinuation = nil
                    self.sessionMode = .scriptRunning
                }
                return nil
            }
        }
    }

    // MARK: - State Recovery

    /// Restore LocalShellSession to a clean state after script completion or interruption.
    func recoverFromScriptExecution() {
        // A stopped session must not be resurrected: resetting the token,
        // emitting output, or displaying a prompt would allocate fresh
        // ios_system state after teardown released it.
        guard isRunning else {
            activeShellInterpreter = nil
            readLineContinuation = nil
            return
        }

        // Clear interpreter reference
        activeShellInterpreter = nil
        readLineContinuation = nil
        scriptReadBuffer = ""
        scriptReadSilent = false

        // Reset session mode
        sessionMode = .localShell

        // Reset cancellation token for next execution
        scriptCancellationToken.reset()

        // Clear type-ahead buffer
        typeAheadBuffer.removeAll()

        // Reset input mode
        stdinLock.withLock {
            inputMode = .lineEditor
        }

        // Reset interactive/full-screen state
        interactiveLock.withLock { isCurrentCommandInteractive = false }
        fullScreenLock.withLock { isFullScreenCommand = false }
        outputNormalizationLock.withLock { shouldNormalizeOutput = true }

        // Invalidate prompt cache (directory may have changed)
        promptCache.invalidate()

        // Flush pending output and display prompt (the session can stop
        // between the flush and the completion — re-check before prompting)
        outputBatcher.flush { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.displayPrompt()
            }
        }
    }

    // MARK: - Script Detection

    /// Check if a file path points to a shell script (hashbang or .sh extension).
    func isShellScript(at path: String) -> Bool {
        let resolvedPath = resolveScriptPath(path)

        // Check extension
        if resolvedPath.hasSuffix(".sh") { return true }

        // Check hashbang
        guard let data = FileManager.default.contents(atPath: resolvedPath),
              data.count >= 2,
              data[0] == 0x23, data[1] == 0x21 else { // #!
            return false
        }

        // Read first line
        if let firstLine = String(data: data.prefix(128), encoding: .utf8)?
            .components(separatedBy: .newlines).first {
            let shebangs = ["/bin/sh", "/bin/bash", "/usr/bin/env sh", "/usr/bin/env bash"]
            for shebang in shebangs {
                if firstLine.contains(shebang) { return true }
            }
        }

        return false
    }

    /// Resolve a script path relative to current working directory.
    func resolveScriptPath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        if path.hasPrefix("~/") {
            let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return (sessionCurrentDirectory as NSString).appendingPathComponent(path)
    }
}

#endif
