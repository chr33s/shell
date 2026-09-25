# Mobile Connectivity and Session Recovery

**Status:** First release (sections 1–9, 11–15) implemented; conditional tmux flow control/catch-up (section 10) not implemented; device/fault matrix (16.3) evidence not yet recorded.
**Scope:** Recovering from mobile network disruption over the existing SSH, Network.framework, Ghostty, and tmux stack. Additive to [`shell.md`](shell.md); independent of [`control-protocol.md`](control-protocol.md).

## 1. Goal

The network can disappear; Shell keeps the last screen and the intent to reconnect, then securely reattaches to the intended tmux session and enables input only once terminal state is ready. No new remote service. A surviving tmux server is the only source of process continuity.

Shell MUST distinguish three outcomes:

- **Session restored** — the intended existing tmux session was verified and reattached.
- **New shell opened** — a new remote shell was explicitly requested; the old one was not resumed.
- **Command outcome unknown** — a connection failed around a remote action whose completion cannot be established; Shell did not rerun it.

"Mosh-inspired" means stale-state visibility and selective resync; "ET-inspired" means separating session identity from transport lifetime. Neither protocol is implemented.[^mosh][^et]

## 2. Scope

### 2.1 Required (first release)

Everything in sections 3–9 and 11–14, for profile-launched and embedded-shell-launched SSH. MUST preserve all existing auth methods (password, saved password, software key, Secure Enclave, certificate, keyboard-interactive), known-host, and jump-host behavior, reusing Ghostty and the native tmux bridge.

### 2.2 Conditional follow-on

tmux control-mode flow control and snapshot catch-up (section 10), only after the pinned Ghostty viewer and tested tmux versions demonstrate a safe synchronization boundary. MUST NOT block the first release; MUST have a non-dropping fallback.

### 2.3 Excluded

No Mosh dependency, custom UDP/QUIC transport, MPTCP entitlement, predictive echo, unrestricted offline keystroke queue, general command journal, SSH host-CA trust, or additional terminal emulator. Do not restore features removed by [`shell.md`](shell.md). Terminal traffic MUST NOT route through the Watch approval broker ([`control-protocol.md`](control-protocol.md)). An ET-compatible client or persistent relay requires a separate approved spec (section 17).

## 3. Invariants

- **CON-01 One owner.** One recovery coordinator and at most one active attempt per logical connection. Projected tmux panes share their gateway's coordinator.
- **CON-02 Generation isolation.** Every async transport/auth/probe/output/reconcile callback carries a connection generation. A superseded generation cannot write to or change a replacement; stale completions still settle their promises and release resources.
- **CON-03 No invented success.** TCP connect, SSH auth, or `start()` returning is not tmux recovery.
- **CON-04 No blind replay.** Never resend uncertain input, repeat a one-shot command, or reissue an unacknowledged mutating tmux command.
- **CON-05 No silent target substitution.** Never select another tmux session, create a missing one, change credentials, or weaken host trust to make progress.
- **CON-06 No arbitrary byte dropping.** SSH data and tmux control messages stay ordered and intact; only a validated state-replacement protocol may supersede pane output.
- **CON-07 Cancellation wins.** Cancel, close, or a new intent invalidates all older attempts before their completion can be adopted.
- **CON-08 Bounded resources.** Timers, queued input, pending requests, snapshots, and abandoned-generation resources have explicit owners and bounds.
- **CON-09 Honest continuity.** Plain SSH reconnection is not process resumption; tmux persistence depends on that server/session surviving.
- **CON-10 Local recovery state.** Recovery descriptors, drafts, and diagnostics never enter CloudKit or iCloud Keychain sync.

## 4. Logical session model

A `RecoveryContext` sits above the SSH session object; its policy MUST be testable without UIKit, a real network, or Ghostty.

| Field | Contract |
| --- | --- |
| `logicalSessionID` | Local UUID stable across transports; gateway-scoped for control mode. |
| `connectionGeneration` | Monotonic; incremented before retiring a transport or changing intent. Async ownership only — not a server identity or byte offset. |
| `intent` | `attachExistingTmux`, `interactiveShell`, or `oneShotCommand`. Never infer replay safety from command text. |
| `targetIdentity` | Host/trust scope, port, user, credential reference, jump config, tmux socket. IP address is transport metadata, not identity. |
| `tmuxIdentity` | Server-instance evidence, session ID + creation metadata, last name, surviving window/pane IDs. |
| `recoveryPreference` | Settings snapshot; changes adopted only at an explicit boundary. |
| `attemptState` | Actual dial count, backoff deadline, epoch, cooldown, cancellation. |
| `freshness` | Last target activity, last confirmed round trip, probe state, pane sync state. |
| `presentationState` | Tab/pane identity, selection, latest requested size, bounded read-only display. |

Never serialize tasks, channels, key material, or Ghostty pointers; store credential references and resolve at connect time. A synced profile edit MUST NOT redirect an in-progress recovery. A name-only "last tmux session" preference is for initial selection only.

## 5. State machine

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

- `awaitingUser` covers rejected trust, unavailable credentials, cancelled auth, unknown command outcome, missing/ambiguous tmux identity, unsupported recovery, protocol mismatch. Network restoration MUST NOT bypass it.
- `stopped`/`exited` are terminal for the intent. Clean exit, tmux detach, or tab close MUST NOT auto-recover.
- Suspension is not failure and consumes no attempts; resume re-evaluates path, settings, intent, and generation without replaying queued events.
- A quiet terminal can be `live`. Transport freshness and pane sync are separate.

## 6. Retry policy and deadlines

### 6.1 One retry budget

The coordinator owns post-disconnect retries via a single-attempt connect operation; recovery MUST NOT nest the startup retry loop. Initial user connect may keep its own bounded policy, sharing failure classification, cancellation, and deadline primitives. Count an attempt only when a dial actually begins — not waits, path events, cancelled waits, suspension, or no usable path. Jump + target handshake is one attempt.

### 6.2 Scheduling defaults

Injectable `RecoveryPolicy` defaults (proposed, not measured optima):

| Parameter | Default |
| --- | --- |
| First eligible attempt | Immediate (subject to global scheduling/coalescing) |
| Rapid burst | `autoReconnectMaxAttempts`, default 5 |
| Delay before burst attempt n ≥ 2 | Equal jitter in `[b/2, b]`, `b = min(30 s, 2^(n-2) s)` |
| After burst exhaustion | One attempt per 60 s ±20% while foreground and path-eligible |
| Path-event coalescing | 500 ms trailing debounce, 2 s max deferral |
| Fast-path cooldown bypass | ≤ 1 per logical connection per 5 s |
| Stable period before clearing failure history | 30 s |
| Global concurrent automatic attempts | 2; ≤ 1 per equivalent endpoint/credential route |
| Queue preference | Visible gateway first, then fair |

Meaningful path restoration or foreground activation may bypass cooldown once; duplicate path notifications MUST NOT reset backoff. Burst exhaustion retains the intent. Pause dialing only on destination-relevant no-route evidence; `NWPathMonitor` is a hint (unknown/VPN-on-demand still gets a bounded attempt), and `satisfied` alone MUST NOT trigger repeated attempts.

### 6.3 Deadlines and failure classification

- Keep the 30 s TCP connect cap and 5 min interactive-login allowance; human auth time is not a network stall.[^citadel]
- Every dial, handshake, PTY request, attach, and sync stage has an owned deadline: attach/sync 10 s no-progress and 30 s overall. Generation-matched progress resets inactivity only.
- Monotonic time for retry arithmetic; wall clock only for display/logs. Cancel deadlines on suspension; do fresh checks on foreground rather than firing overdue timers.
- Classify by typed domain and hop: transport unavailable, timeout, auth needed/rejected, host trust rejected, cancelled, session missing, remote exit, protocol mismatch, resource limit. Never by localized message text. Unknown errors get the burst, then `awaitingUser`.
- No background re-prompting, OTP resubmission, or repeated biometric prompts; cancelled/expired auth → `awaitingUser`.

## 7. Liveness and freshness

### 7.1 Evidence

Track `lastTargetActivity` (authenticated inbound from the **destination**, not the bastion), `lastConfirmedRoundTrip`, and active-pane sync age separately. Use SSH keepalive, never bytes into the PTY. A protocol-level rejection of a global request confirms a round trip; auth rejection or local error does not. Global-request replies are FIFO — a late reply MUST NOT acknowledge a newer request.[^ssh] Report probe failure rate, never "packet loss"; show RTT with its age; exclude cancelled/suspended samples.

### 7.2 Scheduling

- With health monitoring on, keep the 15 s default interval but defer probes while recent target traffic proves freshness — unless user input has outstanding transport work.
- After a path change or foreground activation, validate the existing transport once before replacing it (2 s handoff grace); skip if a fresh round trip already validated it.
- The first user interaction after an interval without a confirmed round trip schedules one validation. Input and local writes never advance server-activity timestamps.
- With monitoring off, no periodic loop, but one-shot validation on foreground, path change, stale interaction, or transport error remains part of recovery.

### 7.3 Timeout and ownership

- At most one unresolved keepalive per SSH connection; 10 s deadline, observable even if the underlying future ignores cancellation.[^swift]
- Expiry means round trip unverified, not process dead. tmux intent may retire and recover; plain-shell intent keeps its display and offers an explicit new shell.
- Timeouts need single completion, parent cancellation, generation checks, and cleanup. A timed-out request still owned by a retained connection holds its FIFO slot; no replacement probe until it resolves or the connection retires.
- Retirement closes channels and resolves pending ops: 2 s graceful close, then verified abort, never blocking UI. Resources MUST stay bounded under repeated blackholes; never reallocate the shared event-loop group per attempt.

## 8. Recovery by session type

### 8.1 tmux control mode (required continuity path)

Keep the logical gateway and local group; freeze the last presentation as stale; gate input. On recovery, in order:

1. SSH with original trust and credential policies, both hops if configured.
2. Discover the intended server/socket; validate server-instance and session evidence.
3. Attach to the exact existing session with safely escaped commands. Never create-or-attach.
4. Initialize a fresh generation-bound parser/viewer and reply queue.
5. Reconcile windows, panes, titles, hidden-window policy, sizes, visible terminal state.
6. Publish readiness only after a matching reconcile commit and visible-pane sync confirmation.

Identity uses IDs, not names/indexes: socket identity, server PID/start metadata, session ID, session creation metadata.[^tmux-man] A renamed session with matching evidence is the same session; a reused name is not. On server restart, insufficient evidence, or legacy name-only state, ask the user to choose — do not claim restoration. Revalidate identity after attach before enabling input. Never kill/detach other clients, start a tmux server during discovery (not-running = missing session), or change host policy that kills unattended sessions.

### 8.2 Regular tmux mode

Reattach only to a verified existing session; keep regular-mode rendering (do not switch to control mode). Report readiness after the PTY/attach contract succeeds, without claiming control-mode pane sync. If unverifiable, require explicit attach; prompt-shaped output is not proof.

### 8.3 Plain interactive SSH

Keep the original transport while it may recover. If unusable, offer **Open new shell** (never "Resume session"), preserving the old display as separate read-only history. Never silently convert to tmux; explain that session-preserving recovery needs tmux.

### 8.4 Remote commands and shell-launched SSH

A dispatched-or-maybe-dispatched one-shot `exec` is never auto-rerun; missing exit status is not evidence of non-execution. Retries before dispatch are allowed; after, show `commandOutcomeUnknown` and require explicit restart. Never replay startup commands, auth responses, terminal replies, or mutating tmux commands from an old generation; read-only discovery may repeat. Embedded shell-launched SSH follows the same policy; cancelling it MUST NOT kill the local shell or let a stale task reopen it.

### 8.5 Readiness API

Readiness (`TerminalSession.onReady` or a typed recovery event) carries generation and kind. Plain SSH: PTY allocated, shell/exec accepted, I/O handlers installed (no byte required). Control mode adds verified identity, committed topology, and synced visible panes — `syncEnd` alone is topology only. Never infer readiness from stream/banner text or a timer.

## 9. Input safety and backpressure

- Gate every input path on current-generation readiness: hardware/software keyboard, paste, accessibility, macros, terminal-generated replies, tmux command routing. Cached replay MUST NOT emit replies to a new connection.
- While not live, never silently queue keystrokes. Selection, search, copy, local cancel stay available; the compose UI is offered explicitly (never auto-diverting password entry).
- Drafts: memory-only, bound to the logical target, ≤ 64 KiB UTF-8, never auto-submitted, cleared on target close, never synced/logged/added to history. Loss on termination is acceptable.
- Live input: ordered writer with bounded backpressure, 256 KiB pending per connection, incremental paste production. Overflow suspends or visibly rejects before acceptance; never drop oldest bytes or reorder control keys around a paste.
- On retirement: stop old writer, cancel paste, discard unsent bytes with an interruption indication, never copy to the new writer. Bytes already accepted by the socket/SSH API are potentially delivered and not replay-safe.[^et]
- Resize is latest-wins, applied once the intended target is attached; nothing else is.

## 10. Conditional tmux flow control and catch-up

tmux control mode offers `pause-after`, `%pause`, `%continue`, `%extended-output`; enabling it changes the output notification format, and pane refresh is the client's job.[^tmux-control]

### 10.1 Capability gate

Enable only when the actual server and bundled Ghostty viewer support all required messages, reply ordering, and state restoration — by feature probe, not version string. Developer-only switch, off by default. Verify against the exact pinned Citadel/GhosttyKit revisions.

### 10.2 Safe state replacement

Ghostty stays the sole interpreter; `capture-pane` text is not a serialization. A tested snapshot/output barrier MUST cover buffers, cursor, attributes, dimensions, modes, pending escapes, Unicode state, and interleaved responses; snapshots are generation- and pane-bound. "Capture then replay everything" is unacceptable; without a safe boundary use non-dropping reattach. Visible panes first; mark history gaps; control responses are always delivered while output is paused.

### 10.3 Hidden panes and other clients

Do not set hidden panes `off` to save bandwidth — it can stop tmux reading the PTY and stall the process.[^tmux-man] Ship suppression only with tests for remote-process behavior, reveal restoration, and other attached clients; never kill windows or alter other clients' subscriptions. Local render coalescing is separate; report bytes and CPU effects separately.

## 11. Recovery user interface

Native, accessible status strip/overlay outside the Ghostty stream. Never inject spinners, countdowns, or messages into terminal content.

| State | Status/action |
| --- | --- |
| `suspect` | "Checking connection…"; keep last screen |
| `waitingForConnectivity` | "Waiting for network"; last verified activity age |
| `waitingForRetry` | "Retrying in …"; **Retry now**, **Stop recovery** |
| `authenticating` | "Authentication required"; name jump host vs destination |
| `attaching` | "Reattaching to session …" |
| `synchronizing` | "Restoring terminal state…" |
| Missing session | "The previous session is unavailable"; explicit session selection |
| Uncertain command | "Connection lost. Command outcome unknown." |

- Say "Last verified activity … ago", not "server offline for …". Show per-pane staleness when transport is healthy but a pane is paused/unsynced.
- Keep tab/group identity without retaining freed viewer pointers: bounded immutable snapshot or owned live state, else a stale placeholder.
- Never steal focus; announce major accessibility changes once (not each tick); no animation while suspended. Auth banners remain separate trusted UI.

## 12. Lifecycle and multiple windows

- Suspension is expected; no continuous background execution is promised.[^background] On background: pause timers, cancel/suspend network work via verified APIs, keep device-local intent. No audio/location/VPN/push keepalive hacks; finite background allowances only within their contract.
- On foreground: wait for the scene-mutation safety gate, coalesce path info, validate or recover once, without losing the latest meaningful path transition.
- Persist recovery descriptors at intent changes and safe checkpoints (termination may skip callbacks). Cold launch restores descriptors only — not transports or readiness; drafts and uncertain commands are not replayed.
- Lifecycle is application/gateway-scoped: one scene backgrounding MUST NOT suspend a connection used by another active scene. On Mac Catalyst, window focus loss is not suspension; validate after sleep/wake.

## 13. Settings, persistence, and migration

The existing registry stays sole settings authority; preserve unknown enum values and stored settings. No new public tuning knobs; dev switches are device-only.

| Setting | Behavior |
| --- | --- |
| `autoReconnectEnabled` | Master gate for automatic attempts; off cancels recovery but not a healthy connection. |
| `autoReconnectMaxAttempts` | Per rapid burst ("Attempts per recovery burst"), not per session. |
| `healthMonitoring` | Periodic probes/diagnostics only; event-driven validation still runs. |
| `healthProbeInterval` | Periodic baseline; validate before creating timers. |
| `backgroundKeepalive` | Finite OS-permitted continuity only; never promises background connectivity. |
| tmux default mode/name | Initial connection only; never replaces a missing recovery target. |

Versioned descriptors live in device-local restoration storage keyed by logical session/gateway UUID, validated before use. Legacy name-only records require rediscovery/explicit selection. Never sync descriptors, timestamps, diagnostics, pane captures, or drafts; no second snapshot database.

## 14. Security and diagnostics

- Reconnect under the original host-trust scope even if DNS changes. Host-key change, missing device-bound key, or auth rejection → explicit flow; no fallback to password, another user/host, or weaker trust.
- Attribute failures/prompts to the failing hop. Preserve Secure Enclave user-presence policy; a blocking auth MUST NOT stall other SSH connections.
- Server-derived names, banners, and errors are untrusted display data; validate/escape before use in commands; prefer exact IDs.
- Diagnostic ring: in-memory, 128 events per coordinator — state/stage, reason code, generation, attempt ordinal, timings, path category, byte counts. Never commands, terminal text, drafts, credentials, auth answers, or secrets. Export is explicit and redacted by default; no analytics service.

## 15. Implementation map

Recovery lives in `shell/Core/Terminal/Reconnect/` (`RecoveryCoordinator`, `RecoveryPolicy`, `RecoveryContext`, `RecoveryDeadline`, `RecoveryInputGate`, `TerminalReadinessGate`, `RecoveryDescriptorStore`, `RecoveryStatusPresentation`), with liveness in `Core/Connection/ConnectionHealthMonitor`, tmux identity in `Features/Tmux/TmuxRecoveryIdentity` and `TmuxContinuityRegistry`, UI in `UI/Overlays/RecoveryStatusStrip`, and tests in `tests/ShellTests/Recovery*`. All new-generation mutations flow through the coordinator; networking stays off the UI actor except serialized state transitions.

## 16. Acceptance and verification

### 16.1 Deterministic suite

Injected monotonic clock, seeded jitter, fake path/lifecycle source, controllable transport, recorded tmux fixtures; no real sleeping.

- **AC-01** 10 min offline, tmux intent → no dials while unavailable; restoration triggers recovery.
- **AC-02** 5 failures then cooldown → intent survives; low-rate attempts; one path bypass.
- **AC-03** 100 duplicate path events during a wait → no extra attempts; one coalesced event.
- **AC-04** Wi-Fi→cellular without offline event → validate; recover stale, keep healthy.
- **AC-05** Same-interface route/VPN change, unknown on-demand path → bounded evaluation; no permanent false-offline.
- **AC-06** Silent blackhole, cancellation-insensitive keepalive → observable deadline; input gated; ≤ 1 probe; no orphan work.
- **AC-07** Late keepalive reply → cannot acknowledge a newer request/generation.
- **AC-08** Cancel during dial/auth/PTY/sync → late success discarded; no reopen/output/success.
- **AC-09** Repeated background/foreground per stage → no spent attempts, no timer storm, one recovery.
- **AC-10** SSH ok but PTY fails; topology before contents → no premature readiness.
- **AC-11** Session renamed offline → reattach only on matching evidence; update name.
- **AC-12** Session recreated with same name; server restarted → no substitution; explicit selection.
- **AC-13** Topology changes during recovery → atomic reconcile; no duplicate tabs, freed pointers, focus theft.
- **AC-14** Drop around Enter/paste/mutating tmux command → no replay; uncertainty shown; paste interrupted.
- **AC-15** One-shot loses exit status → no second dispatch, even after relaunch.
- **AC-16** Plain SSH lost → no resumption claim; new shell only explicitly.
- **AC-17** Expired auth, changed host key, missing Secure Enclave identity → correct hop, explicit attention, no prompt loop/fallback.
- **AC-18** Overlay over full-screen app → terminal bytes unchanged.
- **AC-19** Large paste + repeated resize while stalled → within budget, no silent overflow, latest resize only.
- **AC-20** Two scenes (one backgrounded), many panes → correct ownership; one gateway attempt; fair global limit.
- **AC-21** Auto-reconnect disabled mid-recovery; clean exit → no automatic replacement.
- **AC-22** Legacy/unknown restoration data, synced profile edit → no unsafe target change, rerun, or destructive migration.
- **AC-23** Shell-launched SSH cancel → local shell survives; remote cannot reopen.
- **AC-24** Health after timeout/suspension → age-qualified RTT; cancelled samples excluded; no packet-loss metric.

### 16.2 Conditional flow-control suite

Before enabling section 10: all extended-output notifications and unknown fields; fragmented/interleaved responses; output changing during capture; primary/alternate screen; cursor/modes; split UTF-8/escapes; history gaps; pause/reveal; another attached client. One fixture MUST fail a naive "capture, replay everything" implementation. Prove hidden-pane handling does not stall the producer; unsupported capabilities leave normal operation working.

### 16.3 Device and fault matrix

Physical devices and Mac Catalyst, recording OS, hardware, commit, dependency and tmux versions. Cover direct/jump, IPv4/IPv6, VPN-on-demand, short/long loss, NAT change, latency/jitter, burst loss, refusal, one-way silent drop; busy pane, quiet shell, full-screen app. Count dispatch with a remote counter, not app telemetry.

Lab gates (not field guarantees):

- Recovery scheduling starts ≤ 500 ms after the gate opens and a slot is free.
- Cancel acknowledged ≤ 250 ms in foreground; no later adopted success.
- Probe deadline reported ≤ 500 ms after expiry.
- 100 blackhole/recovery cycles leave no accumulated channels, probes, timers, or event-loop groups.
- Zero automatic duplicate dispatches in ambiguous-delivery scenarios.
- Visible tmux recovery p95 ≤ 20 s (direct, unprompted, 100 ms RTT, ≥ 10 Mbit/s, four 120×40 panes, 1,000 lines each); report p50/p95.

Report auth time, user selection, and OS suspension separately; latency never overrides correctness gates.

### 16.4 Release gates

First release requires policy, transport lifecycle, and tmux/presentation work plus all applicable AC-01–AC-24. Section 10 ships separately, capability-gated. Rollback never reintroduces replay or trust bypass; optimization rollback returns to ordered non-dropping SSH/tmux. `README.md` and [`shell.md`](shell.md) document the plain-SSH limitation, burst semantics, no guaranteed background connection, and no exactly-once execution.

## 17. Future ET-style resumable stream (separate decision)

ET resumes via directional receive positions and retained output.[^et] A future spec comparing an ET-compatible client with a per-user relay over SSH (neither approved here) MUST define:

- **Auth and ownership** — bind to authenticated host/user; authenticate, expire, revoke, and rate-limit resume; fence old connections before new input; no custom crypto; no secrets in logs, URLs, CloudKit, or argv.
- **Stream semantics** — directional offsets, framing, ack meaning, dedup, partial PTY writes, resize ordering, bounds, exhaustion. Resend only within the same authenticated sequence space.
- **Crash semantics** — distinguish network loss, client termination, helper crash, host reboot; ack is a stream boundary, not exactly-once execution.
- **State retention** — client offsets must match terminal state actually retained; tmux control streams need protocol state or a fresh verified attach.
- **Deployment** — install, unprivileged execution, quotas, cleanup, revocation, version negotiation, SSH-only fallback; separate from the Watch broker ([`control-protocol.md`](control-protocol.md)).

Mosh, QUIC, MPTCP, and predictive echo are separate decisions and not prerequisites.

## 18. Definition of done

A surviving tmux session recovers from the specified disruptions without duplicate actions, misleading readiness, corrupted UI, or unbounded work; plain SSH and one-shot commands have explicit safe outcomes; identity, security, and sync boundaries hold; deterministic and device evidence is recorded. The criterion is **the correct existing terminal becoming safely interactive again**, not a shorter spinner.

## References

[^mosh]: [Mosh: technical information](https://mosh.org/#techinfo) — screen-state sync, ordered input, roaming, stale-state feedback.
[^et]: [How Eternal Terminal Works](https://eternalterminal.dev/howitworks/) — buffered directional streams, received positions, tmux control-mode compatibility.
[^tmux-control]: [tmux Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode) — flow control, output notifications, client-managed refresh.
[^tmux-man]: [tmux(1), OpenBSD](https://man.openbsd.org/tmux.1) — server/session format fields, flow-control flags, output-off behavior. Verify the deployed version.
[^swift]: [Apple: TaskGroup](https://developer.apple.com/documentation/swift/taskgroup) and [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html) — structured lifetime, cooperative cancellation.
[^ssh]: [RFC 4254 §4](https://www.rfc-editor.org/rfc/rfc4254.html#section-4) — global-request reply ordering.
[^background]: [Apple DTS: iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525).
[^citadel]: Existing connect/login budgets in `shell/Features/SSH/Session/CitadelSSHSession.swift` and `shell/Core/Terminal/Reconnect/InitialConnectRetry.swift`.
