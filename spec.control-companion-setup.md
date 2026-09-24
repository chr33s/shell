# Shell Control Companion: Guided Setup, Diagnostics, and No-Relay Mode

**Status:** Proposed implementation specification; not an implementation or deployment report.  
**Repository:** `chr33s/shell`  
**Suggested repository filename:** `spec.control-companion-setup.md`  
**Specification version:** 1.0  
**Date:** 24 September 2026  
**Inspected baseline:** `main` at `df8d16871cb8605553b45f78df286cbc9d0cb051`. [R1]  
**Scope:** The optional Mac–iPhone Control companion, with optional Apple Watch enrollment and optional remote alerts.

## 1. Product decision

Implement a guided setup flow and evidence-based diagnostics for **Shell Control**, not general Shell onboarding and not a Watch-only feature.

The complete primary workflow is **Mac + iPhone**. A user MUST be able to finish setup, review a permission request on the iPhone, and report the result without owning an Apple Watch or configuring a notification service.

Apple Watch enrollment is an optional extension. Remote alerts are a separate optional capability. Neither is a prerequisite for the primary workflow.

For this increment, use a guided mode in the existing native Mac CLI and a guided experience under **Settings → Control** on the iPhone. Reuse the current management and protocol layers. A separate Mac setup application is deferred; it is not a prerequisite for shipping this specification.

Fresh guided installations default to **remote alerts off**, called **no-relay mode** in this document. Existing installations retain their choices until the user explicitly changes them.

Ordinary terminal rendering, SSH, tmux, and synchronization MUST remain usable without entering Control setup, installing Control host tools, installing Tailscale for this feature, enrolling a reviewer, or configuring a relay. This maintains the repository's optional-companion boundary. [R2]

## 2. Normative language and relationship to existing specifications

**MUST**, **MUST NOT**, **SHOULD**, and **MAY** identify requirements, recommendations, and permitted alternatives in this proposed specification.

The authority, authentication, signed-decision, request-digest, versioning, idempotency, consume, and receipt rules of `spec.iphone-gateway.md` remain authoritative. This specification adds onboarding, diagnostics, and notification preferences; it does not replace those security rules. The iPhone-gateway profile continues to supersede the older independent-Watch topology. [R3]

All commands, types, screens, and endpoints explicitly labeled **new** below are proposed additions, not claims that they exist at the inspected baseline. Acceptance criteria are release requirements, not completed test results.

## 3. Existing foundation and implementation delta

| Area | Inspected foundation | Required delta |
|---|---|---|
| Host setup | Native setup, service lifecycle, Tailscale checks, Serve configuration, and pairing output. [R4] [R5] | Resumable guided stages, explicit optional choices, and safe remediation. |
| Status | `shell-control status` already emits JSON; `--text` renders a summary and `--check` checks configured-path readiness. [R6] | Component evidence, freshness, corrective actions, and separate feature readiness. |
| iPhone and Watch | The iPhone is a full review client and the Watch's network gateway. [R2] [R3] | Finish-without-Watch flow, optional Watch checklist, and actionable status views. |
| Notifications | The optional relay is a notification sender, not an approval authority. [R7] | Explicit off state and visible registration/delivery failures. |
| Relay registration | The iPhone reads a build-configured URL and caches token, device record, and expiry; failures do not currently become user-visible errors. [R8] | Local policy gate, endpoint-aware cache identity, lifecycle handling, and diagnostics. |

**CLI terminology caveat:** the existing `setup --no-watch` flag disables *monitoring device enrollment*. It does not mean “skip Apple Watch setup.” Preserve that behavior; do not repurpose the flag. [R5]

## 4. Scope and non-goals

### 4.1 Required in this increment

Provide guided Mac installation and iPhone pairing, optional Watch enrollment, separate readiness indicators, no-relay operation, safe end-to-end review testing, redacted diagnostic export, and compatibility with existing installations.

Diagnose an already configured notification path without requiring users to deploy one. Retain existing advanced notification configuration commands.

### 4.2 Deferred

A hosted Shell relay, Cloudflare Worker implementation, relay deployment generator, runtime hosted/custom relay picker, standalone Mac setup app, embedded `tsnet`, and mandatory Tailscale Services are outside this increment.

### 4.3 Explicit exclusions

Do not add public Mac ingress, Cloudflare Tunnel, Funnel exposure, a cloud approval ledger, a cloud host directory, direct Watch-to-Mac networking, independent Watch operation, SSH or terminal streaming on Watch, automatic approvals, queued eventual approvals, or a new VPN implementation inside Shell.

No feature in this specification makes an offline Mac available or guarantees background execution on the iPhone.

## 5. Architecture and trust boundaries

```text
CONTROL: required for live review

Program / permission hook
        |
        | authenticated local IPC
        v
shell-controld -> Mac-local broker -> Tailscale Serve -> iPhone review
                       |                  HTTPS              |
                authoritative ledger                  WatchConnectivity
                                                            |
                                                     optional Watch

ATTENTION: optional, never approval authority

Mac -> configured push relay -> APNs -> iPhone / system Watch presentation
```

Keep the broker on loopback and publish its control endpoint only through the private Tailscale route. Serve provides tailnet access rather than public access, and tailnet access rules still apply. Verify actual Serve configuration rather than assuming a successful command establishes privacy. [R3] [E1]

Pairing MUST pin the origin identity and public signing key. The route is not the identity. A valid origin-signed route update can replace the cached route without replacing trust; a changed key MUST stop the flow and require explicit trust recovery. [R2] [R3]

The iPhone MUST remain a reviewer in its own right. It MUST forward Watch-signed decisions unchanged, not replace them with iPhone approvals. Diagnostics MUST NOT bypass authentication or become an alternative authorization path. [R3] [R9]

## 6. Product modes and readiness

Treat the following as independent dimensions rather than one installation-success boolean:

| Dimension | Values | Meaning |
|---|---|---|
| Control participation | `not_configured`, `configured` | Whether this device has opted into the companion. |
| Host intent | `running`, `stopped` | Persisted user intent, separate from observed process health. |
| iPhone review | `not_paired`, `pending`, `ready`, `unavailable`, `revoked` | Pairing plus current usable control path. |
| Watch extension | `not_configured`, `pending`, `ready`, `unavailable`, `revoked` | Optional enrollment and current gateway path. |
| Remote alerts | `off`, `configured`, `degraded`, `disable_pending` | Notification capability, not control readiness. |

An enrolled device is not necessarily reachable. A configured relay is not evidence of notification delivery. A successful setup checkpoint is not permanent proof of connectivity.

**Primary completion:** an enrolled iPhone verifies the origin, fetches live state, and completes the safe review test in section 11. Watch and notification failures MUST NOT block this completion.

When Control has never been configured, show a neutral invitation in Settings rather than a global warning. When an optional feature was intentionally skipped, show **Not configured**, not **Broken**.

## 7. Guided Mac setup

### 7.1 Entry point and command compatibility

Add these **new** guided options:

```sh
shell-control setup --guided
shell-control setup --guided --skip-watch-setup
```

`--guided` requires an interactive terminal. A non-interactive invocation MUST fail before mutations and explain how to use the existing explicit commands instead. Existing non-guided setup behavior remains compatible.

`--skip-watch-setup` only suppresses the optional Apple Watch stage. It MUST NOT suppress iPhone pairing or device confirmation. Keep the existing `--no-watch` enrollment-monitoring behavior unchanged and describe the distinction in help.

### 7.2 Stages

| Stage | Required behavior | Evidence of completion |
|---|---|---|
| Introduction | Explain Mac–iPhone control, optional Watch, and optional alerts. | Explicit decision to configure Control. |
| Preflight | Check supported native bundle, executable integrity, installation state, Tailscale availability, connectivity, and required route configuration. | Structured checks, not a generic success line. |
| Host services | Reconcile installation and configure the private loopback-to-Serve route. | Broker and daemon health plus verified Serve target. |
| iPhone pairing | Show one-use pairing material and confirmation instructions. | Broker-confirmed iPhone enrollment; QR display alone is insufficient. |
| Review test | Run the harmless request through the selected iPhone. | Matching terminal receipt from the test origin. |
| Optional Watch | Offer **Set up Apple Watch** or **Skip for now**. | Explicit skip or confirmed Watch and successful Watch test. |
| Optional alerts | Explain the current alert mode; permit no-relay completion. | Explicit off choice or accurate existing configuration state. |
| Finish | Summarize enabled features, diagnostics entry points, and service lifetime. | Primary completion criteria met. |

### 7.3 Preflight and safe mutations

Reuse `LifecycleCoordinator` and the existing Tailscale abstractions. Do not implement a second installer as generated shell commands. [R4] [R10] [R12]

Inspect the existing Serve handler before changing it. If the required endpoint belongs to another application, stop with `serve_conflict`; do not silently replace it. Do not reset the user's entire Serve configuration. Refuse public exposure of the Shell endpoint. An unknown or unsupported configuration is not proof of safety.

Guide the user to Tailscale sign-in or administrative settings when needed. Do not collect Tailscale credentials, generate broad access grants, or silently alter tailnet-wide policy.

A stopped installation MUST remain stopped until an explicit **Start Control services** action invokes the existing start operation. Setup MUST NOT treat stopped intent as a defect to repair automatically. The current management model already distinguishes desired state from runtime state. [R10] [R11]

Offer **Start at login** as an explicit choice; preserve existing persistence settings. Explain that closing the setup CLI does not stop installed running services. Never imply that login persistence keeps a sleeping or logged-out execution environment continuously available.

### 7.4 Resume and cancellation

Store non-secret progress checkpoints under the installation state directory. Resume by observing the real installation, not replaying previously successful mutations.

Checkpoint data MUST NOT contain pairing secrets, private keys, bearer credentials, or approval payloads. Generate a new pairing invitation when the old one expires; do not reuse it because a checkpoint names the pairing stage.

Cancellation stops the guide and its transient work. It MUST NOT revoke confirmed devices, delete origin keys, or stop an established installation. Reconcile partial installation operations through the existing lifecycle machinery. Display any resources created or services left running.

## 8. iPhone setup and diagnostics experience

The entry point is **Settings → Control → Set up Control**. Present the primary sequence as **Prepare Mac → Pair iPhone → Test review → Done**, with **Add Apple Watch** and **Remote alerts** as optional next sections.

The scanner MUST retain the current origin-proof and explicit-confirmation flow. Provide an accessible text-entry alternative for pairing material. Never auto-confirm because a QR is nearby or the host is reachable.

The iPhone SHOULD provide guidance for Tailscale VPN On Demand. Current Tailscale documentation describes hostname-triggered connection for `*.ts.net` when the relevant interface rule is **Do Nothing**. Link to current guidance rather than implying that Shell can configure or inspect another app's private VPN settings. [E2]

Use authenticated route checks to establish **Mac reachable** and origin proof to establish **Identity verified**. Where the app cannot directly observe Tailscale installation, sign-in, or policy, label those facts **Unknown** and suggest checks. A timeout alone does not prove the wrong tailnet, a sleeping Mac, or a revoked reviewer.

The main status screen MUST distinguish:

```text
Control review       Ready / Unavailable / Not paired
Mac route            Reachable / Unreachable / Not checked
Origin identity      Verified / Mismatch / Not checked
Apple Watch          Not configured / Pending / Ready / Unavailable
Remote alerts        Off / Configured / Degraded / Disable pending
Last checked         Time of the relevant observation
```

Actions include **Check connection**, **Test review**, **Add Apple Watch**, and **Export diagnostics**. Restrict destructive recovery to a separate, clearly labeled flow.

Support Dynamic Type, VoiceOver, keyboard navigation where applicable, and status descriptions that do not depend on color. Do not use a notification-permission prompt as a prerequisite for review.

## 9. Optional Apple Watch setup

Only offer Watch enrollment after iPhone pairing is confirmed. The user can skip it permanently or resume later without pairing the iPhone again.

The Watch generates and retains its own signing key. The iPhone carries the enrollment request to the Mac; the Mac explicitly confirms the Watch identity and associated gateway iPhone. The Watch receives no Mac network credential or Tailscale configuration. [R3]

Separate installation, enrollment, and reachability states. “Watch app installed” does not mean “reviewer enrolled,” and `WatchConnectivity` reachability does not by itself establish a usable Mac path.

The Watch test MUST use a fresh live round trip and the Watch's signature. When the iPhone or Mac path is unavailable, show the failed segment when known and leave decisions disabled. Do not fall back to background transfer of an approval or substitute an iPhone decision.

The iPhone's primary Control readiness remains independent of Watch readiness. Selecting **Skip** MUST NOT revoke an already enrolled Watch; revocation is a separate explicit operation.

## 10. No-relay mode and notification policy

### 10.1 Definition and defaults

In this specification, **no-relay mode means remote Control alerts are off**. It is not a new network transport and does not mean offline, infrastructure-free, or independent-Watch operation.

A fresh guided setup MUST work with no relay URL, no APNs provider key, no notification permission grant, and no notification capability. It MUST NOT silently use direct APNs as a substitute for the relay.

Review continues through explicit foreground refresh or existing live foreground reconciliation. Do not add background polling or keepalive behavior to compensate for disabled alerts.

Required explanatory copy:

> Remote alerts are off. Open Control and refresh to check for requests. Live review still requires a connection to your Mac.

The existing architecture permits correct operation without its optional relay; the missing capability is prompt remote attention while the iPhone app is suspended. [R3] [R7]

### 10.2 Explicit local policy

Add a **new**, locally persisted per-origin/per-iPhone preference: `off` or `configured`. A build-configured relay URL is availability information, not consent to register.

With `off`, Control MUST NOT register with the relay, upload a Control delivery token or capability, renew a capability, or initiate a notification test. This gate MUST apply even when a build includes a valid relay URL.

Do not globally unregister the app from APNs or change CloudKit behavior. The preference applies only to Control notifications for the selected origin and reviewer.

For existing installations, migrate an already used notification configuration without silently turning it on or off. Where prior use cannot be established, ask once and default to off. Retain existing advanced direct-APNs configuration, but label it accurately rather than calling it a shared relay.

### 10.3 Disabling an existing delivery path

A local preference alone cannot remove a capability already held by the Mac. Add a **new authenticated per-device notification-preference API**:

```text
GET /v1/devices/me/notification-preference
PUT /v1/devices/me/notification-preference

GET response: { "enabled": true, "version": 1 }
PUT body: { "enabled": false, "expected_version": 1 }
PUT response: { "enabled": false, "version": 2 }
```

The API MUST use existing device authentication and operate only on the authenticated iPhone's record. Versions are nonnegative integers; treat a previously absent preference as version 0 while preserving its legacy effective value. It changes notification delivery, not reviewer authorization. Reject unknown fields, invalid types, and unauthenticated calls using the existing API error conventions.

`PUT` with `enabled: false` MUST durably suppress both relay and any direct-APNs delivery to that device and remove its stored Control delivery material. Subsequent token/capability registration MUST NOT implicitly reset an explicit disabled preference. `PUT` with `enabled: true` is allowed only after an explicit local opt-in; the client then obtains fresh delivery material.

Use atomic compare-and-set on `expected_version`; reject stale writes with HTTP 409 and increment the version after an accepted mutation. Serialize client preference changes. After a timeout or conflict, fetch the current preference and reconcile only the latest persisted user intent. Repeating an off operation is semantically idempotent, but a stale conditional request must not overwrite a newer choice. This prevents a delayed enable request from undoing a subsequent disable.

An absent preference on migrated records retains prior eligibility until explicitly changed. New guided clients MUST establish the off preference as part of their no-relay choice. This is an additive API extension; signed approval envelopes and authority rules do not change.

Persist local off intent and invalidate in-flight registration work before contacting the Mac. Until the Mac acknowledges suppression, show **Off on this iPhone; Mac update pending**. Reconcile only this idempotent settings intent during normal foreground reconnection, not approval commands. A response from an older broker that lacks the endpoint MUST produce **Update host to finish disabling alerts**, not false success.

Disabling one iPhone MUST NOT disable another reviewer's alerts. Notifications already submitted to APNs may still appear; do not promise recall. Turning off alerts MUST NOT revoke pairing or affect pending approval correctness.

### 10.4 Registration diagnostics for configured installations

Replace silent failures with bounded, sanitized states: permission denied, token unavailable, relay rejected registration, network failure, capability expired, or Mac registration pending. Unknown causes remain unknown.

Bind cached registration to relay endpoint, app topic, APNs environment, origin identity, iPhone device record, token fingerprint, and expiry. Do not log the token or capability. Endpoint changes, re-pairing, token changes, and explicit off intent invalidate the relevant cache. Ignore late registration results from an older policy generation.

Keep notification state separate from review readiness. Relay acceptance or APNs acceptance MUST NOT be displayed as confirmed screen presentation. A notification test requires explicit user action and remains optional.

## 11. Safe end-to-end review test

Add a **new** command, also accessible from the guide:

```sh
shell-control test-review --reviewer iphone --device-id <ENROLLED-DEVICE-ID>
shell-control test-review --reviewer watch --device-id <ENROLLED-WATCH-ID>
```

Use a packaged, fixed no-operation adapter fixture through the existing publication, review, signed-decision, consume, and receipt pipeline. It MUST have a new run/request identity, bounded expiry, immutable request context, and an unmistakable **Setup test — no operation will be executed** description.

The test adapter MUST NOT accept an arbitrary executable, command string, file path, environment override, terminal target, or network action. Its dispatch implementation records the allowed no-operation result; the test must not authorize a real operation under a reassuring label.

Test success requires a matching successful receipt, not just a tap, accepted decision, or HTTP success. Rejection and expiry are valid outcomes but do not satisfy the successful-review checkpoint. Explicit cancellation cancels the outstanding test where possible. An ambiguous submission MUST reconcile the existing command ID rather than mint another approval automatically.

Only explicit user action may start a test. Passive diagnostics MUST NOT create requests, enroll devices, consume approvals, or send notifications. Testing must not change authorization policy or grant persistent permissions.

## 12. Diagnostic contract

### 12.1 Observation model

Add portable diagnostic models shared by the Mac and iPhone presentation layers. A diagnostic snapshot is evidence for display, never authorization.

Each check includes a stable identifier and code, state, severity, observation source, observation time, applicability, sanitized explanation, and an allowlisted corrective action. Recommended shape:

```json
{
  "schema": "shell-control-diagnostics/1",
  "generated_at": "2026-09-24T09:00:00Z",
  "vantage": "iphone",
  "checks": [
    {
      "id": "origin_identity",
      "code": "origin_verified",
      "state": "pass",
      "severity": "info",
      "required_for": ["iphone_review", "watch_review"],
      "source": "authenticated_origin_proof",
      "observed_at": "2026-09-24T08:59:59Z",
      "summary": "The Mac proved the pinned origin identity.",
      "action": null
    },
    {
      "id": "remote_alerts",
      "code": "alerts_disabled_by_user",
      "state": "disabled",
      "severity": "info",
      "required_for": [],
      "source": "local_preference_and_host_acknowledgement",
      "observed_at": "2026-09-24T08:59:59Z",
      "summary": "Remote Control alerts are off.",
      "action": null
    }
  ]
}
```

Allowed check states: `pass`, `warn`, `fail`, `unknown`, `not_configured`, `disabled`. Missing evidence is `unknown`, never a fabricated pass or a guessed failure. A pending operation uses an appropriate stable code with `unknown` or `warn`, not an unsupported state.

The Mac observes installation, local services, and Serve configuration. The iPhone observes its own authenticated network path, reviewer session, notification permissions, and WatchConnectivity state. A Watch observes its own identity and gateway round trip. Do not imply one vantage has inspected another device's private system state.

### 12.2 Checks and remediation

| Check/code | Observation or failure | Required presentation/action |
|---|---|---|
| `tailscale_missing` | Mac CLI not located. | Explain installation; allow explicit CLI path. |
| `tailscale_not_connected` | Mac CLI reports a non-running backend. | Guide sign-in/connection; retry. |
| `route_configuration_incomplete` | Required DNS/HTTPS route not established. | Identify observed missing prerequisite; no speculative diagnosis. |
| `serve_conflict` | Existing endpoint is not Shell-owned. | Stop before replacing it. |
| `serve_public_exposure` | Shell endpoint is exposed through Funnel. | Block readiness and guide targeted correction. |
| `host_stopped_by_user` | Persisted intent is stopped. | Offer explicit start, not automatic repair. |
| `broker_unavailable` / `daemon_unavailable` | Local health probe fails. | Show the failing component and existing log/restart command. |
| `origin_key_missing` / `origin_key_mismatch` | Trust proof cannot match the pinned identity. | Block control; separate explicit identity recovery. |
| `iphone_enrollment_pending` / `reviewer_revoked` | Confirmed broker state. | Explain confirmation or explicit re-pairing. |
| `route_unreachable` | Phone's control connection fails. | Show observed network error; offer connection checks. |
| `watch_not_configured` / `watch_gateway_unreachable` | Optional step omitted or live gateway unavailable. | Neutral skip state or targeted Watch guidance. |
| `alerts_disabled_by_user` | Off policy acknowledged. | Informational, not degraded Control. |
| `notification_disable_pending` | Local off intent lacks host acknowledgement. | Explain residual delivery possibility and retry on connection. |
| `notification_registration_failed` | Configured notification path fails. | Show stage and sanitized error; keep review available. |

Actions MUST be local allowlisted identifiers, not remotely supplied shell commands. Offer commands as explicit user actions; diagnostics MUST NOT execute them automatically.

### 12.3 Freshness, timeouts, and power

Run checks when the relevant screen opens, on explicit refresh, and after a setup operation. Coalesce duplicate checks and cancel obsolete work. Do not introduce a continuously running iPhone or Watch diagnostic loop.

As proposed product defaults, mark connectivity evidence older than 30 seconds as **Last checked**, and bound a user-requested diagnostic pass to 20 seconds, with individual probe deadlines no greater than the relevant existing transport deadline. These are UI budgets, not changes to approval or cryptographic expiration rules.

An expired diagnostic observation does not revoke a device. A recent green diagnostic result does not authorize a decision. Actual review always uses the live protocol checks.

## 13. CLI, persistence, and diagnostic export

Add a **new** read-only diagnostic command:

```sh
shell-control doctor
shell-control doctor --json
shell-control doctor --check
```

Default output is human-readable. `--json` emits the section 12 schema. `--check` exits 0 only when required host checks have current passing evidence; failed or unknown required host checks produce exit 1, and invalid invocation produces exit 2. An optional unconfigured Watch or disabled alerts do not fail it. State plainly that this checks the **host**, not current iPhone or Watch end-to-end reachability.

Preserve existing `status` JSON output and `status --text` behavior. Do not replace their formats or change existing `status --check` semantics silently; the richer contract belongs to `doctor`. [R6]

Persist setup checkpoints, local alert policy, and registration generations separately from credentials. Use atomic writes and existing secure storage conventions. Existing origin keys, enrolled identities, pending operations, receipts, and journals MUST survive an upgrade and a guide restart.

Diagnostic export is explicit and local. Export structured, allowlisted fields by default: application/build version, OS version, vantage, check codes, timestamps, and sanitized summaries. Redact tokens, keys, capabilities, pairing links/codes, approval content, command text, user paths, account identifiers, and full device/tailnet names. Pseudonymize correlation identifiers within one export where useful.

Do not include raw logs by default, upload reports automatically, or write exported data into a shared cloud directory. The user chooses the destination and can inspect the report before sharing.

## 14. Proposed implementation map

These placements identify existing integration points and clearly labeled proposed files; they are not an assertion that new files already exist.

| Area | Existing integration point | Proposed work |
|---|---|---|
| Guided CLI | `cmd/Sources/shell-control/Commands/SetupCommand.swift` | Add guided options and presentation; preserve current flag meanings. |
| Setup orchestration | `cmd/Sources/ShellControlManagement/` | New `GuidedSetupCoordinator.swift`; reuse lifecycle operations and observation. |
| Tailscale safety | `TailscaleConfiguration.swift` in the management module | Ownership/conflict inspection and precise failure classification. |
| Host diagnostics | Management module and CLI commands | New diagnostic coordinator and `DoctorCommand.swift`. |
| Safe test | Existing CLI/daemon adapter pipeline | New fixed test fixture and `TestReviewCommand.swift`; no arbitrary command path. |
| Shared client model | `Packages/ShellControlCore/Sources/Client/` | New `ControlDiagnostics.swift`; add notification-preference client methods. |
| Broker | `services/shell-control/` | Per-device notification gate and authenticated preference endpoint. |
| iPhone UI | `shell/Features/Control/` | New setup/status views using current pairing, trust, and gateway components. |
| Notification lifecycle | `ControlPushCapability.swift` | Explicit policy, generation-aware work, cache invalidation, and visible outcomes. |
| Watch UI | `ShellWatch/` | Optional enrollment/progress presentation and safe-test review. |
| Tests and documentation | Existing package tests, `ShellWatchTests/`, `cmd/README.md`, gateway spec | Regression coverage, user-facing scope, and additive API documentation. |

Do not introduce a dependency from terminal rendering, SSH, or tmux modules to setup UI, relay code, or Tailscale implementation code. Portable protocol/client code must remain independent of platform presentation frameworks.

## 15. Acceptance criteria

| ID | Scenario | Required result |
|---|---|---|
| AC-01 | User uses only terminal, SSH, or tmux. | No Control prerequisites or setup prompts block use. |
| AC-02 | Fresh Mac + iPhone, no Watch, no relay, no notification permission. | Guided setup and safe iPhone review complete. |
| AC-03 | User skips Watch enrollment. | Primary setup is complete; Watch is neutral **Not configured**. |
| AC-04 | Watch is added later. | Existing iPhone pairing and origin key remain unchanged. |
| AC-05 | Fresh build contains a relay URL but user chooses no-relay mode. | No Control relay registration or capability upload occurs. |
| AC-06 | Alerts are configured but relay registration fails. | Failure is visible; live iPhone review remains usable. |
| AC-07 | User disables alerts while the Mac is offline. | Local work stops immediately; pending host suppression is shown accurately. |
| AC-08 | Host acknowledges alert suppression. | No new Control sends to that reviewer; other reviewers are unaffected. |
| AC-09 | Registration result arrives after the user selected off. | Stale work cannot restore delivery configuration or enabled UI. |
| AC-10 | Wi-Fi/WAN changes or valid signed route update occurs. | Trust is preserved; no unnecessary re-pairing. |
| AC-11 | Origin key is missing or proof mismatches. | Live control is blocked; no silent regeneration or trust replacement. |
| AC-12 | Shell's required Serve endpoint belongs to another app. | Setup stops without changing that endpoint or unrelated handlers. |
| AC-13 | Shell endpoint has public Funnel exposure. | Setup cannot report ready. |
| AC-14 | Guide is rerun after persisted `down`. | Stopped intent remains until explicit start. |
| AC-15 | Guide is cancelled or application restarts mid-stage. | Resume observes reality; established pairing and journals survive. |
| AC-16 | Mac doctor is green but iPhone cannot connect. | Mac output does not claim phone reachability; iPhone shows its own failure. |
| AC-17 | Watch gateway becomes unavailable during review. | No queued eventual approval or substituted iPhone signature. |
| AC-18 | Test decision is accepted but receipt is absent. | Test is not reported as successful; ambiguity is reconciled. |
| AC-19 | Diagnostic report is exported. | Secret/content redaction passes automated fixtures; no automatic upload. |
| AC-20 | Legacy scripts use `status` or `setup --no-watch`. | Existing output/flag semantics are preserved. |
| AC-21 | Existing configured installation upgrades. | Identities, notification choices, persistence, and pending state survive. |
| AC-22 | Older broker lacks the new preference API. | Missing capability is explicit; disabling is not falsely reported complete. |

Automated coverage MUST include guide-state transitions, cancellation, idempotent resume, Serve conflicts, diagnostic aggregation, notification-policy races, cache invalidation, protocol replay protection, and migration.

Physical-device validation MUST cover Mac+iPhone without Watch, real Watch enrollment, iPhone foreground/background/locked states, WatchConnectivity loss, Wi-Fi-to-cellular transitions, VPN reconnection, Mac sleep/wake, and any advertised notification path. Record device/OS/build versions and observed outcomes. The baseline gateway specification explicitly leaves physical-device validation outstanding; source inspection is not evidence that those scenarios pass. [R3]

## 16. Delivery boundaries and definition of done

**Increment A — primary Control setup:** shared diagnostic model, host doctor, guided CLI, iPhone setup/status, fixed review test, and fresh no-relay operation. A Mac+iPhone user can finish without optional infrastructure.

**Increment B — lifecycle and optional extensions:** notification opt-out acknowledgement, visible failures for existing notification paths, migration/race coverage, and optional Watch setup/test integration. These requirements must be complete before claiming the full specification is implemented.

**Separate future proposal:** hosted notifications, a Cloudflare Worker deployment, relay generators, runtime hosted/custom selection, a standalone setup application, or embedded Tailscale networking. None may delay or become a dependency of the primary private control path.

The specification is complete when its applicable acceptance criteria pass, physical-device evidence is retained, documentation names the feature **Control companion setup**, and normal terminal users remain unaffected. Publishing a spec, compiling a target, or deploying a relay alone does not satisfy this definition.

## 17. Source references

Repository links are pinned to the inspected commit so the baseline can be distinguished from future implementation. External documentation was checked on 24 September 2026. References support the existing facts identified inline; proposed requirements are design decisions.

| Reference | Source |
|---|---|
| [R1] | Inspected repository commit. |
| [R2] | Repository README: optional companion, topology, identity, and setup boundary. |
| [R3] | `spec.iphone-gateway.md`: authority model, optional relay, and validation status. |
| [R4] | `cmd/README.md`: native setup and management commands. |
| [R5] | `SetupCommand.swift`: current setup options and enrollment-monitoring behavior. |
| [R6] | `LifecycleCommands.swift`: current status, lifecycle, and log commands. |
| [R7] | Push relay README: capability flow and no approval authority. |
| [R8] | `ControlPushCapability.swift`: build configuration, registration cache, and error handling. |
| [R9] | `GatewayAPI.swift`: origin proof, pairing, push registration, and Watch proxy calls. |
| [R10] | `LifecycleCoordinator.swift`: installation reconciliation and persisted stopped intent. |
| [R11] | Management `Models.swift`: installation, notification, and desired-state models. |
| [R12] | `TailscaleConfiguration.swift`: readiness and Serve inspection abstractions. |
| [E1] | Tailscale Serve documentation: private routing, HTTPS, and access-control requirements. |
| [E2] | Tailscale VPN On Demand documentation: connection rules and hostname matching. |

[R1]: https://github.com/chr33s/shell/commit/df8d16871cb8605553b45f78df286cbc9d0cb051
[R2]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/README.md
[R3]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/spec.iphone-gateway.md
[R4]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/cmd/README.md
[R5]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/cmd/Sources/shell-control/Commands/SetupCommand.swift
[R6]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/cmd/Sources/shell-control/Commands/LifecycleCommands.swift
[R7]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/services/push-relay/README.md
[R8]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/shell/Features/Control/ControlPushCapability.swift
[R9]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/Packages/ShellControlCore/Sources/Client/GatewayAPI.swift
[R10]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/cmd/Sources/ShellControlManagement/LifecycleCoordinator.swift
[R11]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/cmd/Sources/ShellControlManagement/Models.swift
[R12]: https://github.com/chr33s/shell/blob/df8d16871cb8605553b45f78df286cbc9d0cb051/cmd/Sources/ShellControlManagement/TailscaleConfiguration.swift
[E1]: https://tailscale.com/docs/features/tailscale-serve
[E2]: https://tailscale.com/docs/features/client/ios-vpn-on-demand
