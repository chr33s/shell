# Shell Control: CLI-independent service lifecycle

**Status:** Proposed implementation specification; implementation not performed.  
**Suggested repository path:** `spec.control-lifecycle.md`  
**Repository:** `chr33s/shell`  
**Inspected baseline:** `main` at `c7cab2d64eed3bfce79058eae328b270bcf34008`, 12 September 2026.  
**Scope:** The remaining connection-lifecycle gaps identified in the CLI, Mac services, tunnel address, and Watch recovery—not every outstanding feature in `spec.watch.md`.

MUST, MUST NOT, SHOULD, and MAY are normative requirements for the proposed implementation. Timing and retention values below are engineering defaults and test targets, not operating-system or network guarantees. Existing protocol authorization, request expiry, and receipt semantics remain authoritative.

## 1. Product contract

Once setup reports readiness, closing the CLI or its terminal MUST NOT stop the services carrying Watch traffic. The CLI is a management and enrollment interface, not a network relay or the lifetime owner of those services.

The completed implementation uses per-user **launchd agents** for the broker, origin daemon, and an optional managed tunnel. Login persistence is explicit and opt-in. A stable public HTTPS address is required for the supported persistent configuration. The quick-tunnel path remains a development convenience with an explicit address-change/re-pairing boundary.

The user-facing promises are deliberately separate:

| Event | Required behavior |
|---|---|
| Ctrl+C, CLI termination, terminal window closes | Ready services remain running; existing enrollment and the public address are unchanged. |
| Broker or daemon crashes | The service manager restarts the affected service; recovery preserves authority and never replays uncertain execution. |
| Named tunnel process crashes | Restart the same configured tunnel, retaining the configured hostname. |
| Quick tunnel process exits | Report unavailable; do not silently replace its hostname. |
| Network interruption or sleep | Report stale/unreachable state; resume attempts after connectivity returns. No availability while asleep is promised. |
| Logout | Per-user services are unavailable. |
| Reboot followed by login | Explicitly installed and enabled agents resume; no pre-login availability is promised. |
| `down` | Stop owned services and prevent automatic relaunch until an explicit start. Preserve account, enrollment, and journals. |

Apple documents that user agents execute only while their user is logged in; this design does not install a root/system daemon.[E2]

## 2. Baseline and remaining work

The existing implementation already provides separate broker, tunnel, and origin processes; device enrollment; a Watch-owned HTTPS client; credential/cache restoration; and a durable broker and host journal. Preserve these mechanisms rather than replacing the control protocol.[R1] [R2] [R3] [R6]

| Observed implementation | Required completion |
|---|---|
| Broker/daemon use `detached: true` and `unref()`, but inherit stderr; cloudflared uses CLI-owned stdout/stderr pipes. | Remove terminal and CLI I/O dependencies; prove real process exit and continued service operation. |
| Signal handlers are installed after setup; enrollment polling has a non-cancellable sleep and an unbounded administrative fetch. | Install cancellation before asynchronous startup, abort outstanding CLI work, and define startup ownership. |
| `ensureBroker()` and `ensureDaemon()` terminate an existing live process on every setup. | Idempotently reuse healthy, matching installations; restart only on explicit request or necessary recovery. |
| `status()` checks saved PIDs and prints the pairing token. | Separate process liveness from readiness, make reads side-effect-free, and redact credentials/pairing secrets. |
| `killPidFile()` signals the saved PID/process group without establishing process identity. | Use launchd job ownership; conservatively validate legacy processes during migration. |
| Quick-tunnel health failure can cause replacement of its random hostname. | Preserve the configured address through transient failure; require explicit URL rotation. |
| Watch polling is attached to view appearance/disappearance. | Also gate polling on scene activity and serialize refresh/credential renewal. |
| Daemon startup reconciliation uses best-effort remote writes before appending recovery markers. | Retain durable recovery obligations until acknowledged; retry without minting new mutation IDs. |

These are source observations, not results of a macOS runtime reproduction.[R1] [R2] [R4] [R5] Node documents that detachment alone does not remove the parent's standard-I/O relationship.[E1]

## 3. Architecture and boundaries

```text
Management plane:
  npx @chr33s/shell -> launchctl -> per-user service jobs
                   -> local authenticated administration / health

Control traffic:
  Watch -> HTTPS hostname -> tunnel / external reverse proxy -> local broker
                                                              ^
                                                        loopback HTTP
                                                              |
                                                       shell-controld
                                                              |
                                                   authenticated local IPC
                                                              |
                                                            adapter
```

The origin daemon SHOULD use the local broker address for this co-located deployment. The Watch and OAuth verification page use the public HTTPS address. A public tunnel outage must not unnecessarily break local daemon-to-broker communication.

This specification supports an externally operated **reverse proxy to the same local broker**, not provisioning a different remotely hosted broker. WatchConnectivity remains optional setup/handoff assistance, never the control relay. No permanent Watch socket, SSH changes, root privileges, automatic approval, cloud account provisioning, or automatic prevention of Mac sleep is introduced.

## 4. CLI contract

Retain the existing no-argument setup flow and native `request`, `notify`, and `receipt` forwarding. The following commands/flags are the **proposed** interface, not a claim that they already exist.

| Command | Contract |
|---|---|
| `setup` or no arguments | Ensure the configured services; print pairing instructions; monitor enrollments on a TTY. Do not opt into login startup. |
| `setup --no-watch` | Perform the same readiness checks and return without enrollment monitoring. |
| `up` | Start or re-enable an existing configuration; no QR, enrollment loop, or credential regeneration. |
| `down` | Persist stopped intent, disable and unload owned jobs, and verify shutdown. |
| `restart broker\|daemon\|tunnel\|all` | Restart only the requested owned components; preserve identity. Quick-tunnel replacement requires the explicit URL-change flow. |
| `service install` | Install login-persistent agents after validating a stable-address configuration. This explicit command is the opt-in. |
| `service uninstall` | Stop jobs and remove only this installation's agent files. Retain configuration, enrollment, and journals. |
| `status` | Preserve JSON as the default output; return observational status without creating or repairing state. |
| `status --check` | Same JSON, with a nonzero exit when required components are not ready. |
| `logs [broker\|daemon\|tunnel] [--follow]` | Read local diagnostic logs. Exiting a log reader never affects the service. |
| `pair [--watch]` | Explicitly print the pairing link/token/QR; optionally monitor enrollments. |
| `setup --rotate-url` | Explicitly accept replacement of a dead quick-tunnel URL and the resulting device re-pairing requirement. |

Configure the proposed modes through `setup --tunnel-mode quick|named|external-proxy`, `--public-url <https-url>`, and, for named mode, `--tunnel-config <absolute-path>`. Validate the named tunnel's identity, ingress hostname, loopback target, and credential-file ownership before launch. The CLI does not create the tunnel or DNS record. For example, after that infrastructure exists:

```sh
npx @chr33s/shell setup --tunnel-mode named \
  --public-url https://control.example.com \
  --tunnel-config /absolute/path/cloudflared.yml --no-watch
npx @chr33s/shell service install
npx @chr33s/shell pair --watch
```

Explicit configuration flags take precedence when configuring an installation. A stored installation otherwise remains authoritative; a conflicting environment variable must not silently replace its endpoint. On a fresh installation, the existing `SHELL_CONTROL_PUBLIC_URL` override maps to external-proxy mode unless a mode is explicitly selected. Reject unknown flags. Help and status must remain side-effect-free.

Non-TTY setup MUST NOT wait indefinitely or approve a pending device. Print the existing explicit confirmation command and return after readiness. Preserve fingerprint comparison and explicit approval requirements.

Ctrl+C after readiness exits only the interactive command. Use exit status 130 for SIGINT, 143 for SIGTERM, and 129 for SIGHUP; successful finite commands use 0, operational failures 1, and invalid arguments/configuration 2. A hung CLI network request must not prevent cancellation. Target exit within one second of cancellation after readiness in the test harness.

## 5. Phase 1: immediate detachment fix

This phase is independently shippable before launchd migration, but is not the completed persistence solution.

For every detached service, use ignored stdin and securely opened append-only file descriptors for stdout/stderr. Do not use `inherit`, parent-owned pipes, or an IPC channel. Close the parent's copies of the log descriptors after a successful spawn; retain `unref()` for this transitional launcher. Handle both the spawn error event and premature service exit. Do not mark a service ready merely because a PID was allocated.[E1]

Replace the shared temporary cloudflared log with a private, installation-specific startup log. Discover the URL by bounded reads of that file, not by retaining child streams. Read only the current startup generation; maintain a bounded partial-line buffer so fragmented output is handled. Do not accept an old URL from a previous launch. Stop the reader and close all descriptors after discovery or cancellation.

Install one invocation-scoped cancellation controller before any asynchronous startup. Pass its signal through CLI HTTP requests, timers, readiness waits, and prompts; remove all signal listeners in `finally`. Do not share a module-global stop flag between invocations or tests. A CLI cancellation signal MUST NOT be forwarded to an already-ready service.

Record which resources an invocation actually created. Before readiness, cancellation rolls back only those newly created resources, without disturbing reused services or rotating established identities. After readiness, interruption leaves the installation running. If the CLI itself is killed before cleanup, the next invocation reconciles the recorded incomplete startup instead of creating duplicate writers.

## 6. Phase 2: launchd ownership and persistence

Use a single `ServiceManager` abstraction with production operations implemented through `/bin/launchctl` and injected fakes for tests. Use the current user's `gui/<uid>` domain; fail clearly when that domain is unavailable. Do not silently escalate privileges or switch to a system domain.

Use installation-scoped labels, for example:

```text
dev.chr33s.shell.control.<installation-id>.broker
dev.chr33s.shell.control.<installation-id>.daemon
dev.chr33s.shell.control.<installation-id>.tunnel
```

Persist the installation ID once. A PID is an observation, not an identifier or authority to terminate a process.

**Session-only mode:** store agent definitions under the private state directory and bootstrap them explicitly. Do not install them in an automatic-login directory.

**Persistent mode:** install user-owned definitions in `~/Library/LaunchAgents/`. Use `RunAtLoad`, restart-on-exit for broker/daemon/named tunnel, and a restart throttle of at least ten seconds. A quick tunnel is not eligible for persistent installation and MUST NOT be automatically relaunched into a different hostname. Installing an unchanged, already-running session job for future login must not itself restart that job.

Agent definitions MUST use absolute executable, configuration, working-directory, and log paths. Set restrictive permissions, ignored stdin, and service-owned logging. Do not execute through a shell, `npx`, a package-manager cache, the source checkout, or a shell startup file. Managed service executables run in the foreground and do not daemonize themselves.[E2]

Install verified build outputs into versioned directories beneath `~/.local/lib/chr33s-shell/`. Preserve executable permissions/signing where applicable. Retain the previous version for rollback. A checkout deletion, `npm` cache cleanup, or shell PATH change must not break an installed agent. A managed cloudflared binary/configuration must likewise have a stable, validated location; external-proxy mode has no Shell-owned tunnel process.

Add native `--config <absolute-path>` support for broker and daemon startup. Pass paths—not admin/origin secrets—in agent arguments. Keep existing environment-based development entry points compatible, but never dump or wholesale persist the parent process environment.

`down` must disable automatic starts as well as unload jobs. Killing a process while leaving restart policy active is not shutdown. `up` explicitly re-enables the installation. Respect OS/user background-service restrictions; diagnostics must explain a disabled service without attempting to bypass the user's setting.

## 7. State, configuration, and idempotency

Continue using `~/.local/state/shell-control/` by default. Add a consistent state-directory override for all tools and tests. Separate durable identity/configuration from transient runtime observations:

```text
setup.env                     legacy import source; never shell-executed
config.json                   versioned desired configuration; mode 0600
secrets.json                  service-specific credentials; mode 0600
runtime.json                  startup generation and observations; not authority
broker.json                   existing broker ledger; preserve
dispatch-journal.ndjson        existing host journal; preserve
recovery-outbox.ndjson         proposed acknowledged-recovery bookkeeping
launchd/                      generated session definitions
logs/                         private diagnostic output
```

Configuration records schema version, installation ID, desired running/stopped state, login-persistence setting, port, address mode, public URL, tunnel identity/config path, and installed binary version. Credentials include the existing account/admin/cursor/origin/pairing material; their values MUST NOT appear in status or ordinary logs.

All mutating management commands acquire a single installation lock backed by an OS advisory lock. Config/state replacements use a private temporary file, flush, atomic rename, and appropriate directory durability. Reject unsafe ownership, symlinks, unexpected file types, and malformed configuration. Missing or corrupt credentials in an existing installation are a repair error, not permission to silently create a new account.

A repeated setup with matching healthy services MUST preserve broker and daemon PIDs, the tunnel hostname, account/origin IDs, and enrollment. Configuration changes that require a restart must be reported and applied deliberately. A second concurrent setup waits for the lock and then reuses the first result.

The broker and daemon each hold a lifetime singleton lock for their state/socket. Never permit two broker writers against the same ledger. Startup lock acquisition and socket collision failures must be explicit; do not unlink a socket served by another live instance.

Initial quick-mode setup may start the connector first to learn its address, then configure/start the broker, provision the origin, and start the daemon. A temporary proxy error while the broker is not yet ready is expected. Stable mode already knows its hostname. On later login, services must tolerate arbitrary launch order using bounded retry; startup ordering is not their correctness mechanism.

## 8. Public-address policy

Support three explicit modes:

| Mode | Public identity | Ownership and recovery |
|---|---|---|
| `quick` | Random development URL | Shell starts a session-only connector once. Preserve it while alive; explicit rotation after loss. |
| `named` | User-configured stable HTTPS hostname | Shell supervises an existing named Cloudflare connector using a validated configuration/credential file. |
| `external-proxy` | User-configured stable HTTPS hostname | Another service forwards to the local broker; Shell never stops or replaces that service. |

A local/simulator-only mode MAY remain available, but must say that physical devices cannot reach a loopback address. It is not a successful remote-Watch setup.

Quick Tunnels produce random subdomains and are documented for development/testing, not production availability.[E3] A named connector's configured ingress and credentials must be explicit; provisioning Cloudflare accounts, DNS, or new tunnels is outside this change.[E4]

A timeout, DNS failure, TLS failure, captive portal, or broker-side 5xx response MUST NOT automatically rotate the URL. Neither a non-530 response nor a live cloudflared PID proves end-to-end readiness. Preserve the configured address while classifying the actual failure. Named-mode recovery starts the same tunnel; it never falls back to quick mode.

URL replacement displays old/new addresses and an explicit re-pairing notice. Do not imply that a Watch pointing at a dead hostname can learn its replacement over that dead connection. Reuse the existing explicit pairing flow and clear/re-enroll device credentials on a broker-address change; do not copy tokens or silently redirect authenticated requests across origins.[R3]

The implementation may retain the Mac-side ledger during an intentional address change. This does not authorize silently rebinding existing Watch credentials to a different endpoint.

## 9. Readiness and diagnostics

Expose distinct observations for job registration, process liveness, local broker readiness, daemon IPC responsiveness, daemon authentication/reconciliation, and public-route reachability. Every observation has a timestamp and an error category. Public-route success measured on the Mac is not proof that a particular Watch currently has network access.

Add an authenticated local broker diagnostic read and a separate read-only daemon `health.sock`, protected by the existing same-user peer-verification rules. A health query must not register a job, mint a run, or change the published adapter message schema. Readiness requires a loaded durable store, expected installation/configuration generation, responsive IPC, and successful origin authentication. A newly launched process still replaying safe recovery metadata is `recovering`, not fully ready.

A public capabilities check must validate protocol and expected non-secret instance metadata rather than accepting any HTTP 200. Any added metadata is additive and diagnostic, not cryptographic proof of identity. Send no administrative credentials to the public probe; prohibit cross-origin credential forwarding. Use bounded requests and no-store responses to avoid stale proxy health results.

Retain the existing top-level liveness booleans for a transition period and add versioned detail. Omit `pairing_token`; move deliberate secret display to `pair`. For example:

```json
{
  "schema_version": 2,
  "broker": true,
  "tunnel": true,
  "daemon": true,
  "overall": "degraded",
  "manager": "launchd",
  "persistent": true,
  "desired_state": "running",
  "public_url": "https://control.example.com",
  "components": {
    "broker": { "state": "ready" },
    "daemon": { "state": "ready", "recovery_pending": 0 },
    "tunnel": { "state": "running", "mode": "named" },
    "public_route": { "state": "unreachable", "error": "dns_timeout" },
    "push": { "state": "not_configured" }
  }
}
```

The implementation adds observation timestamps and diagnostic identifiers; examples omit them for clarity. External-proxy mode reports its connector as `externally_managed`, not missing.

APNs is an independent capability. Missing provider credentials must say **Push not configured; open the Watch app to refresh**, not imply that background alerts work. Configured credentials also do not prove delivery to a device. Do not block foreground HTTP readiness solely because push is disabled; expose that limitation separately.[R6]

`status` is strictly read-only: it must not create secrets, rewrite configuration, restart services, or rotate URLs. It returns 0 when inspection succeeds, even if degraded; `--check` returns 1 unless all required control-path components are ready.

## 10. Shutdown and safe restart recovery

Handle SIGTERM in native services. Stop accepting new local work, cancel heartbeats/network waits, flush durable state, and close listeners. Target a fifteen-second cooperative shutdown budget, followed by a clearly reported service-manager termination when necessary. Keep the broker available while the daemon records any possible shutdown outcomes, then stop the connector and broker. A failed network write never justifies blocking shutdown indefinitely.

`down` and `restart` MUST NOT kill the user's actual job/application as an undocumented side effect. Adapters must receive a disconnected/unavailable outcome rather than an approval.

Preserve the existing distinction between service transport recovery and execution recovery. A broker restart can retain live adapter waits if the daemon survives. A daemon restart does not prove that its in-memory run bindings or blocked adapter are still valid. Withdraw unresolved requests whose original wait cannot be established, and report uncertain post-claim effects as unknown. Never claim that restarting a service resumes an arbitrary job.[R5]

Fix recovery acknowledgement handling: persist each recovery receipt/withdrawal and its immutable mutation ID before sending. Retain the obligation through transport failure, process restart, or an unavailable broker. Append its acknowledged/terminal marker only after the broker confirms the result or reconciliation proves the same mutation already committed. A `try?` remote write followed by an unconditional local completion marker is forbidden.

Retries reuse the original receipt/mutation identifiers and payloads. Reconciliation may submit recovery metadata; it MUST NOT re-execute the operation, manufacture a new approval, extend an expired grant, or bypass the existing consume/receipt safety rules. Persistent authentication rejection becomes a repair-required state, not an endless re-enrollment loop.

## 11. Watch lifecycle and reconnection

Retain `ControlSession`, its Keychain credentials, protected inbox cache, and command journal. Add explicit scene-activity handling in addition to view visibility; `onDisappear` alone is not the complete backgrounding contract.[R3] [R4]

A single session-owned task controls automatic refresh. Poll only when the scene is active and a relevant screen needs current data. Coalesce simultaneous launch, foreground, notification, manual-refresh, and post-decision triggers. Serialize credential refresh so concurrent requests cannot independently spend rotating refresh credentials.

Refresh immediately on foreground return; while active use the existing minimum five-second interval. Transient failures back off to 10, 20, 40, then 60 seconds, with bounded jitter that never violates the minimum interval. Manual refresh may trigger an immediate coalesced attempt. Backgrounding cancels polling and retry timers. Do not add a silent-push or always-open-socket requirement.

A transport failure, broker 5xx, or route outage retains credentials/cache and shows last verified freshness. Revocation and confirmed invalid refresh credentials follow the existing sign-out/re-enrollment path. A broker-unreachable observation must not be labelled “Mac asleep” or “Mac offline” without evidence; distinguish it from an expired host-presence lease fetched from a reachable broker.

Re-fetch before enabling an approval, and reconcile pending command outcomes after reconnect using their original journal IDs. No cached/offline approval or automatic repeat submission is introduced. A notification is only a hint to fetch authoritative state; missing push does not remove the foreground refresh path.

## 12. Logging and security

All installation directories are user-owned and private; secret-bearing files are mode 0600. Logs exclude authorization headers, device tokens, enrollment secrets, tunnel credentials, and full approval payloads. Diagnostic identifiers must not become authorization capabilities.

Logging must continue after the CLI exits. Provide service-owned or OS-managed retention, with a proposed target of 10 MiB active diagnostic output plus three retained segments per component. Retention must not require a running CLI. Do not mistake renaming a file for reopening a descriptor retained by launchd/cloudflared; the selected logging implementation must demonstrate rotation with the original process still alive. Diagnostic rotation can be lossy, but it must never rotate/truncate the broker ledger or dispatch journal.

Do not publish a raw admin endpoint or local IPC socket as part of this change. Preserve the existing broker authorization checks and TLS requirements. Binding local service HTTP to loopback must be verified, not inferred from the advertised URL. Launch arguments are arrays, never interpolated shell commands.

## 13. Migration and rollback

On first use, detect legacy `setup.env` and PID files. Under the installation lock, create a private backup, validate/import existing credentials, and preserve broker state and the dispatch journal. Do not regenerate account, cursor, origin, or pairing identities merely to adopt launchd.

Before signalling a legacy process, establish same-user ownership, executable path, start identity, and relevant state/socket association. An old PID file alone is insufficient. An unverifiable process is reported as unmanaged; do not guess, kill all processes by name, or signal an arbitrary negative process-group ID.

A running legacy quick tunnel cannot simply be adopted by launchd without affecting its process lifecycle. Preserve it temporarily as `legacy_unmanaged` or require explicit migration that warns of address change. Never tear it down silently to make the installation look fully managed. New persistent setup requires the stable-address transition and normal re-pairing when the endpoint changes.

Upgrade by staging a new binary/configuration generation, validating it, and changing only affected jobs. Preserve the previous generation until readiness passes. On failure, restore prior executable/configuration definitions where compatible. **Never roll back the broker ledger, spent-authority records, or dispatch journal** as part of a binary rollback. Keep journal/configuration schemas backward-compatible throughout this rollout; stop with a repair instruction rather than load an older binary against an incompatible schema.

## 14. Implementation map

Paths marked “new” are proposed, not existing source observations.

| Location | Work |
|---|---|
| `cli/src/cli.ts` | Thin command dispatch; cancellation lifecycle; explicit pairing; replace destructive ensure/kill behavior. |
| `cli/src/services.ts` (new) | Testable service-manager interface and launchd implementation. |
| `cli/src/state.ts` (new) | Versioned configuration, locking, migration, atomic writes, installation identity. |
| `cli/src/tunnel.ts` (new) | Address modes, bounded quick-URL discovery, explicit rotation policy. |
| `cli/src/health.ts` (new) | Read-only probes and versioned status projection. |
| `cli/src/*.test.ts` and test fixtures (new) | CLI lifecycle, fake services, signal handling, state and tunnel regressions. |
| `cmd/Sources/shell-controld/main.swift`, `cmd/Sources/ShellControlDaemon/UnixSocket.swift` | File configuration, shutdown handling, singleton ownership and the peer-verified diagnostic socket. |
| `cmd/Sources/ShellControlDaemon/DaemonCore.swift`, `Journal.swift` | Durable recovery obligations and acknowledged, idempotent reconciliation. |
| `cmd/Tests/ShellControlDaemonTests/` | Restart/disconnect/recovery and no-replay tests. |
| `services/shell-control/Sources/` and corresponding tests | File configuration, singleton ledger ownership, readiness diagnostics, shutdown behavior. |
| `ShellWatch/Services/ControlSession.swift` | Single-flight refresh/token renewal, bounded active retry, recovery projection. |
| `ShellWatch/App/ShellWatchApp.swift`, `ShellWatch/Features/Inbox/InboxView.swift` | Scene/visibility lifecycle wiring and truthful availability labels. |
| `ShellWatchTests/` | Lifecycle, concurrent renewal, offline/foreground, and cache preservation tests. |
| `package.json`, `scripts/test-control.sh` | Include new unit suites and an isolated macOS integration entry point. |
| `README.md`, `cli/README.md`, `cmd/README.md`, `spec.watch.md` | Document ownership, persistent setup, address changes, stop semantics, and availability limits. |

Do not change OS deployment targets, vendored dependencies, SSH, terminal, tmux, or CloudKit behavior as part of this work.

## 15. Required acceptance tests

Use fake clocks/transports and small local fake services for deterministic tests. Use isolated state directories, ports, and installation-scoped launchd labels for macOS integration. Never operate on a developer's real enrollment or installed services.

| ID | Scenario | Required result |
|---|---|---|
| L01 | `setup --no-watch` completes | CLI actually exits; broker, daemon and connector remain usable. |
| L02 | SIGINT during idle monitoring, an open prompt, or a hanging fetch | Exit within the cancellation target; no approvals; ready services unaffected. |
| L03 | Close the PTY/terminal, send SIGHUP, or SIGKILL the ready CLI | Service health and public hostname remain unchanged. |
| L04 | Service writes stdout/stderr continuously after CLI exit | No broken pipe, terminal dependency, log deadlock, or CLI-owned stream. |
| L05 | Fragment URL output; prepopulate a stale log; omit URL; fail spawn | Correct current URL only; bounded failure; no leaked polling/file handles. |
| L06 | Run setup twice and concurrently | One installation and ledger writer; matching healthy PIDs and identities are reused. |
| L07 | Reuse a legacy PID for an unrelated process | No signal reaches the unrelated process; report unverifiable ownership. |
| L08 | Kill broker while keeping connector and daemon alive | Broker restarts; hostname and enrollment survive; no duplicate request or lost ledger state. |
| L09 | Kill named connector | Same configured hostname becomes reachable again; no QR/re-enrollment required for unchanged identity. |
| L10 | DNS timeout, TLS failure, route 502/530, broker down | Correct degraded state; no automatic quick-URL replacement. |
| L11 | Kill quick connector | Unavailable state and explicit rotation guidance; persistent install rejects quick mode. |
| L12 | Run `down`, wait through restart policy, then log out/in | Owned services stay stopped until `up`; ledger/credentials remain. |
| L13 | Install, reboot, then log in with minimal PATH and deleted checkout/cache | Installed services resume without CLI or source checkout; stable endpoint preserved. |
| L14 | Start daemon before broker; lose network during startup | Retry safely; no busy loop, false readiness, or generated replacement identity. |
| L15 | Restart daemon around claim/receipt; fail every recovery network write | No operation replay; original recovery mutation remains durable until acknowledged. |
| L16 | Inspect a running-but-unresponsive process or an unrelated HTTP 200 | `status` is not ready; no state mutation or credentials in output. |
| L17 | Background/foreground Watch; trigger concurrent refresh/renewal | No background polling; one renewal; cache/identity retained after transient failures. |
| L18 | Sleep/wake Mac; expire request or presence lease while unavailable | Refresh on recovery; expired authority stays unusable; no unsupported “resumed” claim. |
| L19 | Remove APNs provider credentials | Foreground review works; status explicitly reports push unavailable. |
| L20 | Interrupt migration; fail upgraded binary; corrupt configuration | Recover or report repair; no credential regeneration, duplicate writer, or ledger rollback. |
| L21 | Rotate logs while CLI absent and services continue writing | Retention works without breaking the connector or touching durable authorization data. |
| L22 | End-to-end physical Watch request after terminal closure | Existing enrolled Watch fetches, explicitly decides, and receives the host receipt with no CLI running. |

Run the existing `npm run typecheck`, `npm test`, `./scripts/test-control.sh`, and `./scripts/test-watch.sh`; expand test discovery because the baseline npm test script currently selects only `cli/src/util.test.ts`.[R7] Add a dedicated macOS lifecycle suite. Physical-device, actual logout/login, and sleep/wake cases are release validation, not falsely reported as Linux/container tests.

## 16. Delivery order and definition of done

**P0 — CLI independence:** complete Section 5 and tests L01–L05, including real PTY/process-exit tests. This fixes the immediate user-visible lifecycle bug but does not claim reboot persistence.

**P1 — Managed stable operation:** complete launchd ownership, explicit persistence, stable-address modes, identity-preserving migration, safe stop/start, and readiness status. Pass L06–L14 and L16. Session-only mode and persistent mode converge on the same manager; the transitional detached launcher is retained only for explicit legacy compatibility.

**P2 — Recovery and release hardening:** complete acknowledged host recovery, Watch lifecycle/coalescing, logging retention, rollback, documentation, and L15/L17–L22. Preserve the existing authorization contract throughout all phases.

Done means the full supported stable-address configuration survives CLI termination, terminal closure, component failure, and reboot-followed-by-login without re-enrollment, subject to the documented user-session and network limits. It also means `down` stays down, quick-URL loss is honest and explicit, status never confuses a PID with readiness, and no recovery path repeats uncertain execution. A spec, code inspection, or green mocked test alone is not evidence that physical-device lifecycle tests passed.

## 17. Source references

Repository references are pinned to the inspected baseline. They establish current behavior; all requirements above are proposed changes.

| Reference | Source |
|---|---|
| [R1] | CLI setup, lifecycle, status, and tunnel handling. |
| [R2] | Repository architecture and control-companion boundary. |
| [R3] | Watch credential, cache, and refresh implementation. |
| [R4] | Watch inbox view lifecycle. |
| [R5] | Host restart reconciliation. |
| [R6] | Broker deployment, persistence, and APNs configuration. |
| [R7] | Package scripts and platform constraints. |
| [E1] | Official Node.js child-process documentation. |
| [E2] | Apple launchd guidance; archived, with target-OS validation required. |
| [E3] | Official Cloudflare Quick Tunnel limitations. |
| [E4] | Official Cloudflare named-tunnel configuration. |

[R1]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/cli/src/cli.ts "CLI setup, process launch, shutdown, tunnel checks and status"
[R2]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/README.md "Current control-companion architecture"
[R3]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/ShellWatch/Services/ControlSession.swift "Watch credentials, refresh, cache and polling"
[R4]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/ShellWatch/Features/Inbox/InboxView.swift "View-owned polling lifecycle"
[R5]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/cmd/Sources/ShellControlDaemon/DaemonCore.swift "Host restart reconciliation and authority preservation"
[R6]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/services/shell-control/README.md "Broker persistence, HTTPS deployment and optional APNs credentials"
[R7]: https://github.com/chr33s/shell/blob/c7cab2d64eed3bfce79058eae328b270bcf34008/package.json "Existing npm scripts and Node/platform constraints"
[E1]: https://nodejs.org/api/child_process.html#optionsdetached "Node.js: detached children, unref and independent standard I/O; consulted 12 September 2026"
[E2]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html "Apple: per-user launch agents, lifecycle and managed-process behavior; archived guidance, verify current launchctl behavior on supported macOS"
[E3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/ "Cloudflare: random Quick Tunnel hostnames and development-only scope; consulted 12 September 2026"
[E4]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ "Cloudflare: explicit named tunnel and ingress configuration; consulted 12 September 2026"
