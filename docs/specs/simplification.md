# Shell: Implementation Simplification

**Status:** In progress. Increment 1 (stable reconnect targeting), increment 5A (CloudKit checkpoint durability), the F-09 test fix, and the first slice of increment 2 (connection-flow payloads) are implemented; increments 2–7 otherwise remain proposed. See §16.
**Scope:** Refactoring ownership of deferred tab/pane actions, connection flows, terminal-session state, command routing, app lifecycle, CloudKit scheduling, and Control composition — without changing the product surface defined in [`shell.md`](shell.md), [`mobile-connectivity.md`](mobile-connectivity.md), and [`control-protocol.md`](control-protocol.md).

Capitalized MUST, MUST NOT, SHOULD, and MAY are normative.

## 1. Purpose and decision

Simplify Shell without replacing Ghostty or removing its supported terminal, SSH, tmux, synchronization, or optional Control capabilities.

The recommended approach is to finish the architectural extractions already underway. Reduce the number of components that must coordinate to perform an action, the number of writable representations of the same state, and the number of independent execution paths for the same operation.

The primary opportunities are:

1. Stable identity for deferred tab and pane actions.
2. Explicit ownership of connection flows and terminal-session state.
3. Typed, scene-targeted application commands.
4. A coherent CloudKit scheduling and durability boundary.
5. An explicit composition boundary for the optional Control companion.

A smaller file count or lower line count is not, by itself, evidence of improvement. Moving code into extensions without moving ownership does not satisfy this specification.

**Review basis:** static review of `1d83be47` (26 Sep 2026) covering app composition, window/tab management, connection preparation, terminal sessions, recovery, CloudKit, Control integration, and selected tests. Source links below pin that revision; findings are source-derived, not reproduced runtime failures. Progress is tracked in §16.

## 2. Scope and constraints

### 2.1 In scope

Refactor deferred-action targeting, connection preparation, presentation payloads, session-domain state, command routing, application lifecycle ownership, sync durability, Control integration, and tests affected by those boundaries.

Behavior-preserving changes are the default. Correctness fixes may deliberately change unsafe behavior, such as replacing an unrelated tab after a deferred reconnect request becomes stale.

### 2.2 Out of scope

This work does not authorize a renderer rewrite, a new terminal engine, a replacement tmux parser, a new SSH implementation, deletion of the local shell, or removal of supported platforms. It does not authorize removing Watch, agent approvals, the broker, or the push relay as a code-size optimization.

Do not introduce a new application framework, generic event bus, dependency-injection framework, or protocol hierarchy merely to perform these refactors. Prefer existing types and concrete owners unless a real boundary requires substitution.

### 2.3 Required product invariants

The existing product specification requires Ghostty rendering, native tmux control-mode integration, independent jump-host authentication and trust, device-bound Secure Enclave identities, and separation of public CloudKit metadata from private credentials. These remain constraints on all changes. [Source: `shell.md`](shell.md).

The implementation MUST preserve:

- Exact targeting of the intended window, tab, pane, session, and SSH hop.
- The distinction between a user-requested new connection and recovery of an existing session.
- Attach-only tmux recovery and honest reporting when continuity cannot be established.
- Off-main terminal-output delivery and recovery UI outside the terminal byte stream.
- Authentication cancellation, host-key verification, and refusal to silently downgrade an unavailable or unsupported identity to password authentication.
- Sync consent, category opt-outs, account isolation, tombstones, and conflict-aware writes.
- Control pinned-origin verification, command-journal reconciliation, and separation from terminal traffic.

## 3. Findings and priorities

| ID | Finding | Evidence classification | Priority |
| --- | --- | --- | --- |
| F-01 | Deferred reconnect stores an array index and later replaces the tab at that index after only a bounds check. | Concrete source-level targeting defect; not reproduced on device. | First correctness fix |
| F-02 | `MainView` retains broad state ownership despite extraction into topic-specific extensions. | Architectural observation. | High |
| F-03 | Connection preparation is distributed across profile connection, configuration connection, and session startup. | Architectural observation; not every repeated check is redundant. | High |
| F-04 | Internal commands use broadcast, payload decoding, window filtering, and target lookup repeatedly. | Architectural observation. | High |
| F-05 | Session-domain state remains view-owned behind a broad writable host interface. | Architectural observation. | High |
| F-06 | CloudKit checkpoints are persisted before the corresponding changes are applied locally. | Crash-consistency risk inferred from source ordering. | Separate correctness fix |
| F-07 | Online upload, offline queue, settings batching, backfill, and notification triggers have overlapping orchestration. | Architectural observation. | High; migration-sensitive |
| F-08 | Control has useful package boundaries, but app lifecycle and presentation directly wire the companion. | Integration simplification opportunity. | Medium |
| F-09 | A notification scanner test requires more than 50 production declarations. | Refactor-obstructing test assumption. | Address during routing migration |

These priorities are engineering judgments, not measured performance, effort, or code-size estimates.

## 4. Stable identity for deferred actions

### 4.1 Source evidence

`MainView` exposes compatibility accessors over UUID-based `TabsModel` selection, while retaining `reconnectingTabIndex`. The connection sheet checks that the stored index is in bounds; `reconnectTab` then replaces the tab at that index. [Sources: MainView](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/UI/Shell/MainView.swift), [connection sheet](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/UI/Shell/MainView%2BConnectionSheet.swift), [tab management](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/UI/Shell/MainView%2BTabManagement.swift).

The failure follows from the stored identity representation:

```text
Tabs are [A, B].
B requests authentication; the request stores index 1.
Tabs become [B, A].
The user submits Connect.
Index 1 is valid, but now identifies A.
```

The same tab-management file already uses the safer pattern for `runPendingTmuxClose`: retain a tab ID and resolve it when the user responds.

### 4.2 Requirements

**TAB-01.** Any operation retained across a sheet, confirmation, asynchronous suspension, or deferred callback MUST identify its target by stable ID rather than an array index.

**TAB-02.** A tab-level request MUST carry a tab UUID. A pane-level request MUST also carry the pane's stable identity. An action bound to a particular session incarnation MUST reject a superseded incarnation, using an existing identity or generation mechanism where available.

**TAB-03.** Resolve the target immediately before applying the action. Reordering MUST NOT change the target. Bounds validation alone is insufficient.

**TAB-04.** A missing or superseded target MUST NOT fall back to the selected tab or another tab at the old position. Cancel the stale request and provide an appropriate visible result. Opening a new session requires explicit user intent.

**TAB-05.** A target transferred to another scene MUST NOT remain actionable through stale source-window state. The first increment MAY cancel the pending flow on transfer; preserving the flow requires explicit transfer of its ownership and callbacks. Do not add a global registry solely for the first targeting fix.

**TAB-06.** Reconnecting a pane MUST NOT unintentionally replace its sibling panes. Preserve relevant profile association, tab identity, ordering, and grouping where the operation is defined to replace only the session. Retire the old session through the established cleanup path exactly once.

**TAB-07.** Indices MAY remain for immediate iteration and layout. Remove index compatibility accessors incrementally as migrated callers stop requiring them.

## 5. Connection-flow ownership

### 5.1 Source evidence

`MainView` coordinates password prompts, key-resolution prompts, reconnect state, and split placement through separate flags and payloads. The connection sheet contains explicit dismissal cleanup to prevent stale reconnect state from surviving into another presentation. Preparation also occurs in both UI helpers and terminal-session startup. [Sources: MainView](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/UI/Shell/MainView.swift), [connection sheet](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/UI/Shell/MainView%2BConnectionSheet.swift), [session controller](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Core/Terminal/TerminalSessionController.swift).

### 5.2 Target model

Introduce a small scene-owned connection-flow owner. Naming is provisional; adding the type is useful only if the corresponding state and responsibilities leave `MainView`.

Each flow has one request identity, one explicit connection intent, one stable placement target, and one authoritative preparation state.

| Concept | Required semantics |
| --- | --- |
| Intent | New session, explicit reconnect, or recovery; never inferred from which booleans happen to be set. |
| Destination | New tab, split at a specified target, or replace the session at a specified target. |
| Preparation | Editing, preparing, awaiting a specific credential or identity decision, ready, failed, or cancelled. |
| Completion | At most one commit of a prepared request. |
| Cancellation | Withdraw pending UI, invalidate late results, and leave unrelated sessions untouched. |

### 5.3 Requirements

**FLOW-01.** Mutually dependent presentation payloads MUST be stored together with the state that makes them valid. A visible password request without its profile or endpoint context MUST not be representable through normal flow transitions.

**FLOW-02.** Completion, failure, cancellation, and dismissal MUST pass through one flow-lifetime boundary. A result arriving after cancellation or replacement MUST be ignored.

**FLOW-03.** Shared credential preparation SHOULD converge on one operation that reuses existing key resolvers and credential stores. It MUST distinguish ready, user interaction required, unavailable identity, unsupported authentication, failure, and cancellation.

**FLOW-04.** Credential requests MUST identify the target or jump hop and preserve the corresponding endpoint and trust context. Do not combine unrelated host-key decisions or interactive challenge rounds.

**FLOW-05.** Share preparation mechanics, not incompatible policies. Recovery MUST retain its session-continuity requirements; a new connection MAY create a session only where current product behavior permits it.

**FLOW-06.** Profile usage MUST be recorded once at the defined user-intent boundary, not once per preparation retry or callback. Existing password-storage preferences and error handling MUST survive migration.

**FLOW-07.** Do not force independent settings overlays, terminal search, or queued keyboard-interactive challenges into one global presentation enum. Keep independent lifetimes independent.

## 6. Terminal-session ownership

### 6.1 Source evidence

`TerminalSessionController` already owns adoption, callback wiring, startup, and reconnection integration. Its host interface still exposes writable configuration, view-defined restoration state, recovery presentation, startup payloads, output plumbing, and explicit change notifications. [Sources: session controller](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Core/Terminal/TerminalSessionController.swift), [session host protocols](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Core/Terminal/TerminalSessionHost.swift).

### 6.2 Requirements

**SESSION-01.** Keep and complete the existing controller extraction. Connection configuration, session lifecycle, and restoration state MUST each have one authoritative session-domain owner.

**SESSION-02.** Move session-domain state types out of `Ghostty.TerminalView` when they no longer belong to the view. Presentation MAY derive from those types without defining the domain contract.

**SESSION-03.** A migrated state update MUST NOT require both mutating view-owned state and calling a separate notification method merely to announce the same mutation. Retain explicit notifications only for genuine boundaries that cannot observe the owning state directly.

**SESSION-04.** The view boundary SHOULD expose capabilities, such as obtaining geometry, delivering output, or requesting user interaction, rather than writable mirrors of controller-owned state.

**SESSION-05.** Preserve weak host lifetime handling and stale-session filtering. Late title, directory, readiness, error, or completion callbacks MUST NOT alter a replacement session's state.

**SESSION-06.** Preserve the existing off-main output path. Do not publish every terminal byte chunk through observable UI state or require a main-actor hop for each chunk.

**SESSION-07.** Do not replace one broad host protocol with many smaller protocols that collectively expose the same mutable internals. A migration is complete only when ownership and synchronization obligations are reduced.

## 7. Typed commands and lifecycle boundaries

### 7.1 Source evidence

`MainView+Notifications` repeatedly decodes payloads, checks window ownership, and resolves the focused terminal. It also owns observer cleanup. `ShellApp` explicitly targets SSH URL notifications to avoid multi-window fan-out and places some app-wide work in window content. [Sources: notification handling](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/UI/Shell/MainView%2BNotifications.swift), [app composition](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/App/ShellApp.swift).

### 7.2 Requirements

**CMD-01.** Provide one typed application-command handler per scene. Menus, keyboard shortcuts, gestures, and deep links SHOULD be adapters into that handler rather than separate implementations.

**CMD-02.** Resolve the destination scene once per command. A command intended for one window MUST execute at most once in that window and never fan out to other windows.

**CMD-03.** Use typed directions and payloads. Deferred commands MUST carry stable targets under Section 4. Immediate focus-based commands MUST resolve focus in the selected destination scene at dispatch time.

**CMD-04.** Extend or consolidate existing typed command structures, including `GhosttyCommandRouting.PaneCommand`, rather than introducing a competing generic bus.

**CMD-05.** Keep platform responder adapters and genuine system notifications. Removing internal command broadcasts does not require removing NotificationCenter everywhere.

**CMD-06.** During migration, each action MUST have exactly one active execution path. A temporary adapter MUST not both invoke the typed handler and post the legacy command.

**LIFE-01.** App-wide startup, activation, sync triggering, and optional companion startup MUST have an app-scoped owner. Opening another window MUST NOT duplicate app-wide observers or startup effects.

**LIFE-02.** Window focus, scene presentation, and window command lifetime remain scene-scoped. Preserve protected-data guards and background/foreground ordering protections when changing ownership.

## 8. CloudKit durability and scheduling

### 8.1 Source evidence

`fetchZoneChanges` persists the next token before its caller applies fetched records. The manager also has immediate uploads, offline uploads, settings batches, backfills, and delayed notification work. The offline queue coalesces and persists changes but logs persistence failures rather than returning them to callers. [Sources: sync manager](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Core/CloudKit/CloudKitSyncManager.swift), [offline queue](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Core/CloudKit/CloudKitOfflineQueue.swift).

The checkpoint-ordering issue is a crash-consistency risk inferred from the source. No termination-at-checkpoint experiment was performed during review.

### 8.2 Checkpoint contract

**SYNC-01.** A persisted fetch checkpoint MUST describe changes that are already durably applied or durably journaled for replay.

```text
Fetch changes and their next token
    → durably apply changes, or journal changes and token
    → persist the corresponding checkpoint
```

**SYNC-02.** A local persistence failure MUST prevent unjournaled checkpoint advancement. Local application MUST be replay-safe so a crash before checkpoint persistence can safely cause repeated delivery.

**SYNC-03.** Record-level failures MUST NOT be silently treated as successfully applied changes. Either retain sufficient durable work to recover them or stop advancement past unapplied work. Checkpointing must remain correct across pages and mixed record types.

**SYNC-04.** Account identity and sync generation MUST be validated around asynchronous boundaries. Work started for an old account or invalidated configuration MUST NOT commit into a new context.

The checkpoint fix SHOULD be implemented and reviewed independently of scheduling replacement.

### 8.3 Upload contract

**SYNC-05.** Every local edit selected for sync MUST enter one authoritative durable pending-change mechanism. Connectivity changes scheduling, not whether the edit is recorded durably.

**SYNC-06.** Use one authoritative drain/scheduling path for immediate changes, offline changes, settings batches, and backfills. Callers express pending work; they do not each implement their own retry loop.

**SYNC-07.** An acknowledgement MUST clear only the submitted revision. When revision B replaces revision A locally while A is in flight, acknowledgement of A MUST leave B pending.

**SYNC-08.** Recheck account identity, category policy, and applicable settings pins before sending. Disabling sync or switching accounts MUST invalidate incompatible in-flight work without silently losing required local data.

**SYNC-09.** Preserve conditional saves, tombstones, newer-record conflict handling, re-enable backfill, settings merge consent, and secret/public-data separation.

**SYNC-10.** Pending-change persistence failures MUST be observable to the owning workflow. Logging an error alone is insufficient if the workflow subsequently represents the edit as safely queued.

### 8.4 Optional `CKSyncEngine` evaluation

`CKSyncEngine` is a candidate replacement for the scheduling boundary, not a mandated dependency change or a validated migration.

A bounded prototype MUST verify SDK compatibility, lifecycle behavior, conflict handling, persistence responsibilities, account switching, and existing product policies against the project's pinned SDK and current Apple documentation.

Choose either the simplified existing implementation or the replacement based on that evidence. Do not layer a third independent scheduler underneath existing online, offline, and settings retry paths. If the candidate owns pending-work metadata, define precisely which durable state remains application-owned and avoid competing sources of truth.

No public claim about reduced code size, improved battery use, or faster sync is an acceptance criterion without measurement.

## 9. Optional Control composition

### 9.1 Source evidence

The Control package already separates protocol, security, client, and server targets. `ControlCompanion` exposes injectable stores and transport, while `ShellApp` directly wires Control presentation, links, and activation refresh. [Sources: package manifest](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/Packages/ShellControlCore/Package.swift), [companion](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Features/Control/ControlCompanion.swift), [app composition](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/App/ShellApp.swift).

### 9.2 Requirements

**CONTROL-01.** Preserve the existing package and injectable service boundaries. They are not removal targets solely because they add types.

**CONTROL-02.** Place app-level Control lifecycle, deep-link handling, and presentation integration behind a small composition boundary. Terminal-session code MUST NOT acquire Control protocol or approval responsibilities.

**CONTROL-03.** Make the documented terminal-without-Control contract an explicit build and smoke-test assertion. First inspect existing project support; this review did not establish whether the necessary variant already exists.

**CONTROL-04.** Preserve origin pinning, route verification, enrollment distinctions, cancellation, durable decision reconciliation, and Watch gateway behavior. Do not use a non-durable fallback to make the journal interface simpler.

**CONTROL-05.** Do not remove companion features under this specification. Any feature deletion requires a separate scope decision.

## 10. Test strategy and acceptance criteria

### 10.1 Test architecture

The existing notification scanner requires more than 50 production declarations. That is a scanner-health check which will obstruct legitimate routing reduction. Replace the production-size assumption with representative scanner fixtures while retaining useful integration checks until their channels are removed. [Source: notification wiring tests](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/tests/ShellTests/NotificationWiringTests.swift).

Behavioral tests SHOULD cover the new owners with controllable session callbacks, transport responses, storage failures, and lifecycle events. Source-text tripwires remain supplemental; they are not proof that behavior is correct.

Retain the existing tmux-continuity and recovery-byte-stream protections. [Sources: tmux recovery identity](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/shell/Features/Tmux/TmuxRecoveryIdentity.swift), [recovery isolation tests](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/tests/ShellTests/RecoveryUIIsolationTests.swift).

### 10.2 Acceptance matrix

| ID | Scenario | Required result |
| --- | --- | --- |
| AC-01 | Reorder tabs while reconnect authentication is open. | Only the original target is eligible for reconnection. |
| AC-02 | Close the target or a preceding tab before submitting. | No unrelated tab is replaced; missing target cancels safely. |
| AC-03 | Reconnect one pane in a split tab. | Sibling panes survive and relevant tab/profile metadata is preserved. |
| AC-04 | Cancel a flow, open a new flow, then deliver an old completion. | Old completion has no effect; no stale configuration appears. |
| AC-05 | Transfer a target tab between windows during a pending request. | Explicit migration or safe cancellation; no stale source-window execution. |
| AC-06 | Target and jump host require different credentials or trust decisions. | Each prompt and result remains bound to the correct hop. |
| AC-07 | A referenced key is missing or authentication type is unsupported. | Explicit failure or resolution UI; no silent password downgrade. |
| AC-08 | Emit callbacks from an old session after replacement. | Replacement state and presentation remain unchanged. |
| AC-09 | Dispatch commands with two windows open and after window recreation. | Exactly one intended execution; no observer accumulation. |
| AC-10 | Open another window and perform activation/background transitions. | App-wide work is not duplicated; lifecycle guards remain effective. |
| AC-11 | Terminate between fetch, local durable apply/journal, and checkpoint persistence. | Relaunch loses no fetched changes; replay is safe. |
| AC-12 | Fail local storage or a record within a fetched page. | No unsupported checkpoint advance or false durable-success indication. |
| AC-13 | Edit a record again while its prior revision is uploading. | Acknowledging the old revision does not remove the new pending edit. |
| AC-14 | Switch accounts or disable a sync category during an await. | Stale work cannot commit or send under the new policy/context. |
| AC-15 | Re-enable categories; encounter tombstones and record conflicts. | Existing consent, backfill, deletion, and conflict semantics are preserved. |
| AC-16 | Recover when the tmux server/session is missing or identity differs. | No silent create-or-attach; continuity is reported honestly. |
| AC-17 | Display recovery status while an alternate-screen program is active. | Status UI injects no terminal bytes. |
| AC-18 | Build the terminal without Control; test normal Control-enabled behavior separately. | Core behavior works independently; supported companion behavior remains intact. |

### 10.3 Execution and evidence

Use the repository's documented build and test entry points as applicable: `scripts/build.sh`, `scripts/test.sh`, `scripts/build-watch.sh`, `scripts/test-watch.sh`, `scripts/test-control.sh`, and `scripts/test-lifecycle.sh`. Include relevant Catalyst smoke checks and supported-platform validation. [Source: build and test instructions](https://github.com/chr33s/shell/blob/1d83be478ca60dbeac89f10deb7d7b9cbf03db02/README.md).

Each implementation PR MUST record commands actually executed, SDK/environment, results, and unexecuted acceptance cases. A listed command is not evidence that it passed.

## 11. Implementation sequence

| Increment | Deliverable | Exit gate |
| --- | --- | --- |
| 0. Baseline | Confirm branch divergence, current ownership, test capability, and relevant behavior. | Reproducible before-state and an explicit evidence log. |
| 1. Stable targeting | Replace deferred reconnect indices; preserve target granularity and cleanup. | AC-01 through AC-05 pass. |
| 2. Connection flow | Group request payloads and centralize shared preparation using existing resolvers. | AC-04, AC-06, AC-07 pass; migrated flags cease to be authoritative. |
| 3. Session ownership | Move session-domain state and narrow view capabilities. | AC-08 passes; off-main output and cleanup behavior remain intact. |
| 4. Commands/lifecycle | Migrate action families into scene handlers and app-wide services into app ownership. | AC-09 and AC-10 pass; migrated broadcasts and redundant observers are removed. |
| 5A. Sync correctness | Fix checkpoint durability independently of scheduler choice. | AC-11 and AC-12 pass with injected failures. |
| 5B. Sync simplification | Select and implement one durable pending-work and scheduling boundary. | AC-13 through AC-15 pass; redundant retry paths are removed. |
| 6. Control composition | Isolate integration and verify the optional build contract. | AC-18 passes. |
| 7. Consolidation | Remove superseded shims, state mirrors, and test assumptions. | All applicable acceptance cases pass, including AC-16 and AC-17. |

The sync correctness fix MAY proceed earlier as an independent PR. Avoid combining checkpoint repair, storage migration, and a scheduler replacement into one change that is difficult to validate or revert.

## 12. Success measures and release gates

Record before/after counts for deferred index targets, authoritative session-state owners, migrated notification routes, duplicate preparation entry points, independent sync retry paths, and writable host-interface members. Counts are diagnostic measures, not arbitrary quotas.

For migrated areas, the required outcomes are zero index-based deferred targets, one authoritative owner per state, one execution path per command, and one scheduling authority for pending sync work.

Where performance is claimed, measure representative terminal throughput, interaction responsiveness, root-view invalidations, and reconnect behavior on the same hardware and workload. No regression threshold is asserted by this static review; implementation must establish and document the comparison.

Release MUST be blocked by cross-window command execution, reconnecting the wrong target, authentication downgrade, loss of unsynced work, false tmux restoration, or recovery output contaminating the terminal stream.

## 13. Migration and rollback

Keep increments independently reviewable. Temporary adapters MUST have one underlying authority, explicit scope, and an exit criterion; they must not become permanent parallel implementations.

Storage changes MUST define how existing pending edits, tokens, settings state, and command journals are read, migrated, and recovered after interruption. Never mark work acknowledged merely to make migration finish. If rollback cannot read the new format, document and test the supported recovery procedure before release.

Review account isolation and credential boundaries whenever persisted state moves. Preserve recoverable data on migration failure and expose an actionable error rather than silently resetting to an empty store.

## 14. Decisions to confirm during implementation

The following were not established by the static review and require explicit resolution:

| Decision | Default direction |
| --- | --- |
| Existing pending-auth behavior during tab transfer | Cancel safely unless the flow and callbacks can be explicitly transferred without stale ownership. |
| Pane versus tab reconnection semantics at each call site | Target the smallest intended session unit; do not infer whole-tab replacement from an index API. |
| Current terminal-without-Control build support | Inspect the project before adding another build variant. |
| Sync scheduler selection | Correct durability first; select the existing scheduler or `CKSyncEngine` only after a bounded validation. |
| Storage transaction/journal strategy | Choose the least invasive mechanism that satisfies durable checkpoint and exact-revision acknowledgement contracts. |

## 15. Completion definition

This work is complete when the affected flows are simpler because fewer components must agree about state, not because the same dependencies have been renamed or spread across more files.

The initial deliverable should be the stable-target reconnect fix and its regression tests. Broader refactors then remove obsolete coordination code as ownership becomes explicit, while preserving the product's security, recovery, and terminal-performance boundaries.

## 16. Implementation status

| Increment / finding | State | Where |
| --- | --- | --- |
| 0. Baseline | Done. `scripts/test.sh` on `42abbbc8`: 383 tests in 33 suites passed (3 known issues). | — |
| 1. Stable targeting (F-01, TAB-01..07) | Implemented. Reconnect is armed with `ReconnectTarget` (tab UUID + weak pane instance) and resolved at commit; a stale target is cancelled with a visible "Reconnect Cancelled" alert. `reconnectPane` swaps only the failed leaf (`SplitTree.replacingLeaf`, zoom preserved), keeps tab identity/position/profile, and retires the old session once via `cleanup(reason: .userClose)` — the old whole-tab replacement never cleaned it up and dropped sibling panes. Tab transfer (TAB-05) cancels by construction: the target no longer resolves in the source window. | `shell/UI/Shell/ReconnectTarget.swift`, `MainView+TabManagement.swift`, `MainView+ConnectionSheet.swift`; `tests/ShellTests/ReconnectTargetTests.swift` |
| 2. Connection flow (FLOW-01) | Partial. Connection-sheet prefill, password prompt, and key resolution are single `Identifiable` requests presented with `.sheet(item:)`; eight loose `@State` fields are gone and late key-resolution callbacks from a replaced sheet are ignored. Shared credential preparation (FLOW-03) is not yet consolidated. | `shell/UI/Shell/ConnectionFlowRequests.swift` |
| 3. Session ownership | Not started. | — |
| 4. Commands / lifecycle | Not started. | — |
| 5A. Sync correctness (F-06, SYNC-01..04) | Implemented. `fetchZoneChanges` no longer persists the fetched token; `applyFetchedChanges` commits it only after every record and tombstone of an enabled class persisted and no record failed to download. Stores now report tombstone and identity-metadata persistence failures instead of `try?`. A checkpoint generation, bumped on account switch and sync disable, stops a stale fetch from applying or committing. | `shell/Core/CloudKit/CloudKitSyncManager.swift`; `tests/ShellTests/CloudKitCheckpointTests.swift` |
| 5B. Sync simplification | Not started. | — |
| 6. Control composition | Not started. | — |
| F-09 scanner floor | Done. The `> 50` production-count assertion is replaced by a fixture test of the scanner. | `tests/ShellTests/NotificationWiringTests.swift` |

After these changes `scripts/test.sh` (iOS Simulator, iPhone 17): 398 tests in 35 suites passed (3 known issues). Not run: `build-watch.sh`, `test-watch.sh`, `test-control.sh`, `test-lifecycle.sh`, Catalyst smoke.

Acceptance cases covered by unit tests: AC-01, AC-02, AC-03 (tree level), AC-05 (resolution level), AC-12 (decision level). Not executed: AC-04, AC-06..AC-11, AC-13..AC-18 and all on-device checks — in particular AC-11 (termination between apply and checkpoint) has no injected-failure harness yet.
