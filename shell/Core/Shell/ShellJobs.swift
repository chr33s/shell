#if !targetEnvironment(macCatalyst)

import Foundation

/// Background job table for `cmd &`, `jobs`, `wait`, and `$!`.
///
/// Jobs run in a sub-interpreter with a snapshotted environment (subshell
/// semantics) on a concurrent queue. There is no fork on iOS, so "pids" are
/// synthetic identifiers used only for `$!`/`wait` bookkeeping.
nonisolated final class ShellJobTable: @unchecked Sendable {
    enum Status: Equatable {
        case running
        case done(Int32)
    }

    struct Job {
        let id: Int
        let pid: Int32
        let command: String
        var status: Status
        let cancellationToken: CancellationToken
    }

    private let lock = UnfairLock()
    private var jobs: [Int: Job] = [:]
    private var nextID = 1
    private var lastPid: Int32 = 0

    /// Synthetic pid base — well clear of ios_system's pid range.
    private static let pidBase: Int32 = 30000

    var lastBackgroundPid: Int32 {
        lock.withLock { lastPid }
    }

    func register(command: String, cancellationToken: CancellationToken) -> Job {
        lock.withLock {
            let id = nextID
            nextID += 1
            let job = Job(id: id, pid: Self.pidBase + Int32(id), command: command,
                          status: .running, cancellationToken: cancellationToken)
            jobs[id] = job
            lastPid = job.pid
            return job
        }
    }

    func markDone(id: Int, exitCode: Int32) {
        lock.withLock {
            jobs[id]?.status = .done(exitCode)
        }
    }

    /// Remove finished jobs after they've been reported (by `jobs` or `wait`).
    func reap(ids: [Int]) {
        lock.withLock {
            for id in ids { jobs.removeValue(forKey: id) }
        }
    }

    func all() -> [Job] {
        lock.withLock { jobs.values.sorted { $0.id < $1.id } }
    }

    func job(withPid pid: Int32) -> Job? {
        lock.withLock { jobs.values.first { $0.pid == pid } }
    }

    func job(withID id: Int) -> Job? {
        lock.withLock { jobs[id] }
    }

    var hasRunningJobs: Bool {
        lock.withLock { jobs.values.contains { $0.status == .running } }
    }

    /// Cancel every running job (session teardown).
    func cancelAll() {
        let running = lock.withLock { jobs.values.filter { $0.status == .running } }
        for job in running { job.cancellationToken.cancel() }
    }
}

// MARK: - Background execution

nonisolated extension ShellInterpreter {

    /// Launch `command &`. The job is gated to backends that are safe to run
    /// detached from the terminal: interpreter-native work (builtins,
    /// functions, pipelines) and non-interactive ios_system commands.
    /// Native app commands (ssh, git, ping, ...) and wasm are refused —
    /// they own the prompt lifecycle / session mode and can't run headless.
    func launchBackgroundJob(_ command: ShellCommand) throws -> Int32 {
        if let refusal = backgroundRefusalReason(command) {
            writeLine("sh: cannot background: \(refusal)")
            environment.setLastExitCode(1)
            return 1
        }

        let jobToken = CancellationToken()
        let job = environment.jobTable.register(command: describeCommand(command),
                                                cancellationToken: jobToken)

        // Subshell semantics: the job sees a snapshot of the current
        // environment; its mutations don't leak back.
        let jobEnvironment = environment.makeIsolatedCopy()

        // Externals run through the background streaming channel, never the
        // plain executeExternal path: runScriptExternalCommand mutates the
        // session's single-slot currentCommand/stdin/TTY state, which the
        // foreground shell owns. The channel also disables native app-command
        // routing at execution time, so dynamically-named commands
        // (`c=ssh; $c host &`) can't reach an interactive handler either.
        let stream = backgroundStreamExternal
        let jobOutput = writeOutput
        let jobExecuteExternal: @Sendable (String) -> Int32 = { command in
            guard let stream else { return 127 }
            return stream(command, nil) { chunk in
                jobOutput(chunk)
                return true
            }
        }

        let jobInterpreter = ShellInterpreter(
            environment: jobEnvironment,
            cancellationToken: jobToken,
            executeExternal: jobExecuteExternal,
            captureExternal: captureExternal,
            streamExternal: backgroundStreamExternal,
            canStreamExternalCommand: canStreamExternalCommand,
            requiresOwnExternalPipelineStage: requiresOwnExternalPipelineStage,
            backgroundStreamExternal: backgroundStreamExternal,
            writeOutput: writeOutput,
            readLine: { _, _ in nil } // background jobs get EOF stdin
        )

        let table = environment.jobTable
        let notify = writeOutput
        DispatchQueue.global(qos: .utility).async {
            var code: Int32
            do {
                code = try jobInterpreter.execute(command)
            } catch ShellError.exitSignal(let c) {
                code = c
            } catch ShellError.cancelled {
                code = 130
            } catch {
                code = 1
            }
            table.markDone(id: job.id, exitCode: code)
            let status = code == 0 ? "Done" : "Exit \(code)"
            notify(Data("[\(job.id)] \(status)    \(job.command)\n".utf8))
        }

        writeLine("[\(job.id)] \(job.pid)")
        environment.setLastExitCode(0)
        return 0
    }

    /// Returns why a command can't be backgrounded, or nil when it's safe.
    /// Classification is static (no expansion — expanding here would run
    /// `$(...)` side effects at gate time). A command whose name is only
    /// known dynamically is allowed through; it executes via the streaming
    /// path either way. Descends into every compound body so constructs
    /// like `if true; then ssh host; fi &` are gated too.
    private func backgroundRefusalReason(_ command: ShellCommand) -> String? {
        switch command {
        case .simple(let simple):
            guard let firstWord = simple.words.first else { return nil }
            // Interpreter-native work (builtins, known functions) is safe
            if canRunWithoutExternal(command) { return nil }
            guard backgroundStreamExternal != nil else {
                return "external commands (no streaming backend)"
            }
            guard let name = Self.staticWordPrefixText(firstWord), !name.isEmpty else {
                return nil // dynamic command name — resolved at execution
            }
            if name == "wasm" || name.hasSuffix(".wasm") || requiresOwnExternalPipelineStage?(name) == true {
                return "wasm programs"
            }
            if canStreamExternalCommand?(name) == false {
                return "\(name) (interactive command)"
            }
            return nil
        case .pipeline(let cmds), .sequence(let cmds):
            for c in cmds {
                if let reason = backgroundRefusalReason(c) { return reason }
            }
            return nil
        case .andOr(let l, _, let r):
            return backgroundRefusalReason(l) ?? backgroundRefusalReason(r)
        case .negation(let c), .subshell(let c), .braceGroup(let c), .background(let c),
             .functionDef(_, let c):
            return backgroundRefusalReason(c)
        case .ifCmd(let clause):
            for branch in clause.branches {
                if let r = backgroundRefusalReason(branch.condition) ?? backgroundRefusalReason(branch.body) {
                    return r
                }
            }
            return clause.elseBranch.flatMap { backgroundRefusalReason($0) }
        case .forCmd(let clause):
            return backgroundRefusalReason(clause.body)
        case .whileCmd(let clause):
            return backgroundRefusalReason(clause.condition) ?? backgroundRefusalReason(clause.body)
        case .untilCmd(let clause):
            return backgroundRefusalReason(clause.condition) ?? backgroundRefusalReason(clause.body)
        case .caseCmd(let clause):
            for item in clause.items {
                if let body = item.body, let r = backgroundRefusalReason(body) { return r }
            }
            return nil
        case .doubleBracket:
            return nil
        }
    }

    /// Static (expansion-free) text of a word's leading literal content —
    /// enough to classify a command name without running substitutions.
    private static func staticWordPrefixText(_ word: ShellWord) -> String? {
        switch word {
        case .literal(let s), .singleQuoted(let s):
            return s
        case .doubleQuoted(let parts), .concat(let parts):
            guard let first = parts.first else { return "" }
            return staticWordPrefixText(first)
        case .variable, .paramExpansion, .commandSub, .arithmetic:
            return nil
        }
    }

    /// Job label without expansion (expanding would run `$(...)` here).
    private func describeCommand(_ command: ShellCommand) -> String {
        if case .simple(let simple) = command {
            let words = simple.words.map { Self.staticWordPrefixText($0) ?? "…" }
            if !words.isEmpty {
                return words.joined(separator: " ")
            }
        }
        return "(compound command)"
    }
}

// MARK: - jobs / wait builtins

nonisolated extension ShellBuiltins {

    static func builtinJobs(_ args: [String], _ env: ShellEnvironment,
                            _ interp: ShellInterpreter) -> Int32 {
        let jobs = env.jobTable.all()
        var reaped: [Int] = []
        for job in jobs {
            switch job.status {
            case .running:
                interp.writeLine("[\(job.id)]  Running    \(job.command)")
            case .done(let code):
                let status = code == 0 ? "Done" : "Exit \(code)"
                interp.writeLine("[\(job.id)]  \(status)    \(job.command)")
                reaped.append(job.id)
            }
        }
        env.jobTable.reap(ids: reaped)
        return 0
    }

    static func builtinWait(_ args: [String], _ env: ShellEnvironment,
                            _ interp: ShellInterpreter) throws -> Int32 {
        let table = env.jobTable

        // Resolve targets: no args = all jobs; `%N` = job id; digits = pid
        func targetIDs() -> [Int] {
            if args.isEmpty { return table.all().map { $0.id } }
            var ids: [Int] = []
            for arg in args {
                if arg.hasPrefix("%"), let id = Int(arg.dropFirst()) {
                    if table.job(withID: id) != nil { ids.append(id) }
                } else if let pid = Int32(arg), let job = table.job(withPid: pid) {
                    ids.append(job.id)
                }
            }
            return ids
        }

        let ids = targetIDs()
        var lastCode: Int32 = 0
        var done: [Int] = []
        for id in ids {
            while true {
                try interp.checkCancelled()
                guard let job = table.job(withID: id) else { break }
                if case .done(let code) = job.status {
                    lastCode = code
                    done.append(id)
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        table.reap(ids: done)
        return lastCode
    }
}

#endif
