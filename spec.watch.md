# Shell Watch and Shell Control v1

**Status:** Proposed implementation specification; no repository changes made.  
**Repository baseline:** `chr33s/shell`, `main` at `6185571cb7145e99f4eaaf38b3bdbb22a2659f6b`, inspected 7 September 2026.  
**Scope:** An independent native watchOS companion app for notifications, explicit approvals/rejections, job status, and capability-gated cancellation.  
**Protocol name:** `shell-control/1`. This is a proposed application protocol, not SSH, tmux control mode, or an existing Shell protocol.

Capitalized MUST, MUST NOT, SHOULD, and MAY express requirements of this proposed specification. Timing, size, and retention values are proposed v1 defaults, not Apple platform guarantees.

## 1. Product decision

Build **Shell Watch** as a native SwiftUI watchOS application that can run without the Shell iPhone app installed. Its critical path is Watch → HTTPS control service → originating host. WatchConnectivity is optional setup/cache/handoff assistance, never a required control transport. Independent watchOS apps must obtain their own data and support independent setup; Apple explicitly says WatchConnectivity cannot be their main data source.[A1]

The Watch is a review and decision client, not a terminal emulator. V1 provides a pending-approval inbox, informational notifications, request details, Approve once, Reject, recent outcomes, host connectivity, and optional cooperative job cancellation. No unrestricted terminal input, SSH client, stored SSH identities, “always allow,” bulk approvals, automatic approvals, or remote host-key trust acceptance.

Use watchOS 11 as the proposed minimum deployment target, without requiring newer APIs. Keep the existing iOS minimum of 18.0. The minimum is a product choice; physical-device validation remains required. The checked-in base configuration currently includes iOS/visionOS platforms, an iOS bridging header, Ghostty linker settings, and the Shell bundle identity, so a Watch target MUST NOT inherit it wholesale.[R2]

## 2. Repository boundary

The existing README deliberately restricts Shell to terminal, SSH, tmux, and configuration sync, and excludes a push subsystem. Amend that product boundary explicitly to allow an **optional control companion**; do not quietly restore the upstream AI/push feature set.[R1]

The current integration points are:

| Existing location | Reuse or change |
|---|---|
| `shell/Core/Ghostty/GhosttyApp.swift` | Preserve desktop-notification, bell, and command-finished callbacks. |
| `shell/UI/Terminal/TerminalView.swift` | Its ignored OSC 9/777 notification callback may feed informational alerts only. It MUST NOT mint approval authority. |
| `shell/App/AppDelegate.swift` | Add early notification category/response initialization without disrupting protected-data handling or CloudKit notification handling. |
| `shell/Entitlements/Shell.entitlements` | Configure push signing and verify built entitlements; preserve existing SSH/CloudKit boundaries. |
| `shell.xcodeproj` | Add the Watch target and new tests. The inspected project has a single app target. |

These source observations are from the baseline above.[R3][R4][R5][R6][R7] No existing UUID representing a view, surface pointer, tab selection, tmux pane number, or terminal title becomes an authorization identifier.

## 3. Components and topology

```text
Program / agent permission hook
             ↕ local authenticated IPC
        shell-controld                      Always-on host
             ↕ outbound HTTPS
       Shell Control service                Durable broker
          ↙             ↘
       HTTPS          APNs alert             Separate channels
          ↘             ↙
           Shell Watch                       Native client
                ↕ optional WatchConnectivity
          Shell iPhone                       Setup / larger review / handoff
```

**Shell Watch** owns its credentials, APNs registration, direct HTTPS client, request cache, review UI, and signed control commands. Apple supports directly registering a watchOS app for APNs and obtaining a distinct Watch device token.[A2]

**Shell Control service** owns enrollment, authorization policy, immutable request documents, mutable resolution/dispatch records, an ordered change log, idempotency records, audit data, and an APNs outbox. Use transactional durable storage. For v1, a single logical writer backed by PostgreSQL is a reasonable implementation choice; preserve per-request/per-job serialization if scaled horizontally.

**shell-controld** runs on the actual execution host as a per-user service on macOS or Linux. It authenticates local adapters, registers jobs, persists pending requests, long-polls the broker, validates decisions against the still-blocked operation, consumes authorization, and returns a response through the program's native permission mechanism.

**Adapters** implement a tool's documented, blocking pre-execution hook or an explicit command wrapper. A tool without a safe request/response hook gets notifications and a link to review elsewhere, not a synthetic approval implementation.

The broker must be reachable over authenticated HTTPS from the Watch and the origins. Origins need outbound connectivity only; do not expose SSH or an unauthenticated local control socket to the internet. The broker may be self-hosted on the same machine as an origin. Keep APNs provider credentials in the broker, never on the Watch, iPhone, or arbitrary job hosts.

An iPhone-local process cannot be treated as an always-available origin. V1's away-from-phone execution guarantee applies to an available host service, not to a suspended iOS terminal session.

## 4. Trust model and permissions

V1 trusts the broker operator and the enrolled origin. TLS protects transport, device signatures bind control commands, and durable records support audit. This is **not end-to-end encryption** and is not protection against a malicious broker that controls the account/key registry. The broker can read request details. Do not market a signed decision as proof of biometric authentication or of the safety of the command.

Every device has a separate identity and revocable grants. Every origin has a separate identity and credential. The server derives the account/tenant from authenticated credentials, never from a caller-supplied account ID. Enforce object-level authorization for every fetch, mutation, change-stream page, attachment, receipt, and push registration.

Watch grants are scoped by origin and action: `requests.read`, `approvals.decide`, `notifications.read`, `notifications.ack`, and optionally `jobs.cancel`. Device enrollment and changing policy require account administration, not ordinary decision credentials. Origin credentials can create/update only their own runs and requests, consume only their own authorizations, and cannot approve them.

The host's same-user/root processes are outside the v1 isolation boundary. File modes and local capabilities prevent accidental cross-process routing and access by other users; they do not turn an arbitrary malicious process under the same account into a trusted participant.

## 5. Enrollment and credentials

The Watch generates a new P-256 signing key locally. Store its private material and refresh credential in the Watch's own Keychain with `kSecAttrSynchronizable=false` and an unlocked-only, device-local policy such as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. That accessibility class restricts access to when the device is unlocked.[A8] V1 MUST NOT require an iPhone Secure Enclave key or assume Watch Secure Enclave signing support. The protocol works with a device-local software key; stronger hardware-backed storage is an optional implementation enhancement.

Independent setup uses OAuth device authorization, with a short code shown on the Watch and confirmation in an authenticated browser on any suitable device. Follow RFC 8628 polling, expiry, denial, and `slow_down` behavior.[S1] This browser does not have to be the paired iPhone, and the Shell iPhone app is not required.

Bind the enrollment to the new public key:

1. `POST /v1/enrollments` accepts a public JWK, platform, and display label; returns an expiring enrollment ID. It grants no control authority.
2. Start the device grant requesting `control.enroll:<enrollment_id>` as a Shell-specific scope. The authenticated confirmation page displays the requested origin permissions, platform, device label, and key fingerprint. This scope is a Shell extension to the standard flow, not a standard OAuth permission.
3. After authorization, `POST /v1/enrollments/{id}/complete` requires the authorized enrollment token and a signature over the server's enrollment challenge. It returns a stable device ID and device-scoped session credentials. The enrollment is one-use.
4. Register the Watch APNs token separately. A push token is a delivery address, not authentication.

Proposed defaults: enrollment lifetime 10 minutes; access tokens 10 minutes; rotating refresh tokens with a 30-day idle lifetime. Refresh and control endpoints verify revocation. The enrollment/token service rate-limits attempts and never embeds a shared client secret in an app.

An iPhone-assisted path MAY present the same enrollment flow or transfer a one-use enrollment reference. It MUST NOT copy private keys or long-lived credentials. Changing the broker/account requires re-enrollment and clearing the old cache. Account logout revokes the device session and removes local credentials. Loss of the key means a new device identity, not restoration of the old one from CloudKit.

Revocation invalidates future commands and unconsumed grants. It cannot retract an action already dispatched at an origin.

## 6. Watch experience

### Inbox

Show pending requests first, then recent notifications/outcomes. Each item shows a trusted origin label, program/job label, concise action, expiry, and last verified state. Labels supplied by a program are visually distinguishable from enrolled identity. Cached/offline data MUST visibly say when it was last refreshed. Do not show a green success state for a local tap.

### Review

Fetch the current request before enabling a decision. Display origin, job/run identity, operation, relevant targets and preconditions, and expiry. For `exec.v1`, show the exact argument vector and working directory, not just a command's friendly title. Escape control characters and bidirectional formatting controls visibly. Never silently truncate authorization-relevant arguments.

A request is Watch-approvable only when the device understands its operation schema and all required features, the effective policy permits Watch review, the content can be reviewed adequately, and the source run has a fresh presence lease. Otherwise show **Review on another device**. A digest alone is not sufficient review material.

Use an explicit confirmation for **Approve once**. Do not provide “approve all,” long-lived permission grants, or approval from a widget/complication. Reject applies to this request; cancelling a job is a different operation. A request requiring fuller review MUST be completed on an enrolled full-review client; until one exists it stays unapproved or expires.

### Notification interaction

Register `SHELL_APPROVAL_V1` on Watch and iPhone. The first action is **Review**, with `.foreground`; Approve and Reject shortcuts, if included, are also foreground actions that select an intent but still fetch/review before submission. A notification action MUST NOT directly authorize from its embedded payload.

Apple runs foreground actions on the device where selected, but background actions on the original notification target. Apple also invokes the first nondestructive notification action for supported Double Tap interactions.[A3] Therefore Review is first, and foreground routing is deliberate: a forwarded notification can launch the native Watch review flow without needing an iPhone background handler to authorize the operation.

After submission distinguish: **Sending**, **Decision recorded**, **Waiting for host**, **Host accepted**, **Not applied**, and **Outcome unknown**. A later operation-completed event can show success/failure. Dismissal is not rejection. Reading is not acknowledging. Acknowledging is not approving.

## 7. Transport and Apple lifecycle

Use `URLSession` HTTPS for Watch reads and short, foreground control requests. Use background transfers/refresh only for deferrable synchronization. V1 MUST NOT depend on an always-open Watch socket, a background polling loop, a silent push arriving, or unlimited runtime. Apple recommends URL sessions for general-purpose direct server communication, and distinguishes immediate foreground interactions from system-scheduled background transfers.[A4]

Refresh on launch, foreground activation, explicit refresh, notification open, and after a command response. While a relevant screen is visible, coalesce refreshes and poll at a bounded interval, initially no faster than every five seconds. Pause that polling when not visible. Receipt checking may reuse the same schedule.

WatchConnectivity MAY exchange an expiring enrollment reference, cache hints, and a request ID for handoff. `updateApplicationContext` is replaceable latest state, whereas queued transfers are not immediate; neither is the authoritative decision ledger.[A4] Do not queue executable approval commands through WatchConnectivity in v1.

The Watch keeps a small protected local cache. On lock/logout/account change, redact sensitive screens and snapshots. An optional WidgetKit complication is read-only, shows cached pending count and freshness, and opens the inbox. Do not promise live counts or use complications to bypass control confirmation.

## 8. Protocol conventions

All runtime resources live under `/v1`. Requests and responses use UTF-8 JSON, unless an endpoint explicitly uses OAuth form encoding. Maximum control/request document size is 64 KiB; cap individual strings and nesting depth to prevent resource exhaustion. Attachments are separately fetched, content-addressed, and never required for an operation classified as fully reviewable on Watch.

Identifiers are canonical lowercase UUID strings. Timestamps are UTC RFC 3339 strings with `Z`; the server returns `server_time`. Counters used as JSON numbers stay in the interoperable safe-integer range. The ordered log sequence is a decimal string; its cursor is opaque and scoped to the authenticated principal.

Duplicate JSON keys, invalid Unicode, unknown command/operation types, and unsupported `required_features` MUST fail closed for mutations. Additive informational fields may be ignored only when specified as non-authorizing extension data. Renaming a field or changing its authority/meaning requires a new schema/version. No silent downgrade to terminal keystrokes.

`GET /v1/capabilities` returns protocol versions, supported command types, operation schemas, required features, limits, and service identity. Discovery is not itself authorization; authenticate before using account resources.

Every mutation uses an idempotency identifier. The server first authenticates and verifies the submitting identity/signature, then looks for an existing immutable result, and only then evaluates expiry/preconditions for a new operation. Thus a legitimate retry after expiry can retrieve an already-recorded outcome without re-executing anything.

## 9. Stable identity and immutable approval specification

Use `origin_id` for the enrolled host/service installation; `job_id` for the logical workflow; `run_id` for one execution attempt; `request_id` for one immutable permission question. A process restart creates a new run unless the adapter can prove durable continuation of the exact prior wait. A transport reconnect alone does not create a new run.

An approval contains an immutable `spec` and a mutable server projection. The projection includes `state_version`, `policy_version`, resolution, dispatch, and source presence. The signed decision commits to the exact spec digest and observed projection versions.

Illustrative `spec` (IDs and digest values are examples):

```json
{
  "v": 1,
  "type": "approval.request",
  "request_id": "10000000-0000-4000-8000-000000000001",
  "origin_id": "20000000-0000-4000-8000-000000000001",
  "job_id": "30000000-0000-4000-8000-000000000001",
  "run_id": "40000000-0000-4000-8000-000000000001",
  "created_at": "2026-09-07T09:00:00Z",
  "expires_at": "2026-09-07T09:05:00Z",
  "summary": "Push feature branch",
  "operation": {
    "schema": "exec.v1",
    "argv": ["/usr/bin/git", "push", "origin", "feature/watch-controls"],
    "cwd": "/srv/work/shell",
    "context_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "minimum_review": "watch",
  "allowed_decisions": ["approve", "reject"],
  "required_features": ["exec.v1", "consume.v1"]
}
```

Compute `request_hash = "sha256:" + lowercase_hex(SHA256(JCS(spec)))`. JCS is RFC 8785, not an ad hoc sorted-key encoder. Preserve signed strings exactly; reject duplicate names and invalid Unicode.[S2] The origin and Watch MUST independently recompute this digest from the full spec; neither may substitute an advertised hash for that computation.

`exec.v1` requires a nonempty argument array, absolute executable path, absolute working directory, and adapter-produced context commitment. The adapter defines and records the context material, including relevant executable identity, effective user, declared environment, and operation-specific preconditions such as a Git object ID. Secret values do not go in the notification or review text. If the visible information is inadequate to understand the operation, require fuller review.

The origin MUST recheck its context before dispatch. A hash binds what was requested; it does not prove that a command is safe, sandbox its effects, or make mutable external systems deterministic. Other tool-operation schemas require negotiated, reviewed adapters/renderers; unknown schemas are not approvable on Watch.

Changing arguments, targets, policy-sensitive context, review requirement, or expiry requires cancellation and a new request ID. Never update a request behind an already-visible approval button. The service may tighten effective policy independently, but doing so changes `policy_version` and invalidates outstanding review challenges.

## 10. Runtime endpoints

Every endpoint enforces authenticated account/object scope. Enrollment/discovery exceptions are explicitly described above. Origin endpoints use a separately provisioned, high-entropy per-origin credential over HTTPS; store only its verifier server-side, rotate/revoke it, and never distribute it to watchOS clients.

| Endpoint | Caller and contract |
|---|---|
| `GET /v1/capabilities` | Version/schema/limit discovery. |
| `PUT /v1/devices/me/push` | Device registers token, platform, environment, and allowed APNs topic. Server validates topic against its configured app IDs. |
| `GET /v1/snapshot` | Initial paginated projection and a consistent high-water cursor. |
| `GET /v1/changes?cursor=C&limit=100&wait=0` | Ordered authorized deltas. Origins may use `wait=25` long polling. |
| `GET /v1/approvals/{request_id}` | Full immutable spec, digest, current versions, resolution/dispatch, source status. |
| `POST /v1/review-challenges` | Device requests a one-use challenge for an exact target/action/hash/version. |
| `POST /v1/commands` | Device submits a signed mutation with `Idempotency-Key` equal to `command_id`. |
| `GET /v1/commands/{command_id}` | Submitting device retrieves recorded result/current delivery state. |
| `PUT /v1/origins/me/runs/{run_id}` | Origin registers a run, logical job, adapter, and supported capabilities. |
| `POST /v1/origins/me/heartbeat` | Origin refreshes presence for its active runs/waiters. |
| `POST /v1/notifications` | Origin creates an informational event, idempotent by event ID and body hash. |
| `POST /v1/approvals` | Origin creates immutable spec; same request ID/hash returns existing record, different hash conflicts. |
| `POST /v1/approvals/{id}/withdraw` | Origin withdraws a pending request or revokes unconsumed dispatch. Body includes mutation ID, run ID, and hash. |
| `POST /v1/approvals/{id}/consume` | Origin claims one recorded approval for the exact still-waiting operation. |
| `POST /v1/receipts` | Origin reports permission response/cancellation application or a known operation outcome. |

`PUT` updates use exact replacement semantics and revisions where conflicting updates matter. Origin POST mutations include a `mutation_id` or explicitly documented resource ID as their idempotency key. Heartbeats are replaceable presence observations, not authorizations.

## 11. Review challenge and signed command

After fetching and rendering a request, the device requests a challenge containing the target request ID/hash, expected state version, desired action, and its device identity. The broker returns a cryptographically random 256-bit `challenge_id`, bound to that device, target, action, state/policy versions, and expiry. Challenge TTL is at most 60 seconds and never exceeds the approval deadline. The broker must return a fresh snapshot or reject stale preconditions; the app must never silently accept a different request after confirmation.

The device confirms the displayed request and signs this payload:

```json
{
  "v": 1,
  "type": "approval.decide",
  "command_id": "50000000-0000-4000-8000-000000000001",
  "device_id": "60000000-0000-4000-8000-000000000001",
  "aud": "shell-control:70000000-0000-4000-8000-000000000001",
  "request_id": "10000000-0000-4000-8000-000000000001",
  "request_hash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "expected_state_version": 1,
  "policy_version": 3,
  "decision": "approve",
  "challenge_id": "server-issued-256-bit-base64url-value",
  "issued_at": "2026-09-07T09:00:20Z",
  "not_after": "2026-09-07T09:01:00Z"
}
```

The hash in this example is a placeholder, not a computed digest of the example request.

Use JWS Compact Serialization, with `alg=ES256`, `kid=<device_id>`, and `typ=shell-control+jws` in the protected header. Payload bytes are JCS-encoded JSON. ES256's JWS signature is the 64-byte `R || S` representation, not DER. Only the explicitly allowed algorithm is accepted; reject `none`, untrusted key URLs, and unknown critical headers.[S3][S4]

Transmit:

```http
POST /v1/commands
Authorization: Bearer <device-access-token>
Idempotency-Key: 50000000-0000-4000-8000-000000000001
Content-Type: application/json

{"signed_command":"<protected>.<payload>.<signature>"}
```

The signed payload is authoritative. Do not accept a second unsigned copy of the decision fields. The broker verifies key registration, token/device binding, audience, command type, challenge, authorization, request hash, expected versions, deadline, and allowed decision. Approve additionally requires fresh source presence and applicable Watch-review policy.

A transaction then records the decision, consumes the challenge, stores the idempotency result, changes the request version, and appends an event/outbox record. The unique idempotency scope is `(account, device_id, command_id)`, with a canonical payload hash. Reusing an ID for a different payload is an error. Signature byte differences do not create distinct logical commands.

The initial response is `201 Created` with `recorded=true`, a `decision_id`, `request_id`, `state_version`, `resolution`, `dispatch`, and `server_time`. An identical retry returns `200` with the original recorded result and separately labelled current projection. Never return a success response before durable commit. A successful decision response does not mean the originating program has resumed.

## 12. Resolution, dispatch, and consumption

Maintain separate states:

```text
resolution:
  pending → approved | rejected | cancelled | expired
  A non-pending resolution is immutable.

dispatch:
  none → awaiting_origin → claimed → applied
                           ↘ not_applied
                           ↘ unknown
  awaiting_origin can also become applied for a verified rejection receipt,
  or not_applied if an unconsumed approval expires/is withdrawn.
```

`approved` means the user decision was recorded. `claimed` means the host consumed its one-use authorization. `applied` means the adapter delivered the approval/rejection to the exact waiting permission gate, or a separately typed control operation was applied. It does not mean the resulting command succeeded. `unknown` means the host cannot safely determine whether dispatch happened. Operation start/completion are separate typed events. Timeout after a claim without a reliable receipt produces `unknown`, not `not_applied`. An `unknown` outcome may later be reconciled to `applied` or `not_applied` only with positive adapter evidence, recorded as a new audit event; it never returns to pending.

**Consume protocol:** before letting work proceed, the origin validates the waiting run, request hash, and actual context locally, then posts `consume_id`, `decision_id`, `request_hash`, and `run_id` to the consume endpoint. The broker serializes this against request withdrawal, device revocation, expiry, and job cancellation. Only one consume ID may claim an approved request.

A permit response binds `consume_id`, `decision_id`, `origin_id`, `run_id`, `request_hash`, `apply_before`, and the original device decision JWS. `apply_before` is no later than the request deadline and initially no more than ten seconds after consumption. The host uses a conservative deadline calculation and fails closed when time validity is uncertain.

The origin durably records its dispatch intent before answering the native permission gate. It must recheck local cancellation/context before applying. Retrying the same consume ID returns the same permit and deadline; a new ID cannot obtain a second grant. A permit can never be renewed silently. Failure to claim or apply before expiry means no authorization to run.

The origin reports a receipt containing receipt ID, decision/consume IDs, request hash, run ID, result (`applied`, `not_applied`, or `unknown`), reason code, and timestamp. Rejection receipts contain no consume ID because rejection grants no execution permission. A job-cancel receipt instead binds the command ID, job/run IDs, and resulting job state. The server validates permitted state transitions and applies each receipt once. A receipt describing another run/hash is rejected.

Withdrawal after approval preserves the historic `approved` resolution but marks an unconsumed dispatch `not_applied`. If consumption already won the race, withdrawal reports `already_claimed`; cancellation becomes best effort and must not claim it prevented execution. Once an effect is dispatched, neither expiry nor revocation rolls it back.

The system guarantees atomic single decision and single claim per request. It **does not guarantee exactly-once arbitrary external side effects**. If an origin crashes between external dispatch and receipt persistence, report `unknown` and do not blindly rerun. Adapters may use the target tool's idempotency mechanism, but must declare that capability. Otherwise require explicit reconciliation/new review.

## 13. Other control messages

The mandatory control command is `approval.decide`. `notification.ack` marks one informational notification acknowledged for the user; it is not an approval and need not create a review challenge. It still uses a signed, idempotent device command with target ID and finite lifetime.

`job.cancel` is capability-gated. It uses a fresh challenge and signed payload binding `job_id`, `run_id`, expected job version, and `mode=cooperative`. The broker marks cancellation requested and invalidates pending/unconsumed approvals transactionally. The origin invokes the registered adapter's cancellation operation and reports a receipt. The Watch says **Cancellation requested** until an origin confirms. V1 does not expose arbitrary signals, kill-by-PID, terminal keystrokes, pause/resume, or job restart.

An optional `handoff.request` is a non-authorizing UI hint carrying request/job identity and expiry. It cannot force the phone to open, cannot authorize work, and is not accepted by an execution adapter. A reachable phone may show a review/open-terminal affordance; otherwise the request remains available through normal synchronization.

## 14. Informational notifications and APNs

An origin informational event contains `event_id`, `origin_id`, optional job/run IDs, `kind`, `severity`, `title`, `body`, and `occurred_at`. V1 kinds are `job.completed`, `job.failed`, and `attention`. The broker authenticates the origin and persists the event before trying APNs. Terminal OSC events observed in the iPhone client may use the same UI locally, but do not become signed host claims or permission requests.

For approval alerts, use:

```json
{
  "aps": {
    "alert": {
      "title": "Shell approval requested",
      "body": "A command needs your review."
    },
    "category": "SHELL_APPROVAL_V1",
    "thread-id": "shell-approvals",
    "sound": "default"
  },
  "v": 1,
  "event_id": "80000000-0000-4000-8000-000000000001",
  "request_id": "10000000-0000-4000-8000-000000000001"
}
```

Provider headers: `apns-push-type: alert`, `apns-priority: 10`, the actual registered target's APNs topic, `apns-expiration` no later than the request deadline, and a request-scoped collapse identifier such as `approval.<request_id>`. Keep payloads below APNs' ordinary 4 KiB limit. A collapse identifier coalesces pushes; it does not implement the protocol's deduplication or consistency.[A6]

For an independent Watch app with an iPhone companion, Apple recommends sending to both installed destinations so the system can choose the appropriate presentation.[A2] Use distinct registered device tokens/topics and matching logical event/request identity. Do not promise simultaneous presentation or a guaranteed Watch buzz. In-app deduplication and fresh server verification remain mandatory.

APNs carries IDs and minimal display metadata, never a reusable permission credential, private key, arbitrary callback URL, or command to execute. Use generic lock-screen text by default. More detailed previews require user opt-in. Plaintext full terminal transcripts are out of scope.

Treat push as a hint, not delivery of the ledger. Apple documents that undelivered pushes may be overwritten or discarded and that APNs has no ordering guarantee.[A7] Reconcile the inbox after opening any notification. Remove stale delivered notifications when a client next learns their resolution; do not depend on guaranteed remote retraction. Notification authorization, Focus, connectivity, and power can all affect presentation. No PushKit/VoIP/audio/workout workaround is permitted.

## 15. Change stream and offline semantics

The initial snapshot is a consistent, paginated view with a server high-water cursor. Pages share a snapshot token and expire together. After atomically applying the completed snapshot, consume deltas after that cursor. Changes that occurred during pagination must remain available in the log. Limit a page to 50 snapshot items or 100 change events initially; fetch full request bodies on demand.

A change event has `v`, `event_id`, decimal-string `sequence`, `type`, `resource_id`, `resource_version`, `server_time`, and a typed projection. Types include `approval.created`, `approval.resolved`, `approval.dispatch_updated`, `notification.created`, `notification.acknowledged`, `job.updated`, and `origin.presence_changed`.

Delivery is at least once. Deduplicate by event ID and ignore stale resource versions. Commit cache mutations and cursor advancement atomically. The server cursor reflects only a stream page, never an APNs payload. A scoped stream may have sequence gaps because of filtering; clients must not treat every numeric gap as data loss.

If a cursor is expired, return `410 cursor_expired` and require a fresh snapshot. Snapshot tokens and cursors are authenticated and bound to account/permission scope. A permissions change may require a reset so stale unauthorized objects are removed. Persist unresolved local command IDs separately; a snapshot refresh cannot erase an ambiguous submitted decision.

**Offline:** cached viewing is allowed; new approvals and job controls are disabled. Do not queue fresh approvals for eventual delivery. On connection loss after submitting, persist the exact command ID/JWS and show outcome unknown. Query command status on reconnection. The identical command may be retried while its challenge/lifetime remains valid; do not generate a fresh signature/challenge automatically. After expiry, retrieve status without creating a new decision. A cancellation of the local HTTP task is not cancellation of the server command.

Defaults: origin heartbeat every 15 seconds; presence becomes stale after 45 seconds. Approval expiry defaults to five minutes, capped at 30 minutes. Reject can be recorded while the origin is offline if the request remains pending; Approve requires fresh presence, and consumption still verifies the actual waiter. Presence is a hint about liveness, never proof that an operation may execute.

Retain ordered deltas for at least seven days and command/receipt records for 30 days initially. Preserve compact consumed/decided request tombstones and mutation IDs for the origin enrollment lifetime to prevent reuse after detailed content is purged. Administrative data resets must rotate the service/enrollment identities and invalidate old credentials; they must not silently resurrect old request authority.

## 16. Errors and retry rules

Errors use `{"error":{"code":"...","message":"...","retryable":false},"server_time":"..."}` with an optional authorized current projection. Never leak the existence of another account's object.

| HTTP | Code | Client action |
|---|---|---|
| 400 | `invalid_payload`, `unsupported_command` | Stop; fix/schema-negotiate. |
| 401 | `invalid_token`, `device_revoked` | Refresh once if appropriate, otherwise re-enroll. No action retry with a new identity. |
| 403 | `not_authorized`, `full_review_required` | No Watch approval; show policy outcome. |
| 404 | `not_found` | Reconcile; do not infer rejection. |
| 409 | `already_resolved`, `idempotency_conflict`, `already_claimed` | Display recorded state; never create a replacement command automatically. |
| 410 | `request_expired`, `challenge_expired`, `cursor_expired` | No new action; refresh review or snapshot as applicable. |
| 412 | `stale_version`, `hash_mismatch`, `policy_changed` | Re-fetch and require fresh review. |
| 422 | `unsupported_operation` | Handoff; do not degrade to raw input. |
| 423 | `origin_unavailable` | Leave pending; do not queue approval. |
| 429 | `rate_limited` | Respect retry guidance only within the original validity window. |
| 503 | `temporarily_unavailable` | Retry reads/backoff; reconcile ambiguous mutations by the same ID. |

The broker is authoritative for new-command deadline checks. Device clock skew cannot extend authorization. A duplicate already-recorded command returns its original result after expiry, subject to current authentication/authorization.

## 17. Host IPC and adapter contract

Use a per-user Unix-domain socket under a private state directory; directory mode 0700 and socket mode 0600. Verify peer identity where supported and issue per-run unguessable local capabilities. Frame IPC as a four-byte unsigned big-endian byte count followed by one UTF-8 JSON document, maximum 64 KiB. This avoids relying on newline parsing of terminal data. Do not reuse the PTY as the control channel.

Mandatory messages are `hello`, `notify`, `approval.request`, `approval.wait`, `approval.withdraw`, and `receipt`. `hello` negotiates protocol, adapter schemas, and capabilities and obtains the local run binding. `approval.wait` names the exact persisted request and returns its resolution/permit or terminal failure. `receipt` reports actual adapter application. IPC requests carry a message ID and the local run capability; retransmission uses the same ID and body hash.

A CLI surface may be:

```sh
shell-control notify --job "$JOB_ID" --title "Build finished"
shell-control request --spec-file request.json --wait --output json
```

CLI stdout is machine-readable JSON only; diagnostics go to stderr. A proposed exit convention is 0 for a valid consumed approval ready for the calling adapter, 10 rejected, 11 expired, 12 cancelled, and 13 unavailable/unknown. The adapter must also validate the structured result; nonzero/error never authorizes. The caller must report application by receipt. A convenience wrapper that executes commands must own the full dispatch journal and precondition check, not interpret a generic exit code as permanent permission.

The daemon persists the immutable question before publishing. Closing an SSH terminal does not cancel an origin-side waiter merely because UI detached. Ending the actual job does withdraw the waiter. On daemon or adapter restart, reconcile journal, broker state, and live run identity. When safe continuation cannot be proven, withdraw/not-apply and require a new request. Never send an answer to whatever happens to occupy a reused PID or tmux pane.

## 18. Implementation layout

All paths below are proposed additions except explicitly existing files:

```text
Packages/ShellControlCore/
  Sources/Protocol/              DTOs, strict validation, versions, hashing
  Sources/Client/                HTTPS API, reconciliation, idempotency
  Sources/Security/              JWS and device-credential interfaces
  Tests/                        Canonicalization/signature/state fixtures

ShellWatch/
  App/                          SwiftUI app and lifecycle/notification delegate
  Features/Inbox/
  Features/ApprovalReview/
  Features/Activity/
  Features/Enrollment/
  Services/                     API orchestration, protected cache, Keychain
  Notifications/                Categories and optional long-look scene
  Entitlements/

shell/Features/Control/          Optional phone setup, larger review, handoff
Configuration/Watch.xcconfig     Watch-specific build/signing settings
services/shell-control/         Broker, durable store, APNs worker
cmd/shell-controld/             Host daemon and local IPC
cmd/shell-control/              CLI
adapters/                      External-tool hook integrations
protocol/                      Published schemas and interoperability fixtures
```

`ShellControlCore` is portable Swift code with no UIKit, Ghostty, Citadel, terminal surface, SSH credential, or CloudKit dependency. Use `Sendable` DTOs, isolated networking/state actors, and main-actor UI. Do not link the terminal renderer into Watch to reuse a few models.

Set a distinct Watch bundle identifier, for example `dev.chr33s.shell.watchkitapp`, and enable independent execution. Configure Watch and iPhone APNs registration independently, including development/production topics and signing. Keep Watch credentials in its own access group. If a widget is later added, use an app group only for sanitized read-only cache, not control signing keys.

Use UserNotifications categories and a native review screen first. A custom long-look scene is optional; Apple supports dynamic and interactive notification interfaces, but they are not necessary for the control protocol.[A5] Preserve a static generic fallback that works without a network fetch.

CI must build the existing iOS target and the Watch target separately, test the shared protocol package, and run broker/daemon integration tests. New shared configuration should include only genuinely platform-neutral settings; do not import the existing iOS bridging header, identity, or linker flags into watchOS.

## 19. Acceptance and failure tests

| Scenario | Required result |
|---|---|
| iPhone off/uninstalled; Watch has usable Wi-Fi or cellular | Enrollment, inbox fetch, review, decision, and receipt operate without iPhone software. |
| Watch has no internet | Cache shows stale status; no new control command is queued. |
| Notification forwarded from iPhone | Foreground Review executes on Watch and uses Watch identity. |
| Watch locked/restarted before unlock | No signing with unavailable credentials; no dependency on phone unlock. |
| Double Tap on notification | Opens Review; does not approve. |
| APNs lost, duplicated, delayed, or reordered | Snapshot/change reconciliation gives correct current state. |
| Two devices approve/reject together | Exactly one pending-resolution transition; loser sees recorded decision. |
| Connection lost after decision commit | Same command ID retrieves result; no second authorization. |
| Same command ID with changed body | Idempotency conflict; no mutation. |
| Changed argv/hash/context/run/policy | Reject or require a new review/request. |
| Expired request with stale actionable notification | Cannot authorize, even if UI button remains visible. |
| Device revoked after decision but before consume | Grant cannot be consumed. |
| Job cancellation races with consume | One serialized winner; never falsely claim already-dispatched work was prevented. |
| Host crashes before/after dispatch | Journal recovery; uncertain external effects reported unknown, never blindly replayed. |
| tmux pane/PID reused or terminal tab changes | No effect on request authority or response routing. |
| Unknown operation/required feature | No approval; fuller review or unsupported state. |
| Another account guesses a request ID | No data disclosure or control. |
| DB restored/reset | Old authority cannot be reactivated; credentials/service identity recovery policy enforced. |
| Broker offline | Host stays blocked/fails closed under its declared timeout policy. |

Use a real paired iPhone and Watch, plus standalone Watch network tests, with the debugger detached for lifecycle/background behavior. Apple specifically recommends device testing without the debugger for real-world transfer behavior.[A4] Simulator and notification-payload previews alone do not validate APNs routing, lock behavior, or suspension.

## 20. Delivery sequence and completion definition

Implement protocol/state machines and a fake origin first; then broker persistence/idempotency/consume; then Watch independent enrollment and inbox; then APNs/foreground review; then one real blocking adapter and receipts; then optional iPhone handoff/custom notification UI/cancellation.

V1 is complete only when a real permission-gated operation can remain blocked on a host, appear on an independently connected Watch, be approved or rejected against its exact immutable request, and produce a verified origin receipt—while duplicate, stale, cancelled, revoked, and ambiguous paths fail safely.

This specification is a design, not an implementation or physical-device test result. Its central invariant is: **a Watch decision authorizes one identified request at one identified permission gate; a notification, terminal location, local tap, or broker acknowledgement alone never proves execution.**

## References

Repository references are pinned to the inspected commit; Apple and standards references were checked on 7 September 2026. References support platform/existing-code facts; normative protocol choices above are proposed design decisions.

[R1]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/README.md
[R2]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/Configuration/Base.xcconfig
[R3]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/shell/Core/Ghostty/GhosttyApp.swift
[R4]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/shell/UI/Terminal/TerminalView.swift
[R5]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/shell/App/AppDelegate.swift
[R6]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/shell/Entitlements/Shell.entitlements
[R7]: https://github.com/chr33s/shell/blob/6185571cb7145e99f4eaaf38b3bdbb22a2659f6b/shell.xcodeproj/project.pbxproj
[A1]: https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps/
[A2]: https://developer.apple.com/documentation/watchos-apps/enabling-and-receiving-notifications
[A3]: https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos?changes=_1
[A4]: https://developer.apple.com/videos/play/wwdc2021/10003/
[A5]: https://developer.apple.com/documentation/watchos-apps/customizing-your-long-look-interface
[A6]: https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns?changes=la_3&language=objc
[A7]: https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns?changes=_7
[A8]: https://developer.apple.com/documentation/security/item-attribute-keys-and-values
[S1]: https://www.rfc-editor.org/rfc/rfc8628.html
[S2]: https://www.rfc-editor.org/rfc/rfc8785.html
[S3]: https://www.rfc-editor.org/rfc/rfc7515.html
[S4]: https://www.rfc-editor.org/rfc/rfc7518.html
