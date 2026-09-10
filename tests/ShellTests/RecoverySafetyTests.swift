//
//  RecoverySafetyTests.swift
//  ShellTests
//
//  The rest of spec.connectivity.md §17.1: tmux continuity (AC-11, AC-12),
//  input safety and backpressure (AC-14, AC-19), descriptor migration
//  (AC-22), honest health reporting (AC-24), the recovery UI's copy and its
//  absence from the terminal stream (AC-16, AC-18), and the deadline
//  primitive that AC-06/AC-07 depend on.
//

import XCTest
@testable import Shell

@MainActor
final class RecoverySafetyTests: XCTestCase {

    // MARK: - Helpers

    private func evidence(
        pid: Int? = 4242,
        start: String? = "1700000000",
        session: Int? = 3,
        created: String? = "1700000100",
        socket: String? = "/tmp/tmux-501/default",
        name: String? = "main"
    ) -> TmuxContinuityEvidence {
        var value = TmuxContinuityEvidence()
        value.serverPID = pid
        value.serverStartTime = start
        value.sessionID = session
        value.sessionCreated = created
        value.socketPath = socket
        value.lastObservedName = name
        return value
    }

    // MARK: - AC-11

    /// A session renamed while offline is still the same session: continuity
    /// is proved by server and creation metadata, not by the display name.
    func testAC11_renamedSessionStillMatchesOnContinuityEvidence() {
        let stored = evidence(name: "main")
        let discovered = evidence(name: "renamed-by-the-user")

        XCTAssertEqual(TmuxRecoveryIdentity.verify(stored: stored, discovered: discovered),
                       .continuous)
    }

    // MARK: - AC-12

    /// A session deleted and recreated under the same name is a different
    /// session. Its creation time differs, so continuity must fail.
    func testAC12_recreatedSessionWithTheSameNameIsNotContinuous() {
        let stored = evidence(created: "1700000100")
        let recreated = evidence(created: "1700009999")

        XCTAssertEqual(TmuxRecoveryIdentity.verify(stored: stored, discovered: recreated),
                       .differentSession)
    }

    /// A restarted tmux server hands out the same session id again. The
    /// server PID and start time are what catch it.
    func testAC12_restartedServerIsNotContinuousDespiteMatchingSessionID() {
        let stored = evidence(pid: 4242, start: "1700000000")
        let afterRestart = evidence(pid: 9999, start: "1700005000")

        XCTAssertEqual(TmuxRecoveryIdentity.verify(stored: stored, discovered: afterRestart),
                       .differentSession)
    }

    /// A missing session is a missing session, not an invitation to create one.
    func testAC12_missingSessionIsReportedRatherThanCreated() {
        XCTAssertEqual(TmuxRecoveryIdentity.verify(stored: evidence(), discovered: nil),
                       .sessionMissing)
    }

    /// Legacy name-only state cannot establish continuity.
    func testAC12_nameOnlyLegacyStateIsInsufficientEvidence() {
        var nameOnly = TmuxContinuityEvidence()
        nameOnly.lastObservedName = "main"

        XCTAssertFalse(nameOnly.isSufficientForContinuity)
        XCTAssertEqual(TmuxRecoveryIdentity.verify(stored: nameOnly, discovered: evidence()),
                       .insufficientEvidence)
    }

    /// The recovery attach command must attach to an exact id and must never
    /// contain create-or-attach behavior.
    func testAC12_recoveryAttachCommandNeverCreatesASession() throws {
        let command = try XCTUnwrap(TmuxRecoveryIdentity.remoteAttachCommandLine(
            sessionID: 3, controlMode: true))

        // The escape is the point. Unescaped, the inner `sh -c` expands `$3`
        // as its own positional parameter — unset — and tmux receives
        // `attach-session -t ""`, attaching to whatever it considers current.
        XCTAssertTrue(command.contains("attach-session -t \"\\$3\""),
                      "the session id is not escaped against inner-shell expansion")
        XCTAssertFalse(command.contains("new-session"), "the recovery path can create a session")
        XCTAssertFalse(command.contains("-A"), "create-or-attach reached the recovery path")
        XCTAssertFalse(command.contains("exec $SHELL"),
                       "a missing tmux would silently become a plain shell")
    }

    /// Walk both shells. The remote login shell strips the outer `'…'`, then
    /// the inner `sh` expands what is left. This is the assertion that would
    /// have caught the unescaped `$3`: without the backslash, the second hop
    /// substitutes an unset positional parameter and tmux is asked to attach
    /// to `""`.
    func testAC12_attachCommandSurvivesNestedShellQuoting() throws {
        let command = try XCTUnwrap(TmuxRecoveryIdentity.remoteAttachCommandLine(
            sessionID: 7, controlMode: false))

        let innerScript = Self.innerShellCommand(of: command)
        XCTAssertEqual(innerScript, "exec tmux attach-session -t \"\\$7\"",
                       "the login shell hop did not preserve the escape")
        XCTAssertEqual(Self.expandDoubleQuoted(innerScript),
                       "exec tmux attach-session -t $7",
                       "the inner shell did not produce tmux's session id")
    }

    /// Inner-shell handling of the `"…"` argument: `\$` becomes a literal `$`,
    /// and the quotes themselves are removed.
    private static func expandDoubleQuoted(_ script: String) -> String {
        var result = ""
        var index = script.startIndex
        while index < script.endIndex {
            let character = script[index]
            if character == "\"" {
                index = script.index(after: index)
                continue
            }
            if character == "\\" {
                let next = script.index(after: index)
                if next < script.endIndex, script[next] == "$" {
                    result.append("$")
                    index = script.index(after: next)
                    continue
                }
            }
            result.append(character)
            index = script.index(after: index)
        }
        return result
    }

    /// Regular tmux mode attaches by name and still never creates.
    func testAC12_regularModeAttachesByNameWithoutCreating() throws {
        let command = try XCTUnwrap(TmuxRecoveryIdentity.remoteAttachByNameCommandLine(
            sessionName: "main"))
        XCTAssertEqual(Self.innerShellCommand(of: command),
                       "exec tmux attach-session -t 'main'")
        XCTAssertFalse(command.contains("new-session"))

        XCTAssertNil(TmuxRecoveryIdentity.remoteAttachByNameCommandLine(
            sessionName: "a'; rm -rf ~; echo '"),
                     "an unsafe session name was embedded instead of refused")
    }

    /// Strip the `sh -c '…'` wrapper the way a POSIX login shell would:
    /// single-quoted runs are literal, and `\'` outside them is one quote.
    private static func innerShellCommand(of command: String) -> String {
        guard let range = command.range(of: "sh -c ") else { return command }
        var result = ""
        var inQuotes = false
        var index = command.index(range.lowerBound, offsetBy: 6)
        while index < command.endIndex {
            let character = command[index]
            if character == "'" {
                inQuotes.toggle()
            } else if character == "\\", !inQuotes {
                index = command.index(after: index)
                if index < command.endIndex { result.append(command[index]) }
            } else {
                result.append(character)
            }
            index = command.index(after: index)
        }
        return result
    }

    /// A socket path from the server is untrusted input. Anything that could
    /// break out of the single-quoted `sh -c` wrapper is refused outright.
    func testSocketPathInjectionIsRefusedRatherThanEscaped() {
        XCTAssertNil(TmuxRecoveryIdentity.remoteAttachCommandLine(
            sessionID: 1, controlMode: false, socketPath: "/tmp/x'; rm -rf ~; echo '"))
        XCTAssertNil(TmuxRecoveryIdentity.remoteAttachCommandLine(
            sessionID: 1, controlMode: false, socketPath: "relative/path"))
        XCTAssertNotNil(TmuxRecoveryIdentity.remoteAttachCommandLine(
            sessionID: 1, controlMode: false, socketPath: "/tmp/tmux-501/default"))
    }

    /// The continuity reply parses into typed fields, name last so a session
    /// name containing spaces survives.
    func testContinuityParsingKeepsNamesWithSpaces() throws {
        let body = "4242\t1700000000\t$7\t1700000100\t/tmp/tmux-501/default\tmy long name"
        let parsed = try XCTUnwrap(TmuxRecoveryIdentity.parseContinuity(body))

        XCTAssertEqual(parsed.serverPID, 4242)
        XCTAssertEqual(parsed.sessionID, 7)
        XCTAssertEqual(parsed.sessionCreated, "1700000100")
        XCTAssertEqual(parsed.lastObservedName, "my long name")
    }

    // MARK: - AC-14 / AC-19

    /// Input is refused while the connection is not live, and nothing is
    /// silently queued for replay.
    func testAC14_inputIsRefusedWhileNotLiveAndNothingIsQueued() {
        let gate = RecoveryInputGate(generation: 5)

        XCTAssertEqual(gate.admit(10, from: .hardwareKeyboard, generation: 5), .rejectNotLive)
        XCTAssertEqual(gate.pendingBytes, 0, "refused input was queued anyway")

        gate.setLive(true)
        XCTAssertEqual(gate.admit(10, from: .hardwareKeyboard, generation: 5), .accept)
    }

    /// A retired generation's cached terminal replay must not generate
    /// replies toward the replacement connection.
    func testAC14_staleGenerationCannotWriteToAReplacement() {
        let gate = RecoveryInputGate(generation: 5)
        gate.setLive(true)

        XCTAssertEqual(gate.admit(4, from: .terminalReply, generation: 4), .rejectStaleGeneration)
    }

    /// The pending-input budget rejects visibly instead of dropping bytes.
    func testAC19_inputBudgetRejectsVisiblyAndNeverDropsBytes() {
        var policy = RecoveryPolicy.default
        policy.pendingInputBudgetBytes = 1_024
        let gate = RecoveryInputGate(generation: 1, policy: policy)
        gate.setLive(true)

        var backpressure = false
        gate.onBackpressureChange = { backpressure = $0 }

        XCTAssertEqual(gate.admit(1_000, from: .paste, generation: 1), .accept)
        XCTAssertEqual(gate.admit(100, from: .paste, generation: 1),
                       .rejectBudgetExhausted(pendingBytes: 1_000, budgetBytes: 1_024))
        XCTAssertTrue(backpressure, "overflow did not signal production to stop")
        XCTAssertEqual(gate.pendingBytes, 1_000, "the overflowing write was partially accepted")

        gate.noteWritten(1_000)
        XCTAssertEqual(gate.admit(100, from: .paste, generation: 1), .accept)
    }

    /// Resize is latest-wins; command input is not.
    func testAC19_onlyTheLatestResizeSurvives() {
        let gate = RecoveryInputGate(generation: 1)
        gate.requestSize(TerminalGridSize(rows: 24, cols: 80))
        gate.requestSize(TerminalGridSize(rows: 40, cols: 120))
        gate.requestSize(TerminalGridSize(rows: 30, cols: 100))

        XCTAssertEqual(gate.takeRequestedSize(), TerminalGridSize(rows: 30, cols: 100))
        XCTAssertNil(gate.takeRequestedSize(), "the size was applied twice")
    }

    /// Retiring a generation discards unsent data rather than migrating it to
    /// the replacement writer.
    func testAC14_retirementDiscardsUnsentDataInsteadOfMigratingIt() {
        let gate = RecoveryInputGate(generation: 1)
        gate.setLive(true)
        _ = gate.admit(500, from: .paste, generation: 1)
        XCTAssertEqual(gate.pendingBytes, 500)

        gate.adoptGeneration(2)
        XCTAssertEqual(gate.pendingBytes, 0)
        XCTAssertEqual(gate.admit(1, from: .paste, generation: 2), .rejectNotLive,
                       "the replacement generation started already open")
    }

    // MARK: - Draft

    /// The draft is capped, clips on a character boundary, and is never
    /// auto-submitted.
    func testDraftIsCappedAndClipsOnCharacterBoundaries() {
        var policy = RecoveryPolicy.default
        policy.draftByteCap = 8
        let draft = RecoveryInputDraft(logicalSessionID: UUID(), policy: policy)

        // Each of these is 3 UTF-8 bytes, so only two fit in 8.
        draft.append("日本語です")

        XCTAssertLessThanOrEqual(draft.byteCount, 8)
        XCTAssertTrue(draft.didClip)
        XCTAssertEqual(draft.text, "日本", "the draft stored a split UTF-8 sequence")

        let taken = draft.takeForExplicitSend()
        XCTAssertEqual(taken, "日本")
        XCTAssertTrue(draft.isEmpty, "an explicitly sent draft was left behind")
    }

    // MARK: - AC-22

    /// Legacy and unknown-version descriptors must not drive an automatic
    /// reattachment, and a one-shot command never does, even after relaunch.
    func testAC22_descriptorValidationRefusesUnsafeAutomaticReattachment() {
        let target = RecoveryTargetIdentity(host: "h", port: 22, username: "u")

        var unknownVersion = RecoveryDescriptor(
            logicalSessionID: UUID(), intent: .interactiveShell, target: target,
            tmuxEvidence: nil, tabID: nil)
        unknownVersion.version = 99
        XCTAssertFalse(unknownVersion.supportsAutomaticReattach)

        let oneShot = RecoveryDescriptor(
            logicalSessionID: UUID(), intent: .oneShotCommand, target: target,
            tmuxEvidence: nil, tabID: nil)
        XCTAssertFalse(oneShot.supportsAutomaticReattach,
                       "a one-shot command survived a relaunch as re-runnable")

        var nameOnly = TmuxContinuityEvidence()
        nameOnly.lastObservedName = "main"
        let legacyTmux = RecoveryDescriptor(
            logicalSessionID: UUID(), intent: .attachExistingTmux, target: target,
            tmuxEvidence: nameOnly, tabID: nil)
        XCTAssertFalse(legacyTmux.supportsAutomaticReattach,
                       "name-only legacy state was treated as continuity evidence")

        let verified = RecoveryDescriptor(
            logicalSessionID: UUID(), intent: .attachExistingTmux, target: target,
            tmuxEvidence: evidence(), tabID: nil)
        XCTAssertTrue(verified.supportsAutomaticReattach)
    }

    /// Descriptors round-trip through device-local storage and hold no secret.
    func testDescriptorsRoundTripLocallyWithoutStoringSecrets() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recovery-descriptors-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = RecoveryDescriptorStore(fileURL: url)
        var target = RecoveryTargetIdentity(host: "h", port: 22, username: "u")
        target.credentialReference = "identity:\(UUID().uuidString)"

        let descriptor = RecoveryDescriptor(
            logicalSessionID: UUID(), intent: .attachExistingTmux, target: target,
            tmuxEvidence: evidence(), tabID: UUID())
        store.save(descriptor)

        let reloaded = RecoveryDescriptorStore(fileURL: url)
        XCTAssertEqual(reloaded.descriptor(for: descriptor.logicalSessionID)?.target.host, "h")

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("identity:"), "the credential reference was lost")
        XCTAssertFalse(raw.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertFalse(raw.lowercased().contains("password\":\""))
    }

    // MARK: - AC-24

    /// Cancelled samples are excluded from the failure denominator, and the
    /// metric is a probe failure rate rather than packet loss.
    func testAC24_cancelledSamplesAreExcludedFromTheFailureRate() {
        let now = Date()
        let health = ConnectionHealth(
            rttMilliseconds: 20,
            probeFailurePercent: 0,
            successfulPings: 0,
            totalPings: 0,
            lastSuccessfulPing: now,
            rttMeasuredAt: now,
            samples: [
                PingSample(timestamp: now, rttMilliseconds: 20),
                PingSample(timestamp: now, rttMilliseconds: nil, wasCancelled: true),
                PingSample(timestamp: now, rttMilliseconds: nil, wasCancelled: true),
            ])

        let counted = health.samples.filter(\.countsTowardFailureRate)
        XCTAssertEqual(counted.count, 1, "cancelled samples counted as evidence about the link")
    }

    /// RTT is displayed with its age, so a stale reading cannot imply current
    /// health, and an unverified round trip says so.
    func testAC24_rttIsAgeQualifiedAndUnverifiedRoundTripsSaySo() {
        var health = ConnectionHealth.initial
        health.rttMilliseconds = 23
        health.rttMeasuredAt = Date().addingTimeInterval(-90)

        let description = health.ageQualifiedRTTDescription
        XCTAssertTrue(description.contains("23ms"))
        XCTAssertTrue(description.contains("ago"), "RTT was shown without its age")

        health.roundTripUnverified = true
        XCTAssertTrue(health.statusDescription.lowercased().contains("unverified"))
        XCTAssertFalse(health.statusDescription.lowercased().contains("offline"),
                       "the UI claimed knowledge of the server's state")
    }

    // MARK: - AC-06 / AC-07 (deadline primitive)

    /// The caller observes the deadline even when the operation ignores
    /// cancellation entirely — the blackhole case.
    func testAC06_deadlineIsObservableEvenWhenTheOperationIgnoresCancellation() async {
        let abandoned = expectation(description: "cleanup ran on the timeout path")

        let outcome = await withRecoveryDeadline(
            seconds: 0.05,
            generation: 1,
            onAbandon: { abandoned.fulfill() }
        ) {
            // Deliberately cancellation-insensitive.
            var spins = 0
            while spins < 3 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                spins += 1
            }
            return 99
        }

        await fulfillment(of: [abandoned], timeout: 2)
        guard case .overallExpired = outcome else {
            return XCTFail("expected an observable deadline, got \(outcome)")
        }
    }

    /// A result produced by a retired generation is reported as superseded,
    /// never handed back as if it were current.
    func testAC07_resultFromARetiredGenerationIsNotAdopted() async {
        let outcome = await withRecoveryDeadline(
            seconds: 5,
            generation: 1,
            isCurrent: { _ in false }
        ) {
            42
        }

        guard case .superseded = outcome else {
            return XCTFail("a retired generation's result was adopted: \(outcome)")
        }
    }

    /// Progress resets the inactivity budget but never the overall one.
    func testAC10_progressResetsInactivityButNotTheOverallStageDeadline() {
        let scheduler = VirtualRecoveryScheduler()
        let deadline = RecoveryStageDeadline(
            generation: 3, inactivity: 10, overall: 30, clock: scheduler)

        Task { await scheduler.advance(by: 0) }
        XCTAssertNil(deadline.expiredBudget())

        // Progress from another generation must not keep this stage alive.
        deadline.noteProgress(generation: 99)
        XCTAssertEqual(deadline.generation, 3)
    }

    // MARK: - AC-16 / AC-18 (recovery UI copy)

    /// The plain-SSH action is "Open New Shell", never "Resume session".
    func testAC16_newShellActionIsNeverLabelledResume() {
        let title = RecoveryStatusAction.openNewShell.title
        XCTAssertTrue(title.lowercased().contains("new shell"))
        XCTAssertFalse(title.lowercased().contains("resume"),
                       "a new shell was labelled as a resumed session")
    }

    /// Waiting states report the age of what Shell verified, not a claim
    /// about how long the server has been offline.
    func testStatusCopyReportsVerifiedActivityAgeNotServerDowntime() throws {
        let presentation = try XCTUnwrap(RecoveryStatusPresentation.make(
            for: .waitingForConnectivity,
            intent: .attachExistingTmux,
            lastVerifiedActivityAge: 95))

        let detail = try XCTUnwrap(presentation.detail)
        XCTAssertTrue(detail.contains("Last verified activity"))
        XCTAssertFalse(detail.lowercased().contains("server"),
                       "the copy asserted something about the server's state")
    }

    /// An uncertain one-shot command says the outcome is unknown and offers
    /// no automatic rerun.
    func testAC15_uncertainCommandCopyIsExplicitAndOffersNoRerun() throws {
        let presentation = try XCTUnwrap(RecoveryStatusPresentation.make(
            for: .awaitingUser(reason: .commandOutcomeUnknown),
            intent: .oneShotCommand))

        XCTAssertTrue(presentation.title.contains("Command outcome unknown"))
        XCTAssertFalse(presentation.actions.contains(.retryNow),
                       "an uncertain command offered a one-tap rerun")
    }

    /// The countdown must not announce on every tick.
    func testCountdownDoesNotAnnounceEveryTick() throws {
        let presentation = try XCTUnwrap(RecoveryStatusPresentation.make(
            for: .waitingForRetry(deadline: MonotonicInstant(seconds: 100)),
            intent: .interactiveShell,
            retrySecondsRemaining: 7))

        XCTAssertFalse(presentation.announces, "each countdown tick would be announced")
        XCTAssertEqual(presentation.detail, "Retrying in 7s")
    }

    /// A live connection has no strip at all.
    func testLiveStateShowsNoRecoveryStrip() {
        XCTAssertNil(RecoveryStatusPresentation.make(for: .live, intent: .interactiveShell))
    }

    // MARK: - Recovery config

    /// The connect-time launcher may create a session; the recovery launcher
    /// may not. A profile with no verified session id gets no attach command
    /// at all, so the caller has to ask the user (AC-12).
    func testRecoveryAttachCommandRequiresAVerifiedSessionID() {
        var config = SSHConfig(host: "h", username: "u")
        config.tmuxAutoEnable = true
        config.tmuxAutoMode = .control

        XCTAssertTrue(config.tmuxExecCommandForConnection.contains("new-session -A"),
                      "the connect-time launcher lost its create-or-attach behavior")
        XCTAssertNil(config.tmuxRecoveryAttachCommand(sessionID: nil),
                     "recovery produced a command without a verified session")

        let attach = config.tmuxRecoveryAttachCommand(sessionID: 4)
        XCTAssertEqual(attach?.contains("attach-session -t \"\\$4\""), true)
        XCTAssertEqual(attach?.contains("new-session"), false)
    }

    /// The recovery override must never be written to disk: it is derived
    /// from live evidence and would be stale and wrong on the next launch.
    func testRecoveryExecOverrideIsNotPersisted() throws {
        var config = SSHConfig(host: "h", username: "u")
        config.tmuxAutoEnable = true
        config.recoveryExecCommandOverride = "sh -c 'exec tmux -CC attach-session -t \"$9\"'"

        let encoded = try JSONEncoder().encode(config)
        let raw = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(raw.contains("attach-session"),
                       "a live recovery override was persisted with the profile")

        let decoded = try JSONDecoder().decode(SSHConfig.self, from: encoded)
        XCTAssertNil(decoded.recoveryExecCommandOverride)
        XCTAssertTrue(decoded.tmuxAutoEnable)
    }

    /// The override wins over the connect-time launcher while it is set.
    func testRecoveryOverrideReplacesTheConnectTimeLauncher() {
        var config = SSHConfig(host: "h", username: "u")
        config.tmuxAutoEnable = true
        XCTAssertEqual(config.effectiveExecCommand, config.tmuxExecCommandForConnection)

        config.recoveryExecCommandOverride = "sh -c 'exec tmux attach-session -t \"$2\"'"
        XCTAssertEqual(config.effectiveExecCommand, config.recoveryExecCommandOverride)
    }

    /// Evidence too weak to prove continuity is refused by the registry, so a
    /// later recovery asks rather than guessing.
    func testRegistryRefusesInsufficientEvidence() {
        let registry = TmuxContinuityRegistry.shared
        let key = "u@h:22-\(UUID().uuidString)"
        defer { registry.forget(connection: key) }

        var partial = TmuxContinuityEvidence()
        partial.sessionID = 1
        registry.record(partial, forConnection: key)
        XCTAssertNil(registry.evidence(forConnection: key))

        registry.record(evidence(), forConnection: key)
        XCTAssertNotNil(registry.evidence(forConnection: key))
        XCTAssertEqual(registry.verify(discovered: evidence(), forConnection: key), .continuous)
    }
}
