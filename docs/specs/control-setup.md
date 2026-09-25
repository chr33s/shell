# Shell Control: Guided Setup, Diagnostics, and No-Relay Mode

**Status:** Implemented (`shell-control setup --guided`, `doctor`, `test-review`, iPhone **Settings → Control**, broker notification-preference API). Requirements remain normative; physical-device validation is tracked by the acceptance criteria.
**Scope:** Onboarding, diagnostics, safe review testing, and notification preferences for the optional Mac–iPhone Control companion, with optional Apple Watch enrollment and optional remote alerts.

## 1. Scope and boundaries

### 1.1 Product decision

The primary workflow is **Mac + iPhone**. A user MUST be able to finish setup, review a request on the iPhone, and report the result without an Apple Watch or a notification service. Watch enrollment and remote alerts are independent optional extensions; neither blocks the primary workflow.

Setup is a guided mode of the native Mac CLI ([`control-cli.md`](control-cli.md)) plus a guided flow under **Settings → Control** on the iPhone, reusing the existing management and protocol layers. Fresh guided installations default to **remote alerts off** (no-relay mode). Existing installations keep their choices until the user changes them.

Terminal rendering, SSH, tmux, and sync MUST remain usable without entering Control setup, installing host tools or Tailscale, enrolling a reviewer, or configuring a relay.

### 1.2 Relationship to other specifications

The authority, authentication, signed-decision, request-digest, versioning, idempotency, consume, and receipt rules of [`control-protocol.md`](control-protocol.md) remain authoritative. This document adds onboarding, diagnostics, and notification preferences only.

### 1.3 Non-goals

Deferred: hosted relay, relay generators, runtime relay picker, standalone Mac setup app, embedded `tsnet`, mandatory Tailscale Services. Excluded: public ingress, Cloudflare Tunnel, Funnel, cloud ledger or host directory, direct Watch-to-Mac networking, independent Watch, SSH on Watch, automatic or queued approvals, an in-app VPN. Nothing here makes an offline Mac available or guarantees iPhone background execution.

## 2. Architecture and trust boundaries

```text
CONTROL: required for live review
Program / permission hook --authenticated local IPC--> shell-controld -> Mac-local broker
  -> Tailscale Serve (HTTPS, tailnet only) -> iPhone review --WatchConnectivity--> optional Watch
     (broker holds the authoritative ledger)

ATTENTION: optional, never approval authority
Mac -> configured push relay -> APNs -> iPhone / system Watch presentation
```

- The broker stays on loopback; its endpoint is published only through the private Tailscale Serve route. Setup MUST verify the actual Serve configuration rather than trusting a command's success. See [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve).
- Pairing pins the origin identity and public signing key; the route is not the identity. A valid origin-signed route update may replace the cached route without replacing trust. A changed key MUST stop the flow and require explicit trust recovery.
- The iPhone is a reviewer in its own right and MUST forward Watch-signed decisions unchanged. Diagnostics MUST NOT bypass authentication or become an authorization path.

## 3. Readiness dimensions

Readiness is a set of independent dimensions, not one success boolean:

| Dimension | Values | Meaning |
|---|---|---|
| Control participation | `not_configured`, `configured` | Device has opted into the companion. |
| Host intent | `running`, `stopped` | Persisted user intent, separate from process health. |
| iPhone review | `not_paired`, `pending`, `ready`, `unavailable`, `revoked` | Pairing plus current usable path. |
| Watch extension | `not_configured`, `pending`, `ready`, `unavailable`, `revoked` | Optional enrollment and gateway path. |
| Remote alerts | `off`, `configured`, `degraded`, `disable_pending` | Notification capability, not control readiness. |

Enrolled is not reachable; a configured relay is not delivery; a past checkpoint is not current connectivity.

**Primary completion:** an enrolled iPhone verifies the origin, fetches live state, and completes the safe review test (section 8). Watch and notification failures MUST NOT block it. Never-configured Control shows a neutral invitation, not a warning; intentionally skipped features show **Not configured**, not **Broken**.

## 4. Guided Mac setup

### 4.1 Entry point

```sh
shell-control setup --guided
shell-control setup --guided --skip-watch-setup
```

- `--guided` requires an interactive terminal; otherwise it MUST fail before mutation (exit 2) and point to the explicit commands (`setup --no-watch`, `pair`, `confirm --yes`, `test-review`, `doctor`). Non-guided setup is unchanged.
- `--skip-watch-setup` suppresses only the optional Watch stage, never iPhone pairing. The existing `--no-watch` flag keeps its meaning (do not monitor enrollment after non-guided setup) and MUST NOT be repurposed; combining it with `--guided` is rejected.

### 4.2 Stages

| Stage | Evidence of completion |
|---|---|
| Introduction (Mac–iPhone control; Watch and alerts optional) | Explicit decision to configure Control. |
| Preflight (bundle integrity, installation, Tailscale, route) | Structured checks, not a generic success line. |
| Host services (reconcile; loopback-to-Serve route) | Broker and daemon health plus verified Serve target. |
| iPhone pairing (one-use material) | Broker-confirmed enrollment; showing a QR is insufficient. |
| Review test | Matching terminal receipt from the test origin. |
| Optional Watch (**Set up** / **Skip for now**) | Explicit skip, or confirmed Watch plus Watch test. |
| Optional alerts (no-relay allowed) | Explicit off choice or accurate existing state. |
| Finish (features, diagnostics, service lifetime) | Primary completion met. |

### 4.3 Preflight and safe mutations

- Reuse `LifecycleCoordinator` and the Tailscale abstractions; no second installer built from generated shell commands.
- Inspect the Serve handler before changing it. If the endpoint belongs to another application, stop with `serve_conflict`; never silently replace it or reset the whole Serve configuration. Refuse public (Funnel) exposure. Unknown configuration is not proof of safety.
- Guide the user to Tailscale sign-in/admin settings; never collect Tailscale credentials, generate broad grants, or alter tailnet policy.
- Stopped intent MUST remain stopped until an explicit **Start Control services** action; setup MUST NOT "repair" it.
- **Start at login** is an explicit choice; preserve existing persistence. Explain that closing the CLI does not stop running services, and never imply login persistence keeps a sleeping/logged-out Mac available.

### 4.4 Resume and cancellation

- Non-secret checkpoints live in `guided-setup.json` (format `shell-control.guided-setup/1`) in the state directory. Resume observes the real installation; it does not replay mutations.
- Checkpoints MUST NOT contain pairing secrets, private keys, bearer credentials, or approval payloads. Expired invitations are regenerated, never reused.
- Cancellation stops the guide and its transient work only. It MUST NOT revoke confirmed devices, delete origin keys, or stop an established installation. Partial operations reconcile through the lifecycle machinery; the guide reports what was left running.

## 5. iPhone setup and status

Entry: **Settings → Control → Set up Control**, sequence **Prepare Mac → Pair iPhone → Test review → Done**, with **Add Apple Watch** and **Remote alerts** as optional next sections.

- The scanner keeps the origin-proof and explicit-confirmation flow, with an accessible text-entry alternative. Never auto-confirm because a QR is nearby or the host is reachable.
- The iPhone SHOULD link to current Tailscale VPN On Demand guidance ([docs](https://tailscale.com/docs/features/client/ios-vpn-on-demand)) rather than implying Shell can configure or inspect another app's VPN.
- **Mac reachable** comes from authenticated route checks; **Identity verified** from origin proof. Unobservable Tailscale facts are labelled **Unknown** with suggested checks. A timeout alone does not prove a wrong tailnet, sleeping Mac, or revoked reviewer.

The status screen MUST distinguish:

```text
Control review   Ready / Unavailable / Not paired
Mac route        Reachable / Unreachable / Not checked
Origin identity  Verified / Mismatch / Not checked
Apple Watch      Not configured / Pending / Ready / Unavailable
Remote alerts    Off / Configured / Degraded / Disable pending
Last checked     Time of the relevant observation
```

Actions: **Check connection**, **Test review**, **Add Apple Watch**, **Export diagnostics**; destructive recovery is a separate labelled flow. Support Dynamic Type, VoiceOver, keyboard navigation, and non-color status. Notification permission is never a prerequisite for review.

## 6. Optional Apple Watch setup

- Offered only after iPhone pairing is confirmed; skippable permanently or resumable later without re-pairing the iPhone.
- The Watch generates and keeps its own signing key. The iPhone carries the enrollment request; the Mac explicitly confirms the Watch identity and its gateway iPhone. The Watch receives no Mac network credential or Tailscale configuration.
- Installation, enrollment, and reachability are separate: "app installed" is not "enrolled"; `WatchConnectivity` reachability is not a usable Mac path.
- The Watch test MUST be a fresh live round trip with the Watch's signature. On a broken path, show the failed segment when known and keep decisions disabled; never fall back to background transfer or an iPhone substitute decision.
- iPhone readiness is independent of Watch readiness. **Skip** MUST NOT revoke an enrolled Watch; revocation is explicit.

## 7. No-relay mode and notification policy

### 7.1 Definition and defaults

**No-relay mode means remote Control alerts are off.** It is not a transport, not offline operation, and not independent Watch operation.

A fresh guided setup MUST work with no relay URL, APNs key, notification permission, or capability, and MUST NOT silently substitute direct APNs. Review continues through foreground refresh/live reconciliation; no background polling or keepalive compensates. Required copy:

> Remote alerts are off. Open Control and refresh to check for requests. Live review still requires a connection to your Mac.

### 7.2 Local policy

- A locally persisted per-origin/per-iPhone preference: `off` or `configured`. A build-configured relay URL is availability, not consent.
- With `off`, Control MUST NOT register with the relay, upload a delivery token/capability, renew a capability, or send a notification test — even when the build has a valid relay URL.
- Do not unregister the app from APNs globally or change CloudKit; the preference covers Control notifications for that origin and reviewer only.
- Migration: keep an already-used configuration as is; where prior use cannot be established, ask once and default to off. Direct-APNs configuration is retained but labelled accurately, not as a shared relay.

### 7.3 Disabling an existing delivery path (host API)

```text
GET /v1/devices/me/notification-preference   -> { "enabled": true, "version": 1 }
PUT /v1/devices/me/notification-preference   body { "enabled": false, "expected_version": 1 }
                                             -> { "enabled": false, "version": 2 }
```

- Device-authenticated; acts only on the caller's record. Versions are nonnegative; absent = version 0 with its legacy value. Unknown fields, bad types, and unauthenticated calls are rejected. It changes delivery, never authorization.
- `enabled: false` MUST durably suppress relay and direct-APNs delivery to that device and remove its stored delivery material. Later token/capability registration MUST NOT reset an explicit disable. `enabled: true` only after explicit local opt-in, followed by fresh delivery material.
- Compare-and-set on `expected_version`; stale writes get HTTP 409; accepted writes increment the version. Clients serialize changes and after timeout/conflict reconcile only the latest intent, so a delayed enable cannot undo a later disable. New guided clients MUST set `off` explicitly.
- The client persists off intent and cancels in-flight registration first, showing **Off on this iPhone; Mac update pending** until acknowledged; only this setting is reconciled on reconnect. An older broker without the endpoint yields **Update host to finish disabling alerts**, never false success.
- Disabling one iPhone MUST NOT affect other reviewers, pairing, or pending approvals. Already-submitted APNs notifications may still appear.

### 7.4 Registration diagnostics

- Replace silent failures with bounded sanitized states: permission denied, token unavailable, relay rejected, network failure, capability expired, Mac registration pending. Unknown stays unknown.
- Bind cached registration to relay endpoint, app topic, APNs environment, origin identity, device record, token fingerprint, and expiry; never log token or capability. Endpoint change, re-pairing, token change, or off intent invalidate the cache; late results from an older policy generation are ignored.
- Relay/APNs acceptance MUST NOT be shown as confirmed presentation. Notification tests are explicit and optional.

## 8. Safe end-to-end review test

```sh
shell-control test-review --reviewer iphone --device-id <ENROLLED-DEVICE-ID>
shell-control test-review --reviewer watch  --device-id <ENROLLED-WATCH-ID>
```

- Uses a packaged fixed no-operation fixture through the real publication, review, signed-decision, consume, and receipt pipeline, with a fresh run/request identity, bounded expiry, immutable context, and the description **Setup test — no operation will be executed**.
- The fixture MUST NOT accept an executable, command string, path, environment override, terminal target, or network action; dispatch records only the allowed no-op result.
- Success requires a matching successful receipt — not a tap, accepted decision, or HTTP success. Rejection/expiry are valid outcomes but not success. Cancellation cancels the outstanding test where possible; an ambiguous submission reconciles the existing command ID rather than minting a new approval.
- Only explicit user action starts a test. Passive diagnostics MUST NOT create requests, enroll devices, consume approvals, or send notifications; tests never change authorization policy.

## 9. Diagnostic contract

### 9.1 Observation model

Shared portable models (`ControlDiagnostics`) serve Mac and iPhone presentation. A snapshot is evidence for display, never authorization. Each check has a stable `id` and `code`, `state`, `severity`, `required_for`, `source`, `observed_at`, sanitized `summary`, and an allowlisted `action`:

```json
{ "schema": "shell-control-diagnostics/1", "generated_at": "2026-09-24T09:00:00Z", "vantage": "iphone",
  "checks": [ { "id": "origin_identity", "code": "origin_verified", "state": "pass", "severity": "info",
                "required_for": ["iphone_review", "watch_review"], "source": "authenticated_origin_proof",
                "observed_at": "2026-09-24T08:59:59Z", "summary": "The Mac proved the pinned origin identity.",
                "action": null } ] }
```

- States: `pass`, `warn`, `fail`, `unknown`, `not_configured`, `disabled`. Missing evidence is `unknown`, never a fabricated pass or guessed failure; pending work uses a stable code with `unknown`/`warn`.
- `required_for` features: `host`, `iphone_review`, `watch_review`, `remote_alerts`.
- Vantages observe only themselves: the Mac its installation, services, and Serve; the iPhone its network path, session, notification permission, and WatchConnectivity; the Watch its identity and gateway round trip.

### 9.2 Checks and remediation

| Code | Observation | Required presentation/action |
|---|---|---|
| `tailscale_missing` | Mac CLI not located. | Explain installation; allow explicit CLI path. |
| `tailscale_not_connected` | Backend not running. | Guide sign-in/connection; retry. |
| `route_configuration_incomplete` | DNS/HTTPS route not established. | Name the observed missing prerequisite only. |
| `serve_conflict` | Endpoint not Shell-owned. | Stop before replacing it. |
| `serve_public_exposure` | Shell endpoint exposed via Funnel. | Block readiness; guide targeted correction. |
| `host_stopped_by_user` | Persisted intent stopped. | Offer explicit start, not auto-repair. |
| `broker_unavailable` / `daemon_unavailable` | Local health probe fails. | Show component and log/restart command. |
| `origin_key_missing` / `origin_key_mismatch` | Proof cannot match pinned identity. | Block control; separate explicit recovery. |
| `iphone_enrollment_pending` / `reviewer_revoked` | Confirmed broker state. | Explain confirmation or explicit re-pairing. |
| `route_unreachable` | Phone's connection fails. | Show observed error; offer connection checks. |
| `watch_not_configured` / `watch_gateway_unreachable` | Step omitted or gateway down. | Neutral skip state or targeted guidance. |
| `alerts_disabled_by_user` | Off policy acknowledged. | Informational, not degraded. |
| `notification_disable_pending` | Off intent lacks host ack. | Explain residual delivery; retry on connection. |
| `notification_registration_failed` | Configured path fails. | Stage + sanitized error; review stays available. |

Further stable pass/unknown codes exist (e.g. `serve_active`, `serve_status_unknown`). Actions are local allowlisted identifiers (e.g. `install_tailscale`, `disable_funnel`, `resolve_serve_conflict`, `recover_origin_identity`), never remotely supplied shell commands, and are never executed automatically.

### 9.3 Freshness, timeouts, power

- Run checks on screen open, explicit refresh, and after a setup operation; coalesce duplicates, cancel obsolete work, no continuous iPhone/Watch diagnostic loop.
- Connectivity evidence older than 30 s shows **Last checked**; a user-requested pass is bounded to 20 s, with each probe no longer than its transport deadline. These are UI budgets, not approval/crypto expiry.
- An expired observation never revokes a device; a green result never authorizes a decision. Review always uses live protocol checks.

## 10. `doctor`, persistence, and export

```sh
shell-control doctor            # human-readable
shell-control doctor --json     # shell-control-diagnostics/1
shell-control doctor --check    # exit 0 only if required host checks pass with current evidence
shell-control doctor --export <new-absolute-path>
```

- `doctor` is read-only. `--check` exits 1 on failed/unknown required host checks and 2 on invalid invocation; an unconfigured Watch or disabled alerts do not fail it. It checks the **host**, not iPhone/Watch end-to-end reachability, and says so.
- `status`, `status --text`, and `status --check` keep their existing formats and semantics; the richer contract belongs to `doctor`.
- Checkpoints, local alert policy, and registration generations are persisted separately from credentials, with atomic writes and existing secure storage. Origin keys, enrolled identities, pending operations, receipts, and journals MUST survive upgrades and guide restarts.
- Export is explicit and local: allowlisted fields only (app/build and OS version, vantage, check codes, timestamps, sanitized summaries). Redact tokens, keys, capabilities, pairing links/codes, approval content, command text, user paths, account identifiers, and full device/tailnet names; pseudonymize correlation IDs per export. No raw logs by default, no automatic upload, no shared cloud directory.

## 11. Implementation map

CLI: `cmd/Sources/shell-control/Commands/SetupCommand.swift`, `DiagnosticCommands.swift`. Host: `cmd/Sources/ShellControlManagement/GuidedSetupCoordinator.swift`, `HostDiagnostics.swift`, `SetupReviewTest.swift`, `TailscaleConfiguration.swift`. Shared: `Packages/ShellControlCore/Sources/Client/ControlDiagnostics.swift`, `RemoteAlerts.swift`, `Protocol/NotificationPreference.swift`, `Protocol/SetupTest.swift`. Broker: `services/shell-control/`. iPhone: `shell/Features/Control/ControlSetupGuide.swift`, `ControlPushCapability.swift`. Watch: `ShellWatch/`.

Terminal, SSH, and tmux modules MUST NOT depend on setup UI, relay, or Tailscale code; portable protocol/client code stays free of presentation frameworks.

## 12. Acceptance criteria

| ID | Scenario | Required result |
|---|---|---|
| AC-01 | Terminal/SSH/tmux only. | No Control prerequisites or prompts block use. |
| AC-02 | Fresh Mac + iPhone; no Watch, relay, or notification permission. | Guided setup and safe iPhone review complete. |
| AC-03 | Watch skipped. | Primary setup complete; Watch **Not configured**. |
| AC-04 | Watch added later. | iPhone pairing and origin key unchanged. |
| AC-05 | Build has relay URL; user picks no-relay. | No relay registration or capability upload. |
| AC-06 | Alerts configured; relay registration fails. | Failure visible; live review usable. |
| AC-07 | Alerts disabled while Mac offline. | Local work stops; pending suppression shown accurately. |
| AC-08 | Host acknowledges suppression. | No new sends to that reviewer; others unaffected. |
| AC-09 | Registration result arrives after off. | Cannot restore delivery or enabled UI. |
| AC-10 | Wi-Fi/WAN change or signed route update. | Trust preserved; no re-pairing. |
| AC-11 | Origin key missing or proof mismatch. | Control blocked; no silent regeneration/replacement. |
| AC-12 | Serve endpoint owned by another app. | Setup stops without touching it or other handlers. |
| AC-13 | Shell endpoint Funnel-exposed. | Setup cannot report ready. |
| AC-14 | Guide rerun after `down`. | Stopped until explicit start. |
| AC-15 | Guide cancelled or restarted mid-stage. | Resume observes reality; pairing and journals survive. |
| AC-16 | Mac doctor green, iPhone cannot connect. | Mac claims no phone reachability; iPhone shows its failure. |
| AC-17 | Watch gateway lost during review. | No queued approval or substituted iPhone signature. |
| AC-18 | Test decision accepted, receipt absent. | Not success; ambiguity reconciled. |
| AC-19 | Diagnostics exported. | Redaction passes fixtures; no upload. |
| AC-20 | Legacy `status` / `setup --no-watch` scripts. | Output and flag semantics preserved. |
| AC-21 | Configured installation upgrades. | Identities, notification choices, persistence, pending state survive. |
| AC-22 | Older broker lacks preference API. | Missing capability explicit; disable not falsely complete. |

Automated coverage MUST include guide-state transitions, cancellation, idempotent resume, Serve conflicts, diagnostic aggregation, notification-policy races, cache invalidation, replay protection, and migration.

Physical-device validation MUST cover no-Watch setup, real Watch enrollment, iPhone foreground/background/locked, WatchConnectivity loss, Wi-Fi↔cellular, VPN reconnection, Mac sleep/wake, and any advertised notification path, with device/OS/build versions recorded. Compiling or source inspection is not evidence.
