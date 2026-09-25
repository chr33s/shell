# Shell Control: Native Swift CLI

**Status:** Implemented by the native `shell-control` command tree in `cmd/`; the TypeScript/npm CLI has been removed. Requirements remain normative.
**Scope:** Management CLI, native installation state, per-user `launchd` lifecycle, address policy, health, administration/pairing, adapters, daemon restart recovery, and packaging. Guided setup and `doctor` are specified in [`control-setup.md`](control-setup.md).

MUST, MUST NOT, SHOULD, and MAY express requirements. Timing values are engineering defaults and test targets, not OS guarantees.

## 1. Scope and invariants

### 1.1 Scope

`shell-control` is a native Swift executable. `shell-control-broker` and `shell-controld` run as separate processes owned by per-user `launchd` jobs. Runtime users need no Node, npm, TypeScript, Xcode, Swift compiler, or source checkout. There is exactly one management implementation: no npm wrapper, compatibility executable, legacy-state importer, PID adoption, dual implementation, or fallback flag.

Out of scope: Linux/Windows, system-wide root services, pre-login availability, remote-host execution, a new approval protocol, automatic approval, terminal emulation on Watch, and automatic updates.

### 1.2 Invariants

- The CLI is a management client, not a relay or long-lived supervisor. Ready services survive its exit and terminal closure.
- `down` means stopped and prevented from automatically restarting until an explicit `up`.
- A healthy repeat invocation does not restart services, change the endpoint, or regenerate enrollment identity.
- Decisions use `shell-control/1`. An exit code, cached record, notification, or health probe is never execution authority.
- An interrupted operation with uncertain effects is not replayed; recovery never classifies live work as abandoned.
- Unrecognized existing state is an error, never an invitation to reset or delete it.

These supplement, and never replace, the request, signature, consume, receipt, and authorization rules in [`control-protocol.md`](control-protocol.md).

## 2. Architecture and package boundaries

```text
shell-control --admin HTTP (loopback)--> shell-control-broker
     |--launchctl--> per-user launchd: broker, daemon
     `--local IPC--> shell-controld <--local IPC-- permission adapters

iPhone --HTTPS over Tailscale Serve (tailnet only)--> loopback broker <-- shell-controld (loopback)
Watch  --WatchConnectivity--> iPhone gateway
```

The daemon MUST use the loopback broker URL, never a round trip through the published route. The CLI adds no phone relay or permanent Watch socket.

### 2.1 Source layout

```text
cmd/Sources/
  shell-control/            @main AsyncParsableCommand root + Commands/ (argument validation and dispatch only)
  ShellControlManagement/   installation store, lifecycle coordinator, launchd service manager,
                            admin client, Tailscale configuration, pairing renderer, cancellation,
                            bundle installer, guided setup, host diagnostics
  ShellControlHostSupport/  UnixSocket, ProcessLock, AtomicFileStore, ProcessRunner, framed IPC
  ShellControlDaemon/       DaemonCore, Journal
  shell-controld/           daemon entry point
services/shell-control/     broker (separate package)
```

- `ShellControlHostSupport` holds reusable host I/O and depends only on needed protocol modules; management MUST NOT depend on the daemon actor to get a lock or socket.
- `ShellControlManagement` owns configuration, lifecycle policy, administration, and diagnostics; lifecycle logic MUST NOT accumulate in command types.
- Broker and daemon are never modes of the CLI. Watch/phone targets MUST NOT depend on host management or its admin credentials.

### 2.2 Implementation choices

- Pinned, vendored `swift-argument-parser` with an `AsyncParsableCommand` root and a single entry point ([Swift command-line tools](https://www.swift.org/get-started/command-line-tools/), [AsyncParsableCommand](https://apple.github.io/swift-argument-parser/documentation/argumentparser/asyncparsablecommand/)).
- Foundation plus existing transport/protocol modules for HTTP, JSON, URLs. Injectable `ProcessRunner` for helpers and `ServiceManager` for service ownership. Core Image QR generation ([CIQRCodeGenerator](https://developer.apple.com/documentation/coreimage/ciqrcodegenerator)) with a terminal matrix renderer; no JavaScript QR dependency.
- Strict-concurrency errors are resolved with ownership, actors, or synchronization — not blanket `@unchecked Sendable`.

## 3. Command-line contract

No subcommand shows help and exits 0 without changing state. Common options: `--help`, `--version`, `--state-dir <absolute-path>`; `SHELL_CONTROL_STATE_DIR` applies when the option is absent (must be absolute). Default root: `~/.local/state/shell-control`.

| Command | Contract |
|---|---|
| `setup [--no-watch] [--mode tailscale\|loopback] [--port N] [--tailscale-path P] [--reset-origin-key] [--guided [--skip-watch-setup]]` | Create or reconcile a native installation; print pairing instructions after local commit; monitor enrollment only interactively. `--reset-origin-key` replaces the origin key (all devices re-pair) and is never combined with `--guided`. |
| `up` | Enable and start an existing installation. Does not enroll or print a QR. |
| `down` | Persist stopped intent, disable and unload every owned job, verify both. Keep configuration, credentials, journals. |
| `restart broker\|daemon\|all` | Restart selected owned components after validating the whole request. Rejected while stopped. |
| `service install` | Opt into start after graphical login; requires tailscale mode with its HTTPS route. Preserves running/stopped intent. |
| `service uninstall` | Remove login persistence without deleting data or interrupting a running session job. |
| `status [--check] [--text]` | Observational JSON (`--text`: summary). `--check` fails unless the configured control path is ready. |
| `logs [broker\|daemon] [--follow]` | Bounded diagnostic output; cancellation affects only the reader. |
| `pair [--watch]` | Print saved pairing URL/token and QR; optionally monitor enrollment. Does not start stopped services. |
| `route` | Print the origin-signed route update for the current route; trust unchanged. |
| `confirm <USER-CODE> [--yes]` | Show device description/fingerprint and approve that one code. TTY prompts unless `--yes`; non-interactive use MUST pass `--yes`. |
| `revoke <DEVICE-ID>` | Revoke one reviewer; revoking an iPhone cuts off Watches it gateways for. |
| `push configure [--relay-url U] [--key-id --team-id --key-file] [--topic ...]` | Validate and persist a complete relay or APNs configuration; key copied into protected storage. |
| `push disable` | Explicitly disable push and remove installed key material after updating the broker. |
| `notify`, `request`, `receipt` | Adapter operations as native handlers, not subprocess proxies. |
| `doctor`, `test-review` | See [`control-setup.md`](control-setup.md). |
| `agent ...` | See [`agent-relay.md`](agent-relay.md). |

### 3.1 Parsing and output

- Each subcommand owns its options. Unknown/conflicting options and extra positionals MUST fail before any filesystem or service change. Management flags never consume adapter flags (`notify --title`, `request --spec-file`, `request --wait`, receipt options); `--` is never required for ordinary adapter use.
- Ports are 1–65535; timeouts bounded positive values.
- `status`, `notify`, `request`, `receipt` reserve stdout for their JSON; diagnostics, prompts, and progress go to stderr (help and pairing output are human-readable exceptions). Writes MUST complete or report failure before exit; SIGPIPE is ignored so EPIPE surfaces as an error, never truncated success.
- Exit codes: `0` success; `1` unavailable/degraded/runtime failure (including timeout); `2` invalid invocation or unsupported configuration; `128+signal` for cancellation (130 SIGINT, 143 SIGTERM, 129 SIGHUP).
- Resolved `request --wait`: approved `0`, rejected `10`, expired `11`, cancelled `12`, unavailable `13`. A local signal is not broker cancellation and never maps to `12`. Creation without `--wait` exits `0` but grants nothing.

### 3.2 Setup behavior

- Fresh setup starts session-scoped services without login persistence. Repeat setup with matching configuration reuses healthy services and identity.
- After `down`, `setup` MUST NOT override stopped intent or re-enable jobs; it reports that `up` is required.
- Non-interactive setup returns after readiness evaluation and never waits for input or approves devices; `--no-watch` does the same interactively. Monitoring runs outside the installation lock and owns no service.

## 4. Native installation state

```text
~/.local/state/shell-control/
  installation.json        # format marker, identity, desired state, deployment
  secrets.json             # account, admin, cursor, pairing, origin credentials
  runtime.json             # interrupted management-operation metadata
  guided-setup.json        # non-secret guided checkpoints (control-setup.md)
  install.lock             # kernel flock; never an ownership PID
  credentials/             # origin-signing-key.pem; apns.p8 only when direct APNs is configured
  services/                # broker.json, daemon.json (derived)
  launchd/<label>.plist    # canonical session registrations
  logs/
  broker.json              # broker ledger
  dispatch-journal.ndjson  # daemon journal
  broker.lock  daemon.lock  control.sock  health.sock
```

`installation.json` has format `shell-control.native/1` with `installation_id`, `desired_state`, `persistent`, `port`, `address_mode`, `public_url`, `release_id`, typed `push`, `tailscale_path`, and `serve_ports`. `runtime.json` is reconciliation state, not the authority ledger.

Identity and secrets are generated exactly once for a genuinely fresh installation. Native state missing credentials, malformed, or in an unsupported format fails closed. Another installation format or unexplained broker/journal state is refused without adoption, reset, or deletion. A recorded origin-key fingerprint with a missing key is never silently regenerated.

### 4.1 Files and locking

- Directories with configuration, secrets, journals, or logs are `0700`; files `0600` (except release executables). Verify current-user ownership; reject unsafe symlinks and traversal at sensitive paths. The managed executable symlink is validated separately.
- Mutating commands take a nonblocking `flock` on `install.lock`, retried with a cancellable 30 s deadline and held for the whole mutation; the lock inode is never unlinked. Kernel lock ownership is the only cross-process exclusion.
- Read-only commands MUST NOT create the state directory, generate secrets, recover an unfinished transaction, or take the mutating lock; they may report an operation in progress.
- Updates use same-directory temp file, full write, fsync, atomic rename. Before side effects that outlive the CLI, record an operation ID, validated plan, and pending step; the next mutating invocation reconciles incomplete steps against owned launchd registrations. Multiple renames are not one transaction.

### 4.2 Configuration persistence

- `setup`, `up`, `restart`, `status`, and login startup load committed configuration; they MUST NOT rebuild it from the current shell environment.
- Push is either disabled or a complete validated configuration (relay URL, or key ID/team ID/key reference, with allowed topics). Missing environment variables never clear it; `push configure` replaces atomically; `push disable` is the only clearing action. Only the broker receives the key reference.
- Service JSON and plists are derived; identical rewrites MUST NOT restart services. A failed reconfiguration reports which steps applied and never implies rollback while a service may run the previous generation.

## 5. Lifecycle ownership and cancellation

### 5.1 Service manager

- Injectable `ServiceManager` (install, start, stop, restart, enable, disable, remove-persistence, observe). Production supports `launchd` only; the fake is test-only and not selectable by environment.
- Labels `dev.chr33s.shell.control.<installation-id>.broker|daemon`, domain `gui/<uid>` only. A missing GUI domain is an actionable error; never escalate to the system domain.
- Absolute paths and argument arrays; broker and daemon take protected `--config` paths. Secrets MUST NOT appear in `ProgramArguments`, plists, process titles, status, or diagnostics. stdin is `/dev/null`, stdout/stderr go to files; no inherited terminal streams or CLI-owned pipes.
- Broker and daemon restart automatically with a throttle ≥ 10 s ([launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)).
- Every helper exit status is checked; `Input/output error` or unrecognized output is not success. Disabled, registered, running, and application-ready are separate observations; disabled overrides are verified independently of load state.
- Never signal a process because its name/PID resembles a service; never adopt unmanaged processes.

### 5.2 Operations

- Validate arguments, components, paths, release integrity, and address policy before any mutation.
- `down` commits stopped intent first, then disables and unloads every owned job, attempting all even on failure, aggregating errors, and verifying absence and durable disablement. `service install` while stopped writes a disabled future-login registration.
- Session jobs bootstrap from the canonical state-directory plist; login persistence adds an identical plist under `~/Library/LaunchAgents`. Adding/removing it MUST NOT restart a matching running job.
- Startup is journaled (`route → broker → origin → daemon → serve → readiness`): stage bundle/configuration, resolve the tailnet route, start and verify the broker, provision/persist the origin, start and verify the daemon, configure and verify Serve, evaluate readiness. Record created resources before launch; release the lock before enrollment monitoring.
- Before local commit, failure/cancellation cleans up only resources this invocation created, never pre-existing healthy services. After local commit, a route failure leaves services running and returns degraded.

### 5.3 Invocation cancellation

- One owner handles SIGINT, SIGTERM, SIGHUP, Ctrl+C, and task cancellation, interrupting prompt reads, HTTP, sockets, log following, helpers, and lock waits.
- Terminal input uses a dedicated cancellable reader (no uninterruptible `readLine()` on the main actor, no handler that swallows Ctrl+C) and restores terminal settings on every path.
- `ProcessRunner` drains bounded stdout/stderr concurrently, propagates exit status, and on cancellation terminates/reaps only its own helper.
- Cancellation after readiness affects only the CLI. Library code returns errors; only the entry point maps results to exit.

## 6. Address policy

The Cloudflare tunnel modes (`quick`, `named`, `external-proxy`) and managed `cloudflared` are superseded by the Tailscale model in [`control-protocol.md`](control-protocol.md); older installations decode to `tailscale` and setup removes the legacy tunnel job and its files.

### 6.1 Tailscale mode (default)

- The broker stays on loopback; Tailscale Serve (`--bg`, HTTPS) publishes it inside the tailnet at the node's MagicDNS name, which becomes `public_url`. The Tailscale CLI path is resolved once (or given by `--tailscale-path`) and persisted.
- Before changing Serve, inspect it: a handler for a port in `serve_ports` is Shell's; any other handler or a foreground serve/funnel session is a conflict and stops setup. Funnel exposure of the Shell endpoint is refused (`serve_public_exposure`). Success is judged by the resulting Serve state, not the command's exit code.
- Account sign-in, MagicDNS/HTTPS enablement, and tailnet policy are operator prerequisites; the CLI never collects credentials or changes tailnet-wide policy.
- Switching away from tailscale mode withdraws only Shell's own Serve handler, or reports the manual step.

### 6.2 Loopback mode

For local development/simulator. Owns no route, makes no physical-device reachability claim, and its readiness scope is `local`. Plain HTTP is allowed only here. Origins otherwise are HTTPS with no user info, query, fragment, or non-root path, normalized with shared URL code; management probes keep TLS validation and reject cross-origin redirects. An address-mode change is deliberate, validated as a whole, and reported as an endpoint change.

## 7. Health, status, and logging

- `status` schema `shell-control.status/1`: `overall` (`ready`, `degraded`, `unavailable`, `stopped`), `readiness_scope` (`remote`, `local`, `none`), `desired_state`, `persistent`, `public_url`, and per-component observations (`broker`, `daemon`, `public_route`, `push`, plus `tailscale`, `serve`, `origin`, `management_operation` when applicable), each with a check time and machine-readable reason when not ready.
- The broker probe checks protocol compatibility, store readiness, and the installation-specific `service_identity` discriminator (diagnostic, not authorization), avoiding cached or redirected responses.
- The daemon health socket reports store initialization, IPC responsiveness, fresh origin authentication, and abandoned-work recovery count; a PID or responsive socket alone is insufficient. Recovery in progress is `recovering`, not a crash.
- Tailscale readiness = local broker and daemon ready + tailnet connected + validated Serve active. The Mac's HTTPS probe of its own Serve name is reported but does not gate readiness. Loopback readiness is local only. Push is reported separately and never proves delivery.
- `status` is read-only even with no installation. `status --check`, setup completion, and `up` share one readiness projection.
- Deadlines: 4 s per HTTP probe, 2 s per health-socket attempt, 8 s per admin request, 60 s overall startup readiness; monotonic, cancellable, clock-injected in tests.
- Logs are written independently of the CLI. Never log keys, tokens, capabilities, authorization headers, or full approval documents. `logs` tails by default and handles rotation/truncation while following. Retention works without an open CLI and never truncates broker or dispatch journals.

## 8. Administration, pairing, and adapters

- A host-only `ControlAdminClient` over the shared HTTP transport; the admin secret never passes through a device client or into Watch/phone configuration.
- Administration stays on loopback: authenticated, bounded, cancellable; unexpected bodies/statuses are errors. Provisioning POSTs are not retried with a new identity after an ambiguous response; the pending operation is persisted and reconciled.
- Pairing uses shared URL construction. The QR is generated natively with a quiet zone and no smoothing, scannable in light and dark terminals; non-TTY output is plain text without escape art.
- Enrollment monitoring shows sanitized label, platform, fingerprint, and requested permissions before asking; default is no. EOF, cancellation, malformed descriptions, and non-TTY never approve. `confirm` approves exactly one code. Push or pairing tokens are not device credentials.
- `notify`, `request`, `receipt` reuse the framed IPC, JSON types, and outcome mapping; they never install/start services or create accounts. Permits are validated against the exact request/run context, never reduced to a zero exit status.
- Admin and IPC endpoints keep their caller/scope checks. The CLI gains no remote execution, approval shortcut, or SSH host-key authority.

## 9. Daemon restart recovery

Recurring work retries abandoned-work obligations; it never rediscovers current work as though the process had just restarted.

### 9.1 Startup boundary

- After acquiring the daemon singleton lock and before accepting IPC, read the journal and capture an immutable startup frontier; persist interrupted-work candidates before admitting new runs.
- Only frontier candidates enter restart recovery. Work created later in this process is live, even if unresolved, claimed, or awaiting a receipt; do not rely on in-memory run maps across `await`s.
- On a later real restart, unfinished work from the prior process becomes eligible at the new boundary.

### 9.2 Retrying obligations

```text
discoverInterruptedWorkAtStartup(frontier)
retryUnresolvedStartupCandidates()
retryPersistedRecoveryMutations()
heartbeatLiveRuns()
```

- The heartbeat loop may run the last three, never unbounded rediscovery. Discovery and retry are single-flight despite actor reentrancy.
- Before a remote withdrawal or unknown-outcome receipt, durably record its mutation/receipt IDs and immutable payload; retries reuse them. Record terminal interpretation only after a verified or explicitly idempotent response; network failure leaves the obligation pending.
- Failed lookup keeps the candidate (recovery pending). Retire without mutation only when an authenticated response and protocol state rules show nothing remains.
- An abandoned claim may need an unknown-outcome receipt; a live claim awaiting its adapter receipt never does. No recovery path dispatches or replays the operation.
- Shutdown: stop accepting work, cancel handlers, drain bounded in-flight work, flush records; no unbounded network work in signal handlers.
- Journal corruption is surfaced. An unparseable final record without trailing newline is a torn append and may be dropped. Corruption elsewhere preserves the original bytes beside the journal, rebuilds it from every decodable record, and reports `journal_quarantined` in daemon health; startup MUST NOT crash-loop.

## 10. Packaging and installation

- One native bundle per architecture (macOS 26 arm64 and x86_64): three executables, `release-manifest.json`, checksums, licenses, documentation. Each artifact is tested on its target.
- Both SwiftPM packages build in CI with a pinned toolchain; the argument parser is vendored at a reviewed revision. First-party build, test, and release need no npm.
- Bundles contain prebuilt binaries. Setup MUST NOT run `swift build`, download a compiler, evaluate remote scripts, or execute unverified code.
- Distribution is a Developer ID–signed, hardened-runtime, notarized, stapled disk image validated under Gatekeeper ([notarization](https://developer.apple.com/documentation/Security/customizing-the-notarization-workflow)); users run `bin/shell-control setup` from it and are never told to strip quarantine.
- Setup stages the verified bundle at `~/.local/lib/chr33s-shell/<release-id>/`, then atomically publishes it and an owned `~/.local/bin/shell-control` symlink, never replacing an unrelated file. Launchd points at absolute versioned binaries, so unmounting the image does not break services.
- The manifest records architecture, minimum OS, toolchain, and hashes of all three executables; release identity changes for a CLI-only change. The whole bundle is validated before publication, and the manifest is trusted only via the signed container.
- Repeat setup of the same release is supported; import from other implementations, downgrade, auto-update, and cross-version conversion are not.

## 11. Acceptance tests

Tests use isolated state roots, labels, sockets, ports, and credentials; never touch the developer's real services or a production broker. Unit tests inject clocks, I/O, transport, and service observations; integration tests run the built executable.

| ID | Scenario | Required result |
|---|---|---|
| N01 | Help, no args, or version with no state directory | Correct output; nothing created, no network. |
| N02 | Adapter flags (`--title`, `--spec-file`, `--wait`, receipt options) | Parsed by the right subcommand without `--`. |
| N03 | Invalid flags, ports, conflicting modes, extra args | Exit 2 before mutation. |
| N04 | Adapter terminal outcomes | JSON and 0/10/11/12/13 mapping match protocol. |
| N05 | Fresh setup from downloaded bundle, no Node/dev tools | Installs and runs. |
| N06 | Repeat healthy setup, same release | Same identities, endpoint, PIDs, configuration. |
| N07 | Unrecognized state or corrupt credentials | Actionable error; no import/reset/regeneration/deletion. |
| N08 | Two concurrent mutating commands | Kernel lock serializes; cancelled wait is prompt. |
| N09 | SIGKILL during a journaled step | Next mutation reconciles only owned resources; no duplicates. |
| N10 | Real PTY Ctrl+C at fingerprint prompt | CLI exits; services unaffected. |
| N11 | SIGTERM, SIGHUP, EOF, HTTP timeout, cancelled lock wait | Distinct outcomes; no inferred approval; terminal restored. |
| N12 | CLI exits, image unmounted, terminal closed | Services continue on installed binaries and file logs. |
| N13 | `down` with persistent agents, then logout/login | Nothing returns until `up`; disablement verified. |
| N14 | launchctl disable/bootstrap/bootout fails | Nonzero result; no suppressed errors. |
| N15 | `service install` while stopped; uninstall while running | Stopped intent kept; uninstall does not restart jobs. |
| N16 | Whole-request validation (`restart` while stopped, invalid component) | Rejected before any PID, configuration, or registration change. |
| N17 | Broker restart | Daemon and Serve configuration untouched. |
| N18 | Tailscale disconnected with a saved route | Degraded; no silent route or identity change. |
| N19 | Tailscale CLI missing | Tailscale mode fails clearly; loopback proceeds. |
| N20 | Serve handler owned by another app / foreground session | Conflict; nothing replaced. |
| N21 | Funnel exposure, wrong service identity, stale/redirected response, invalid TLS | Not ready; no credential leakage or TLS bypass. |
| N22 | Loopback versus tailscale mode | Correct readiness scope; no remote claim for loopback. |
| N23 | Configure push, then setup/up/restart with empty environment | Push configuration and key retained. |
| N24 | `push disable`; malformed partial configuration | Disable works; bad replacement leaves valid config intact. |
| N25 | Expired code, malformed fingerprint, no TTY, EOF | No approval; bounded diagnostics. |
| N26 | Pairing QR light/dark and non-TTY | Scannable; non-TTY text escape-free. |
| N27 | Live pending request across heartbeat/retry cycles | Stays pending; no withdrawal queued. |
| N28 | Live claim delays its real receipt | No restart-generated unknown receipt. |
| N29 | Real daemon restart with abandoned pending/claimed work | Startup discovery creates durable obligations. |
| N30 | Broker outage during recovery, reconnect, another crash | Stable IDs/payloads; logically exactly-once; no replay. |
| N31 | Corrupt/truncated journal | Safe diagnostic or validated tail recovery/quarantine; no silent omission. |
| N32 | CLI-only binary change; incomplete/tampered bundle | Release identity changes; bad bundle rejected before publish. |
| N33 | Full stdout pipe, vanished reader, concurrent helper output | No truncated success JSON or deadlock; failure surfaced. |
| N34 | Service logs after CLI exit | Retention independent; no secrets or journal truncation. |
| N35 | Native-only build/test/release | No Node/npm/TypeScript dependency. |
| N36 | Physical iPhone/Watch with stable route, CLI absent | Fresh request reviewed, decided, consumed once, receipted. |
| N37 | Mac sleep/network loss and wake | No replay or invented continuity; status recovers with real services/route. |

N10–N17 and N36–N37 require real macOS/device evidence; fakes, source inspection, or non-macOS reproductions do not substitute. Keep test logs and artifact hashes with release evidence.

**Done** means a clean Mac installs the signed bundle without Node or developer tools, enrolls a reviewer, closes the CLI and terminal, and continues making validated decisions; configuration survives ordinary management; `down` holds across login; and recovery never withdraws live requests or invents outcomes for live claims.
