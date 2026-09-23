# Shell Control: Swift CLI

**Status:** Implemented by the native `shell-control` command tree in `cmd/`. Requirements remain normative for that implementation.  
**Repository:** `chr33s/shell`  
**Deployment model:** Clean installation of a native Swift implementation.

Capitalized MUST, MUST NOT, SHOULD, and MAY express requirements. Timing and retention values are engineering defaults and test targets, not operating-system guarantees.

## 1. Decision and scope

Replace the TypeScript management CLI with a native Swift command tree in the existing `shell-control` executable. Keep `shell-control-broker`, `shell-controld`, and managed `cloudflared` as separate processes owned by per-user `launchd` jobs.

The implementation assumes a clean installation. It MUST NOT include an npm wrapper, Node bootstrapper, compatibility executable, legacy-state importer, PID adoption, dual implementation, feature-flagged fallback, or staged deployment transition. Delete the first-party TypeScript CLI and its dedicated npm build/test/package configuration in the same deliverable.

Runtime users MUST NOT need Node, npm, TypeScript, Xcode, a Swift compiler, or a source checkout. Developers build the release with SwiftPM. `cloudflared` remains a separately supplied executable for managed tunnel modes; “Swift-only” refers to Shell's management implementation, not rewriting that external transport.

The work includes service management, installation state, typed administration requests, pairing and enrollment prompts, health reporting, diagnostics, native distribution, and regression tests. It also includes the daemon recovery correction in section 10 because that defect affects normal approval handling independently of the CLI language.

The following remain out of scope: Linux/Windows support, system-wide root services, unattended pre-login availability, Cloudflare account or DNS provisioning, remote-host execution, a new approval protocol, automatic approval, terminal emulation on Watch, and automatic software updates.

### 1.1 Invariants

- The CLI is a management client, not a network relay or long-lived supervisor. Ready services survive its exit and terminal closure.
- `down` means stopped and prevented from automatically restarting until an explicit `up`.
- A healthy repeat invocation does not restart services, change the endpoint, or regenerate enrollment identity.
- Permission decisions continue to use `shell-control/1`. An exit code, cached record, notification, or successful health probe is never execution authority.
- An interrupted operation with uncertain effects is not replayed. Recovery discovery must not classify live work as abandoned.
- Clean installation is not permission to delete an existing installation. Unrecognized existing state is an error, not an invitation to reset it.

These requirements supplement the protocol and safety boundaries in `spec.watch.md`; they do not replace its request, signature, consume, receipt, or authorization rules. [R7][R14]

## 2. Baseline findings and required corrections

The inspected host package already provides `shell-control` and `shell-controld`, uses Swift tools version 6.2, and targets macOS 26. The TypeScript layer supplies management behavior around those executables. [R2][R5][R6]

The following source-review findings are implementation requirements, not claims of completed macOS reproductions:

| ID | Baseline finding | Required outcome |
|---|---|---|
| F1 | `runHeartbeats()` invokes recovery discovery over the current journal, whose unresolved set includes live requests. | Only work identified as interrupted at a process-start boundary is eligible for restart recovery. |
| F2 | The enrollment prompt installs a no-op readline `SIGINT` handler. | Actual terminal Ctrl+C cancels the invocation and closes the prompt without stopping ready services. |
| F3 | The management parser rejects adapter options before forwarding them. | `notify`, `request`, and `receipt` are typed native subcommands that accept their own options directly. |
| F4 | Service configuration writes replace APNs values with empty strings when the current shell lacks environment variables. | Persisted push configuration survives all ordinary management commands. Clearing it is explicit. |
| F5 | `launchctl enable`/`disable` results are ignored; shutdown verification can confuse unloaded with persistently disabled. | Every state-changing result is checked; persistent disablement and current process absence are verified separately. |
| F6 | Startup checks local services without requiring the public route to work; `restart all` can mutate services before rejecting quick-tunnel restart. | Readiness is mode-aware, and the complete requested operation is validated before side effects. |
| F7 | Installation generation hashes omit the native CLI. | Release identity and integrity validation cover every Shell executable, including `shell-control`. |

F1 is evidenced by the daemon and journal; F2–F6 by the management and service implementations; F7 by binary installation code. [R2][R3][R8][R9]

The native implementation MUST correct these behaviors rather than preserve bug-for-bug parity.

## 3. Architecture and package boundaries

```text
shell-control  --administration HTTP--> local broker
     |
     +--invoke launchctl--> per-user launchd
     |                         |-- shell-control-broker
     |                         |-- shell-controld
     |                         `-- cloudflared, when managed
     |
     `--local IPC--> shell-controld <--local IPC-- permission adapters

Watch --HTTPS--> configured public endpoint --> local broker
                                                  ^
                                                  |
                                         shell-controld over loopback
```

The local daemon MUST use the loopback broker URL, not make a round trip through the public tunnel. The Watch continues to contact the public endpoint directly. Changing the CLI does not add a phone relay or a permanent Watch socket. [R2][R14]

### 3.1 Proposed source layout

```text
cmd/
  Package.swift
  Sources/
    shell-control/
      ShellControlCommand.swift
      Commands/
        SetupCommand.swift
        UpCommand.swift
        DownCommand.swift
        RestartCommand.swift
        ServiceCommand.swift
        StatusCommand.swift
        LogsCommand.swift
        PairCommand.swift
        ConfirmCommand.swift
        PushCommand.swift
        NotifyCommand.swift
        RequestCommand.swift
        ReceiptCommand.swift
    ShellControlManagement/
      InstallationStore.swift
      LifecycleCoordinator.swift
      ServiceManager.swift
      LaunchdServiceManager.swift
      ControlAdminClient.swift
      TunnelConfiguration.swift
      TunnelDiscovery.swift
      HealthChecks.swift
      TerminalPrompt.swift
      PairingRenderer.swift
      InvocationCancellation.swift
      ProcessRunner.swift
      NativeBundleInstaller.swift
    ShellControlHostSupport/
      UnixSocket.swift
      ProcessLock.swift
      AtomicFileStore.swift
    ShellControlDaemon/
      DaemonCore.swift
      Journal.swift
      ...
    shell-controld/
      main.swift
  Tests/
    ShellControlManagementTests/
    ShellControlCommandTests/
    ShellControlDaemonTests/
```

`ShellControlHostSupport` contains reusable host I/O primitives and depends only on the protocol modules it actually needs. The management target MUST NOT depend on the daemon actor merely to acquire a lock or use its socket. Extract reusable code without changing IPC framing.

`ShellControlManagement` owns configuration, lifecycle policy, administration, and diagnostics. Command types perform argument validation and dispatch; they MUST NOT accumulate service lifecycle logic in one large root file.

The broker remains in `services/shell-control`. Neither the broker nor the daemon becomes a mode of the user-facing CLI. Watch and phone targets MUST NOT acquire a dependency on the host-management target or its administrative credentials.

### 3.2 Swift implementation choices

Use a pinned, vendored `swift-argument-parser` dependency and an `AsyncParsableCommand` root. Rename the executable's current `main.swift` when introducing an `@main` command type; do not retain two entry points. The official parser supports nested commands and asynchronous command execution. [E1][E2]

Use Foundation and the existing transport/protocol modules for HTTP, JSON, and URLs. Use a dedicated, injectable `ProcessRunner` for short-lived helper processes and a dedicated `ServiceManager` protocol for service ownership. Use Core Image's QR generator plus a small terminal matrix renderer; no JavaScript QR dependency is permitted. [R10][R11][E3]

Do not add a new subprocess framework merely to implement this specification. Swift strict-concurrency errors MUST be resolved with explicit ownership, actors, or synchronization—not blanket `@unchecked Sendable` declarations.

## 4. Command-line contract

The executable name is `shell-control`. Invoking it with no subcommand shows help and exits successfully without changing state. There is no `shell` or npm compatibility alias.

Common options are `--help`, `--version`, and `--state-dir <absolute-path>`. `SHELL_CONTROL_STATE_DIR` may supply the state root when the explicit option is absent, including for adapters and isolated tests. The production default is `~/.local/state/shell-control`.

| Command | Contract |
|---|---|
| `setup [--no-watch] [address options]` | Create a fresh native installation or reconcile an existing native installation. Print pairing instructions after the local installation is committed; monitor enrollment only with interactive input. |
| `up [--rotate-url]` | Explicitly enable and start an existing native installation. It does not enroll devices or print a QR. URL rotation is allowed only when explicitly requested for quick mode. |
| `down` | Persist stopped intent, disable and unload every owned job, and verify both conditions. Retain configuration, credentials, and journals. |
| `restart broker\|daemon\|tunnel\|all` | Restart the selected owned components after validating the entire request. Reject an installation with stopped intent. |
| `service install` | Opt into startup after graphical login. Requires a stable address. Preserve current running/stopped intent. |
| `service uninstall` | Remove login persistence without deleting data or interrupting an already-running session job. Stopped services remain stopped. |
| `status [--check]` | Emit an observational JSON status document. `--check` fails unless the configured control path is ready. |
| `logs [broker\|daemon\|tunnel] [--follow]` | Read bounded diagnostic output. Cancellation affects the reader only. |
| `pair [--watch]` | Print the saved pairing URL/token and a QR when supported; optionally monitor enrollment. It does not start stopped services. |
| `confirm <USER-CODE> [--yes]` | Display the device description/fingerprint and approve that one code. A TTY prompts unless `--yes` is passed. Non-interactive use MUST pass `--yes`. Never infer consent from mere discovery. |
| `push configure --key-id <id> --team-id <id> --key-file <absolute-path>` | Validate and persist a complete APNs provider configuration. Copy the key into protected installation storage. |
| `push disable` | Explicitly disable push and remove its installed key material after updating the broker configuration. |
| `notify`, `request`, `receipt` | Run the existing adapter operations as native command handlers, not subprocess proxies. |

### 4.1 Parsing and output

Each subcommand owns its options. Unknown or conflicting options and extra positionals MUST fail before filesystem or service changes. Management flags MUST NOT consume adapter flags. Support `--` where needed to terminate option parsing, but ordinary adapter invocations MUST NOT require it.

The adapter surface retains its functional flags, including `notify --title`, `request --spec-file`, `request --wait`, and receipt parameters. Port validation requires a value from 1 through 65535. Timeouts must be bounded positive values. [R5]

`status`, `notify`, `request`, and `receipt` reserve stdout for their documented JSON. Diagnostics, prompts, and progress go to stderr. Help and pairing output are human-readable exceptions. Output writers MUST finish or report a write failure before process exit; success must not truncate piped JSON.

Management exit codes are `0` for success, `1` for unavailable/degraded/runtime failure, and `2` for invalid invocation or unsupported configuration. Signal cancellation uses `128 + signal`: 130 for SIGINT, 143 for SIGTERM, and 129 for SIGHUP. Timeout is a runtime failure, not a fabricated signal event.

For a successfully resolved `request --wait`, preserve the protocol exit convention: approved `0`, rejected `10`, expired `11`, cancelled `12`, unavailable `13`. A local signal interruption is not a broker cancellation and must not be translated into `12`. A successful notification or request creation without `--wait` also exits `0`, but does not grant execution permission. [R7]

### 4.2 Setup behavior

Fresh setup starts session-scoped services; it does not enable login persistence. A second setup with matching configuration reuses healthy services and the existing native identity.

After `down`, `setup` MUST NOT override stopped intent or re-enable jobs. It reports that `up` is required. `up --rotate-url` is the explicit recovery path when a stopped quick tunnel cannot retain its old hostname.

Noninteractive setup returns after readiness evaluation and never waits for input or approves devices. `--no-watch` produces that behavior in an interactive terminal too. Monitoring is outside the installation lock and does not own any running service.

## 5. Native installation state

Use a new self-identifying native format, not an importer for the TypeScript files.

```text
~/.local/state/shell-control/
  installation.json            # format marker, identity, desired state, deployment
  secrets.json                 # account, admin, cursor, pairing, origin credentials
  runtime.json                 # interrupted management-operation metadata
  install.lock                 # kernel-owned exclusive flock; never an ownership PID
  credentials/
    apns.p8                    # present only when push is configured
    tunnel.json                # present only in named mode
  services/
    broker.json
    daemon.json
    tunnel.yml                 # generated for named mode, never arbitrary imported YAML
  launchd/
    <label>.plist               # canonical session registrations
  logs/
  broker.json                  # existing broker ledger role
  dispatch-journal.ndjson      # existing daemon journal role
  broker.lock
  daemon.lock
  control.sock
  health.sock
```

The native installation format marker is `shell-control.native/1`. Its required fields include `installation_id`, `desired_state`, `persistent`, `port`, `address_mode`, `public_url`, `release_id`, and typed tunnel/push configuration. `runtime.json` is diagnostic/reconciliation state, not the broker's authority ledger.

Generate identity and secrets exactly once for a genuinely fresh installation. Existing native state that is missing required credentials, malformed, or from an unsupported format fails closed. If the root contains another installation format or unexplained broker/journal state, refuse setup without adopting, resetting, or deleting it. No automatic uninstall of another implementation is provided.

### 5.1 Files and locking

Directories containing configuration, secrets, journals, or logs use mode `0700`; regular files use `0600`, except executable release files. Verify current-user ownership and reject unsafe symlinks or path traversal at security-sensitive paths. A managed executable symlink is a separately validated installation artifact, not a blanket exception.

Mutating management commands take a nonblocking `flock` on `install.lock`, retry with a cancellable deadline of 30 seconds, and hold the descriptor until the mutation ends. Do not unlink the lock inode during normal release. Kernel lock ownership—not a PID file, socket liveness guess, or Swift actor—is the cross-process exclusion mechanism. There is no requirement to coordinate with the removed TypeScript implementation.

Read-only commands MUST NOT create a state directory, generate secrets, recover an unfinished installation transaction, or obtain a mutating lock. They may report a concurrent operation as in progress and retry a bounded read of its generation metadata.

Use same-directory temporary files, complete writes, file synchronization, and atomic rename for individual updates. Record a management operation ID, its validated plan, and pending step before side effects that can outlive the CLI. Reconcile incomplete steps against owned launchd registrations on the next mutating invocation. Do not assume multiple separate JSON renames form one atomic transaction.

### 5.2 Configuration persistence

Ordinary `setup`, `up`, `restart`, `status`, and login startup load the committed native deployment configuration. They MUST NOT rebuild it from the environment of the current terminal.

Push configuration has two valid states: disabled, or a complete validated key ID/team ID/private-key reference with an allowed topic set. Missing shell variables never clear it. `push configure` replaces the tuple atomically; `push disable` is the only clearing action. Only the broker receives the provider key reference.

Service JSON and plists are derived artifacts. A content/generation change is detected before restarting an affected service. Rewriting identical content must not cause restarts. A failed reconfiguration reports which steps applied; it must not imply successful rollback when a running service may still use the previous generation.

## 6. Lifecycle ownership and cancellation

### 6.1 Service manager

Define an injectable `ServiceManager` with install, start, stop, restart, enable, disable, remove-persistence, and observe operations. The production implementation supports `launchd` only. A fake implementation is test-only and cannot be selected through a production environment variable.

Use labels derived from the native installation ID, such as `dev.chr33s.shell.control.<installation-id>.broker`, with corresponding daemon and tunnel labels. Operate only in `gui/<uid>`. Absence of the graphical login domain is an actionable error; never escalate to a system domain.

Use absolute executable/configuration paths and argument arrays. Broker and daemon take protected `--config` paths. Secrets MUST NOT appear in `ProgramArguments`, plists, process titles, status, or diagnostics. Plists use `/dev/null` for stdin and explicit files for stdout/stderr; no inherited terminal streams and no CLI-owned service pipes are permitted.

Broker and daemon are restartable jobs. Named tunnels may restart automatically with their fixed identity; quick tunnels must not automatically restart and silently replace their address. Set a restart throttle of at least 10 seconds. Apple documents per-user agents and launchd ownership; the target-platform suite must validate the actual command/state behavior on macOS 26. [E4]

Always check helper exit status. `Input/output error` or an unrecognized response is not evidence of successful bootstrap or bootout. Treat disabled, registered, running, and application-ready as separate observations. Verify disabled overrides independently of whether a job is loaded, including after bootout.

No process is signalled solely because its name or PID resembles a service. Do not adopt unmanaged processes. Owned service shutdown goes through the service manager and the validated label.

### 6.2 Operations

Validate command arguments, all selected components, paths, release integrity, and the complete address policy before any mutation. In particular, `restart all` in quick mode rejects the whole request before restarting broker or daemon. `restart tunnel` in external-proxy or loopback mode reports that no tunnel is owned.

`down` first commits stopped intent, then disables and unloads every owned job. Attempt all components even when one fails, aggregate failures, and verify both current absence and durable disablement. Never emit success with an unchecked job. `service install` while stopped writes future-login registration but keeps it disabled; removing persistence does not enable it.

Session jobs are bootstrapped from the canonical state-directory plist. Login persistence adds an identical owned plist under `~/Library/LaunchAgents`. Adding/removing that future-login file must not restart a matching running job. The implementation must test this behavior rather than rely on plist existence as proof.

Startup proceeds as a journaled operation: validate and stage the bundle/configuration; establish tunnel configuration and any required quick address; start and verify the broker; provision/persist the origin; start and verify the daemon; then evaluate the public route. Record newly created resources before launch and release the installation lock before enrollment monitoring.

Local-service commit and remote readiness are distinct. Before local commit, cancellation or failure cleans up only resources created by that invocation. It must not stop a pre-existing healthy service. After local commit, a public-route failure leaves diagnosable services running, returns a degraded result, and does not repeatedly tear down a healthy tunnel.

### 6.3 Invocation cancellation

One cancellation owner handles SIGINT, SIGTERM, SIGHUP, terminal Ctrl+C, and explicit task cancellation. Cancellation must interrupt prompt reads, HTTP requests, socket operations, bounded file following, helper processes, and lock waits.

Terminal input must be genuinely cancellable. Do not put an uninterruptible `readLine()` on the main actor or install a signal handler that consumes Ctrl+C without cancelling the invocation. Use a dedicated input reader with a tested descriptor/dispatch cancellation mechanism and restore terminal settings on every exit path.

For short-lived helpers, `ProcessRunner` must drain bounded stdout and stderr concurrently, propagate exit status, and terminate/reap only the helper it owns on cancellation. It must never treat a helper's process group as authority to kill managed services.

Cancellation after readiness affects the CLI only. Library code returns errors/results; it does not call `exit()` to bypass cleanup. Only the executable entry point maps the completed result to process exit.

## 7. Address and tunnel policy

Setup supports these address options:

```text
--tunnel-mode quick|named|external-proxy|loopback
--public-url <https-origin>
--tunnel-id <uuid>                       # named only
--tunnel-credentials <absolute-path>     # named only
--cloudflared-path <absolute-path>      # managed modes; otherwise resolve PATH once
--rotate-url                            # existing quick mode only
```

Default fresh setup uses quick mode. Missing `cloudflared` is an explicit error, not silent fallback to loopback. Local-only testing requires `--tunnel-mode loopback`.

Accept public HTTPS origins only: no embedded user information, query, fragment, or non-root path. Normalize with shared URL code. Plain HTTP is allowed only for explicit loopback use. Retain normal TLS validation and reject cross-origin redirects for management probes. [R11]

### 7.1 Named mode

Require an already-provisioned tunnel UUID, credential file, and stable public hostname. Validate credentials against the chosen tunnel identity, copy them into private installation storage, and generate the tunnel YAML from typed configuration. Do not port the handwritten arbitrary-YAML parser from TypeScript.

Generate exactly the intended public-host rule pointing at `http://127.0.0.1:<port>` and a final `http_status:404` catch-all. Quote scalar values safely and validate the resulting ingress configuration with the selected `cloudflared` executable. Cloudflare documents ordered ingress rules and their final catch-all requirement. [E5]

DNS creation, account login, and tunnel creation are operator prerequisites. The CLI must not invoke `cloudflared service install`; Shell owns only its per-user tunnel job.

### 7.2 Quick mode

Quick mode is a development convenience. Discover its address from bounded, generation-scoped reads of file-backed logs, not child stdout/stderr pipes owned by the CLI. Ignore earlier log generations and bound partial lines and total read buffers.

A saved address with a dead tunnel is `degraded`, not ready. Do not silently create a replacement on setup, health failure, broker restart, or login. `setup --rotate-url` or `up --rotate-url` explicitly authorizes a new address; print old and new endpoints and explain that devices must be paired/enrolled against the replacement.

Quick mode cannot enable login persistence. Broker failure, HTTP 502, DNS timeout, or a captive portal must not by itself trigger hostname rotation.

### 7.3 External proxy and loopback

External-proxy mode routes a stable public origin to the same local broker. Shell neither owns nor stops the proxy. The daemon still talks to the broker on loopback.

Loopback mode owns no tunnel and makes no physical-Watch reachability claim. Its readiness result is explicitly scoped to local services. Any address-mode change must be deliberate, validated as a whole, and reported as an endpoint change when it affects enrolled devices.

## 8. Health, status, and logging

Expose a new native management status schema rather than retaining TypeScript compatibility fields. Use `schema: "shell-control.status/1"` with `overall`, `readiness_scope`, `desired_state`, `persistent`, `public_url`, and per-component observations for broker, daemon, tunnel, public route, and push. Every observation includes a check time and a machine-readable reason when not ready.

The broker probe must check protocol compatibility, loaded-store readiness, and the expected installation-specific service identity. Use the existing `service_identity` capability field as a nonsecret instance discriminator rather than assuming the literal `shell-control` identifies this installation. A matching discriminator is diagnostic evidence, not authorization. Verify the public route against the same identity and avoid accepting cached or redirected responses as a fresh health result. [R10][R12]

The daemon health socket reports store initialization, IPC responsiveness, fresh origin authentication, and outstanding abandoned-work recovery count. An existing PID or responsive socket alone is insufficient. Recovery in progress is `recovering`, not a crash that should be fixed by endless restarts.

Remote mode is ready only when the local broker, authenticated daemon, required managed tunnel, and public route are ready. External-proxy mode substitutes a verified public route for a managed-tunnel process. Loopback readiness is local only. Push absence is reported separately and does not block foreground HTTPS review; configured push is not proof of actual notification delivery.

`status` is read-only, including when no installation exists. `status --check`, setup completion, and `up` must share the same readiness projection and cannot disagree because one only checks PIDs.

Proposed deadlines: 4 seconds per HTTP health probe, 2 seconds per health-socket attempt, 8 seconds per administration request, 30 seconds for quick URL discovery, and a 60-second overall startup readiness budget. Use monotonic deadlines and cancellable waits; tests inject the clock rather than sleep through these limits.

All logs must be written independently of the CLI lifetime. Never log keys, tokens, capabilities, raw authorization headers, or full sensitive approval documents. Bound `logs` output to a tail by default and handle rotation/truncation while following. Broker and daemon log retention must operate without an open CLI. Tunnel log retention must use a tested OS/transport-supported mechanism, not restart a quick tunnel just to rotate its log. Diagnostic-log cleanup must never truncate broker or dispatch journals.

## 9. Administration, pairing, and adapters

Implement a host-only `ControlAdminClient` over the shared injectable HTTP transport. The existing `ControlAPIClient` has device/origin credentials, not the administration surface required by setup. Do not pass an admin secret through a device client or add it to Watch configuration. [R10]

Administration stays on the configured loopback broker. Requests are authenticated, bounded, and cancellable; unexpected response bodies or statuses are errors, not silently decoded empty success objects. Do not retry a provisioning POST with a new identity after an ambiguous response. Persist its pending operation and reconcile with the broker; add a stable idempotency contract for origin provisioning if necessary.

Use the shared pairing URL construction/normalization. Generate the pairing-page QR natively, preserve a quiet zone, render without smoothing, and verify that it scans from both light and dark terminals. Non-TTY output includes the textual link/token without terminal escape art. [R11][E3]

Enrollment monitoring prints a sanitized label, platform, fingerprint, and requested permissions before asking for consent. Default answer is no. EOF, cancelled input, malformed description, and a non-TTY never approve. `confirm <USER-CODE>` is a deliberate single-code approval command, not a bulk-confirm mechanism. A push token or pairing token is not a device authentication credential.

Move adapter handlers into native subcommands and reuse the existing framed IPC, JSON types, and outcome mapping. Keep `notify`, `request`, and `receipt` free of management side effects: they do not implicitly install/start services or create an account when a socket is unavailable. Validate a complete permit and the exact request/run context; never reduce permission to a zero exit status. [R5][R7]

Administrative and local IPC endpoints must continue to enforce their existing caller/scope checks. The CLI does not gain unrestricted remote execution, approval shortcuts, or authority to accept SSH host keys.

## 10. Correct restart recovery before release

The baseline's recurring recovery discovery is unsafe because journal entries for live requests appear unfinished until completion. A recurring worker must retry abandoned-work obligations, not rediscover current work as though the process just restarted. [R8][R9]

### 10.1 Startup boundary

After acquiring the daemon singleton lock and before accepting new IPC work, read the durable journal and capture an immutable startup frontier: a record sequence, byte boundary, or equivalent boot-scoped candidate set. Persist interrupted-work candidates before admitting new runs.

Only candidates identified at that boundary may enter restart recovery. Requests created later in the current process are live work, even if their journal entries are unresolved, claimed, or awaiting a receipt. Do not rely solely on checking whether an in-memory run dictionary happens to contain a request during an `await`.

On a subsequent real restart, unfinished work from the preceding process is naturally eligible at the new boundary. The startup frontier is not a permanent exemption across future restarts.

### 10.2 Retrying obligations

Separate these operations:

```text
discoverInterruptedWorkAtStartup(frontier)
retryUnresolvedStartupCandidates()
retryPersistedRecoveryMutations()
heartbeatLiveRuns()
```

The heartbeat loop may invoke the latter three operations, but never an unbounded rediscovery of all currently unfinished journal work. Discovery and retry must be single-flight despite actor reentrancy across network awaits.

Before a remote withdrawal or unknown-outcome receipt, durably record its exact mutation/receipt identifiers and immutable payload. Retries reuse them. Record local terminal interpretation and acknowledgement only after a verified response or an explicitly idempotent terminal result. Network failure leaves the obligation pending.

If request lookup fails, retain the candidate and report recovery pending; do not mark it complete merely because no record was fetched. A candidate can be retired without a mutation only when an authenticated response and the protocol's state rules establish that no recovery action remains.

An abandoned claim may require an unknown-outcome receipt. A live claim awaiting its adapter receipt must never receive that restart receipt. No recovery path dispatches or replays the underlying operation.

During normal shutdown, stop accepting new work, signal cancellable handlers, drain bounded in-flight work, flush durable records, and let restart recovery handle unresolved obligations. Do not perform synchronous unlimited network work in a signal handler. Journal corruption must be surfaced; silently skipping an authority-relevant record is not safe recovery. An unparseable final record without a trailing newline is a torn append that never returned and may be dropped. Corruption anywhere else preserves the original bytes beside the journal, rebuilds the live journal from every record that still decodes, and reports `journal_quarantined` in daemon health so the loss is visible; startup must not crash-loop on it.

## 11. Native packaging and installation

Ship one native release bundle per supported architecture, with the three Swift executables, a release manifest, checksums, licenses, and user documentation. Required runtime targets are macOS 26 on arm64 and x86_64; each advertised artifact must be tested on that target rather than assumed from a successful cross-build. [R6]

Build both SwiftPM packages in CI with a pinned toolchain. Vendor the argument-parser dependency through the repository's manifest process, recording an exact reviewed revision. First-party command tests and packaging must run without npm. [R13]

Release bundles MUST contain prebuilt binaries. Setup MUST NOT run `swift build`, download a compiler, evaluate a remote script, or fetch and execute unverified code. Developers use an explicit build script; runtime bootstrap is not a build system.

Use a signed/notarized native distribution container and validate the actual downloaded artifact under Gatekeeper. A disk image is the primary delivery container for this specification; its contents include the versioned bundle, from which the user invokes `bin/shell-control setup`. Apply Developer ID signing, appropriate hardened-runtime settings, notarization, and container stapling in CI. Test the workflow rather than instructing users to remove quarantine attributes. [E6]

Setup stages the verified bundle under `~/.local/lib/chr33s-shell/<release-id>/`, then atomically publishes it and an owned `~/.local/bin/shell-control` symlink. Never replace an unrelated existing executable or symlink. Launchd registrations point to absolute versioned binaries, not the mounted image, a build directory, or a temporary download. Deleting/unmounting the source container must not break installed services.

The release manifest identifies architecture, minimum OS, toolchain/build version, and hashes for all three executables. The release identity must change for a CLI-only change. Validate the complete bundle before publishing it; a partial directory or one matching binary does not establish a complete installation. The manifest itself must be bound to the trusted signed distribution, not treated as independent proof of authenticity.

`cloudflared` is a declared external prerequisite for managed modes. Resolve and validate its absolute executable path, persist that selection, and report a missing/changed dependency rather than silently choosing a different program after login. It is not needed for external-proxy or loopback mode. Do not ship a package manager bootstrap or maintain a second JavaScript installation path.

Ordinary repeat setup of the same native release is supported. Importing another implementation, binary downgrade, automatic update, and cross-version state conversion are not part of this clean-install deliverable.

## 12. Remove the TypeScript implementation

Delete `cli/bin/shell.ts`, the management `.ts` sources and declarations, their Node tests, and `qrcode-terminal` usage. Remove the root npm manifest/lockfile and TypeScript configuration when they exist solely for this CLI. Do not delete unrelated vendored resources merely because their extension is JavaScript or JSON.

Replace `cli/README.md` with native command documentation under `cmd/`, update the root README and lifecycle documentation, and replace the Node-based lifecycle test invocation with native tests and a macOS integration harness. Remove npm commands from first-party build, release, onboarding, and CI instructions.

Any older lifecycle design text that prescribes TypeScript management, legacy PID adoption, or an npm launch path must be updated or clearly marked obsolete. Preserve the independent Watch/host protocol documentation and its security requirements.

The final repository must contain one authoritative management implementation. There is no wrapper, compatibility package, parallel installation mode, or temporary production selection flag.

## 13. Acceptance tests

Tests use isolated state roots, launchd labels, socket paths, ports, and credentials. They must never stop the developer's real services or contact a production broker. Unit tests use injected clocks, I/O, transport, and service observations; integration tests exercise the built executable.

| ID | Scenario | Required result |
|---|---|---|
| N01 | Root help, no args, or version with no state directory | Correct output; no files, services, network calls, or secrets created. |
| N02 | Adapter flags, including `--title`, `--spec-file`, `--wait`, and receipt options | Parsed by the correct native subcommand without a separator workaround. |
| N03 | Invalid flags, ports, conflicting modes, extra arguments | Exit 2 before any mutation. |
| N04 | Adapter terminal outcomes | Structured response and 0/10/11/12/13 mappings match the protocol. |
| N05 | Fresh setup from a downloaded native bundle on a Mac without Node or developer tools | Installs and runs without a compiler, npm, or source checkout. |
| N06 | Repeat healthy setup of the same release | Same identities, endpoint, PIDs, and effective service configuration. |
| N07 | Unrecognized existing state or corrupt native credentials | Actionable error; no import, reset, credential regeneration, or deletion. |
| N08 | Two concurrent mutating commands | Kernel lock serializes writes; cancellation while waiting is prompt. |
| N09 | SIGKILL during a journaled installation step | Next mutation reconciles only owned incomplete resources; no duplicate broker or account. |
| N10 | Real PTY Ctrl+C while a fingerprint prompt is open | Prompt and CLI exit; ready service PIDs and reachability are unaffected. |
| N11 | SIGTERM, SIGHUP, EOF, HTTP timeout, cancelled lock wait | Correct distinct outcome; no inferred approval; terminal state restored. |
| N12 | CLI exits, source disk image is unmounted, then terminal is closed | Services continue using installed binaries and file-backed logs. |
| N13 | `down` with persistent agents, followed by logout/login | No owned services return until `up`; each disabled state is verified. |
| N14 | A launchctl disable/bootstrap/bootout operation fails | Nonzero command result; no unconditional success or generic-error suppression. |
| N15 | `service install` while stopped; uninstall while running | Install preserves stopped intent; uninstall removes persistence without restarting the session jobs. |
| N16 | `restart all` in quick mode | Rejected before any PID, configuration, or registration changes. |
| N17 | Broker restart with healthy named or quick tunnel | Tunnel PID/address are retained; unrelated components are not restarted. |
| N18 | Missing/dead quick tunnel with a saved URL | Degraded result; no silent rotation; explicit rotation reports the new pairing requirement. |
| N19 | Missing cloudflared | Managed mode fails clearly; only explicit loopback/external mode proceeds without it. |
| N20 | Generated named-tunnel configuration | Exactly intended ingress plus catch-all; safe quoting; selected tunnel/credential identity validated. |
| N21 | Public route wrong identity, stale response, DNS failure, invalid TLS, or redirect | Not ready; no credential leakage, TLS bypass, or destructive tunnel recreation. |
| N22 | Loopback mode versus external-proxy mode | Correct readiness scope; no claim that local-only service is remotely reachable. |
| N23 | Configure APNs, then run setup/up/restart with an empty environment | Provider tuple and protected key remain configured. |
| N24 | `push disable` and malformed partial push configuration | Explicit disable works; incomplete replacement fails without erasing valid configuration. |
| N25 | Enrollment code expired, malformed fingerprint, no TTY, or EOF | No approval; bounded useful diagnostics. |
| N26 | Pairing QR in light/dark terminals and non-TTY output | Physical phone can scan both; non-TTY text remains usable and escape-free. |
| N27 | Live pending request spans multiple heartbeat/recovery retry cycles | Remains pending; no recovery withdrawal is queued. |
| N28 | Live claimed operation delays its real receipt | No false restart-generated unknown receipt. |
| N29 | Actual daemon restart with abandoned pending/claimed work | Startup-boundary discovery produces the appropriate durable obligations. |
| N30 | Broker outage during recovery, then reconnection and another crash | Stable mutation IDs/payloads are retained and acknowledged exactly once logically; no replay of execution. |
| N31 | Corrupt/truncated authority-relevant journal input | Safe diagnostic failure or explicitly validated tail recovery; no silent omission of completed/claimed records. |
| N32 | CLI-only binary change; incomplete or tampered bundle | Release identity changes; invalid bundle is rejected before publication. |
| N33 | Full stdout pipe, disappearing reader, and concurrent helper output | No truncated success JSON or helper deadlock; output failure is surfaced. |
| N34 | Continuous service logs after CLI exit | Retention operates independently; no secret exposure, journal truncation, or forced quick-tunnel rotation. |
| N35 | Native-only build/test/release environment | First-party management tooling has no Node/npm/TypeScript dependency or alternate implementation. |
| N36 | Physical Watch with stable endpoint, CLI absent, and phone app unavailable | Fresh request can be reviewed, explicitly decided, consumed once, and receipted through the existing protocol. |
| N37 | Mac sleep/network interruption and later wake | No execution replay or invented continuity; status recovers when services/routes actually recover. |

N10–N17 and N36–N37 require real macOS/device evidence. A fake service manager, source inspection, simulated exception, or Linux terminal reproduction cannot substitute for those release gates. Keep test logs and artifact hashes with the release evidence.

## 14. Implementation work breakdown

These are source-work dependencies, not a staged deployment scheme. The shipped result is the native implementation only.

| Work package | Primary changes | Completion gate |
|---|---|---|
| Recovery correctness | Split daemon startup discovery from recurring retries; add boot-frontier/candidate persistence and regression coverage. | N27–N31 pass. |
| Native command core | Add parser dependency and command tree; extract host support; integrate adapter handlers; implement cancellation and administration. | N01–N04, N10–N11, N25 pass. |
| Native management | Implement installation store, launchd manager, tunnel generation/discovery, push persistence, status, and logs. | N06–N09, N13–N24, N33–N34 pass. |
| Distribution and removal | Build/sign/notarize native bundles; validate clean setup; remove TypeScript/npm code and instructions. | N05, N12, N26, N32, N35 pass. |
| End-to-end validation | Exercise actual macOS lifecycle, login, network, and physical Watch paths. | N36–N37 and all real-platform gates pass. |

Update `cmd/Package.swift`, the vendor manifest, source notices, native tests, root onboarding documentation, and release scripts together. Replace relevant entry points in `scripts/test-lifecycle.sh` and extend native `scripts/test-control.sh` coverage rather than leave dormant Node tests as the nominal validation path.

## 15. Definition of done

The release is complete when a clean Mac can install the signed native bundle without Node or developer tools, enroll a Watch, close the CLI and terminal, and continue making correctly validated decisions through independently running services.

All required commands are implemented in Swift; the first-party npm/TypeScript implementation is removed; native configuration survives ordinary management actions; `down` remains effective across login; and recovery never withdraws live requests or invents outcomes for live claims.

The repository includes automated tests, recorded macOS/physical-device results, native installation instructions, and an explicit report of any unsupported distribution target. No missing lifecycle guarantee is described as solved merely because the implementation compiles or the language changed.

## References

Repository links below are pinned to the reviewed commit. The architecture, command additions, native file format, clean-install restrictions, and acceptance budgets are decisions of this specification.

- [R1] — Baseline commit
- [R2] — TypeScript management CLI
- [R3] — Existing service manager and binary installation
- [R4] — Existing installation state
- [R5] — Existing Swift adapter CLI
- [R6] — Host package
- [R7] — IPC and exit conventions
- [R8] — Daemon recovery and heartbeats
- [R9] — Dispatch journal
- [R10] — Shared HTTP API client
- [R11] — Shared broker and pairing URL implementation
- [R12] — Existing health projection
- [R13] — Vendored package manifest
- [R14] — Watch/control protocol specification
- [E1] — Swift command-line tools
- [E2] — AsyncParsableCommand and entry-point requirements
- [E3] — Native QR generation
- [E4] — Apple launchd agents and lifecycle
- [E5] — Cloudflare named-tunnel configuration and ingress
- [E6] — Apple notarization workflow

[R1]: https://github.com/chr33s/shell/commit/ac2790875dda069b9310dc5bc9a415e5282e5321 "Baseline commit"
[R2]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cli/src/cli.ts "TypeScript management CLI"
[R3]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cli/src/services.ts "Existing service manager and binary installation"
[R4]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cli/src/state.ts "Existing installation state"
[R5]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cmd/Sources/shell-control/main.swift "Existing Swift adapter CLI"
[R6]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cmd/Package.swift "Host package"
[R7]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/Packages/ShellControlCore/Sources/Protocol/HostIPC.swift "IPC and exit conventions"
[R8]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cmd/Sources/ShellControlDaemon/DaemonCore.swift "Daemon recovery and heartbeats"
[R9]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cmd/Sources/ShellControlDaemon/Journal.swift "Dispatch journal"
[R10]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/Packages/ShellControlCore/Sources/Client/ControlAPIClient.swift "Shared HTTP API client"
[R11]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/Packages/ShellControlCore/Sources/Client/ControlBrokerAddress.swift "Shared broker and pairing URL implementation"
[R12]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/cli/src/health.ts "Existing health projection"
[R13]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/vendor/manifest "Vendored package manifest"
[R14]: https://github.com/chr33s/shell/blob/ac2790875dda069b9310dc5bc9a415e5282e5321/spec.watch.md "Watch/control protocol specification"
[E1]: https://www.swift.org/get-started/command-line-tools/ "Swift command-line tools"
[E2]: https://apple.github.io/swift-argument-parser/documentation/argumentparser/asyncparsablecommand/ "AsyncParsableCommand and entry-point requirements"
[E3]: https://developer.apple.com/documentation/coreimage/ciqrcodegenerator "Native QR generation"
[E4]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html "Apple launchd agents and lifecycle"
[E5]: https://developers.cloudflare.com/tunnel/advanced/local-management/configuration-file/ "Cloudflare named-tunnel configuration and ingress"
[E6]: https://developer.apple.com/documentation/Security/customizing-the-notarization-workflow "Apple notarization workflow"
