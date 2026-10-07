# Shell OSC 7501 Program Status Integration

**Repository:** `chr33s/shell`  
**Status:** Proposed  
**Dependency:** `chr33s/swiftty` implements the previously specified OSC 7501 terminal-core support.  
**Scope:** Consume Swiftty's typed program-status state and terminal replies; implement Shell-specific routing, presentation, acknowledgment, and notifications.

## 1. Objective

Integrate Swiftty's OSC 7501 support without reimplementing protocol parsing or record semantics.

```text
program → OSC 7501 → Swiftty
                       ├─ parse/validate/store/lifecycle
                       └─ typed terminal reply
                              ↓
                         SwifttyKit/Shell
                         ├─ transport routing
                         ├─ pane presentation
                         ├─ tab aggregation
                         └─ acknowledgment/notifications
```

Shell MUST NOT parse OSC 7501 strings or duplicate Swiftty's replacement, hierarchy, clear, validation, or prompt/reset semantics.

## 2. Assumed Swiftty contract

Shell assumes Swiftty exposes typed equivalents of:

```swift
ProgramStatusState        // idle, working, done, blocked, error
ProgramStatusBlockedKind  // permission, question, auth
ProgramStatusRecord
ProgramStatusSnapshot
programStatusSnapshot
onProgramStatusChange
onTerminalReply
```

Swiftty guarantees validated/decoded records, correct record replacement/clear semantics, prompt/reset/session transient cleanup, state independent of rendering-surface lifetime, and terminal-generated support-query replies distinguishable from user input.

## 3. Goals

Shell MUST:

1. Bridge typed status through SwifttyKit without protocol loss.
2. Derive lightweight per-pane presentation from the authoritative Swiftty snapshot.
3. Surface active-pane status without obscuring terminal content.
4. Aggregate split-pane status into tab-level attention.
5. Surface blocked/error/unseen-done state on inactive tabs.
6. Define deterministic priority and acknowledgment behavior.
7. Preserve presentation correctness across background/foreground and surface recreation.
8. Route terminal replies through ordinary sessions and native tmux correctly.
9. Ensure replies are never treated as typing, paste, drafts, or type-ahead.
10. Support tmux panes with no attached UI surface.
11. Keep `permission` informational; never auto-approve.
12. Test local, SSH, split-pane, background, and tmux integration.

## 4. Non-goals

Shell MUST NOT parse OSC fields/base64, implement hierarchical clear, infer status from terminal output, synthesize done/error from exit status, automatically approve permissions, interpret program text as markup, or persist authoritative status after terminal destruction.

Native tmux MUST NOT be advertised as fully compatible until the support-probe ordering test passes.

## 5. Architecture

Swiftty's `ProgramStatusSnapshot` is authoritative. Shell stores only presentation/acknowledgment state.

```text
Swiftty TerminalSession
      ↓ ProgramStatusSnapshot
SwifttyKit bridge
      ↓
PanePresentationState
      ├─ pane UI
      ↓
Tab status reducer
      └─ tab UI
```

A terminal session can continue receiving output without a `Surface`. Surface/view objects MUST NOT own authoritative status. Recreated surfaces hydrate immediately from Swiftty's current snapshot.

## 6. SwifttyKit bridge

Expose Swiftty's typed status directly where practical. Any adapter MUST preserve record ID, state, blocked kind, progress, app, title, message, and revision.

Recommended API shape:

```swift
var programStatusSnapshot: ProgramStatusSnapshot { get }
var onProgramStatusChange: (@Sendable (ProgramStatusSnapshot) -> Void)? { get set }
var onTerminalReply: (@Sendable (Data) -> Void)? { get set }
```

If Swiftty uses a typed action stream, forward it instead of creating a competing callback architecture.

### Background behavior

Do not discard authoritative status because the app is backgrounded. UI observation may be suppressed while backgrounded, but foreground MUST re-read the latest snapshot and recompute presentation.

### No timeout

OSC 7501 MUST NOT reuse the existing short progress-expiry timer. `working`/`blocked` remain current until Swiftty removes or replaces them.

## 7. Pane presentation

Recommended derived type:

```swift
struct ProgramStatusPresentation: Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case idle, working, done, error, blocked
    }

    let severity: Severity
    let primaryRecordID: String
    let app: String?
    let title: String?
    let message: String?
    let progress: UInt8?
    let blockedKind: ProgramStatusBlockedKind?
    let activeRecordCount: Int
    let revision: UInt64
    let requiresAcknowledgment: Bool
}
```

This is presentation only; full records remain in Swiftty.

Recommended summary priority:

```text
blocked > error > unacknowledged done > working > idle > none
```

Within equal priority, prefer the most recently updated record. Do not invent aggregate progress across records.

## 8. Pane UI

Initial UI should be compact:

- small state indicator in existing pane/session chrome;
- optional percentage for the primary working/blocked record;
- tap/hover/details affordance for app/title/message and other records;
- accessible text labels;
- no persistent overlay over terminal cells.

Example labels:

```text
Working — 42%
Needs permission — Apply changes?
Question — Choose deployment region
Authentication required
Done — Build complete
Error — Deployment failed
```

Program-provided strings are plain, untrusted text.

## 9. Tab aggregation

A tab reduces status across all split panes, including unfocused panes.

Recommended priority:

```text
blocked > error > unacknowledged done > working > none
```

Use a compact badge/indicator rather than replacing the tab title.

Integrate with the existing per-tab observation/equality strategy so progress bursts in one pane do not unnecessarily invalidate every tab. Update tab sizing metadata to account for the new badge width.

## 10. Acknowledgment

Shell needs a separate concept of whether completed/error status has been seen.

Recommended model:

```swift
struct ProgramStatusAcknowledgment {
    let terminalUUID: UUID
    var acknowledgedRevision: UInt64
}
```

A result is unseen when its relevant revision is newer.

Recommended acknowledgment triggers:

- deliberately focusing/selecting the originating pane;
- keyboard input into that pane;
- opening/tapping its status details.

Do NOT acknowledge merely because the app foregrounded, layout recreated the view, or a tab was selected while another split retained focus.

Acknowledgment affects attention presentation only. It never removes Swiftty's authoritative record. A later done/error revision becomes unseen again.

## 11. Session end

Current Shell behavior normally closes a split when a session ends.

Recommended policy:

- no unseen done/error → preserve normal auto-close;
- unseen done/error → retain an inspectable ended pane/history state long enough for acknowledgment, if feasible;
- never infer OSC 7501 status from process exit code.

If retained ended panes are out of initial scope, document auto-close as a limitation and use notifications to preserve discoverability.

## 12. Notifications

Optional for first release, but design for:

- blocked;
- new error;
- new done in an inactive/background terminal.

Deduplicate by terminal identity + record ID + revision/state. Foreground hydration must not duplicate notifications.

`kind=permission` is informational. A notification may focus the terminal but MUST NOT approve on the program's behalf.

Notification/details UI should identify the originating terminal/tab so program text cannot impersonate another terminal.
## 13. Ordinary terminal-reply routing

Swiftty's OSC 7501 support response is terminal-generated data.

For ordinary local PTY and SSH sessions:

```text
Swiftty terminalReply
    ↓
TerminalSessionController/session host
    ↓
session.sendInput(replyData)
```

Reuse the existing terminal-response pipeline where possible.

Hard requirements:

- bypass keyboard encoding and paste handling;
- do not set `hasUserTyped`;
- do not enter line-editor type-ahead;
- do not become a compose/reconnect draft;
- do not trigger user-input behavior;
- preserve ordering with other terminal-generated replies.

## 14. Built-in local shell

The local shell needs explicit verification because not every command is a conventional child PTY.

### Terminal replies

The support reply must reach the currently executing producer/query reader and MUST NOT become the next shell command.

If current input plumbing cannot preserve reply provenance, add an explicit terminal-reply path. Do not rely on broadening byte-pattern heuristics.

### Prompt lifecycle

The local Shell prompt must provide Swiftty a genuine new-prompt lifecycle event so transient working/blocked status is cleaned up.

Preferred approach: emit the same semantic prompt-start signal used by shell integration immediately before a newly displayed prompt.

Do not emit a new-command boundary for Ctrl-L, line-editor redraw, or prompt repaint.

Verify ios_system commands, interpreter scripts, app-native intercepted commands, interruptions, redirected output, and queries while stdin is active.

## 15. SSH

No OSC-specific SSH parser should exist in Shell.

Verify:

- remote reports reach the correct Swiftty terminal;
- terminal replies reach the remote channel;
- background/reconnect correctly rehydrates presentation;
- stale status is not attached to a replacement process/session.

Do not carry authoritative status across a newly created remote process unless continuity is explicitly guaranteed.

## 16. Native tmux control mode

Native tmux is the main Shell-specific transport integration.

### Incoming reports

`%output` for pane `%N` must feed only that pane's Swiftty terminal. This must work for active panes, inactive panes, hidden windows, and panes without a UI surface.

### Reply routing

Do NOT globally re-enable all pane replies if tmux currently owns ordinary query responses.

Route Swiftty's typed OSC 7501 support reply selectively to the originating pane:

```text
pane %7 output
  ↓
Swiftty terminal for %7
  ↓
terminalReply
  ↓
TmuxController
  ↓
pane-addressed send-keys bytes to %7
```

Use the existing pane-addressed byte-send mechanism where possible. Routing must not depend on a `Surface`.

### Capture/reset

Internal screen reconstruction/reset MUST NOT erase authoritative OSC 7501 state unless it represents a genuine reset emitted by the pane application.

If capture restore feeds RIS through the normal terminal parser, introduce a reconstruction-specific reset path or otherwise preserve metadata correctly.

### Initialization

If live pane output is currently dropped while identity/capture initializes, ensure status reports and support queries are not lost. Prefer early pane identity, bounded buffering, or metadata processing; never unbounded buffering.

### Pane process exit

For `remain-on-exit`, provide a reliable process-death signal so Swiftty session-exit cleanup runs even though the tmux pane object survives.

## 17. Native tmux support-probe release gate

A producer may send OSC 7501 support detection alongside a standard terminal query and decide OSC 7501 is unsupported if the standard response arrives first.

With native tmux there may be two responders:

```text
program
  ├─ standard query → tmux → immediate response
  └─ OSC 7501 query → control output → Shell → pane-addressed reply
```

This creates a possible ordering race.

Before claiming full native-`tmux -CC` support, run an integration test using the protocol's representative/recommended combined detection sequence.

Release gate:

- **PASS:** OSC 7501 is detected reliably through native tmux.
- **FAIL:** document probe compatibility as limited; do not claim transparent support.
- If a complete fix requires tmux cooperation, track that separately.

Correct pane routing is necessary but not sufficient; detection timing must work.

## 18. Background and restoration

### Foreground replay

On foreground:

1. read current snapshots for all live terminals;
2. recompute pane presentation;
3. recompute tab aggregation;
4. do not treat hydration itself as a new notification unless a genuinely unseen revision exists.

### Surface recreation

Hydrate immediately from Swiftty's current snapshot.

### App/session restoration

Do not serialize OSC 7501 state as authoritative across a recreated terminal process.

For restored tmux sessions with surviving pane processes, any retained status is at best last-known if Shell missed output while disconnected. Screen capture cannot reconstruct OSC reports that were not observed.

## 19. Accessibility

Indicators MUST have textual accessibility labels and not rely on color alone.

Examples:

```text
Terminal status: working, 42 percent
Terminal needs permission: Apply changes?
Terminal status: deployment failed
```

Status details must remain associated with the correct pane/tab.

## 20. Suggested Shell files/areas

Exact paths may change, but expected areas include:

```text
Packages/SwifttyKit/
  Sources/SwifttyKit/
    Surface.swift
    Types.swift
    Tmux/TmuxViewer.swift
    terminal/session bridge code

shell/Core/Swiftty/
  SwifttyApp.swift

shell/UI/Terminal/
  TerminalView.swift
  TerminalView+SessionHost.swift
  SplitPaneView.swift
  PanePresentationState or equivalent

shell/UI/Tabs/
  TabBar.swift
  tab badge/button presentation

shell/Features/LocalShell/
  LocalShellSession+Prompt.swift
  input/reply routing

shell/Features/Control/
  optional notification integration
```

Keep protocol semantics out of these files; they consume typed Swiftty state.

## 21. Test plan

### SwifttyKit bridge

- snapshot fields preserved without loss;
- current snapshot available on attachment;
- updates publish without cell damage;
- surface teardown/recreation rehydrates;
- background suppression does not lose authoritative state.

### Pane/tab presentation

- each state maps to correct pane summary;
- blocked priority beats error/done/working;
- error beats unseen done/working;
- acknowledged done stops tab attention;
- new revision reactivates attention;
- status in unfocused split affects tab;
- status in one tab does not invalidate unrelated tab items unnecessarily;
- tab sizing accommodates badge.

### Local shell

- support query reply reaches querying command;
- reply never becomes next command/type-ahead;
- prompt-start clears transient status through Swiftty;
- redraw does not clear status;
- interruption and script completion behave correctly.

### SSH

- remote report → correct pane;
- query → remote reply;
- reconnect/replacement does not leak stale status.

### tmux

- active/inactive/hidden pane reports;
- pane without surface;
- query reply addressed to originating pane;
- no global reply enablement regression;
- capture reconstruction does not clear status;
- initialization does not lose metadata;
- `remain-on-exit` triggers session-exit cleanup;
- combined support-probe ordering test.

### Background/restoration

- status arrives while backgrounded;
- foreground shows latest snapshot;
- no duplicate notification on hydration;
- recreated surface displays current status immediately.

### Security

- title/message rendered as plain text;
- permission status cannot invoke approval;
- provenance identifies terminal/tab;
- terminal reply does not traverse user-input paths.

## 22. Acceptance criteria

- [ ] Shell consumes typed Swiftty OSC 7501 snapshots without parsing OSC.
- [ ] Status remains authoritative in Swiftty, not view state.
- [ ] Pane summary renders blocked/error/done/working correctly.
- [ ] Split-pane status aggregates to tab attention.
- [ ] Done/error acknowledgment is revision-based.
- [ ] Program status has no arbitrary progress timeout.
- [ ] Background/foreground preserves current status.
- [ ] Surface recreation hydrates immediately.
- [ ] Ordinary terminal replies bypass user-input semantics.
- [ ] Local-shell replies cannot become shell commands/type-ahead.
- [ ] Local prompt emits a genuine lifecycle boundary without redraw false positives.
- [ ] SSH reports/replies work.
- [ ] tmux replies route to the originating pane.
- [ ] tmux status works without an attached surface.
- [ ] internal tmux capture reset does not erase status.
- [ ] tmux process exit triggers Swiftty cleanup.
- [ ] native-tmux combined-probe behavior is tested before support is claimed.
- [ ] permission status never automatically approves an action.
- [ ] accessibility does not depend on color.
- [ ] existing progress, terminal response, tmux, tab, and reconnection behavior does not regress.

## 23. Recommended implementation order

1. Update/vendor the Swiftty revision containing OSC 7501.
2. Add SwifttyKit typed snapshot/reply bridge.
3. Add pane presentation reducer and tests.
4. Add pane UI.
5. Add tab aggregation/badge and sizing updates.
6. Add revision-based acknowledgment.
7. Wire ordinary local/SSH terminal replies.
8. Add local-shell prompt lifecycle and reply provenance.
9. Add tmux pane reply routing.
10. Fix tmux capture/init/process-exit lifecycle gaps.
11. Run the native-tmux support-probe ordering experiment.
12. Add optional notifications.
13. Run regression and accessibility tests.

## 24. Definition of done

Shell is OSC 7501-integrated when a supported producer can report status through local and SSH terminals; Shell shows the correct pane/tab attention state; completed/error results can be acknowledged without corrupting protocol state; support-query replies travel through terminal-reply paths rather than user-input paths; and the integration remains correct across splits, backgrounding, surface recreation, and session lifecycle.

Native tmux is considered fully supported only after pane-addressed replies, metadata lifetime, process-exit cleanup, and combined support-probe ordering all pass integration tests.

## 25. Repository boundary

The implementation boundary is intentional:

**`chr33s/swiftty` owns:**

- OSC 7501 parsing and validation;
- decoded typed records;
- record replacement/hierarchy/clear;
- bounded status storage;
- prompt/reset/session protocol lifecycle;
- support-query response generation;
- terminal-reply provenance.

**`chr33s/shell` owns:**

- SwifttyKit exposure/integration;
- transport-specific routing, especially tmux;
- pane and tab presentation;
- attention and acknowledgment;
- notifications;
- local-shell lifecycle signaling where Shell itself produces the prompt;
- app background/restoration behavior;
- user-facing security and accessibility behavior.

No OSC 7501 parser or duplicate `ProgramStatusStore` should be added to Shell.
