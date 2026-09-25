# Shell Control native host tools

The signed release contains three prebuilt macOS executables:

- `shell-control` — native management command tree and adapter client
- `shell-controld` — per-user origin daemon
- `shell-control-broker` — local broker

Runtime installation does not use Node, npm, a compiler, or a checkout. From the mounted signed disk image:

```sh
bin/shell-control setup                     # iPhone-gateway profile over Tailscale
bin/shell-control setup --mode loopback --no-watch   # local development with the simulator
```

Tailscale is the only way a phone reaches the Mac. The default `tailscale` mode is the iPhone-gateway profile of
[`spec.iphone-gateway.md`](../spec.iphone-gateway.md): it checks that Tailscale is
installed, connected, and has MagicDNS; keeps the broker on `127.0.0.1`; points
Tailscale Serve's HTTPS 443 at it; verifies the resulting Serve state (and refuses
Funnel); creates the Mac's origin signing key under `credentials/`; and prints a
one-use pairing QR that pins the origin identity. There is no public listener,
hostname, tunnel, or reverse proxy. `loopback` mode serves `http://127.0.0.1` for
the simulator only.

`setup` copies the complete verified bundle to `~/.local/lib/chr33s-shell/<release-id>/`, publishes `~/.local/bin/shell-control` without replacing unrelated files, and starts launchd jobs in the current graphical user domain. Closing the CLI does not stop them.

## Commands

```text
shell-control setup --guided [--skip-watch-setup] [--mode tailscale|loopback] [--port N] [--tailscale-path PATH]
shell-control setup [--no-watch] [--mode tailscale|loopback] [--port N] [--tailscale-path PATH] [--reset-origin-key]
shell-control doctor [--json] [--check] [--export /absolute/new-file.json]
shell-control test-review --reviewer iphone|watch --device-id <ENROLLED-DEVICE-ID> [--timeout SECONDS]
shell-control up
shell-control down
shell-control restart broker|daemon|all
shell-control service install|uninstall
shell-control status [--check] [--text]
shell-control logs [broker|daemon] [--follow]
shell-control pair [--watch]
shell-control route
shell-control confirm <USER-CODE> [--yes]
shell-control revoke <DEVICE-ID>
shell-control push configure --relay-url https://relay.example
shell-control push configure --key-id ID --team-id ID --key-file /absolute/key.p8
shell-control push disable
shell-control notify --title TEXT [options]
shell-control request --spec-file /absolute/request.json [--wait]
shell-control receipt --run-capability CAP --result RESULT [options]
shell-control agent install claude-code|codex [--dry-run] [--include-file-changes] [--no-questions] [--watch-shell-approval] [--enable-managed]
shell-control agent uninstall claude-code|codex
shell-control agent doctor [--json]
shell-control agent hook claude-code|codex
shell-control agent test claude-code|codex --reviewer iphone|watch
shell-control agent launch claude-code|codex -- <provider arguments>
shell-control agent launch codex --managed [--thread THREAD-ID]
shell-control agent grant <DEVICE-ID> [--revoke] [--messages] [--cancel]
shell-control agent allow-build claude-code|codex <BUILD> [--yes] [--remove]
```

Use `--state-dir /absolute/path` before or after a subcommand, or `SHELL_CONTROL_STATE_DIR`, for an isolated native installation. The production default is `~/.local/state/shell-control`. Non-interactive `confirm` requires `--yes`.

`pair` mints a fresh one-use, ten-minute pairing and prints its QR; `confirm`
approves the iPhone pairing or Watch reviewer the phone or Watch displays, after
showing its label, key fingerprint, and permissions (a Watch also shows its
gateway iPhone). `route` prints the origin-signed route-update QR for the current
Tailscale name: scanning it changes routing only, never trust. `up` re-reads the
MagicDNS name, so a renamed Mac is a route change, not a re-pairing. The origin
key is never regenerated silently: if it goes missing, setup stops, and
`--reset-origin-key` is the explicit way to mint a new one (every device must then
pair again). `revoke` disables an iPhone (and with it the transport of every
Watch it gateways for) or a single Watch reviewer. `push configure --relay-url`
sends approval hints through the stateless Shell Push Relay; the Mac then holds
no APNs credential.

## Control companion setup

`setup --guided` is the interactive path of
[`spec.control-companion-setup.md`](../spec.control-companion-setup.md): it
explains the companion, runs read-only preflight checks (release bundle,
installation state, Tailscale, MagicDNS, and Serve ownership), reconciles the
services through the same lifecycle as `setup`, offers **Start at login**, shows a
one-use pairing QR and waits for a broker-confirmed iPhone, runs the safe review
test, and then offers the optional Apple Watch and describes the remote-alert mode.
It needs an interactive terminal and refuses otherwise before changing anything.
Rerunning it observes the installation instead of replaying steps; non-secret
checkpoints live in `guided-setup.json`. Ctrl+C stops only the guide: pairings,
keys, journals, and running services are left as they are. A stopped installation
stays stopped unless you choose **Start Control services**.

`--skip-watch-setup` skips only the optional Apple Watch step. `--no-watch` keeps
its meaning for non-guided setup — do not monitor enrollment — and is rejected with
`--guided`. `--reset-origin-key` is a separate recovery step and is also rejected
with `--guided`.

Setup never replaces another application's Tailscale Serve handler: if HTTPS 443
on this Mac's name already serves something that is not Shell's loopback broker, it
stops with `serve_conflict` and changes nothing. It never resets the whole Serve
configuration, and a Funnel-exposed endpoint is never reported ready.

`doctor` is read-only host evidence in the `shell-control-diagnostics/1` schema
(`--json`). It checks the host, not whether an iPhone or Watch can reach it now.
`--check` exits 0 only when every required host check passed just now; an
unconfigured Watch or disabled remote alerts do not fail it. `status` and
`status --check` are unchanged.

`test-review` publishes the fixed setup-test request ("Setup test — no operation
will be executed", `/usr/bin/true`, never executed) to the selected enrolled
reviewer and passes only when that device's signed approval is consumed and the
no-operation receipt is recorded. It exits 0/10/11/12/13 like `request --wait`, and
1 when a decision was recorded but the receipt was not.

Login persistence requires tailscale mode. `down` commits stopped intent, disables and unloads every owned job, and survives logout/login. `service uninstall` removes future-login registration without interrupting current jobs.

An installation made by an earlier release with a Cloudflare tunnel mode is migrated to `tailscale` by the next `setup`, which also stops and removes the old cloudflared job and its files. Devices paired against the old public URL must pair again from the new QR.

Adapter stdout is JSON. Permission authority remains the structured `shell-control/1` permit and exact run/request context—not an exit status. `request --wait` exits 0/10/11/12/13 for approved/rejected/expired/cancelled/unavailable.

## Agent relay

`agent` implements the hook profile of
[`spec.agent-relay.md`](../spec.agent-relay.md): Claude Code `PermissionRequest`
(Bash; Edit/Write with `--include-file-changes`, iPhone review only) and
`PreToolUse` `AskUserQuestion`, and Codex `PermissionRequest` (Bash).

`install` merges only Shell's stanzas into `~/.claude/settings.json` or
`~/.codex/hooks.json` (other hooks are preserved; the previous file is kept as
`*.shell-control-backup-<time>`), with a 360-second outer timeout. Codex runs
the hook only after you trust it with `/hooks` in Codex; setup never bypasses
that. `grant` adds the separately revocable agent grants to one enrolled iPhone
(`agent.sessions.read`, `agent.inputs.read`, `agent.inputs.respond`) or Watch
(`agent.inputs.read-via-gateway`, `agent.inputs.respond`); approvals need only
the existing approval grant.

The hook reviews within 300 seconds, stops waiting by 330 seconds after entry,
and always exits 0 — its stdout is the provider's decision JSON or nothing.
Before a request is published (Control stopped, unsupported tool, untested
build) it writes nothing and the provider's own terminal prompt applies. After
publication, failure, expiry, or changed context writes a denial labelled a
system outcome. An allow is written only after a validated claim, a local
recheck, and a journaled `dispatch_started`; delivery is then reported
`native_response_written`, because a hook cannot observe acceptance. A
question that is not answered in time stays with the terminal; no answer is
invented.

Every provider build is informational until it is covered by a
`contract_tested` range in `adapters/<provider>/manifest.json`, or until you run
`allow-build` for that exact build (`user_attested`, never "Ready"). `doctor`
reports readiness per provider. `test` runs the safe fixture — a fixed
`true` command that is never executed — through the real reviewer, claim,
native-response encoding, and receipt pipeline. The hook-profile limits are
real: a provider that never starts the hook, kills it, or auto-approves a tool
before the hook runs is not reviewed by Shell.

### Managed Codex (experimental)

`agent install codex --enable-managed` enables the managed app-server routes, and
`agent launch codex --managed` then runs `codex app-server` over stdio, owned by
that command (spec.agent-relay.md sections 11.2, 11.3, and 16). There is no Codex
TUI in this mode: agent text streams to the terminal, and typed lines start a turn
or steer the active one (`/interrupt`, `/approve N`, `/deny N`, `/answer N a || b`,
`/quit`). Command and file-change approvals and `requestUserInput` questions go to
Shell Control with their exact JSON-RPC ID and connection epoch; whichever answers
first — this terminal or a device — wins, and the other is withdrawn. A remote
answer is written only as a one-time `accept`/`decline` (never `acceptForSession`),
and `accepted` is reported only from the app-server's correlated
`serverRequest/resolved`. A remote request that expires stays with the terminal.

Devices granted `agent grant <id> --messages` (and `--cancel`) can send new
instructions, steer the active turn, or interrupt it. Each command is signed
against a digest of the exact text, mode, and turn it targets, recorded once,
claimed once for this connection, and refused — never queued — if the session
moved. An interrupt acknowledgement is not proof the process stopped. Messages
carry plain text only. The app-server interface is documented as experimental,
so this profile stays opt-in; every build is informational until attested or
covered by a tested range.

## Bundled Control host (TestFlight profile)

Section 19 of [`spec.agent-relay.md`](../spec.agent-relay.md) adds a second
distribution profile: the Control host packaged **inside the Mac Catalyst
app** as the sandboxed `ShellControlHost.app` LaunchAgent (see
[`../ShellControlHost`](../ShellControlHost/README.md)). It is separate from
the standalone Developer ID/CLI profile above and never installs, copies, or
starts it.

`ShellControlHostRuntime` (this package) composes the broker and daemon in one
process: single-writer lock of its private container, identity, legacy
detection, ledger restore, loopback broker, journal recovery with bounded
backoff, and only then adapter ingress and a `ready` phase. It depends on
`ShellControlDaemon`, `ShellControlHostSupport`, and `ShellControlBroker`, and
must never depend on `ShellControlManagement`. The adapter accept loop it
shares with `shell-controld` is `FramedIPCServer` in `ShellControlHostSupport`.

| Boundary | Mechanism |
|---|---|
| Storage | Ledger, journal, lock, identity, and origin key in the host's sandbox container (`Application Support/ShellControlHost`, 0700/0600); nothing resolved from `$HOME`. The origin key is never regenerated once the identity exists. |
| UI ↔ host | Swift XPC on the launchd Mach service `group.dev.chr33s.shell.control.host`: Codable `ControlHostRequest`/`ControlHostReply` (`status`, `mint_pairing`, `list_devices`, `list_pending_pairings`, `confirm_pairing`, `revoke_device`, `set_agent_grants`, `set_route`, `verify_route`, `stop_accepting_work`, `resume_accepting_work`). The listener requires `isFromSameTeam(andMatchesSigningIdentifier: "dev.chr33s.shell")`, and every message is re-checked against the sender's audit token (`senderSatisfies`); unknown operations and versions are rejected. `NSXPCConnection(machServiceName:)` is unavailable to Mac Catalyst, so both sides use `XPCSession`/`XPCListener`. |
| Adapter ↔ host | **Candidate:** the framed Unix socket `control.sock` in the App Group container, same-user peer check, per-run capabilities, 64 concurrent connections. `agent hook`, `agent test`, and `agent doctor` use it when no `--state-dir` is given and no standalone daemon is live. Whether an external provider hook can reach it under the distributed sandbox, and whether macOS prompts for group-container access, is for the distribution spike (spec 19.6). |
| Tailscale | The host never runs `tailscale`. You configure `tailscale serve --bg --https=443 http://127.0.0.1:8443`, enter the MagicDNS name in Shell, and the host verifies it by fetching `/v1/origin/proof` through it and checking the signature under its origin key. Failures are `invalid_name`, `unreachable`, `tls_failure`, `http_status`, `not_shell_broker`, or `origin_mismatch`. Pairing is refused until the route is verified. |
| Legacy install | Before claiming authority the host probes `127.0.0.1:<port>/v1/capabilities` and, where readable, `~/.local/state/shell-control/control.sock`. A foreign broker, a live standalone daemon, or an occupied port is `legacy_conflict` with the remedy (`shell-control down`); nothing is bound and no second ledger is written. |

The Catalyst UI reports the readiness states of spec 19.9
(`not_enabled`, `approval_required`, `registered_starting`, `ready_local`,
`route_unavailable`, `disabled_by_user`, `incompatible_build`, `degraded`, plus
`legacy_conflict`) from user intent, `SMAppService` status, and host status
together; `.enabled` alone is never "ready". `ready_local` means the host and
route are healthy, not that approvals are: that still needs the safe fixture
(`shell-control agent test`).

What is validated in this repository: `swift test --package-path cmd`
(`ShellControlHostRuntimeTests`: startup order, recovery before readiness,
duplicate refusal, legacy conflicts, identity persistence, stop/resume,
XPC peer rejection with the real code-signing check, route verification,
socket discovery), the Catalyst build layout, the absence of the host from iOS
builds, and a manual run of the unsigned host binary. What remains a release
gate, and is not claimed: signing and provisioning of both bundle IDs with the
App Group, TestFlight processing and install on a clean Mac, sandbox
enforcement with a real provider hook, the background-item consent prompts,
quit/logout/sleep behaviour, and scenarios A37–A52 of spec section 22.

## Development and release

```sh
swift test --package-path cmd
./scripts/test-lifecycle.sh
./scripts/build-control-release.sh arm64
./scripts/build-control-release.sh x86_64
DEVELOPER_ID_APPLICATION='Developer ID Application: …' NOTARYTOOL_PROFILE=shell \
  ./scripts/package-control-dmg.sh .derivedData/shell-control-1.0.0-arm64
```

`swift-argument-parser` is pinned and vendored under `vendor/`. Release manifests bind architecture, minimum OS, toolchain, release identity, and hashes of all three executables. CI must run the native tests on each advertised macOS 26 architecture and retain notarization/Gatekeeper evidence; physical Watch gates remain separate release evidence.
