# Shell Control Protocol

**Status:** Implemented (`shell-control/1` with the `shell-watch-gateway/1` transport profile); physical-device validation (section 19.4) outstanding.  
**Scope:** Approvals, notifications, job status, and capability-gated cancellation between a macOS execution host, the Shell iPhone app, and Shell Watch.

Shell Control lets a program blocked at a permission gate on a Mac be reviewed and approved or rejected from the paired iPhone or Apple Watch, against an exact immutable request, with a verified host receipt of what was applied. The authoritative ledger lives on the Mac, reached privately over Tailscale; the Watch reaches it only through its paired iPhone. Pairing is bound to a cryptographic origin key, not a URL, so network and route changes never force re-enrollment.

`shell-control/1` is a Shell application protocol, not SSH or tmux control mode. Capitalized MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative. Timing, size, and retention values are v1 defaults, not Apple platform guarantees. Related specs: [`control-cli.md`](control-cli.md), [`control-setup.md`](control-setup.md), [`agent-relay.md`](agent-relay.md), [`mobile-connectivity.md`](mobile-connectivity.md), [`shell.md`](shell.md).

## 1. Overview

### 1.1 Topology

```text
Program / permission hook
      │ local authenticated IPC
      ▼
shell-controld ── loopback ──► Mac-local broker (authoritative ledger)
                                     │ HTTPS via Tailscale Serve
                                     ▼
                                  iPhone ── WatchConnectivity ──► Watch

Mac-local broker ── push capability ──► Push Relay (optional) ── APNs ──► iPhone ─► (system mirroring) Watch
```

The Watch never connects to the Mac, Tailscale, or a broker directly. The Push Relay is not a control broker and owns no approval authority.

**Change from the original design:** Shell Watch was originally an independent HTTPS client of a shared/public broker with its own APNs path. That topology is superseded: the paired iPhone is required for Watch reads and decisions, WatchConnectivity is the required Watch transport, and an unavailable iPhone makes Watch control unavailable. The iPhone remains a full control client.

### 1.2 Design goals

The system MUST:

1. require Tailscale on the Mac and the paired iPhone, and no public listener, Cloudflare Tunnel, Funnel, reverse proxy, or public DNS name on the Mac;
2. keep the authoritative approval ledger on the Mac;
3. bind pairing to a cryptographic origin identity, treating a Tailscale address as a route, not an identity;
4. preserve pairing across Wi-Fi, WAN, NAT, DHCP, public-IP, Tailscale route, and hostname changes while the pinned origin key is unchanged;
5. keep Watch signing material on the Watch and prevent the iPhone from forging a Watch decision;
6. prevent WatchConnectivity background queues from authorizing delayed execution;
7. preserve immutable request hashes, state/policy versions, decision idempotency, one-time consume, and receipts;
8. fail closed when the iPhone, Tailscale path, Mac authority, or current operation context is unavailable;
9. let notification delivery fail without affecting correctness, keeping the Push Relay optional;
10. keep the Watch idle when no user interaction is occurring.

### 1.3 Non-goals

V1 does not provide: Watch control while the iPhone is absent; direct Watch-to-Mac networking or Tailscale on watchOS; public access to the Mac; terminal streaming, unrestricted remote input, or SSH on the Watch; approval from a notification action without current review; queued eventual, automatic, or bulk approval; "always allow" grants; tmux pane/window/PID authority; a Shell-operated peer directory; cloud durability for approval state; operation while the Mac is offline. Tailscale's control plane remains an external networking dependency.

## 2. Components

### 2.1 `shell-controld`

Per-user host daemon on the execution Mac. It authenticates local adapter IPC, registers runs/jobs, persists and publishes immutable requests, waits for decisions, revalidates local operation context, consumes authorization, journals dispatch, returns the response through the program's native permission mechanism, and reports receipts. The `shell-control` CLI enrolls devices and manages services but does not own their lifetime: closing it MUST NOT stop a ready broker or daemon; `down` persists stopped intent; login persistence is opt-in (`service install`). See [`control-cli.md`](control-cli.md).

### 2.2 Mac-local broker

The broker (`services/shell-control/`) runs on the execution Mac and:

- listens on loopback only and is exposed to the iPhone only through Tailscale Serve, never to the Watch;
- is the authoritative, durable ledger of iPhone devices, Watch reviewers, gateway bindings, requests, decisions, consumes, receipts, changes, idempotency records, and audit data;
- never requires an Internet-reachable listener.

### 2.3 Tailscale and Tailscale Serve

Tailscale provides private reachability between iPhone and Mac. Shell relies on it for connectivity, not authorization, and MUST authenticate every request at the application layer. [Tailscale Serve][T6] terminates HTTPS inside the tailnet, with [tailnet certificates][T7], (`https://<mac>.<tailnet>.ts.net`) and proxies to the loopback broker (e.g. `http://127.0.0.1:8443`), conceptually `tailscale serve --bg localhost:8443` on HTTPS 443. The exact invocation is implementation-owned; setup MUST validate the resulting Serve state rather than assume command success.

### 2.4 Shell iPhone

The iPhone is a normal review device and full-review client, the Watch's network gateway, the owner of the Tailscale connection used by Shell, and the recipient of remote notification hints. Its own decisions use its own signing key.

### 2.5 Shell Watch

A review/signing client behind the iPhone gateway, not a terminal emulator. It owns its device ID, P-256 signing private key, protected review cache, pending ambiguous command IDs/JWSs, and review UI. It does not own a broker URL, Tailscale session, origin credential, HTTP refresh token for the Mac, or APNs provider credentials. A Watch decision remains attributable to the Watch key.

### 2.6 Push Relay (optional)

A small shared Internet service (`services/push-relay/`) delivering APNs hints to the iPhone. It MUST NOT store or decide approvals, decisions, consumes, receipts, jobs, run state, origin presence, or terminal data, and has no dependency on approval-state storage. A deployment without it is fully correct but lacks prompt remote alerts while the iOS app is suspended.

### 2.7 Adapters

Adapters implement a tool's documented, blocking pre-execution hook or an explicit command wrapper. A tool without a safe request/response hook gets notifications and a link to review elsewhere, not a synthetic approval implementation. Agent-specific adapters are specified in [`agent-relay.md`](agent-relay.md).

## 3. Trust model

### 3.1 Trusted parties

The system trusts the execution host and its local authority; an enrolled iPhone signing identity for actions attributed to that iPhone; an enrolled Watch signing identity for actions attributed to that Watch; and Tailscale for authenticated, encrypted reachability per the tailnet configuration. TLS protects transport, device signatures bind control commands, and durable records support audit. This is **not end-to-end encryption**; a signed decision is not proof of biometric authentication or of the command's safety.

The following are never authorization: Tailscale reachability, a Tailscale IP, a MagicDNS name, the current Wi-Fi network, an APNs token, a push notification, a WatchConnectivity packet, an iPhone assertion that the Watch approved, or any tmux/terminal identifier. The host's same-user/root processes are outside the v1 isolation boundary; file modes and local capabilities prevent accidental cross-process routing and other-user access only.

### 3.2 Identities, grants, and scope

Every device and every origin has a separate identity and revocable credential. The broker derives account/gateway scope from authenticated credentials, never from caller-supplied IDs, and enforces object-level authorization for every fetch, mutation, change-stream page, attachment, receipt, and push registration. Responses MUST NOT leak the existence of another account's object.

Device grants are scoped by origin and action: `requests.read`, `approvals.decide`, `notifications.read`, `notifications.ack`, optionally `jobs.cancel`. Watch reviewer grants are listed in section 5.3. Enrollment and policy changes require local administration, not decision credentials. Origin credentials can create/update only their own runs and requests, consume only their own authorizations, and cannot approve them.

### 3.3 Tailscale authentication versus Shell enrollment

Tailscale authentication establishes tailnet connectivity; Shell enrollment establishes application identity and grants. A Tailscale login refresh, VPN restart, Wi-Fi change, DERP fallback, node address change, or MagicDNS resolution change MUST NOT clear Shell credentials. Shell re-enrollment is required only when the origin key is replaced, a device identity is intentionally reset, a device is revoked, a Watch gateway binding is intentionally changed, or local authority data is administratively reset.

### 3.4 Privacy

Approval contents stay on the Mac/iPhone/Watch path; a Push Relay sees only notification-routing material; there is no shared approval database or central service that sees command contents. Tailscale observes network metadata per its architecture. No formal zero-knowledge property is claimed.

## 4. Identity and routing

### 4.1 Prerequisites

- **Mac:** Tailscale installed and authenticated on the iPhone's tailnet; MagicDNS or another stable tailnet route; Tailscale Serve available; host binaries installed. Setup MUST detect and report absent prerequisites.
- **iPhone:** [Tailscale][T1] installed with a usable VPN configuration reaching the Mac endpoint; Shell installed; WatchConnectivity for Watch control. [VPN On Demand][T2] SHOULD be recommended so `*.ts.net` requests bring up or keep the tunnel.
- **Watch:** paired to the gateway iPhone with Shell Watch installed. It does not join the tailnet.

### 4.2 Origin identity

On first setup the Mac generates or loads a long-lived origin signing key: `origin_id` (stable UUID), `origin_public_key` (P-256), `origin_fingerprint` (SHA-256 of the canonical public key). The private key is stored only on the Mac. **The origin key is identity; the Tailscale URL is routing.**

### 4.3 Routes and pairing rule

A route (`{kind: "tailscale_https", url, observed_at}`) is not an authorization identifier. The iPhone pins `origin_id` and `origin_public_key` and MAY cache several routes. Changing a route MUST NOT invalidate the origin identity, iPhone enrollment, Watch reviewer enrollment, device keys, grants, or idempotency records. Ordinary network changes SHOULD need no route update: Tailscale node IPs are [stable][T3] while the node stays registered and [MagicDNS][T4] names are stable across movement. Node removal/reinstall or a deliberate [rename][T5] may need a route refresh, never a new trust relationship.

### 4.4 Signed route updates

A route update MUST be authenticated by the pinned origin key:

```json
{
  "v": 1,
  "type": "origin.route",
  "origin_id": "20000000-0000-4000-8000-000000000001",
  "route": { "kind": "tailscale_https", "url": "https://new-name.example.ts.net" },
  "issued_at": "2026-09-19T02:00:00Z",
  "nonce": "..."
}
```

The Mac signs the canonical object. The iPhone accepts it only if `origin_id` matches the pinned origin, the signature verifies under the pinned key, scheme/host satisfy the Tailscale route policy, and the new endpoint proves possession of the same origin key. A route update is not re-enrollment and MUST be labelled as a route update, not a trust decision. A route-only QR (`type: "shell-control.route-update"`, with `origin_id`, `route`, `issued_at`, `signature`) MAY update routing without re-enrollment.

### 4.5 Route recovery

When the pinned route fails, the iPhone: (1) retries the last MagicDNS HTTPS route after ensuring Tailscale is active; (2) retries other previously signed routes for the same `origin_id`; (3) uses an explicitly supplied route object signed by the pinned key; (4) requires new pairing only if the origin key cannot be matched. A losing route, Tailscale outage, or origin-proof mismatch never clears credentials.

### 4.6 Endpoint exposure

The broker MUST listen only on loopback; setup MUST NOT expose it on a LAN/WAN interface. A [Tailscale Service][T8] (e.g. `svc:shell-control`) MAY replace a machine-specific MagicDNS route where the user has tag-based service hosts and tailnet administration; it is an optional advanced profile. Users SHOULD restrict tailnet access to the Shell Control HTTPS port, using [Grants][T9] on managed tailnets. Shell authentication remains mandatory regardless.

## 5. Enrollment and credentials

### 5.1 Device keys

Each device generates its own P-256 signing key locally and stores private material and refresh credentials in its own Keychain with `kSecAttrSynchronizable=false` and a device-local unlocked-only class such as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.[A8] V1 MUST NOT require Secure Enclave signing; hardware-backed storage is optional. Private keys and long-lived credentials MUST NOT be copied between devices. Key loss means a new device identity, not restoration from CloudKit. Logout revokes the device session and removes local credentials.

Defaults: pairing/enrollment lifetime 10 minutes; access tokens 10 minutes; rotating refresh tokens with 30-day idle lifetime. Refresh and control endpoints verify revocation. Pairing and device-mutation endpoints are rate-limited; no shared client secret is embedded in an app. Revocation invalidates future commands and unconsumed grants; it cannot retract an action already dispatched.

### 5.2 iPhone pairing

`shell-control setup` shows a pairing QR containing only bootstrap material:

```json
{
  "v": 1,
  "type": "shell-control.pairing",
  "origin_id": "...",
  "origin_public_jwk": { "...": "..." },
  "route": "https://mac-name.example.ts.net",
  "pairing_id": "...",
  "pairing_secret": "...",
  "expires_at": "..."
}
```

The pairing secret is random, one-use, short-lived, and not an origin credential. The iPhone scans the QR, verifies the route is a permitted Tailscale route, connects over Tailscale, obtains a server challenge, verifies the Mac's origin signature with the QR key, generates its P-256 key, and submits its public key, device label, and pairing proof (HMAC over the pairing secret plus a signature by the new key). The claim then uses the RFC 8628 device-grant machinery[S1] (polling, expiry, denial, `slow_down`): the Mac displays iPhone label, platform, key fingerprint, and requested grants, and explicit local confirmation (`shell-control confirm`) enrolls it. Direct `POST /v1/enrollments` is closed whenever the broker holds an origin identity.

The Mac stores `device_id`, `platform=ios`, public key, grants, session verifier, `paired_at`, and revocation state. The phone stores `origin_id`, `origin_public_key`, routes, `device_id`, signing key, and session credentials. Route changes do not alter these records. Only a revoked device or a spent refresh token returns the iPhone to pairing; the pinned origin survives either. Guided setup is specified in [`control-setup.md`](control-setup.md).

### 5.3 Watch reviewer enrollment

The Watch is enrolled as a reviewer behind a specific gateway iPhone:

1. The Watch generates its own P-256 key; the private key MUST NOT be copied to the iPhone.
2. WatchConnectivity sends an enrollment reference: Watch public key, fingerprint, label, and Watch-generated nonce.
3. The iPhone registers it with the Mac over its authenticated session; the Mac records a pending reviewer (`watch_device_id`, public key, `gateway_device_id`, requested grants).
4. Explicit confirmation is required; v1 SHOULD require Mac-local confirmation.

Watch grants are `requests.read-via-gateway`, `approvals.decide`, `notifications.read-via-gateway`, `notifications.ack`, and optionally `jobs.cancel`. The Mac strips any standalone read grant on confirmation. A Watch reviewer has no standalone network credential.

### 5.4 Gateway binding

A Watch is bound to one current `gateway_device_id`. Changing the gateway iPhone requires explicit re-binding: confirming a request from a new iPhone for an already-enrolled Watch key is that re-binding. Rotating the Mac's Tailscale address does not affect the binding.

## 6. Protocol conventions

### 6.1 Encoding and limits

Runtime resources live under `/v1`, using UTF-8 JSON unless an endpoint explicitly uses OAuth form encoding. Maximum control/request document size is 64 KiB; individual strings and nesting depth are capped. Attachments are fetched separately, content-addressed, and never required for an operation classified as fully reviewable on Watch.

### 6.2 Identifiers and time

Identifiers are canonical lowercase UUID strings. Timestamps are UTC RFC 3339 with `Z`; responses include `server_time`. JSON-number counters stay in the safe-integer range. The log sequence is a decimal string; its cursor is opaque and scoped to the authenticated principal.

### 6.3 Strictness

Duplicate JSON keys, invalid Unicode, unknown command/operation types, and unsupported `required_features` MUST fail closed for mutations. Additive fields may be ignored only when specified as non-authorizing extension data. Renaming a field or changing its authority/meaning requires a new schema/version. No silent downgrade to terminal keystrokes.

### 6.4 Capabilities

`GET /v1/capabilities` returns protocol versions, command types, operation schemas, required features, limits, and service identity (e.g. `notification.preference.v1`). Discovery is not authorization.

### 6.5 Idempotency

Every mutation carries an idempotency identifier. The server first authenticates and verifies the submitter/signature, then looks up an existing immutable result, and only then evaluates expiry/preconditions for a new operation, so a legitimate retry after expiry retrieves an already-recorded outcome without re-executing.

## 7. Approval requests

### 7.1 Stable identity

`origin_id` names the enrolled host installation (equal to the daemon's origin credential UUID, so specs, proofs, and relay hints name one origin); `job_id` the logical workflow; `run_id` one execution attempt; `request_id` one immutable permission question. A process restart creates a new run unless the adapter proves durable continuation of the exact prior wait; a reconnect alone does not. No view UUID, surface pointer, tab, tmux pane/window/session, PTY, PID, or terminal title is an authorization identifier.

### 7.2 Immutable spec and hash

An approval contains an immutable `spec` and a mutable projection (`state_version`, `policy_version`, resolution, dispatch, source presence). Illustrative spec:

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

`request_hash = "sha256:" + lowercase_hex(SHA256(JCS(spec)))`, where JCS is RFC 8785[S2], not an ad hoc sorted-key encoder. Signed strings are preserved exactly; duplicate names and invalid Unicode are rejected. The origin and each reviewing device MUST independently recompute the digest from the full spec, never trusting an advertised hash.

### 7.3 `exec.v1`

Requires a nonempty `argv`, absolute executable path, absolute `cwd`, and an adapter-produced context commitment covering executable identity, effective user, declared environment, and operation-specific preconditions (e.g. a Git object ID). Secrets never appear in notification or review text. Inadequate visible information requires fuller review. The origin MUST recheck context before dispatch. A hash binds what was requested; it does not prove safety, sandbox effects, or make external systems deterministic. Other schemas require negotiated, reviewed adapters/renderers; unknown schemas are not Watch-approvable.

### 7.4 Changes require a new request

Changing arguments, targets, policy-sensitive context, review requirement, or expiry requires cancellation and a new `request_id`; a request MUST NOT be updated behind a visible approval button. The service may tighten policy independently, which bumps `policy_version` and invalidates outstanding challenges.

## 8. Endpoints

### 8.1 Device and origin endpoints

Origin endpoints use a high-entropy per-origin credential (verifier-only server-side, rotatable, never given to watchOS). `PUT` uses exact replacement with revisions where conflicts matter; origin POSTs carry a `mutation_id` or documented resource ID as idempotency key.

| Endpoint | Caller and contract |
|---|---|
| `GET /v1/capabilities` | Version/schema/limit discovery. |
| `PUT /v1/devices/me/push` | iPhone registers direct-APNs token, platform, environment, topic (validated against configured app IDs). |
| `PUT /v1/devices/me/push-capability` | iPhone publishes its relay push capability (section 12.2). |
| `GET`/`PUT /v1/devices/me/notification-preference` | Per-device delivery preference (section 12.5). |
| `GET /v1/snapshot` | Paginated projection with consistent high-water cursor. |
| `GET /v1/changes?cursor=C&limit=100&wait=0` | Ordered authorized deltas; origins may long-poll with `wait=25`. |
| `GET /v1/approvals/{request_id}` | Immutable spec, digest, versions, resolution/dispatch, source status. |
| `POST /v1/review-challenges` | One-use challenge for an exact target/action/hash/version. |
| `POST /v1/commands` | Signed device mutation; `Idempotency-Key` = `command_id`. |
| `GET /v1/commands/{command_id}` | Submitter retrieves recorded result/current delivery state. |
| `PUT /v1/origins/me/runs/{run_id}` | Origin registers run, job, adapter, capabilities. |
| `POST /v1/origins/me/heartbeat` | Replaceable presence observation, not authorization. |
| `POST /v1/notifications` | Informational event, idempotent by event ID and body hash. |
| `POST /v1/approvals` | Create immutable spec; same ID/hash returns existing, different hash conflicts. |
| `POST /v1/approvals/{id}/withdraw` | Withdraw pending or revoke unconsumed dispatch (mutation ID, run ID, hash). |
| `POST /v1/approvals/{id}/consume` | Claim one recorded approval for the exact waiting operation. |
| `POST /v1/receipts` | Report application/cancellation or known outcome. |

### 8.2 Gateway endpoints

Proxied Watch operations (route shape is implementation detail; the authorization semantics of section 10.4 are normative):

```text
POST /v1/gateways/me/watch-reviewers
GET  /v1/gateways/me/watch-reviewers/{watch_device_id}/approvals/{request_id}
POST /v1/gateways/me/watch-reviewers/{watch_device_id}/review-challenges
POST /v1/gateways/me/watch-reviewers/{watch_device_id}/commands
GET  /v1/gateways/me/watch-reviewers/{watch_device_id}/commands/{command_id}
```

The broker MUST derive the gateway identity from the authenticated iPhone credential, never a caller-supplied gateway ID.

## 9. Decisions, dispatch, and consumption

### 9.1 Review challenge

After fetching and rendering a request, the device requests a challenge naming target request ID/hash, expected state version, desired action, and its identity. The broker returns a random 256-bit `challenge_id` bound to device, target, action, state/policy versions, and expiry. TTL is at most 60 seconds and never exceeds the approval deadline. The broker returns a fresh snapshot or rejects stale preconditions; the app MUST NOT silently accept a different request after confirmation.

### 9.2 Signed command

```json
{
  "v": 1,
  "type": "approval.decide",
  "command_id": "50000000-0000-4000-8000-000000000001",
  "device_id": "60000000-0000-4000-8000-000000000001",
  "aud": "shell-control:70000000-0000-4000-8000-000000000001",
  "request_id": "10000000-0000-4000-8000-000000000001",
  "request_hash": "sha256:<64 hex>",
  "expected_state_version": 1,
  "policy_version": 3,
  "decision": "approve",
  "challenge_id": "server-issued-256-bit-base64url-value",
  "issued_at": "2026-09-07T09:00:20Z",
  "not_after": "2026-09-07T09:01:00Z"
}
```

JWS Compact Serialization[S3][S4]: protected header `alg=ES256`, `kid=<device_id>`, `typ=shell-control+jws`; payload is JCS-encoded JSON; the signature is 64-byte `R || S`, not DER. Only the allowed algorithm is accepted; `none`, untrusted key URLs, and unknown critical headers are rejected. Submitted as `POST /v1/commands` with `Authorization: Bearer <device-access-token>`, `Idempotency-Key: <command_id>`, body `{"signed_command":"<protected>.<payload>.<signature>"}`. The signed payload is authoritative; no unsigned copy of decision fields is accepted.

The broker verifies key registration, token/device binding, audience, command type, challenge, authorization, request hash, expected versions, deadline, and allowed decision. Approve additionally requires fresh source presence and applicable Watch-review policy.

### 9.3 Commit and response

One transaction records the decision, consumes the challenge, stores the idempotency result, bumps the request version, and appends an event/outbox record. Idempotency scope is `(account, device_id, command_id)` with a canonical payload hash; reusing an ID for a different payload is an error; signature byte differences do not make distinct commands. The first response is `201` with `recorded=true`, `decision_id`, `request_id`, `state_version`, `resolution`, `dispatch`, `server_time`; an identical retry returns `200` with the original result and a separately labelled current projection. Success MUST NOT be returned before durable commit, and does not mean the program has resumed.

### 9.4 Resolution and dispatch states

```text
resolution: pending → approved | rejected | cancelled | expired   (non-pending is immutable)

dispatch:   none → awaiting_origin → claimed → applied
                                     ↘ not_applied
                                     ↘ unknown
            awaiting_origin → applied      (verified rejection receipt)
            awaiting_origin → not_applied  (unconsumed approval expired/withdrawn)
```

`approved` = decision recorded; `claimed` = host consumed its one-use authorization; `applied` = the adapter delivered approval/rejection to the exact waiting gate (not that the command succeeded); `unknown` = host cannot determine whether dispatch happened. Timeout after a claim without a reliable receipt is `unknown`, not `not_applied`. `unknown` may later reconcile to `applied`/`not_applied` only on positive adapter evidence, recorded as a new audit event; it never returns to pending. Operation start/completion are separate typed events.

### 9.5 Consume and permit

Before letting work proceed, the origin validates the waiting run, request hash, and actual context locally, then posts `consume_id`, `decision_id`, `request_hash`, `run_id`. The broker serializes consume against withdrawal, revocation, expiry, and job cancellation; only one consume ID may claim an approved request. The permit binds `consume_id`, `decision_id`, `origin_id`, `run_id`, `request_hash`, `apply_before`, and the original device JWS. `apply_before` is at most the request deadline and initially at most 10 seconds after consumption; the host uses a conservative deadline and fails closed when time validity is uncertain.

The origin durably records dispatch intent before answering the permission gate and rechecks local cancellation/context before applying. The same consume ID returns the same permit; a new ID cannot obtain a second grant; a permit is never silently renewed. Failure to claim or apply before expiry means no authorization to run.

### 9.6 Receipts, withdrawal, and side effects

A receipt carries receipt ID, decision/consume IDs, request hash, run ID, result (`applied`, `not_applied`, `unknown`), reason code, and timestamp. Rejection receipts have no consume ID. A job-cancel receipt binds command ID, job/run IDs, and resulting job state. The server validates transitions, applies each receipt once, and rejects receipts naming another run/hash.

Withdrawal after approval keeps the historic `approved` resolution but marks an unconsumed dispatch `not_applied`. If consume already won, withdrawal reports `already_claimed` and cancellation is best effort, never claiming it prevented execution. Expiry and revocation never roll back a dispatched effect.

The system guarantees one decision and one claim per request; it does **not** guarantee exactly-once external side effects. If an origin crashes between dispatch and receipt persistence, it reports `unknown` and MUST NOT blindly rerun. Adapters may use the target tool's idempotency mechanism only if they declare that capability; otherwise explicit reconciliation/new review is required.

### 9.7 Other control commands

- `notification.ack`: marks one informational notification acknowledged; not an approval, needs no challenge, but is still a signed, idempotent device command with target ID and finite lifetime.
- `job.cancel` (capability-gated): fresh challenge and signed payload binding `job_id`, `run_id`, expected job version, `mode=cooperative`. The broker marks cancellation requested and transactionally invalidates pending/unconsumed approvals; the origin invokes the adapter's cancel operation and reports a receipt. Clients show **Cancellation requested** until confirmed. V1 exposes no arbitrary signals, kill-by-PID, keystrokes, pause/resume, or restart.
- `handoff.request` (optional): non-authorizing UI hint with request/job identity and expiry; cannot force the phone open or authorize work, and is never accepted by an adapter.

## 10. Watch gateway (`shell-watch-gateway/1`)

WatchConnectivity is transport only, never the authoritative ledger.

### 10.1 Channels

**Immediate:** `sendMessageData`, requiring current iPhone reachability, for fetching the current approval, fetching a review challenge, submitting a signed decision, querying an ambiguous command, cancelling a job, and fetching the current outcome. The Watch MUST check `isReachable`[A9] before enabling a decision.

**Background:** `updateApplicationContext`, `transferUserInfo`, and file transfer MAY carry a sanitized inbox projection, pending count, request IDs, freshness timestamp, refresh hints, informational events, and route/display metadata. They MUST NOT carry an executable approval command to be applied later.

### 10.2 No queued authorization

Queuing a Watch decision via `transferUserInfo` (or any background channel) for later delivery and execution is forbidden. An approval is interactive and requires a live gateway round trip. If the iPhone is unreachable, the Watch MUST show a gateway-unavailable state and disable Approve/Reject. Cached request material MAY be shown, marked stale, but MUST NOT enable a decision.

### 10.3 Framing

Messages use a strict JSON envelope, maximum 64 KiB:

```json
{ "v": 1, "protocol": "shell-watch-gateway/1", "message_id": "uuid",
  "type": "approval.fetch", "watch_device_id": "uuid", "request_id": "uuid" }
```

```json
{ "v": 1, "message_id": "uuid", "ok": true, "server_time": "...", "body": { } }
```

The iPhone MUST reject unknown message types, duplicate JSON keys, oversized messages, invalid identifiers, messages naming a Watch not bound to this gateway, and unsupported versions. Message IDs give gateway-level idempotency for retries.

### 10.4 Gateway authorization

The iPhone MUST NOT assert that a Watch made a decision.

**Reads:** the iPhone authenticates with its own gateway session; the Mac authorizes when the gateway device and named Watch are active, the Watch is bound to this gateway, the Watch holds the relevant grant, and the resource belongs to an origin accessible to the gateway.

**Watch decisions:** the Watch receives through the iPhone the immutable record, request hash, state and policy versions, and a current challenge with expiry; signs the standard decision JWS (section 9.2) with its own key; the iPhone forwards it unchanged. The Mac verifies, in order: gateway session; Watch-to-gateway binding; Watch revocation/grants; Watch JWS; command ID/idempotency; challenge; request hash; state version; policy version; request expiry; still-blocked run/presence; allowed decision. The iPhone cannot substitute its own approval for the Watch signature.

**iPhone decisions** use the standard device flow with the iPhone's own key.

### 10.5 Watch approval flow

1. **Request:** an adapter blocks; `shell-controld` publishes; the broker durably records the immutable request before reporting publication.
2. **Notify:** with a Push Relay configured the Mac emits a non-authoritative hint to the iPhone; otherwise the request is discovered on next refresh.
3. **Open:** the Watch fetches the current approval via `sendMessageData` → iPhone → HTTPS over Tailscale → broker.
4. **Review:** the Watch requests a fresh challenge through the same live path and recomputes `request_hash` from the full spec.
5. **Decide:** the Watch creates a stable `command_id`, signs, journals the JWS locally as pending, and sends it immediately; the iPhone forwards it.
6. **Commit:** the broker atomically records exactly one pending-to-resolved transition and the immutable command result.
7. **Reply:** Mac → iPhone → Watch; only then does the Watch show **Decision recorded**.
8. **Consume:** `shell-controld` verifies request/run/context, claims a one-time permit, journals dispatch intent, returns authorization to the adapter, which reports a receipt.

### 10.6 Ambiguous results

If connectivity fails after sending, the Watch MUST NOT generate a replacement decision. It persists `command_id`, target `request_id`, the exact JWS, and submission time; when reachable it queries `GET /v1/commands/<command_id>` through the iPhone. With no result and a still-valid challenge, the identical command MAY be retried. A changed command under the same ID is an idempotency conflict. Expiry never erases a committed result.

## 11. Client experience and lifecycle

### 11.1 Inbox

Pending requests first, then recent notifications/outcomes. Each item shows a trusted origin label, program/job label, concise action, expiry, and last verified state. Program-supplied labels are visually distinct from enrolled identity. Cached/offline data MUST show when it was last refreshed. No green success state for a local tap.

### 11.2 Review

Fetch the current request before enabling a decision. Show origin, job/run, operation, targets, preconditions, and expiry; for `exec.v1` the exact `argv` and `cwd`. Escape control characters and bidirectional formatting controls visibly; never silently truncate authorization-relevant arguments.

A request is Watch-approvable only when the Watch understands its schema and required features, policy permits Watch review, content is adequately reviewable (a digest alone is not), the source run has a fresh presence lease, and the gateway is live. Otherwise show **Review on another device**; a request needing fuller review stays unapproved or expires until a full-review client decides it.

**Approve once** requires explicit confirmation. No "approve all", long-lived grants, or approval from a widget/complication. Reject applies to the request only; cancelling a job is a separate operation.

### 11.3 Notification interaction

Register category `SHELL_APPROVAL_V1` on iPhone and Watch. The first action is **Review** (`.foreground`); Approve/Reject shortcuts, if present, are also foreground actions that select an intent but still fetch and review before submission. A notification action MUST NOT authorize from its embedded payload. Review is first because Double Tap invokes the first nondestructive action[A3], and foreground actions run on the device where selected.

After submission distinguish **Sending**, **Decision recorded**, **Waiting for host**, **Host accepted**, **Not applied**, and **Outcome unknown**; a later completion event can show success/failure. Dismissal is not rejection; reading is not acknowledging; acknowledging is not approving.

### 11.4 iPhone lifecycle

The iOS app MUST NOT require an always-open socket. Refresh on launch, foreground activation, manual refresh, notification open, optional background push callback, and active Watch gateway request. While a relevant screen is visible, coalesced bounded polling (no faster than every 5 seconds) or a short-lived change request MAY be used; pause it when not visible. When suspended, correctness relies on the Mac's durable state. Protected control material is redacted while locked as appropriate.

### 11.5 Watch lifecycle and cache

With no Shell Watch screen needing live data: no polling, no URLSession control traffic, no persistent socket, no Tailscale. The Watch relies on system notification presentation, opportunistic WatchConnectivity background cache delivery ([background refresh][A10]), and live WatchConnectivity only after user interaction. The protected local cache is redacted on lock/logout/account change. An optional complication is read-only (cached pending count and freshness, opens the inbox), promises no live counts, and never bypasses confirmation. No PushKit/VoIP/audio/workout workaround is permitted.

## 12. Notifications

### 12.1 Informational events

An origin event has `event_id`, `origin_id`, optional job/run IDs, `kind` (`job.completed`, `job.failed`, `attention`), `severity`, `title`, `body`, `occurred_at`. The broker authenticates the origin and persists the event before any push. Terminal OSC 9/777 notifications observed in the iPhone client MAY use the same UI locally but never become signed host claims or permission requests.

### 12.2 Push capability

The relay avoids a durable account registry. The iPhone registers its APNs token with the relay and receives a relay-signed **push capability** (APNs token, topic, environment, capability ID, expiry, rate class, allowed notification schema), verifiable without a database lookup. The iPhone transfers it to the Mac over the authenticated Tailscale channel (`PUT /v1/devices/me/push-capability`); the Mac stores it locally. On token change the iPhone publishes a replacement.

### 12.3 Relay request and payload

The Mac sends the capability, event type, `request_id`, `origin_id`, `collapse_id`, and a generic presentation class. The relay verifies the capability signature, enforces expiry and rate limits, constructs the APNs payload itself, and sends only to the embedded token/topic. It MUST NOT accept arbitrary topics or alert text. Default approval payload:

```json
{
  "aps": {
    "alert": { "title": "Approval needed", "body": "A Shell request is waiting for review" },
    "category": "SHELL_APPROVAL_V1",
    "content-available": 1
  },
  "v": 1, "event": "approval.created", "origin_id": "...", "request_id": "..."
}
```

Direct or relayed APNs uses `apns-push-type: alert`, priority 10, the registered topic, `apns-expiration` no later than the request deadline, a request-scoped collapse ID (e.g. `approval.<request_id>`), and stays under 4 KiB.[A6] Payloads carry IDs and minimal generic display text, never a permission credential, key, callback URL, or command; detailed previews require opt-in; full transcripts are out of scope.

### 12.4 Delivery semantics

APNs goes to the iPhone; the system may mirror it to the paired Watch. A Watch tap opens Watch review, which still needs the live gateway. The iOS [background callback][A11] MAY fetch the current request and stage a WatchConnectivity cache update, but correctness MUST NOT depend on that runtime.[A12] Push is a hint: APNs may drop, coalesce, or reorder.[A7] Clients reconcile after opening any notification, remove stale delivered notifications when they learn a resolution, and never infer authorization from a push.

**No-relay mode:** no remote alert is promised; iPhone refresh (launch/foreground/manual) and Watch refresh through the iPhone discover requests; authorization is unchanged. Fresh guided setup starts in no-relay mode even when the build carries a relay URL; registration requires explicit per-origin, per-iPhone opt-in ([`control-setup.md`](control-setup.md)).

### 12.5 Per-device notification preference

```text
GET /v1/devices/me/notification-preference   → { "enabled": true, "version": 0 }
PUT /v1/devices/me/notification-preference   { "enabled": false, "expected_version": 0 }
                                              → { "enabled": false, "version": 1 }
```

Device-authenticated and scoped to the calling iPhone (Watch reviewers have none). An unset record reports version 0, enabled. `PUT` is atomic compare-and-set: a stale `expected_version` is `409 idempotency_conflict` with the current preference in `current_projection`; an accepted write increments the version. `enabled: false` durably suppresses relay and direct-APNs sends to that device and deletes its delivery material; `PUT .../push-capability` and `PUT .../push` are refused while off, so registration never re-enables implicitly. It changes delivery only, never grants, pairing, pending approvals, or other reviewers. A serving broker lists `notification.preference.v1` in capabilities; a `404` from an older broker means disabling cannot be reported complete.

## 13. Synchronization, presence, and persistence

### 13.1 Snapshot and change stream

The snapshot is consistent and paginated (50 items/page initially) with a high-water cursor; pages share a snapshot token and expire together. After atomically applying it, clients consume deltas (100 events/page) after the cursor; changes during pagination remain in the log. Full request bodies are fetched on demand.

A change event has `v`, `event_id`, decimal-string `sequence`, `type`, `resource_id`, `resource_version`, `server_time`, and a typed projection. Types: `approval.created`, `approval.resolved`, `approval.dispatch_updated`, `notification.created`, `notification.acknowledged`, `job.updated`, `origin.presence_changed`. Delivery is at least once: deduplicate by event ID, ignore stale resource versions, and commit cache mutations with cursor advancement atomically. The cursor reflects only stream pages, never an APNs payload. Filtered streams may have sequence gaps that are not data loss. An expired cursor returns `410 cursor_expired` and requires a fresh snapshot. Tokens/cursors are bound to account and permission scope; a permission change may force a reset. Unresolved local command IDs persist separately; a snapshot refresh cannot erase an ambiguous decision.

### 13.2 Offline

Cached viewing is allowed; new approvals and job controls are disabled and MUST NOT be queued. After connection loss post-submission, persist the exact command ID/JWS, show **Outcome unknown**, and query status on reconnection. The identical command may be retried while its challenge/lifetime is valid; never re-sign or re-challenge automatically. After expiry, retrieve status only. Cancelling the local HTTP task is not cancelling the server command.

### 13.3 Presence

Broker and daemon share a machine, so no cloud heartbeat is needed; `shell-controld` publishes local presence over loopback/IPC with a short lease (default heartbeat 15 s, stale after 45 s). Approval requires: request pending and unexpired, exact run still registered, exact waiter still live, policy permits review. Reject MAY be recorded while the waiter is absent if the request is pending. If the daemon crashes or its waiter disappears, the broker withdraws/expires authority per journal-recovery rules. Presence and remote reachability are hints, never proof an operation may execute. Approval expiry defaults to 5 minutes, capped at 30.

### 13.4 Persistence and retention

The broker persists origin identity, devices, Watch reviewers, gateway bindings, runs/jobs, specs, projections, challenges, commands/idempotency, consumes, receipts, change log, push capabilities, and audit events, using atomic write/fsync/rename (`FileBrokerPersistence`). Retain deltas at least 7 days and command/receipt records 30 days; keep compact decided/consumed request tombstones and mutation IDs for the origin enrollment lifetime. A restored old state file MUST NOT resurrect spent authorization; administrative resets rotate service/enrollment identities and invalidate old credentials.

## 14. Errors and retry

Errors are `{"error":{"code":"...","message":"...","retryable":false},"server_time":"..."}` with an optional authorized `current_projection`.

| HTTP | Code | Client action |
|---|---|---|
| 400 | `invalid_payload`, `unsupported_command` | Stop; fix/schema-negotiate. |
| 401 | `invalid_token`, `device_revoked` | Refresh once if appropriate, else re-pair; never retry an action under a new identity. |
| 403 | `not_authorized`, `full_review_required` | No Watch approval; show policy outcome. |
| 404 | `not_found` | Reconcile; do not infer rejection. |
| 409 | `already_resolved`, `idempotency_conflict`, `already_claimed` | Show recorded state; never auto-create a replacement command. |
| 410 | `request_expired`, `challenge_expired`, `cursor_expired` | No new action; refresh review or snapshot. |
| 412 | `stale_version`, `hash_mismatch`, `policy_changed` | Re-fetch; require fresh review. |
| 422 | `unsupported_operation` | Hand off; never degrade to raw input. |
| 423 | `origin_unavailable` | Leave pending; do not queue approval. |
| 429 | `rate_limited` | Honor retry guidance only within the original validity window. |
| 503 | `temporarily_unavailable` | Back off reads; reconcile ambiguous mutations by the same ID. |

The broker is authoritative for deadlines; device clock skew cannot extend authorization. A duplicate already-recorded command returns its original result after expiry, subject to current authentication/authorization.

## 15. Host IPC and adapter contract

### 15.1 Local IPC

A per-user Unix-domain socket in a private state directory (dir 0700, socket 0600), with peer-identity verification where supported and per-run unguessable local capabilities. Frames are a 4-byte unsigned big-endian length plus one UTF-8 JSON document, max 64 KiB. The PTY MUST NOT be the control channel. Mandatory messages: `hello` (negotiates protocol, schemas, capabilities; obtains run binding), `notify`, `approval.request`, `approval.wait` (names the persisted request; returns resolution/permit or terminal failure), `approval.withdraw`, `receipt`. Requests carry a message ID and run capability; retransmission reuses ID and body hash.

### 15.2 Adapter CLI

```sh
shell-control notify --job "$JOB_ID" --title "Build finished"
shell-control request --spec-file request.json --wait --output json
```

Stdout is machine-readable JSON only; diagnostics go to stderr. Exit codes: 0 valid consumed approval, 10 rejected, 11 expired, 12 cancelled, 13 unavailable/unknown. Adapters MUST also validate the structured result; nonzero/error never authorizes; application is reported by receipt. A wrapper that executes commands owns the full dispatch journal and precondition check and MUST NOT treat an exit code as standing permission.

### 15.3 Restart and tmux boundary

The daemon persists the question before publishing. Closing an SSH terminal does not cancel a waiter; ending the job does. On daemon/adapter restart, reconcile journal, broker state, and live run identity; when safe continuation cannot be proven, withdraw/not-apply and require a new request. Never answer whatever occupies a reused PID or tmux pane. A tmux session preserves the execution environment but establishes no approval identity; authority is only `origin_id`, `job_id`, `run_id`, `request_id`, `request_hash`.

## 16. Management CLI

Full command behavior is in [`control-cli.md`](control-cli.md) and [`control-setup.md`](control-setup.md).

- `shell-control setup` checks Tailscale and MagicDNS, starts the loopback broker and `shell-controld`, configures and validates Serve, prints the origin ID and fingerprint, and shows the pairing QR. There is no cloudflared, quick/named tunnel, public reverse proxy, or public broker URL. Transport modes are `tailscale` and, for simulator development only, `loopback`; earlier Cloudflare installations migrate to `tailscale` on the next `setup`, withdrawing the old launchd job and files.
- A missing origin key with a recorded fingerprint stops `setup`/`up`; `setup --reset-origin-key` is the explicit replacement.
- `shell-control status` reports tailscale, serve URL, broker (loopback), daemon, origin, iPhone/Watch enrollment, push configured/disabled, and pending count.
- `shell-control route` prints the current origin-signed route-update QR without changing trust state.

## 17. Failure behavior

| Condition | Behavior |
|---|---|
| iPhone unavailable | Watch shows "iPhone unavailable"; cache readable, decisions disabled. |
| Tailscale down on iPhone | Gateway reads/decisions fail closed; iPhone reports private route unavailable; no re-enrollment. |
| Mac unavailable | No decision can be recorded; clients may show stale cached pending data. |
| WatchConnectivity delayed | Cache may be late; authorization never falls back to a queued transfer. |
| Push Relay/APNs unavailable or delayed | No prompt alert; request stays durable on the Mac and appears on refresh. |
| Mac route changes | Trust remains; apply a signed route update. |
| Tailscale reauthentication needed | Prompt to restore connectivity; do not delete enrollment. |
| Decision response lost | Reconcile by original `command_id`; never mint a second authorization. |
| Broker offline | Host stays blocked/fails closed under its declared timeout. |
| iPhone compromised | Attacker acts with the iPhone's own grants and can relay, but cannot forge a Watch signature; revoking the gateway disables Watch transport until rebound. |
| Watch compromised | Revoke the Watch reviewer; the iPhone remains usable. |

## 18. Security requirements and invariants

### 18.1 Requirements

The Mac-local authority MUST: authenticate every application request despite Tailscale; rate-limit pairing and device mutation; verify exact object ownership/scope; require current version/hash/challenge for decisions; expire challenges quickly; serialize resolution/consume; keep immutable idempotency results; keep the listener on loopback; verify gateway-to-Watch binding on every proxied operation; never trust a WatchConnectivity request merely because it arrived through the paired phone.

The iPhone MUST: pin the origin key; validate route signatures; validate Mac-signed/hashed review material; never manufacture a Watch JWS; never queue a fresh Watch authorization; redact protected control material while locked as appropriate.

The Watch MUST: store its signing key device-locally; recompute request hashes before signing; bind decisions to challenge/state/policy versions; journal ambiguous commands; disable decisions when live gateway conditions are not met.

### 18.2 Invariants

- A decision authorizes one identified request at one identified permission gate; a notification, terminal/tmux location, local tap, network identity, or broker acknowledgement alone never proves or authorizes execution.
- The origin key is identity; the Tailscale URL is routing. Changing routing MUST NOT silently change trust.
- The iPhone is required transport for Watch control but cannot forge the Watch's signature.
- WatchConnectivity background delivery carries stale-tolerant state, never executable authority; an approval is valid only over a live gateway path against current Mac state.
- Tailscale authenticates connectivity; Shell authenticates control actions.
- The Mac-local ledger is the source of truth; APNs and WatchConnectivity are delivery mechanisms.

## 19. Acceptance tests

### 19.1 Pairing, routing, and tailnet

- Moving the Mac between networks, changing public IP/NAT, or restarting Tailscale causes no re-enrollment.
- A signed route change with the same origin key updates routing without re-enrollment; one signed by another key is rejected; a replaced origin key requires explicit new pairing.
- Route resolution failure never clears credentials.
- The broker is unreachable from LAN/WAN outside Tailscale and reachable from the authorized iPhone; a denying Grant blocks access without altering enrollment, and restoring it restores access without re-enrollment.

### 19.2 Watch gateway

- Fetch succeeds when `WCSession.isReachable` and the Mac route works; decisions succeed through the iPhone and are attributed to the Watch key.
- The iPhone cannot replace a Watch JWS with its own or an unsigned decision.
- iPhone unreachable disables Watch decisions; a decision-like `transferUserInfo` object is rejected/ignored; late background cache transfers create no authority.
- Switching gateway iPhone requires explicit re-binding.
- Watch locked/restarted before unlock: no signing with unavailable credentials.
- Double Tap on a notification opens Review and does not approve.

### 19.3 Approval safety and recovery

- The exact request hash is recomputed on the reviewing device; stale state/policy version or changed argv/hash/context/run requires fresh review or a new request; an expired challenge or request cannot decide, even with a visible stale button.
- Simultaneous iPhone/Watch decisions yield exactly one transition; the loser sees the recorded decision.
- Duplicate command ID/body returns the original result; same ID with changed body is an idempotency conflict.
- Consume occurs once; changed run/context before consume prevents dispatch; revocation before consume prevents consume; cancel racing consume has one serialized winner and never falsely claims prevention.
- Host crash before/after dispatch: journal recovery; uncertain effects reported `unknown`, never replayed.
- tmux pane/PID reuse or tab changes have no effect on authority or routing.
- Unknown operation/required feature: no approval.
- Another account guessing a request ID gets no disclosure or control.
- Restored/reset state cannot reactivate old authority.
- Relay down, APNs lost/duplicated/delayed/reordered, or background push not run: refresh and reconciliation give correct state; no authorization is inferred from a payload.
- Broker restart preserves pending and idempotency state; daemon restart reconciles the exact waiter/run; connection loss after commit resolves by command-status query.

### 19.4 Physical-device tests (outstanding)

Before release validate on a physical iPhone and paired Apple Watch with the debugger detached: Wi-Fi-to-cellular transitions; iPhone locked/unlocked; iPhone app backgrounded/terminated; Watch app backgrounded; VPN On Demand enabled and disabled; Tailscale temporarily disconnected; Mac moved between networks; APNs background delivery delayed or omitted; WatchConnectivity immediate and queued paths. Simulator-only validation is insufficient for WatchConnectivity reachability, iOS suspension, Tailscale VPN behavior, or notification routing.

### 19.5 Completion definition

Complete when a permission-gated operation inside tmux on a Tailscale-connected Mac remains blocked under `shell-controld`; is durably represented by the Mac-local broker; optionally notifies the iPhone via a non-authoritative APNs hint; appears on the Watch and is fetched live Watch → iPhone → Tailscale → Mac; is reviewed against the exact immutable request, signed by the Watch key, and submitted immediately; yields exactly one decision, one consume by the exact waiting operation, and a receipt of what was applied; and survives Mac network changes and authenticated route changes without re-enrollment — with no public Mac listener, rotating tunnel hostname, cloud approval ledger, or queued Watch authorization, while duplicate, stale, cancelled, revoked, and ambiguous paths fail safely.

## 20. Implementation notes

### 20.1 File map

| Concern | Location |
|---|---|
| Portable protocol: DTOs, strict validation, JCS hashing, JWS, fixtures | `Packages/ShellControlCore/` (`Sources/Protocol`, `Sources/Client`, `Sources/Security`, `Tests`); `protocol/` |
| Origin identity, signed routes, pairing invitations, origin proofs, Watch enrollment requests | `Packages/ShellControlCore/Sources/Security/OriginIdentity.swift`, `OriginRouting.swift`, `WatchReviewer.swift` |
| Pinned-origin trust, route recovery (section 4.5), gateway API | `Packages/ShellControlCore/Sources/Client/OriginTrust.swift`, `GatewayAPI.swift` |
| `shell-watch-gateway/1` framing, iPhone router, Watch client | `Packages/ShellControlCore/Sources/Client/WatchGatewayProtocol.swift`, `WatchGatewayRouter.swift`, `WatchGatewayClient.swift` |
| Mac-local broker: state machine, persistence, origin proofs, pairings, Watch reviewers, gateway authorization, relay outbox | `services/shell-control/` (`Sources/ShellControlBroker/BrokerStore+Gateway.swift`, `BrokerService.swift`) |
| Host daemon and support | `cmd/ShellControlDaemon/`, `cmd/ShellControlHostSupport/` |
| Tailscale detection, Serve configuration/validation, origin key lifecycle, pairing/route QRs | `cmd/Sources/ShellControlManagement/TailscaleConfiguration.swift`, `LifecycleCoordinator.swift`, `PairingRenderer.swift` |
| Guided setup, `doctor`, `test-review`, diagnostics, notification preference ([`control-setup.md`](control-setup.md)) | `cmd/Sources/ShellControlManagement/GuidedSetupCoordinator.swift`, `HostDiagnostics.swift`, `SetupReviewTest.swift`; `Packages/ShellControlCore/Sources/Client/ControlDiagnostics.swift`, `RemoteAlerts.swift`; `shell/Features/Control/ControlSetupGuide.swift` |
| iPhone | `shell/Features/Control/ControlOriginTrust.swift`, `ControlTailnetTransport.swift`, `ControlGatewaySession.swift`, `ControlWatchGateway.swift`, `ControlRouteStore.swift`, `ControlPushCapability.swift`, `ControlPairingSession.swift` |
| Watch | `ShellWatch/Services/WatchGatewayClient.swift`, `GatewayCache.swift`, `WatchDecisionJournal.swift`, `ControlSession.swift`; features under `ShellWatch/Features/` |
| Push Relay | `services/push-relay/` |
| Existing app hooks | `shell/Core/Ghostty/GhosttyApp.swift` (notification/bell/command-finished callbacks), `shell/UI/Terminal/TerminalView.swift` (OSC 9/777, informational only), `shell/App/AppDelegate.swift` (early category registration), `shell/Entitlements/Shell.entitlements` |

### 20.2 Build and platform

- README scopes Shell to terminal, SSH, tmux, and config sync plus an **optional control companion**; the upstream AI/push feature set is not restored.
- `ShellControlCore` has no UIKit, Ghostty, Citadel, terminal-surface, SSH-credential, or CloudKit dependency; `Sendable` DTOs, isolated networking/state actors, main-actor UI. The terminal renderer MUST NOT be linked into the Watch.
- Watch: minimum watchOS 11, distinct bundle ID (`dev.chr33s.shell.watchkitapp`), own Keychain access group, `Configuration/Watch.xcconfig`; it MUST NOT inherit the iOS base configuration (bridging header, Ghostty linker flags, Shell identity). iOS minimum stays 18.0. A widget may use an app group only for sanitized read-only cache, never signing keys.
- UserNotifications categories and a native review screen come first; a custom long-look scene is optional[A5] with a static generic fallback that needs no network fetch.
- CI builds the iOS and Watch targets separately, tests the shared protocol package, and runs broker/daemon integration tests.

## References

- [A3] Watch notification actions
- [A5] Long-look interface
- [A6] Sending notification requests to APNs
- [A7] APNs delivery status and metrics
- [A8] Keychain item attributes
- [A9] `WCSession`
- [A10] WatchConnectivity background refresh
- [A11] Background notifications
- [A12] Background execution strategies
- [S1] RFC 8628 OAuth device authorization
- [S2] RFC 8785 JSON Canonicalization Scheme
- [S3] RFC 7515 JWS
- [S4] RFC 7518 JWA
- [T1] Tailscale on iOS
- [T2] VPN On Demand
- [T3] Stable Tailscale IPs
- [T4] MagicDNS
- [T5] Machine names
- [T6] Tailscale Serve
- [T7] HTTPS certificates
- [T8] Tailscale Services
- [T9] Grants

[A3]: https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos
[A5]: https://developer.apple.com/documentation/watchos-apps/customizing-your-long-look-interface
[A6]: https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
[A7]: https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns
[A8]: https://developer.apple.com/documentation/security/item-attribute-keys-and-values
[A9]: https://developer.apple.com/documentation/watchconnectivity/wcsession
[A10]: https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask
[A11]: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
[A12]: https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
[S1]: https://www.rfc-editor.org/rfc/rfc8628.html
[S2]: https://www.rfc-editor.org/rfc/rfc8785.html
[S3]: https://www.rfc-editor.org/rfc/rfc7515.html
[S4]: https://www.rfc-editor.org/rfc/rfc7518.html
[T1]: https://tailscale.com/docs/install/ios
[T2]: https://tailscale.com/docs/features/client/ios-vpn-on-demand
[T3]: https://tailscale.com/docs/concepts/ip-and-dns-addresses
[T4]: https://tailscale.com/docs/features/magicdns
[T5]: https://tailscale.com/docs/concepts/machine-names
[T6]: https://tailscale.com/docs/reference/tailscale-cli/serve
[T7]: https://tailscale.com/docs/how-to/set-up-https-certificates
[T8]: https://tailscale.com/docs/features/tailscale-services
[T9]: https://tailscale.com/docs/features/access-control/grants
