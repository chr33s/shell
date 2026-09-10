# Shell — Mobile Connectivity and Session Recovery Specification

**Status:** Proposed implementation specification  
**Suggested repository path:** `spec.connectivity.md`  
**Repository:** `chr33s/shell`  
**Source baseline:** `577616f483373cffa0d25e052aee3f46e76588cc` (`main`, checked 2026-09-10)  
**Relationship:** Additive to `spec.md`; does not replace the minimal-fork architecture or `spec.watch.md`  
**Validation:** Static source review and primary-source protocol documentation. No implementation, device testing, or performance results are claimed.

## 1. Goal

Make mobile network disruption recoverable without confusing a lost connection with a lost session, corrupting the terminal display, or repeating remote actions.

The primary experience is:

> The network can disappear. Shell retains the last screen and the intention to reconnect. When connectivity returns, it securely reattaches to the intended tmux session and enables input only after the relevant terminal state is ready.

The first release uses the existing SSH, Network.framework, Ghostty, and tmux architecture. No new remote service is required. A surviving tmux server is the source of process continuity; Shell cannot preserve a process that the server has terminated.

Shell must distinguish three outcomes:

| Outcome | Meaning shown to the user |
| --- | --- |
| **Session restored** | The intended existing tmux session was verified and reattached. |
| **New shell opened** | A new remote shell was explicitly requested; the old shell was not resumed. |
| **Command outcome unknown** | A connection failed around a remote action whose completion cannot be established. Shell did not rerun it. |

“Mosh-inspired” means adopting stale-state visibility and selective state resynchronization. “ET-inspired” means separating session identity from transport lifetime. It does not mean implementing either protocol in the first release. Mosh synchronizes screen state and ordered input over UDP; ET uses buffered streams and received-byte positions to resume communication.[^mosh][^et]

## 2. Scope and architectural boundaries

### 2.1 Required for the first release

Implement a single recovery coordinator, correct retry accounting, bounded liveness checks, safe cancellation, verified tmux reattachment, explicit readiness, native recovery UI, input safety, and lifecycle-aware operation. Cover both profile-launched SSH and SSH launched from the embedded local shell.

Preserve password, saved-password, software-key, Secure Enclave, user-certificate, keyboard-interactive, known-host, and jump-host behavior. Reuse Ghostty for terminal interpretation and the existing native tmux bridge.[^extraction]

### 2.2 Conditional follow-on

Add tmux control-mode flow control and snapshot-based catch-up only after the pinned Ghostty viewer and tested tmux versions demonstrate a safe synchronization boundary. This optimization must not block shipping the first release and must have a non-dropping fallback.

### 2.3 Explicitly excluded

No Mosh dependency, custom UDP or QUIC transport, multipath entitlement, predictive echo, unrestricted offline keystroke queue, general command journal, SSH host-CA trust, or additional terminal emulator. Do not restore features removed by the extraction specification. Do not route terminal traffic through the optional Watch approval broker or extend its permission protocol to unrestricted remote input.[^readme][^extraction]

An ET-compatible client or persistent SSH relay requires a separate approved protocol/security specification. Section 19 records its requirements, not permission to implement it as part of this work.

## 3. Current implementation and change rationale

These are observations at the source baseline, not claims about measured runtime behavior.

| Existing area | Observation | Required change |
| --- | --- | --- |
| `ReconnectionManager` | Defaults to five attempts; increments before its wait; restoration only accelerates the waiting state; exhausted recovery remains manual. | Count actual attempts and retain recoverable intent after a burst is exhausted. |
| `InitialConnectRetry` and `CitadelSSHSession.start()` | The session's startup contains its own retry loop, while the reconnection manager retries session startup. | Prevent nested retry multiplication during recovery. |
| `ConnectionHealthMonitor` | Uses a task-group timeout race and reports unsuccessful keepalive probes as `packetLossPercent`. | Establish a real operation deadline and report probe failures, not IP packet loss. |
| `TerminalSessionController` | Replaces the SSH session and awaits `start()`; PTY startup proceeds asynchronously. | Separate transport establishment from terminal readiness. |
| `TerminalReconnectionController` | Writes recovery text and spinner escape sequences into Ghostty. | Render recovery status outside the terminal stream. |
| `TmuxController` and session extension | Already provide topology reconciliation and attached-session metadata. | Extend these mechanisms rather than introduce another terminal model. |
| `MPTCPBootstrap` | Uses Network.framework-backed NIOTS connections; deliberately does not enable MPTCP. | Keep this transport path and entitlement boundary. |

Sources: recovery manager, startup retry, health monitor, session startup/controller, recovery UI, tmux bridge, and bootstrap.[^retry][^initial][^health][^citadel][^controller][^recovery-ui][^tmux-code][^tmux-sessions][^bootstrap]

The keepalive timeout issue is a **verification requirement**, not a confirmed dependency bug. Swift task groups wait for their children, and cancellation is cooperative; a task-group race alone cannot guarantee a deadline for a cancellation-insensitive operation. The repository's `AsyncTimeout.swift` documents the same concern.[^swift][^timeout]

## 4. Mandatory invariants

The following requirements apply to every implementation phase.

**CON-01 — One owner.** Each logical connection has one recovery coordinator and at most one active connection attempt. Projected tmux panes share their gateway's coordinator.

**CON-02 — Generation isolation.** Every asynchronous transport, authentication, probe, output, and reconciliation callback is associated with a connection generation. A superseded generation cannot write to a replacement terminal or change its state. Stale completions must still settle their own promises and release owned resources.

**CON-03 — No invented success.** TCP connection, SSH authentication, or the return of `start()` alone is not sufficient to report tmux recovery.

**CON-04 — No blind replay.** Recovery never resends uncertain input, repeats a one-shot command, or reissues an unacknowledged mutating tmux command.

**CON-05 — No silent target substitution.** Recovery does not select another tmux session, create a missing session, change credentials, or weaken host trust to make progress.

**CON-06 — No arbitrary byte dropping.** SSH data and tmux control messages remain ordered and intact. Only a validated state-replacement protocol may supersede pane output.

**CON-07 — Cancellation wins.** User cancellation, closure, or a new connection intent invalidates all older attempts before their completion can be adopted.

**CON-08 — Bounded resources.** Retry timers, queued input, pending requests, snapshots, and abandoned-generation resources have explicit ownership and bounds.

**CON-09 — Honest continuity.** Plain SSH reconnection is not remote process resumption. tmux persistence is conditional on that server/session surviving and on server policy.

**CON-10 — Local recovery state.** Live recovery descriptors, input drafts, and connection diagnostics do not enter CloudKit or iCloud Keychain sync.

## 5. Logical session model

Introduce a `RecoveryContext`, owned above the current SSH session object. Its implementation may be an actor or an existing main-actor coordinator, but policy must be independently testable without UIKit, a real network, or Ghostty.

The context contains:

| Field | Contract |
| --- | --- |
| `logicalSessionID` | Local UUID retained across replacement transports; gateway-scoped for control mode. |
| `connectionGeneration` | Monotonically advancing local generation, incremented before retiring a transport or changing intent. |
| `intent` | Typed choice: `attachExistingTmux`, `interactiveShell`, or `oneShotCommand`. Never infer replay safety from command text. |
| `targetIdentity` | Host/trust scope, port, username, resolved credential reference, jump-host configuration, and tmux socket selection. IP address is transport metadata, not the trust identity. |
| `tmuxIdentity` | Verified server-instance evidence, session ID and creation metadata, last observed name, and surviving window/pane IDs. |
| `recoveryPreference` | Snapshot of applicable settings; configuration changes are adopted at an explicit boundary. |
| `attemptState` | Actual dial count, backoff deadline, recovery epoch, cooldown, and cancellation status. |
| `freshness` | Last authenticated target activity, last confirmed round trip, probe state, and pane synchronization state. |
| `presentationState` | Local tab/pane identity, selection, latest requested size, and bounded read-only display retention. |

A local connection generation identifies asynchronous ownership only. It is neither a server-instance identifier nor a resumable-stream byte offset.

Do not serialize tasks, channel objects, private-key material, or raw Ghostty pointers. Store credential references, then resolve them through the existing identity layer at connection time.

A synced profile edit must not silently redirect an in-progress recovery. Stage it for the next explicitly adopted connection intent. A name-only “last tmux session” preference remains a convenience for initial selection, not authoritative recovery identity.

## 6. State machine

Use these observable states; internal transport details may be richer.

```text
live
  -> suspect
       -> live                         existing transport proved healthy
       -> waitingForConnectivity
       -> recovering(connecting -> authenticating -> attaching -> synchronizing)
            -> live
            -> waitingForRetry(deadline)
            -> awaitingUser(reason)

any active state -> suspended(savedRecoveryIntent)
any state        -> stopped            explicit local stop
live             -> exited             verified normal remote exit
```

`awaitingUser` includes rejected trust, unavailable credentials, cancelled authentication, unknown command outcome, missing/ambiguous tmux identity, unsupported recovery, and protocol incompatibility. Network restoration does not bypass this state.

`stopped` and `exited` are terminal for that intent. Only a new user action starts another intent. A known clean shell exit, tmux detach, or intentional tab closure must not trigger auto-recovery.

Suspension is not failure and consumes no attempts. Resume reevaluates the current path, settings, intent, and generation; it does not replay a backlog of timer or reachability events.

A quiet terminal can be `live`. “No output” alone is not failure. Transport freshness and pane synchronization are distinct: a healthy SSH channel may still carry a stale or paused pane.

## 7. Retry policy and deadlines

### 7.1 One retry budget

The coordinator owns post-disconnection retries. Expose a single-attempt connection operation from the SSH session/bootstrap layer. Recovery must not invoke a three-attempt startup loop inside each outer retry.

Initial user-initiated connection may keep a separate bounded startup policy. Both paths must use common typed failure classification, cancellation, and deadline primitives.

Increment `attemptCount` only when an actual connection attempt begins. Waiting, receiving path events, cancelling a scheduled wait, being suspended, and lacking a usable path consume no attempts. One attempt spans the configured target route; a jump and target handshake are stages, not independently multiplying retry loops.

### 7.2 Proposed scheduling defaults

All numerical values below are proposed policy defaults, not measured optimal settings. Keep them in an injectable `RecoveryPolicy`.

| Parameter | Initial value |
| --- | --- |
| First eligible attempt | Immediate, subject to global scheduling and event coalescing |
| Rapid retry burst | Existing `autoReconnectMaxAttempts`, default 5 |
| Delay before subsequent burst attempt `n >= 2` | Equal jitter: random value in `[b/2, b]`, where `b = min(30 s, 2^(n-2) s)` |
| After burst exhaustion | One attempt per 60-second cooldown, jittered ±20%, while foreground-active and path-eligible |
| Path-event coalescing | 500 ms trailing debounce, with a 2-second maximum deferral |
| Fast-path bypass rate | At most once per logical connection per 5 seconds |
| Stable-ready period before clearing failure history | 30 seconds |
| Global concurrent automatic attempts | 2; at most 1 per equivalent endpoint/credential route |
| Preference within the queue | Visible gateway first, then fair scheduling of other eligible sessions |

A meaningful restored path or foreground activation may bypass cooldown once. Repeated equivalent path notifications must not reset backoff. Reaching the burst limit is not permanent failure: retain the intent and continue with the low-rate foreground policy.

Pause automatic dialing when destination-relevant evidence establishes no usable route. A generic `NWPathMonitor` result is a hint, not an absolute reachability gate: unknown/VPN-on-demand cases must still be allowed a bounded Network.framework connection attempt. Do not start repeated attempts merely because the global path is `satisfied`.

### 7.3 Deadlines and failure classification

Preserve the existing 30-second TCP connect cap and generous five-minute interactive login allowance initially; do not shorten VPN setup or count human authentication time as an ordinary network stall. The current source deliberately separates those budgets.[^citadel][^initial]

Each dial, handshake, PTY request, attachment, and synchronization stage must have an owned deadline. Attachment/synchronization starts with a proposed 10-second no-progress deadline and a 30-second overall deadline per stage. Valid, generation-matched progress may reset the inactivity deadline but not the overall deadline. Authentication prompts retain their separate allowance.

Use monotonic elapsed time. Cancel running deadlines on suspension, and establish fresh foreground checks rather than firing every overdue timer immediately. Wall-clock timestamps may be used for presentation and logs, not retry arithmetic.

Classify failures by typed domain and hop: transport unavailable, timeout, authentication needed/rejected, host trust rejected, cancelled, session missing, remote exit, protocol mismatch, or resource limit. Do not classify solely by localized message substrings. An unknown error may get the bounded burst, then requires attention instead of indefinite retries.

No background re-prompting, automatic OTP resubmission, or repeated biometric prompts. A human-cancelled or expired authentication interaction returns to `awaitingUser`.

## 8. Liveness and freshness

### 8.1 Evidence

Observe authenticated inbound traffic from the **destination SSH connection**, not merely its bastion. Maintain `lastTargetActivity`, `lastConfirmedRoundTrip`, and the age of the active pane's synchronized state separately.

Use the existing keepalive mechanism without writing bytes into the remote PTY. A protocol-level rejection of an unsupported global request can still confirm a round trip; authentication rejection or a local error cannot. Preserve SSH reply ordering: global-request replies correspond to requests by order, so local timeout bookkeeping must not let a late reply acknowledge a newer request.[^ssh]

Do not call probe failure rate “packet loss.” Display RTT with its age; stale historical RTT must not imply current health. Cancellation and intentional suspension are excluded from the probe-failure denominator.

### 8.2 Scheduling

With health monitoring enabled, retain the configured default 15-second probe interval, but defer periodic probes while recent authenticated target traffic establishes inbound freshness. When user input has outstanding transport work or outbound progress is suspect, inbound traffic alone is not sufficient to suppress a round-trip check indefinitely.

After a relevant path change or foreground activation, validate the existing transport once before replacing it. Allow a proposed 2-second handoff grace period where appropriate. If a fresh request/reply has already validated that transport after the event, no extra probe is needed.

The first user interaction after the configured interval without a confirmed round trip also schedules one validation, subject to the single-probe rule. User input and a successful local write never advance server-activity timestamps.

With periodic health monitoring disabled, do not run the periodic loop. A bounded one-shot validation associated with foreground recovery, a detected path change, stale user interaction, or a transport error remains part of recovery; explain this distinction in settings.

### 8.3 Timeout and ownership

Allow at most one unresolved keepalive request per SSH connection. Start with a 10-second request deadline. The coordinator must observe deadline expiry even when the underlying future ignores task cancellation.

Deadline expiry marks the round trip unverified, not the remote process dead. If target output is still arriving, report that distinction rather than claiming total server silence. A tmux intent may retire that transport and recover. A plain-shell intent keeps its last display and offers an explicit new-shell action rather than destroying the user's apparent session to create another one.

A timeout implementation must provide single completion, parent cancellation, generation checking, and a transport/request cleanup path. Replacing the task-group race with unstructured tasks alone is insufficient. If a timed-out request remains owned on a retained connection, reserve its FIFO position and issue no replacement probe until it resolves or the connection is retired. Unrelated authenticated traffic must not be mislabeled as that probe's response.

Retirement closes/aborts owned channels and resolves pending operations. Allow a proposed 2-second graceful-close budget before invoking the verified abort path; never block the UI while waiting. Returning from a timeout is not evidence that a file descriptor or event-loop resource has been reclaimed. Repeated blackhole tests must show bounded resources. Do not reallocate the shared event-loop group per attempt.

## 9. Recovery behavior by session type

### 9.1 tmux control mode: required continuity path

Preserve the logical gateway and its local group while replacing transport-bound objects. Freeze the last valid presentation, mark it stale, and gate remote input.

On recovery, perform these operations in order:

1. Establish SSH with the original host-trust and credential policies, including both hops when configured.
2. Discover the intended tmux server/socket and validate server-instance and session evidence.
3. Attach to the exact existing session using safe structured/escaped command construction. Never use create-or-attach behavior on a recovery path.
4. Initialize a fresh, generation-bound control-mode parser/viewer and command-reply queue.
5. Reconcile windows, panes, titles, hidden-window policy, sizes, and the currently visible terminal state.
6. Publish readiness only after a matching reconciliation commit and visible-pane synchronization confirmation.

Use server/session IDs rather than display names or indexes. The tmux manual exposes process/start and session-creation metadata that can contribute to continuity checks; those fields are not credentials or a universal cryptographic incarnation identifier.[^tmux-man]

Store the strongest evidence supported by the tested server: socket identity, server PID/start metadata, session ID, and session creation metadata. A renamed session with matching continuity evidence remains the same session. A name reused by a different session does not.

If a server restart, insufficient evidence, or legacy name-only state prevents establishing identity, ask the user to select an existing session. Do not claim restoration. Revalidate the identity after attachment before enabling input to cover discovery/attach races. Authentication proves the host, not that a particular tmux process survived.

Do not kill or detach other clients to simplify recovery. Do not start a new tmux server as a side effect of discovery/recovery; server-not-running is a missing-session outcome. Respect host settings that intentionally terminate unattended sessions rather than changing them automatically.

### 9.2 Regular tmux mode

Reattach only to a verified existing session. Preserve regular-mode rendering rather than silently switching the user's profile into control mode. Report attachment readiness after the PTY/attachment contract succeeds; do not claim the native pane-by-pane synchronization guarantees of control mode.

If the supported server/launch path cannot verify this contract, require explicit attachment. A prompt-shaped output string is not proof of successful attachment.

### 9.3 Plain interactive SSH

Keep the original transport during a temporary interruption when it may recover. If it becomes unusable, offer **Open new shell**. Do not call that action “Resume session.” Preserve the old display as a separately identifiable read-only history instead of appending a new shell invisibly to it.

The first release must not silently convert plain SSH into tmux. Explain that session-preserving recovery requires tmux when the user configures a profile.

### 9.4 Remote commands and shell-launched SSH

A one-shot `exec` command is never automatically rerun after dispatch may have occurred. Missing exit status is not evidence that it did not execute. Initial connection retries before command dispatch remain permitted; after uncertain dispatch, show `commandOutcomeUnknown` and require an explicit restart action.

Do not replay startup commands, authentication responses, terminal replies, or mutating tmux commands from an old generation. Read-only discovery can be repeated after a fresh connection.

Apply the same policy to embedded shell-launched SSH. Closing or cancelling that embedded connection must not terminate the containing local shell or allow its stale recovery task to reopen the remote connection.

### 9.5 Readiness API

Reuse or strengthen the existing `TerminalSession.onReady` contract, or introduce a distinct typed recovery-readiness event. Its evidence must include the connection generation and readiness kind.[^terminal-api]

For ordinary SSH, PTY allocation, shell/exec request acceptance, and installed input/output handlers establish terminal readiness; a quiet shell need not emit a byte. For control mode, add verified target identity, committed topology, and synchronized visible panes. `syncEnd` alone establishes topology, not necessarily terminal contents.

An 8-bit terminal stream or banner text must never be parsed heuristically as a readiness signal. Unsupported library visibility into acceptance/readiness requires an adapter or dependency change, not a timer that declares success.

## 10. Input safety and backpressure

Gate all input paths on current-generation readiness: hardware keyboard, software keyboard, paste, accessibility actions, macros, terminal-generated replies, and tmux command routing. Cached terminal replay must not generate replies toward a new connection.

While suspect, waiting, suspended, or synchronizing, do not silently queue raw keystrokes. Keep selection, search, copy, and local cancellation available. Offer the existing compose UI explicitly; do not automatically divert password entry or an arbitrary key stream into a visible draft.

A draft is local, memory-only, bound to the logical target, capped at a proposed 64 KiB of UTF-8, and never auto-submitted. On recovery, the user reviews the destination and explicitly sends it. App termination or memory eviction may lose a draft; do not promise durable draft recovery. Clear it when its logical target is closed, and do not sync, log, or add it to shell history.

For live input, retain the ordered writer but introduce bounded producer backpressure. Initial pending-input budget: 256 KiB per connection, with incremental paste production. Overflow must suspend production or reject it visibly before acceptance; never drop the oldest bytes or reorder control keys around a paste. Existing scrollback limits remain separate.

On generation retirement, stop sending queued data through the old writer, cancel paste production, and discard connection-bound unsent data with an interruption indication. Do not copy it to the replacement writer. Data already accepted by a socket or SSH write API remains potentially delivered; do not automatically classify it as safe to replay.[^et]

Resize is different from command input: retain only the latest desired dimensions and apply them when the intended target is attached. Do not replay every intermediate rotation/keyboard resize. Other ordered actions are not automatically “latest wins.”

## 11. Conditional tmux flow control and state catch-up

Mosh's latest-screen principle can inform a tmux-specific optimization without changing the SSH transport. tmux control mode supports `pause-after`, `%pause`, `%continue`, and `%extended-output`; enabling flow control changes the pane-output notification format. Client-side pane refresh is the client's responsibility.[^tmux-control]

### 11.1 Capability gate

Enable this only when both the actual tmux server and the bundled Ghostty viewer support all required messages, reply ordering, and state restoration. Feature-probe rather than infer support from a version string alone. Begin with a local developer-only switch, off by default.

The baseline pins Citadel-rootshell 0.12.3 and GhosttyKit-rootshell 0.2.8. Their relevant cancellation and snapshot semantics must be verified against those exact revisions; a current upstream feature is not proof of support in the shipped binary.[^dependencies]

### 11.2 Safe state replacement

Ghostty remains the sole terminal interpreter. Do not add a Swift terminal emulator or treat `capture-pane` text as a complete terminal serialization.

Before replacing any pane state, the implementation must establish a tested barrier between the accepted snapshot and subsequent output. The design must account for screen buffers, cursor, attributes, dimensions, relevant modes, pending escape parsing, Unicode state, and interleaved control responses. Each snapshot and continuation is generation- and pane-bound.

Validate with output changing continuously during capture. A capture followed by blindly replaying buffered output is not acceptable: it may duplicate state or apply old output after a newer snapshot. If the pinned protocol/core cannot provide a safe boundary, keep this optimization disabled and use normal non-dropping reattachment/reconciliation. Never “solve” the boundary by discarding arbitrary protocol bytes.

Visible panes get synchronization priority. History remains bounded by existing limits; after a discontinuity, mark unavailable history instead of manufacturing a complete transcript. Preserve all control-command responses even when pane-output delivery is paused.

### 11.3 Hidden panes and other clients

Do not use a hidden pane's `off` state merely to save bandwidth: tmux documents that turning output off for all clients can stop reading from the process's PTY and thereby affect application progress.[^tmux-man]

Ship hidden-pane suppression only after tests demonstrate the intended remote-process behavior, restoration on reveal, and no regression for another attached client. Hiding a window never authorizes killing it or changing another client's subscriptions. Maintain a capability-safe fallback to normal delivery.

Local rendering coalescing is an independent CPU optimization. Only server-side suppression/state replacement can reduce bytes that would otherwise traverse the mobile connection; report these effects separately.

## 12. Recovery user interface

Use a native, accessible status strip or overlay outside the Ghostty output stream. Do not inject recovery spinners, countdowns, success lines, or errors into either normal or alternate-screen terminal contents.

Suggested copy:

| State | Status/action |
| --- | --- |
| `suspect` | “Checking connection…”; retain the last screen. |
| `waitingForConnectivity` | “Waiting for network”; show last verified activity age. |
| `waitingForRetry` | “Retrying in …”; expose **Retry now** and **Stop recovery**. |
| `authenticating` | “Authentication required”; identify jump host or destination accurately. |
| `attaching` | “Reattaching to session …” |
| `synchronizing` | “Restoring terminal state…” |
| Missing session | “The previous session is unavailable”; expose explicit session selection. |
| Uncertain command | “Connection lost. Command outcome unknown.” |

Display age as “Last verified activity … ago,” not “The server has been offline for ….” Show stale status per pane when transport is healthy but its state is paused or unsynchronized.

Retain stable tabs and group identity without retaining freed viewer pointers. Use a bounded immutable render snapshot or explicitly owned live-state retention. If neither is safe, show a stale placeholder rather than risking a use-after-free. Newly constructed terminal objects are allowed; preserved raw pointers are not required.

Do not steal focus if the user changed tabs while recovery was running. Announce major accessibility state changes once; do not announce every countdown tick. No animated polling continues while suspended. Preserve existing authentication-banner handling as a separate trusted-UI concern.

## 13. Application lifecycle and multiple windows

Treat iOS/iPadOS/visionOS suspension as expected. The specification does not promise continuous background execution; Apple does not provide a general-purpose mechanism for an app to run arbitrarily while suspended.[^background]

On backgrounding, pause recovery/probe timers, cancel or suspend owned network work through verified APIs, retain device-local intent, and allow the process to quiesce. Do not add audio, location, VPN, push, or other background capabilities as keepalive workarounds. Any existing legitimate finite background allowance may be used only within its real expiration contract.

On foreground activation, wait for the existing scene-mutation safety gate, coalesce path information, then validate or recover once. A callback received during a quiet window must not create a second attempt or lose the latest meaningful path transition.

Update durable recovery descriptors at intent changes and safe checkpoints, not only at background callbacks: termination may occur without a final callback. Cold app launch restores descriptors, not transports, tasks, or an assumption of readiness. Draft input and uncertain commands are not replayed.

Coordinate app lifecycle at application/gateway scope, not per pane. One disappearing SwiftUI view or one backgrounded scene must not suspend a connection still used by another active scene. On Mac Catalyst, loss of window focus alone is not mobile-style suspension; retain normal desktop operation and validate after system sleep/wake.

## 14. Settings, persistence, and migration

Keep the current registry as the sole settings authority. Preserve unknown enum values and previously stored settings; no broad profile-schema rewrite is part of this work.[^settings]

| Existing setting | Specified behavior |
| --- | --- |
| `autoReconnectEnabled` | Master gate for automatic replacement attempts. Turning it off cancels recovery, but does not close an otherwise healthy connection. |
| `autoReconnectMaxAttempts` | Attempts per rapid burst, not session lifetime. Relabel as “Attempts per recovery burst”; preserve valid stored values. |
| `healthMonitoring` | Enables periodic probes/diagnostics, separate from event-driven recovery validation. |
| `healthProbeInterval` | Retained as the periodic baseline; validate malformed values before creating timers. |
| `backgroundKeepalive` | Preserve the key; wording must describe only finite, OS-permitted continuity attempts, never guaranteed background connectivity. |
| tmux default mode/name | Continue to govern initial connection. Do not overwrite explicit profile choices or use them to replace a missing recovery target. |

The first release adds no required public tuning knobs. Retry jitter, bounds, and stage deadlines live in a tested internal policy. Temporary development switches are device-only and must not accidentally sync.

Store versioned recovery descriptors in the existing device-local restoration mechanism, keyed by logical session/gateway UUID. Validate them before use. Legacy records containing only a session name require rediscovery and explicit selection when continuity cannot be established.

Do not synchronize descriptors, per-connection timestamps, diagnostic rings, pane captures, or drafts. Existing profile and credential sync remains unchanged. Existing terminal-history persistence, when enabled, retains its protection and retention rules; this work does not add a second snapshot database.[^extraction]

## 15. Security and diagnostic requirements

Reconnect with the original host-trust scope even when DNS resolves to a different address. Host-key changes, unavailable device-bound keys, and authentication rejection require the appropriate explicit flow. No new fallback to password, a different user, a different host, or a weaker trust policy is permitted.

Attribute failures and prompts to the hop that actually failed. Preserve the existing Secure Enclave authorization policy. Do not bypass user presence to make recovery feel seamless, and do not let a blocking authentication operation stall every independent SSH connection.

Validate and escape server-derived names before using them in commands. Use exact IDs where possible. A remote hostname, tmux name, banner, or error string is untrusted display data, not an instruction to alter recovery policy.

Use a bounded in-memory diagnostic ring, initially 128 events per coordinator. Record state/stage, reason code, generation, attempt ordinal, elapsed timings, path category, and byte counts. Do not record commands, terminal text, draft input, credentials, authentication answers, or resume secrets. Diagnostic export is explicit and redacts identifying fields by default. No analytics service is introduced.

## 16. Implementation map

Paths below refer to existing files unless marked **proposed**. New type names are design suggestions; the behavioral contracts are mandatory.

| Area | Integration point |
| --- | --- |
| Recovery ownership and pure policy | Refactor `shell/Core/Terminal/Reconnect/ReconnectionManager.swift`; add **proposed** `RecoveryPolicy.swift`, `RecoveryContext.swift`, and typed events/errors in that directory. |
| Attempt/deadline control | `InitialConnectRetry.swift`, `CitadelSSHSession.swift`, `SSHConnectionHelper.swift`, `MPTCPBootstrap.swift`, and `Core/Foundation/AsyncTimeout.swift`. |
| Health and path evidence | `Core/Connection/ConnectionHealthMonitor.swift`, `ConnectionHealth.swift`, and `NetworkReachabilityMonitor.swift`. |
| Readiness and input gates | `Core/Terminal/TerminalSession.swift`, `TerminalSessionController.swift`, `TerminalResponsePipeline.swift`, `TerminalOutputPipeline.swift`, and `UI/Terminal/TerminalInputController.swift`. |
| Embedded SSH parity | `Features/LocalShell/LocalShellSession+EmbeddedSessions.swift` and its existing cancellation/input routing. |
| tmux identity and reconciliation | `Features/Tmux/TmuxController.swift`, `TmuxController+Sessions.swift`, `TmuxGatewaySessionStore.swift`, and the pinned Ghostty viewer/bridge as necessary. |
| Recovery presentation | `TerminalReconnectionController.swift`, `UI/Overlays/ReconnectionOverlayView.swift`, and `UI/Terminal/PanePresentationState.swift`. |
| Draft UI | Reuse `UI/Overlays/TerminalComposeOverlay.swift`; enforce explicit entry and target binding. |
| Lifecycle and restoration | `UI/Shell/MainView+Lifecycle.swift`, `Core/Terminal/Reconnect/TerminalRestorationReconnector.swift`, and existing local persistence. |
| Settings and tests | `Core/SettingsSync/Registry/Settings+Connections.swift`, `tests/ShellTests/`, and a **proposed** opt-in network fault harness under `tests/`. |

All mutations of a new-generation connection must flow through the coordinator. Replace ad hoc reconnect triggers rather than adding a second set beside them. Networking work stays off the UI actor except for serialized ownership/state transitions.

## 17. Acceptance and verification

### 17.1 Deterministic regression suite

Use an injected monotonic clock, seeded jitter source, fake path/lifecycle source, controllable transport, and recorded tmux protocol fixtures. Timers must not make these tests depend on real sleeping.

| ID | Scenario | Required result |
| --- | --- | --- |
| AC-01 | Ten-minute offline period with an existing tmux intent | No dial attempts while unavailability is established; restoration triggers recovery without manual reset. |
| AC-02 | Five actual rapid failures, then cooldown | Intent survives; low-rate attempts continue only when eligible. A meaningful new path can bypass once. |
| AC-03 | 100 duplicate path notifications during a scheduled wait | No extra attempt counts; one coalesced event; no parallel attempts. |
| AC-04 | Wi-Fi-to-cellular change without a global offline event | Existing transport is validated; a stale one recovers; a healthy one is not unnecessarily replaced. |
| AC-05 | Same-interface route/VPN change and unknown on-demand path | Bounded target-aware evaluation; no permanent false-offline gate. |
| AC-06 | Silent blackhole, no FIN/RST, cancellation-insensitive keepalive | Deadline is observable; input is gated; one unresolved probe maximum; no unbounded orphan work. |
| AC-07 | Late keepalive reply after timeout | FIFO/request ownership is preserved; it cannot acknowledge a new request or new generation. |
| AC-08 | Close/cancel during dial, authentication, PTY setup, or sync | Late success is closed/discarded; no reopened tab, output, or success state. |
| AC-09 | Background/foreground repeatedly during each stage | No spent attempts while paused, no timer storm, one valid recovery on resume. |
| AC-10 | SSH succeeds but PTY fails, or tmux topology arrives before pane contents | Never publish premature session-restored readiness. |
| AC-11 | Session renamed while offline | Reattach only when continuity evidence still matches; update its display name. |
| AC-12 | Session deleted/recreated with the same name; tmux server restarted | No automatic substitution or create-or-attach; require explicit selection. |
| AC-13 | Session/window/pane changes during recovery | Atomic current-generation reconcile; no duplicate tabs, freed-pointer use, or focus theft. |
| AC-14 | Drop immediately before/after Enter, paste segment, or mutating tmux command | No automatic replay. Surface uncertainty; interrupt remaining paste production. |
| AC-15 | One-shot command loses its exit status | No second dispatch, including after app relaunch. |
| AC-16 | Plain SSH connection lost | Never claim process resumption; new shell requires the explicit action. |
| AC-17 | Expired/cancelled auth challenge, changed host key, missing Secure Enclave identity | Correct target/hop and explicit attention; no retry-prompt loop or new fallback. |
| AC-18 | Native recovery overlay over full-screen application | Terminal content/cursor bytes remain unchanged by recovery UI. |
| AC-19 | Large paste and repeated resize while connection stalls | Input queue remains within budget; no silent overflow; only latest resize applies. |
| AC-20 | Two active scenes, one backgrounded; many tmux panes | Shared connection remains correctly owned; one gateway attempt, fair global limit. |
| AC-21 | Auto-reconnect disabled during recovery; clean remote exit | No automatic replacement despite later network events. |
| AC-22 | Legacy/unknown restoration data or synced profile edit | No unsafe target change, command rerun, or destructive migration. |
| AC-23 | Shell-launched SSH cancellation | Local shell survives; embedded remote connection cannot reopen itself. |
| AC-24 | Health reporting after timeout or suspension | RTT is age-qualified; cancelled samples are excluded; no false packet-loss metric. |

### 17.2 Conditional flow-control suite

Before enabling section 11, test all extended-output notifications and unknown extension fields; fragmented and interleaved command responses; continuously changing output during capture; primary/alternate screen transitions; cursor and terminal modes; split UTF-8 and escape sequences; history discontinuities; pause/reveal; and another attached control or regular client.

At least one fixture must fail an intentionally incorrect “capture, then replay everything” implementation. Prove that hidden-pane optimization does not unexpectedly stop the remote producer. Unsupported capabilities must leave ordinary SSH/tmux operation usable with optimization off.

### 17.3 Device and fault-injection matrix

Exercise physical mobile devices and Mac Catalyst, not just the simulator. Record exact OS, hardware, app commit, dependency revisions, and server/tmux versions. Test direct SSH and a jump host, IPv4/IPv6 configurations, an external VPN-on-demand route, short and multi-minute loss, NAT/address change, high latency/jitter, burst loss, connection refusal, and silent packet dropping in each direction.

Use a controlled remote counter/log to observe command dispatch without storing real user commands in application telemetry. Compare application-observed readiness with the actual intended pane/session identity. Include a busy pane, a quiet shell, and a full-screen application.

Proposed lab gates, not field guarantees:

| Measure | Acceptance target |
| --- | --- |
| Eligible recovery scheduling | Begins within 500 ms after the coalescing/activation gate opens and a global slot is available. |
| User cancellation | UI acknowledges within 250 ms while foreground-active; no later adopted success. |
| Probe deadline | Coordinator notified within 500 ms of the configured deadline under the non-suspended lab workload. |
| Resource stability | 100 blackhole/recovery cycles, then a drain period: no accumulation of owned channels, pending probes, timers, or per-attempt event-loop groups. |
| Input/action duplication | Zero automatic duplicate dispatches in the injected ambiguous-delivery scenarios. |
| Visible tmux recovery | Measure p50/p95 from usable path to correct interactive pane; initial target p95 ≤20 s for an unprompted direct connection at 100 ms RTT, ≥10 Mbit/s, four 120×40 panes, and 1,000 retained lines per pane. |

Human authentication time, user-selected sessions, and OS suspension are measured separately, not hidden inside or subtracted without disclosure from reported results. The latency target does not override trust, resource, or correctness gates. Measure transferred bytes and rendering CPU separately when evaluating flow control.

## 18. Delivery sequence and release gates

**Change set A — Recovery policy.** Introduce typed context/events, generation isolation, single-attempt recovery, path coalescing, burst/cooldown accounting, and deterministic tests. Preserve existing startup behavior outside recovery until parity tests pass.

**Change set B — Transport lifecycle.** Implement verified operation cancellation/deadlines, liveness ownership, hop-aware failures, bounded input, and true PTY readiness. Validate the pinned dependencies; update a dependency only with a targeted change and regression evidence.

**Change set C — tmux and presentation.** Implement verified existing-session attachment, readiness reconciliation, stable local gateway identity, native recovery UI, explicit draft handling, lifecycle coordination, and local migration. First-release completion requires A–C and all applicable AC-01–AC-24 tests.

**Change set D — Optional state catch-up.** Add capability-gated flow control only after its core/protocol tests pass. Disable it cleanly on unsupported combinations. A–C ship without it.

Do not roll back by reintroducing unsafe command replay or bypassing trust. Optimization rollback returns to ordered non-dropping SSH/tmux behavior. If verified continuity is unavailable, the safe fallback is explicit user action, not a misleading automatic “restore.”

Update `README.md` and the reconnect section of `spec.md` when implementation is accepted. Document the plain-SSH limitation, recovery-burst setting semantics, no guaranteed background connection, and no exactly-once execution promise. Keep extraction and settings-inventory tests passing.

## 19. Future ET-style resumable stream: separate decision

ET demonstrates session continuation using directional receive positions and retained output, including support for tmux control-mode traffic. Borrowing that architecture is different from simply retrying SSH.[^et]

A future proposal may compare a real ET-compatible client with a narrow per-user persistent relay reached through SSH. Neither is approved by this specification. It must define:

**Authentication and ownership.** Bind session identity to the authenticated host and user. Authenticate resume attempts, expire/revoke credentials, rate-limit failures, and fence old connections before a replacement can send input. Do not invent a new cipher or place resume secrets in logs, URLs, CloudKit, or command arguments.

**Stream semantics.** Specify both directional offsets, framing, acknowledgement meaning, deduplication, partial writes to the remote PTY, resize ordering, bounds, and buffer exhaustion. A connection generation alone does not deduplicate byte delivery. Resending is permitted only within the same authenticated session and retained sequence space.

**Crash semantics.** Distinguish a transient network interruption from client termination, helper crash, and host reboot. Acknowledgement means the defined stream/relay boundary was reached, not that a shell command completed exactly once. Relay crashes around PTY writes remain an explicit uncertainty unless a stronger end-to-end execution contract exists.

**State retention.** Client output offsets must correspond to terminal state actually retained by that client. Do not persist a receive cursor and then silently skip bytes needed to reconstruct a lost terminal/parser after relaunch. tmux control streams require their protocol state or a fresh verified attachment, not just a screenshot.

**Deployment and scope.** Specify installation, unprivileged execution, session quotas, cleanup, revocation, version negotiation, and an SSH-only fallback. Keep the Watch companion and approval broker separate. Do not treat ET terminal transport as a general SSH channel implementation.

Mosh integration, QUIC, MPTCP, and predictive echo remain separate product/architecture decisions. None is a prerequisite for the first release described here.

## 20. Definition of done

The work is complete when a surviving tmux session recovers from the specified mobile disruptions without duplicate actions, misleading readiness, corrupted recovery UI, or unbounded work; plain SSH and one-shot commands have explicit safe outcomes; identity/security and sync boundaries remain intact; and the deterministic plus device tests provide recorded evidence.

A shorter reconnect spinner is not completion. The success criterion is the **correct existing terminal becoming safely interactive again**.

---

## References

Repository observations below are pinned to the reviewed baseline. External references describe mechanisms; proposed policy numbers and architecture decisions in this document are Shell requirements, not claims made by those projects.

[^readme]: [Shell README at the reviewed commit](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/README.md): minimal-fork invariants, terminal/tmux architecture, optional control-companion separation.
[^extraction]: [Shell extraction specification](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/spec.md): SSH scope, known-host trust, tmux, sync exclusions, and entitlement boundaries.
[^retry]: [ReconnectionManager.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Terminal/Reconnect/ReconnectionManager.swift): `startReconnectionLoop`, `calculateDelay`, `handleNetworkRestored`.
[^initial]: [InitialConnectRetry.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Terminal/Reconnect/InitialConnectRetry.swift): startup retry policies and interactive login-budget separation.
[^health]: [ConnectionHealthMonitor.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Connection/ConnectionHealthMonitor.swift): `sendKeepalive`, task-group deadline race, and `calculateHealth`.
[^citadel]: [CitadelSSHSession.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Features/SSH/Session/CitadelSSHSession.swift): `start`, `performInitialConnect`, PTY startup, input writer, and cleanup.
[^controller]: [TerminalSessionController.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Terminal/TerminalSessionController.swift): `performReconnection` and session replacement.
[^recovery-ui]: [TerminalReconnectionController.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Terminal/Reconnect/TerminalReconnectionController.swift): recovery UI writes and stale-session guard.
[^tmux-code]: [TmuxController.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Features/Tmux/TmuxController.swift): Ghostty-owned protocol/terminal state, reconciliation operations, and payload lifetimes.
[^tmux-sessions]: [TmuxController+Sessions.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Features/Tmux/TmuxController%2BSessions.swift): command replies and attached-session identity.
[^bootstrap]: [MPTCPBootstrap.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Features/SSH/Session/MPTCPBootstrap.swift): NIOTS/Network.framework bootstrap, shared event loops, and deliberately disabled MPTCP.
[^timeout]: [AsyncTimeout.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Foundation/AsyncTimeout.swift): cancellation-insensitive operations and existing hard-timeout helper limitations.
[^terminal-api]: [TerminalSession.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/Terminal/TerminalSession.swift): readiness callback, disconnect distinction, and lifecycle hooks.
[^settings]: [Settings+Connections.swift](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell/Core/SettingsSync/Registry/Settings%2BConnections.swift): existing connection/tmux settings and defaults.
[^dependencies]: [Package.resolved](https://github.com/chr33s/shell/blob/577616f483373cffa0d25e052aee3f46e76588cc/shell.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved): Citadel revision `57b6c3a0d2c7161bec7f9b4cdf4b009b2b69d30f`; GhosttyKit revision `413b720e5602b7bdfb948009f8c19773f6de1ce4`.
[^mosh]: [Mosh: technical information and design principles](https://mosh.org/#techinfo), consulted 2026-09-10. Screen-state synchronization, ordered input, roaming, prediction, and stale-state feedback.
[^et]: [How Eternal Terminal Works](https://eternalterminal.dev/howitworks/), consulted 2026-09-10. Buffered directional streams, received positions, authentication bootstrap, and tmux control-mode compatibility.
[^tmux-control]: [tmux Control Mode documentation](https://github.com/tmux/tmux/wiki/Control-Mode), consulted 2026-09-10. Flow control, output notifications, command responses, and client-managed refresh.
[^tmux-man]: [tmux manual, OpenBSD](https://man.openbsd.org/tmux.1), consulted 2026-09-10. Server/session format fields, client flow-control flags, output-off behavior, and persistence options. Verify the actual deployment's version before depending on a feature.
[^swift]: [Apple: TaskGroup](https://developer.apple.com/documentation/swift/taskgroup) and [The Swift Programming Language: Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), consulted 2026-09-10. Structured task lifetime and cooperative cancellation.
[^ssh]: [RFC 4254: SSH Connection Protocol, section 4](https://www.rfc-editor.org/rfc/rfc4254.html#section-4). Global-request reply ordering and success/failure responses.
[^background]: [Apple Developer Technical Support: iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525), consulted 2026-09-10. General-purpose background execution limits.
