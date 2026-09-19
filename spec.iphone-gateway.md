# Shell Control iPhone Gateway over Tailscale

**Status:** Implemented (see "Implementation notes" at the end); physical-device validation (section 33) outstanding.  
**Repository:** `chr33s/shell`  
**Repository baseline:** `main` at `6c39c7df504e5d58fc0167ff6edec645f7e30cf6`, inspected 19 September 2026.  
**Protocol:** `shell-control/1` plus the `shell-watch-gateway/1` transport profile defined here.  
**Scope:** Replace the shared/public Shell Control broker path with a Mac-local authority reached privately over Tailscale by the iPhone; use WatchConnectivity between Apple Watch and iPhone.  
**Primary goal:** Eliminate Shell re-enrollment caused by changing public tunnel URLs while removing public ingress to the execution Mac and preserving the existing immutable-request, signed-decision, idempotency, consume, and receipt semantics.

Capitalized **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** express normative requirements of this proposed profile.

---

## 1. Product decision

Adopt an **iPhone gateway** architecture.

The macOS execution host remains authoritative for Shell Control state. The iPhone reaches that host over the user's tailnet. The Watch never connects to the Mac, Tailscale, or a Shell broker directly; it communicates only with its paired iPhone through WatchConnectivity.

The normal topology is:

```text
Program / permission hook
          │
          │ local authenticated IPC
          ▼
   shell-controld
          │
          │ loopback
          ▼
 Mac-local Shell Control broker
          │
          │ HTTPS via Tailscale Serve
          ▼
      Tailscale
          │
          ▼
       iPhone
          │
          │ WatchConnectivity
          ▼
        Watch
```

For remote attention, a minimal shared **Push Relay** MAY send APNs notifications to the iPhone:

```text
Mac-local broker ── push capability ──► Shell Push Relay ── APNs ──► iPhone
                                                                    │
                                                          system presentation /
                                                          Watch mirroring
                                                                    ▼
                                                                  Watch
```

The Push Relay is not a control broker and owns no approval authority.

### 1.1 Deliberate change from `spec.watch.md`

This profile intentionally supersedes the existing requirement that Shell Watch operate independently of the iPhone.

Under this profile:

- the paired iPhone is required for Watch reads and decisions;
- the Watch has no direct HTTPS control-service connection;
- the Watch has no Tailscale prerequisite;
- the Watch does not require its own APNs delivery path;
- WatchConnectivity becomes the required Watch transport;
- an unavailable iPhone makes Watch review/control unavailable;
- the iPhone itself remains a full control client and may review directly.

This tradeoff is accepted in exchange for eliminating public Mac ingress and the shared durable broker.

---

## 2. Design goals

The system MUST:

1. require Tailscale on the macOS execution host and the paired iPhone;
2. require no public listener, Cloudflare Tunnel, Funnel, reverse proxy, or public DNS name on the Mac;
3. keep the authoritative approval ledger on the Mac;
4. bind Shell pairing to a cryptographic origin identity rather than a hostname or URL;
5. treat a Tailscale address as a route, not an identity;
6. preserve pairing across ordinary Wi-Fi, WAN, NAT, DHCP, and public-IP changes;
7. avoid Shell re-enrollment when a Tailscale route or hostname changes but the pinned Shell origin key does not;
8. keep Watch signing material on the Watch;
9. prevent the iPhone from forging a Watch decision;
10. prevent WatchConnectivity background queues from authorizing delayed execution;
11. preserve immutable request hashes, state versions, policy versions, decision idempotency, one-time consume, and receipts;
12. fail closed when the iPhone, Tailscale path, Mac authority, or current operation context is unavailable;
13. allow notification delivery to fail without affecting correctness;
14. keep the Watch idle when no user interaction is occurring;
15. make the shared Push Relay optional for correctness.

---

## 3. Non-goals

V1 does not provide:

- independent Watch control while the iPhone is absent;
- direct Watch-to-Mac networking;
- Tailscale on watchOS;
- public access to the Mac;
- terminal streaming to the Watch;
- unrestricted remote input;
- SSH on the Watch;
- approval from a notification action without current review;
- queued eventual approval;
- automatic or bulk approval;
- long-lived "always allow" grants;
- tmux pane/window/PID authority;
- peer discovery through a Shell-operated cloud directory;
- cloud durability for approval state;
- end-to-end operation when the Mac itself is offline.

The Tailscale control plane remains an external networking dependency. This specification removes the Shell-operated shared control plane; it does not claim that the underlying network is infrastructure-free.

---

## 4. Components

### 4.1 `shell-controld`

Runs per user on the execution Mac.

Responsibilities remain:

- authenticated local adapter IPC;
- run/job registration;
- immutable approval publication;
- waiting for decisions;
- consume validation;
- local operation-context revalidation;
- dispatch journaling;
- receipt reporting.

### 4.2 Mac-local Shell Control broker

The existing broker state machine is retained initially, but moves entirely onto the execution Mac.

It:

- listens on loopback only;
- is the authoritative ledger;
- stores enrolled iPhone and Watch reviewer identities;
- stores requests, decisions, consumes, receipts, changes, and idempotency records;
- never requires an Internet-reachable listener;
- is exposed to the iPhone only through Tailscale Serve;
- is not exposed to the Watch.

The initial implementation SHOULD reuse `services/shell-control/` rather than rewrite the authorization state machine into `shell-controld`.

A later version MAY merge the local broker into `shell-controld`; this is not required by this profile.

### 4.3 Tailscale

Tailscale provides private network reachability between the iPhone and Mac.

Shell relies on Tailscale for connectivity, not for application authorization.

Shell MUST continue to authenticate requests at the application layer.

### 4.4 Tailscale Serve

Tailscale Serve terminates HTTPS inside the tailnet and proxies to the loopback broker.

Conceptually:

```text
https://<mac>.<tailnet>.ts.net
             │
       Tailscale Serve
             │
             ▼
http://127.0.0.1:8443
```

Production setup SHOULD use:

```sh
tailscale serve --bg localhost:8443
```

or the equivalent current Tailscale Serve configuration for HTTPS port 443.

The exact CLI invocation is implementation-owned because Tailscale CLI syntax may evolve; setup MUST validate resulting Serve state rather than assume command success.

### 4.5 Shell iPhone

The iPhone is simultaneously:

- a normal Shell Control review device;
- a full-review client;
- the network gateway for the paired Watch;
- the owner of the Tailscale connection used by Shell;
- the recipient of remote notification hints.

Its own decisions use its own signing key.

A Watch decision remains attributable to the Watch's signing key.

### 4.6 Shell Watch

The Watch is a review/signing client behind the iPhone gateway.

It owns:

- its device ID;
- its P-256 signing private key;
- protected review cache;
- pending ambiguous command IDs/JWSs;
- review UI.

It does not own:

- a broker URL used directly for networking;
- a Tailscale session;
- an origin bearer credential;
- an HTTP refresh token for the Mac;
- APNs provider credentials.

### 4.7 Optional Shell Push Relay

A small shared Internet service MAY provide APNs delivery to the iPhone.

It MUST NOT store or decide:

- approvals;
- decisions;
- consumes;
- receipts;
- jobs;
- run state;
- origin presence;
- terminal data.

A deployment without the Push Relay is fully correct but lacks prompt remote notification delivery while the Shell iOS app is suspended.

---

## 5. Trust model

The system trusts:

- the execution host and its local Shell Control authority;
- an enrolled iPhone signing identity for actions attributed to that iPhone;
- an enrolled Watch signing identity for actions attributed to that Watch;
- Tailscale to provide authenticated encrypted network reachability according to the user's tailnet configuration.

The system does not treat the following as authorization:

- Tailscale reachability alone;
- a Tailscale IP;
- a MagicDNS name;
- the current Wi-Fi network;
- possession of an APNs token;
- a push notification;
- a WatchConnectivity packet;
- an iPhone assertion that the Watch approved;
- a tmux identifier.

The host's same-user/root processes remain outside the v1 local isolation boundary as in the existing design.

---

## 6. Prerequisites

### 6.1 Mac

The execution Mac MUST have:

- Tailscale installed and authenticated;
- connectivity to the same tailnet as the iPhone;
- MagicDNS enabled or another stable tailnet route available;
- Tailscale Serve available;
- Shell Control host binaries installed.

Shell setup MUST detect and report when these prerequisites are absent.

### 6.2 iPhone

The iPhone MUST have:

- Tailscale installed;
- a usable Tailscale VPN configuration;
- access to the Mac's Tailscale endpoint;
- Shell installed;
- WatchConnectivity available when Watch control is desired.

VPN On Demand SHOULD be recommended so access to the `*.ts.net` route can cause or preserve the Tailscale connection when appropriate.

### 6.3 Watch

The Watch MUST be paired to the gateway iPhone and have Shell Watch installed.

The Watch does not join the tailnet.

---

## 7. Stable Shell identity versus network route

This distinction is the central invariant of the profile.

### 7.1 Origin identity

On first setup the Mac generates or loads a long-lived Shell Control origin signing key.

Define:

```text
origin_id          stable UUID
origin_public_key  P-256 public key
origin_fingerprint SHA-256 fingerprint of canonical public key
```

The private key is stored only on the Mac.

### 7.2 Route

A route is separately represented:

```text
route {
    kind: "tailscale_https"
    url: "https://mac-name.tailnet-name.ts.net"
    observed_at: ...
}
```

The route is not an authorization identifier.

### 7.3 Pairing rule

The iPhone pins:

```text
origin_id
origin_public_key
```

It MAY cache one or more routes.

Changing a route MUST NOT invalidate:

- the origin identity;
- the iPhone device enrollment;
- the Watch reviewer enrollment;
- device signing keys;
- grants;
- prior idempotency records.

### 7.4 Route update

A route update MUST be authenticated by the already pinned origin key.

Illustrative object:

```json
{
  "v": 1,
  "type": "origin.route",
  "origin_id": "20000000-0000-4000-8000-000000000001",
  "route": {
    "kind": "tailscale_https",
    "url": "https://new-name.example.ts.net"
  },
  "issued_at": "2026-09-19T02:00:00Z",
  "nonce": "..."
}
```

The Mac signs the canonical route object.

The iPhone accepts it only if:

- `origin_id` matches the pinned origin;
- signature verifies under the pinned origin key;
- scheme/host satisfy the Tailscale route policy;
- the new endpoint proves possession of the same origin key.

A route update is not re-enrollment.

### 7.5 Expected Tailscale stability

Ordinary physical network changes SHOULD require no route update. Tailscale assigns stable node IPs while the node remains registered, and MagicDNS names provide stable tailnet addressing across network movement.

If a Tailscale node is removed/reinstalled or deliberately renamed, Shell may need a route refresh, but not a new Shell trust relationship.

---

## 8. Tailscale endpoint configuration

The broker MUST listen only on loopback, for example:

```text
127.0.0.1:8443
```

Tailscale Serve exposes it inside the tailnet on HTTPS.

The Mac firewall MUST NOT expose the broker on the LAN/WAN interface as part of setup.

### 8.1 Tailscale Service

A Tailscale Service such as:

```text
svc:shell-control
```

MAY be used instead of a machine-specific MagicDNS route when the user has the required tailnet administrative setup.

Tailscale Services provide a stable service identity independent of a specific hosting node, but require tag-based service hosts and tailnet administration. They are therefore an optional advanced profile, not a v1 consumer prerequisite.

### 8.2 Tailnet grants

Users SHOULD restrict network access so only intended identities can reach the Shell Control HTTPS port.

For managed tailnets, use Tailscale Grants rather than new ACL rules.

Shell application authentication remains mandatory even when tailnet policy already restricts access.

---

## 9. Pairing the iPhone with the Mac

### 9.1 Setup QR

`bin/shell-control setup` produces a pairing QR containing only bootstrap material:

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

The pairing secret is:

- random;
- one use;
- short lived;
- not an origin credential.

### 9.2 iPhone action

The iPhone:

1. scans the QR;
2. verifies the route is a permitted Tailscale route;
3. connects through Tailscale;
4. obtains a server challenge;
5. verifies the Mac's origin signature using the key from the QR;
6. generates its own P-256 signing key;
7. submits its public key, device label, and pairing proof.

### 9.3 Mac confirmation

The Mac displays:

- iPhone label;
- platform;
- device public-key fingerprint;
- requested grants.

Explicit local confirmation enrolls the iPhone.

The Mac stores:

```text
device_id
platform = ios
public_key
grants
refresh/session verifier
paired_at
revocation state
```

The phone stores:

```text
origin_id
origin_public_key
route(s)
device_id
device_signing_key
session credentials
```

A future route change does not alter these records.

---

## 10. Watch reviewer enrollment

The Watch is enrolled as a **reviewer behind a specific gateway iPhone**.

### 10.1 Watch key

The Watch generates its own P-256 signing key locally.

The private key MUST NOT be copied to the iPhone.

### 10.2 Watch-to-iPhone bootstrap

WatchConnectivity sends an enrollment reference containing:

```text
watch public key
watch fingerprint
watch label
watch-generated nonce
```

No private key is transferred.

### 10.3 Gateway registration

The iPhone sends a Watch enrollment request to the Mac over Tailscale using its own authenticated device session.

The Mac records a pending reviewer:

```text
watch_device_id
public_key
gateway_device_id
requested grants
```

### 10.4 Confirmation

Enrollment requires explicit confirmation through an already authorized full-review surface or locally on the Mac.

Initial v1 SHOULD require Mac-local confirmation.

The resulting Watch grants may include:

```text
requests.read-via-gateway
approvals.decide
notifications.read-via-gateway
notifications.ack
jobs.cancel        optional
```

A Watch reviewer has no standalone network credential.

### 10.5 Gateway binding

A Watch is bound to one current `gateway_device_id`.

Changing the paired/gateway iPhone requires explicit re-binding.

Rotating the Mac's Tailscale address does not.

---

## 11. WatchConnectivity transport contract

Define the transport profile:

```text
shell-watch-gateway/1
```

WatchConnectivity is transport only. It is not the authoritative ledger.

### 11.1 Immediate interactive channel

Use:

```text
sendMessageData
```

for operations that require an immediate request/reply and current iPhone reachability:

- fetch current approval;
- fetch review challenge;
- submit a signed decision;
- query an ambiguous command result;
- cancel a job;
- fetch current outcome.

The Watch MUST check `isReachable` before enabling a decision.

### 11.2 Background channel

`updateApplicationContext`, `transferUserInfo`, and background file transfer MAY carry:

- sanitized cached inbox projection;
- latest pending count;
- request IDs;
- freshness timestamp;
- "refresh requested" hints;
- informational events;
- route/display metadata.

They MUST NOT carry an executable approval command that will be applied later.

### 11.3 No queued authorization

The following is forbidden:

```text
Watch user taps Approve
    ↓
transferUserInfo queues decision
    ↓
iPhone wakes minutes later
    ↓
Mac executes
```

An approval is interactive and requires a live gateway round trip.

If the iPhone is not reachable, the Watch MUST show a gateway-unavailable state and disable Approve/Reject submission.

### 11.4 Cached review

The Watch MAY display cached request material when the gateway is unavailable, clearly marked stale.

Cached material MUST NOT enable a new decision.

---

## 12. Gateway request framing

WatchConnectivity messages use a strict binary/JSON envelope with a 64 KiB maximum.

Illustrative request:

```json
{
  "v": 1,
  "protocol": "shell-watch-gateway/1",
  "message_id": "uuid",
  "type": "approval.fetch",
  "watch_device_id": "uuid",
  "request_id": "uuid"
}
```

Illustrative response:

```json
{
  "v": 1,
  "message_id": "uuid",
  "ok": true,
  "server_time": "...",
  "body": { "...": "..." }
}
```

The iPhone MUST reject:

- unknown message types;
- duplicate JSON keys;
- oversized messages;
- invalid identifiers;
- messages naming a Watch not bound to this gateway;
- unsupported protocol versions.

Message IDs provide gateway-level idempotency for retries.

---

## 13. iPhone gateway authorization model

The iPhone is not allowed to assert that a Watch made a decision.

### 13.1 Reads

For Watch read requests, the iPhone authenticates to the Mac using its own gateway device session.

The Mac authorizes the read based on:

- gateway device is active;
- named Watch is active;
- Watch is bound to this gateway;
- Watch has the relevant review grant;
- resource belongs to an origin accessible to the gateway.

### 13.2 Watch decision

The Watch receives from the Mac, through the iPhone:

- immutable approval record;
- request hash;
- state version;
- policy version;
- current review challenge;
- challenge expiry.

The Watch signs the existing Shell decision JWS with its own Watch private key.

The iPhone forwards that JWS unchanged.

The Mac verifies:

1. gateway session;
2. Watch-to-gateway binding;
3. Watch revocation/grants;
4. Watch JWS;
5. command ID/idempotency;
6. review challenge;
7. request hash;
8. state version;
9. policy version;
10. request expiry;
11. still-blocked run/presence;
12. allowed decision.

The iPhone cannot substitute its own approval for the Watch's signature.

### 13.3 iPhone decision

When review occurs on the iPhone itself, it uses the existing device decision flow and its own key.

---

## 14. Approval flow from Watch

### 14.1 Request creation

A local adapter blocks on the Mac.

```text
adapter
  │
  ▼
shell-controld
  │
  ▼
Mac-local broker
```

The broker durably records the immutable request before reporting publication.

### 14.2 Notification

If the Push Relay is configured, the Mac emits a non-authoritative notification hint for the iPhone.

Otherwise the request remains discoverable when the iPhone next refreshes.

### 14.3 User opens Watch review

The Watch requests the current approval over immediate WatchConnectivity.

```text
Watch
  │ sendMessageData
  ▼
iPhone
  │ HTTPS over Tailscale
  ▼
Mac-local broker
```

The iPhone returns the current broker record.

### 14.4 Fresh review

Before enabling a decision, the Watch requests a fresh review challenge through the same live path.

The Watch recomputes `request_hash` from the complete immutable spec.

### 14.5 Decision

The Watch creates a stable `command_id`, signs the decision JWS, journals it locally as pending, and sends it by immediate WatchConnectivity.

The iPhone forwards it to the Mac.

### 14.6 Commit

The Mac-local broker atomically records exactly one pending-to-resolved transition and immutable command result.

### 14.7 Reply

The result returns:

```text
Mac → iPhone → Watch
```

Only then does the Watch show `Decision recorded`.

### 14.8 Host consume

`shell-controld` sees the local broker transition, verifies the exact request/run/context, claims a one-time consume permit, journals dispatch intent, and returns authorization to the blocked adapter.

The adapter reports what it actually applied through a receipt.

---

## 15. Ambiguous decision results

If connectivity fails after the Watch sends a decision, the Watch MUST NOT generate a replacement decision.

It persists:

```text
command_id
target request_id
exact signed JWS
submission timestamp
```

When the gateway becomes reachable, it asks:

```text
GET /v1/commands/<command_id>
```

through the iPhone.

If no result exists and the original challenge remains valid, the identical signed command MAY be retried.

A changed command under the same `command_id` is an idempotency conflict.

Expiry does not erase an already committed result.

---

## 16. Optional Push Relay

A useful Watch/iPhone experience requires remote attention while the Shell iOS app is suspended. Tailscale connectivity alone does not give the Shell app arbitrary background execution.

Therefore a small Push Relay is RECOMMENDED, but it is not part of authorization correctness.

### 16.1 Stateless push capability

The preferred design avoids a durable user/account registry in the relay.

The iPhone registers its current APNs token with the relay and receives a relay-signed **push capability** containing:

```text
APNs token
APNs topic
environment
capability ID
expiry
rate class
allowed notification schema
```

The capability is signed by the relay and can therefore be verified later without a database lookup.

The iPhone transfers the capability to the Mac over the authenticated Tailscale channel.

The Mac stores it locally.

When the APNs token changes, the iPhone obtains and publishes a replacement capability.

### 16.2 Relay request

The Mac sends:

```text
push capability
event type
request_id
origin_id
collapse_id
generic presentation class
```

The relay:

1. verifies its capability signature;
2. enforces expiry and rate limits;
3. constructs the APNs payload itself;
4. sends only to the token/topic embedded in the capability.

The relay MUST NOT accept arbitrary APNs topics or arbitrary alert text.

### 16.3 Payload

Default approval push:

```json
{
  "aps": {
    "alert": {
      "title": "Approval needed",
      "body": "A Shell request is waiting for review"
    },
    "category": "SHELL_APPROVAL_V1",
    "content-available": 1
  },
  "v": 1,
  "event": "approval.created",
  "origin_id": "...",
  "request_id": "..."
}
```

The notification is a hint only.

The iOS background callback MAY opportunistically fetch the current request over Tailscale and stage a WatchConnectivity cache update. Correctness MUST NOT depend on the system granting that background runtime.

### 16.4 Watch presentation

V1 sends APNs to the iPhone.

The system may present/mirror the notification on the paired Watch according to Apple notification routing behavior.

A Watch tap opens the Watch review flow, which still requires the live iPhone gateway to fetch/review/submit.

### 16.5 No-relay mode

If no Push Relay is configured:

- no remote alert is promised;
- iPhone refresh on launch/foreground/manual action discovers requests;
- Watch refresh through the iPhone discovers requests;
- authorization behavior is unchanged.

---

## 17. iPhone lifecycle

The Shell iOS app MUST NOT maintain an always-open application socket as a correctness requirement.

Refresh triggers:

- app launch;
- foreground activation;
- manual refresh;
- notification open;
- optional background push callback;
- active Watch gateway request.

While the relevant iPhone screen is visible, bounded polling or a short-lived change request MAY be used.

When suspended, correctness relies on the Mac's durable local state, not an iPhone background loop.

Tailscale VPN On Demand SHOULD be recommended so tailnet connectivity is available when Shell performs a request.

---

## 18. Watch lifecycle and battery

When no Shell Watch screen needs live data:

```text
no polling
no URLSession control traffic
no persistent socket
no Tailscale
```

The Watch relies on:

- system notification presentation;
- WatchConnectivity background cache delivery when opportunistically available;
- live WatchConnectivity only after user interaction.

This is battery-efficient but deliberately less independent than the original Watch architecture.

Background WatchConnectivity transfers are permitted for stale-tolerant cache updates because Apple schedules those opportunistically for power efficiency.

Interactive authorization uses immediate messages only.

---

## 19. Mac-local API

The existing `/v1` API SHOULD be preserved where possible.

Relevant endpoints include:

```text
GET  /v1/capabilities
GET  /v1/snapshot
GET  /v1/changes
GET  /v1/approvals/{request_id}
POST /v1/review-challenges
POST /v1/commands
GET  /v1/commands/{command_id}
POST /v1/approvals/{request_id}/consume
POST /v1/receipts
```

Add gateway-aware operations as needed, for example:

```text
POST /v1/gateways/me/watch-reviewers
GET  /v1/gateways/me/watch-reviewers/{watch_device_id}/approvals/{request_id}
POST /v1/gateways/me/watch-reviewers/{watch_device_id}/review-challenges
POST /v1/gateways/me/watch-reviewers/{watch_device_id}/commands
GET  /v1/gateways/me/watch-reviewers/{watch_device_id}/commands/{command_id}
```

The exact route structure is implementation detail; the authorization semantics are normative.

The broker MUST derive the gateway identity from the authenticated iPhone credential, never a caller-supplied gateway ID.

---

## 20. Local broker persistence

The broker remains durable because the Mac is now the sole authority.

Its state includes:

```text
origin identity
iPhone devices
Watch reviewer devices
gateway bindings
runs/jobs
immutable approval specs
approval projections
review challenges
commands/idempotency
consumes
receipts
change log
push capabilities
audit events
```

Atomic write/fsync/rename semantics from the current `FileBrokerPersistence` remain acceptable for v1.

A restored old state file MUST NOT resurrect spent authorization.

Detailed tombstone/idempotency semantics from `spec.watch.md` remain in force.

---

## 21. Origin presence

Cloud origin heartbeat is unnecessary because broker and execution daemon are on the same machine.

The local broker needs to know whether the exact run/waiter is live.

`shell-controld` publishes local presence through loopback/IPC with a short lease.

Approval requires:

```text
request pending
request unexpired
exact run still registered
exact waiter still live
policy permits review
```

If `shell-controld` crashes or its waiter disappears, the broker withdraws/expires authority according to the existing journal-recovery rules.

Remote network reachability does not constitute execution presence.

---

## 22. tmux boundary

tmux remains outside the authorization identity model.

Do not authorize by:

```text
pane ID
window ID
session name
PTY
PID
terminal title
selected tab
```

Authority remains:

```text
origin_id
job_id
run_id
request_id
request_hash
```

A tmux session preserves the user's execution environment but does not establish approval identity.

---

## 23. Tailscale authentication versus Shell authentication

The user may still be required to reauthenticate **Tailscale itself** according to their tailnet policy and key-expiry configuration.

That is separate from Shell pairing.

The system MUST distinguish:

```text
Tailscale authentication
    establishes tailnet connectivity

Shell enrollment
    establishes application identity and control grants
```

A Tailscale login refresh, VPN restart, Wi-Fi change, DERP fallback, node address change, or MagicDNS resolution change MUST NOT automatically clear Shell credentials.

Shell re-enrollment is required only for security events such as:

- origin signing key replaced;
- device signing identity intentionally reset;
- device revoked;
- Watch gateway binding intentionally changed;
- local authority data administratively reset.

---

## 24. Route recovery

When the pinned route fails, the iPhone proceeds in this order:

1. retry the last known MagicDNS HTTPS route after ensuring Tailscale is active;
2. retry other previously signed routes for the same `origin_id`;
3. use an explicitly supplied new route object signed by the pinned origin key;
4. require a new pairing only if the origin key itself cannot be matched.

A manually scanned **route-only QR** MAY update routing without re-enrollment.

Example:

```json
{
  "v": 1,
  "type": "shell-control.route-update",
  "origin_id": "...",
  "route": "https://replacement-name.example.ts.net",
  "issued_at": "...",
  "signature": "..."
}
```

The iPhone MUST label this as a route update, not a new trust decision.

---

## 25. CLI experience

### 25.1 Setup

Desired flow:

```text
$ shell-control setup

Checking Tailscale...
  connected
  MagicDNS: available

Starting local broker...
  http://127.0.0.1:8443

Starting shell-controld...
  ready

Configuring private HTTPS...
  https://macbook.example.ts.net
  Tailscale Serve: active

Shell origin:
  20000000-0000-4000-8000-000000000001
  fingerprint: SHA256:...

Scan this QR in Shell on iPhone to pair.
```

There is no:

```text
cloudflared
quick tunnel hostname
named tunnel
public reverse proxy
broker public URL
```

### 25.2 Status

```text
$ shell-control status

tailscale     connected
serve         https://macbook.example.ts.net
broker        ready (loopback)
daemon        ready
origin        20000000-...
iphone        enrolled
watch         enrolled via iPhone
push          configured | disabled
pending       0
```

### 25.3 Route update

```text
$ shell-control route
```

prints the current origin-signed route update QR without changing trust state.

---

## 26. Repository changes

### 26.1 Preserve

Reuse:

```text
Packages/ShellControlCore/
services/shell-control/
cmd/ShellControlDaemon/
cmd/ShellControlHostSupport/
protocol/
```

Preserve current protocol fixtures for:

- canonicalization;
- request hashes;
- signed decisions;
- state transitions;
- idempotency;
- consume permits;
- receipts.

### 26.2 Mac management

Refactor:

```text
cmd/ShellControlManagement/
```

to add:

- Tailscale prerequisite detection;
- Tailscale Serve configuration/status;
- origin signing identity lifecycle;
- route object signing;
- route-only QR output;
- removal of managed Cloudflare Tunnel setup from this profile.

### 26.3 iPhone

Add/modify under:

```text
shell/Features/Control/
```

Suggested components:

```text
ControlOriginTrust.swift
ControlTailnetTransport.swift
ControlGatewaySession.swift
ControlWatchGateway.swift
ControlRouteStore.swift
ControlPushCapability.swift
```

`ControlPairingSession.swift` changes from enrollment-assistance-only WatchConnectivity to the required Watch gateway transport.

### 26.4 Watch

Replace direct broker networking in:

```text
ShellWatch/Services/ControlSession.swift
```

with a gateway client.

Suggested:

```text
ShellWatch/Services/WatchGatewayClient.swift
ShellWatch/Services/GatewayCache.swift
ShellWatch/Services/WatchDecisionJournal.swift
```

Remove direct Watch broker credential refresh from the gateway profile.

The Watch signing-key abstraction remains.

### 26.5 Push relay

If operated by the project, place it outside the authority packages, for example:

```text
services/push-relay/
```

It must have no dependency on approval-state storage.

---

## 27. Migration from the current architecture

### Phase 1 — localize broker

Keep existing broker and daemon code.

Change production setup from:

```text
Mac local broker
    +
public tunnel
```

to:

```text
Mac local broker
    +
Tailscale Serve
```

iPhone talks directly to the Mac-local broker.

### Phase 2 — separate trust from route

Introduce stable origin signing keys and origin-pinned iPhone trust.

Stop treating broker URL changes as account/broker changes.

Add signed route updates.

### Phase 3 — make iPhone the Watch gateway

Move Watch reads through WatchConnectivity.

Enroll Watch as a reviewer bound to the iPhone gateway.

Keep Watch signing keys local.

Disable direct Watch HTTPS in this profile.

### Phase 4 — interactive Watch decisions

Implement live fetch/challenge/decision/query message flows.

Forbid queued authorization commands.

### Phase 5 — notification relay

Add stateless push capabilities and iPhone APNs hints.

Retire broker-owned APNs state from this profile.

### Phase 6 — remove old tunnel lifecycle

Remove normal-profile commands/configuration for:

```text
quick tunnels
tunnel rotation
named tunnel credentials
public broker URL pairing
```

A legacy/public-broker profile MAY remain separately if desired.

---

## 28. Failure behavior

### iPhone unavailable

Watch shows:

```text
iPhone unavailable
```

Cached content may remain readable, but new decisions are disabled.

### Tailscale unavailable on iPhone

Watch gateway reads/decisions fail closed.

iPhone UI reports that the private Mac route is unavailable.

No Shell re-enrollment occurs.

### Mac unavailable

No new decision can be recorded.

The Watch/iPhone may show cached pending data with stale status.

### WatchConnectivity delayed

Background cache delivery may be late.

Interactive authorization never falls back to a queued background transfer.

### Push Relay unavailable

No prompt notification is guaranteed.

The request remains durable on the Mac and appears on next refresh.

### APNs delayed/dropped

Same as relay unavailable; correctness is unchanged.

### Mac route changes

Existing Shell trust remains.

Apply a signed route update.

### Tailscale node reauthentication required

Prompt the user to restore Tailscale connectivity.

Do not delete Shell enrollment.

### Decision response lost

Reconcile by the original `command_id`.

Do not mint a second authorization.

### iPhone compromised

The attacker may act with the iPhone's own enrolled grants and may relay traffic for the Watch, but cannot forge a Watch-signed decision without the Watch private key.

Revoking the iPhone gateway disables Watch transport until rebound.

### Watch compromised

Revoke the Watch reviewer identity.

The iPhone remains independently usable.

---

## 29. Security requirements

The Mac-local authority MUST:

- authenticate every application request despite Tailscale;
- rate-limit pairing and device mutation endpoints;
- verify exact object ownership/scope;
- require current version/hash/challenge for decisions;
- expire challenges quickly;
- serialize resolution/consume transitions;
- maintain immutable idempotency results;
- keep broker listener on loopback;
- verify gateway-to-Watch binding on every proxied Watch operation;
- never trust a WatchConnectivity request merely because it arrived through the paired phone.

The iPhone MUST:

- pin the origin public key;
- validate route signatures;
- validate Mac-signed/hashed review material;
- never manufacture a Watch JWS;
- never queue a fresh Watch authorization for later submission;
- redact protected control material while locked as appropriate.

The Watch MUST:

- store its signing private key device-locally;
- recompute request hashes before signing;
- bind decisions to challenge/state/policy versions;
- journal ambiguous commands;
- disable decision actions when live gateway conditions are not met.

---

## 30. Privacy properties

Compared with the shared-cloud-broker profile:

- approval contents stay on the Mac/iPhone/Watch path;
- a Shell-operated Push Relay, if used, sees only notification-routing material;
- there is no shared approval database;
- there is no central Shell service that sees command contents;
- Tailscale observes/control-planes network metadata according to its product architecture, but Shell control documents are carried inside the private connection.

This specification does not claim a formal zero-knowledge property.

---

## 31. Tradeoffs

### Advantages

- no changing public tunnel hostname in the critical path;
- no Shell re-enrollment for normal network changes;
- no public Mac endpoint;
- no shared durable Shell approval infrastructure;
- fewer cloud consistency/race concerns;
- lower hosted infrastructure cost;
- decisions travel directly to the authoritative Mac;
- existing broker protocol can largely be reused;
- Watch remains cryptographically distinct from iPhone.

### Costs

- Tailscale becomes mandatory on Mac and iPhone;
- users must operate or join a tailnet;
- Tailscale authentication/key-expiry remains a separate lifecycle;
- Watch control fails when the iPhone gateway is unavailable;
- WatchConnectivity immediate reachability is required for decisions;
- remote notifications still need APNs provider infrastructure for good UX;
- the Mac must remain online because there is no cloud ledger to accept decisions while it is away;
- multi-origin use requires each origin to be reachable in the tailnet;
- switching gateway iPhones requires an explicit Watch re-binding.

The profile deliberately favors **private direct connectivity and stable identity** over independent Watch operation.

---

## 32. Acceptance tests

### Pairing and routing

- Pair iPhone once, then move Mac between Wi-Fi networks: no Shell re-enrollment.
- Change Mac public IP/NAT: no Shell re-enrollment.
- Restart Tailscale: no Shell re-enrollment after connectivity returns.
- Change signed route while origin key is unchanged: route updates without device re-enrollment.
- Present route update signed by another origin key: reject.
- Replace origin key: require explicit new trust/pairing.

### Tailnet isolation

- Broker cannot be reached from LAN/WAN outside Tailscale.
- Broker remains reachable from authorized iPhone over Tailscale.
- Tailscale Grant denying the iPhone blocks access without altering Shell enrollment.
- Restoring the Grant restores connectivity without Shell re-enrollment.

### Watch gateway

- Watch fetch succeeds when iPhone `WCSession.isReachable` and Mac route works.
- Watch decision succeeds through iPhone and is attributed to Watch key.
- iPhone cannot replace Watch JWS with an unsigned decision.
- iPhone unreachable: Watch decision controls disabled.
- `transferUserInfo` containing a decision-like object is rejected/ignored.
- background cache transfer may arrive later without creating authority.
- switching paired/gateway iPhone requires explicit Watch re-binding.

### Approval safety

- exact request hash is recomputed on Watch.
- stale state version requires fresh review.
- stale policy version requires fresh review.
- expired challenge cannot decide.
- simultaneous iPhone and Watch decisions yield one winner.
- duplicate Watch command ID/body returns original result.
- same command ID with changed body returns idempotency conflict.
- consume occurs only once.
- changed run/context before consume prevents dispatch.
- tmux pane/PID reuse has no effect on request authority.

### Notification

- Push Relay down: request remains available through manual refresh.
- APNs delayed: no authorization is inferred.
- background iOS push not executed: tapping/foreground refresh still works.
- APNs payload alone cannot authorize.

### Recovery

- Mac broker restart preserves pending request/idempotency state.
- daemon restart reconciles exact waiter/run.
- connection loss after command commit resolves through command-status query.
- route resolution failure does not clear local credentials.

---

## 33. Physical-device tests

Before release validate with:

- physical iPhone;
- physical paired Apple Watch;
- debugger detached;
- Wi-Fi-to-cellular transitions;
- iPhone locked/unlocked;
- iPhone app backgrounded/terminated;
- Watch app backgrounded;
- Tailscale VPN On Demand enabled and disabled;
- Tailscale temporarily disconnected;
- Mac moved between networks;
- APNs background delivery delayed or omitted;
- WatchConnectivity immediate and queued paths.

Simulator-only validation is insufficient for WatchConnectivity reachability, iOS suspension, Tailscale VPN behavior, or notification routing.

---

## 34. Completion definition

This profile is complete when a permission-gated operation running inside tmux on a Tailscale-connected Mac can:

1. remain blocked under `shell-controld`;
2. be durably represented by the Mac-local broker;
3. notify the iPhone through an optional non-authoritative APNs hint;
4. appear on the Watch through the paired-iPhone experience;
5. be fetched live by Watch → iPhone → Tailscale → Mac;
6. be reviewed against the exact immutable request;
7. be signed by the Watch's own private key;
8. be submitted immediately through the reachable iPhone gateway;
9. produce exactly one recorded decision;
10. be consumed exactly once by the exact waiting host operation;
11. produce a receipt describing what was actually applied;
12. survive Mac physical-network changes without Shell re-enrollment;
13. accept a cryptographically authenticated route change without changing the Shell trust relationship;

while requiring no public Mac listener, no rotating public tunnel hostname, no cloud approval ledger, and no queued eventual Watch authorization.

---

## 35. Core invariants

> **The Shell origin key is identity; the Tailscale URL is routing.**

> **Changing routing MUST NOT silently become changing trust.**

> **The iPhone is required transport for Watch control, but it cannot forge the Watch's signature.**

> **WatchConnectivity background delivery may carry stale-tolerant state, never executable approval authority.**

> **An approval is valid only during a live interactive gateway path and against current Mac-authoritative state.**

> **Tailscale authenticates connectivity; Shell still authenticates control actions.**

> **The Mac-local ledger is the source of truth. APNs and WatchConnectivity are delivery mechanisms.**

> **A tmux location, notification, local tap, or network identity alone never authorizes execution.**

---

## References

Repository references:

- `README.md`: https://github.com/chr33s/shell/blob/6c39c7df504e5d58fc0167ff6edec645f7e30cf6/README.md
- `spec.watch.md`: https://github.com/chr33s/shell/blob/6c39c7df504e5d58fc0167ff6edec645f7e30cf6/spec.watch.md
- Watch pairing session: https://github.com/chr33s/shell/blob/6c39c7df504e5d58fc0167ff6edec645f7e30cf6/ShellWatch/Services/ControlPairingSession.swift
- Watch control session: https://github.com/chr33s/shell/blob/6c39c7df504e5d58fc0167ff6edec645f7e30cf6/ShellWatch/Services/ControlSession.swift
- iPhone pairing session: https://github.com/chr33s/shell/blob/6c39c7df504e5d58fc0167ff6edec645f7e30cf6/shell/Features/Control/ControlPairingSession.swift

Apple references:

- `WCSession`: https://developer.apple.com/documentation/watchconnectivity/wcsession
- WatchConnectivity background refresh: https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask
- Background notifications: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
- Background execution strategies: https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app

Tailscale references:

- iOS installation/VPN: https://tailscale.com/docs/install/ios
- VPN On Demand: https://tailscale.com/docs/features/client/ios-vpn-on-demand
- Stable Tailscale IPs: https://tailscale.com/docs/concepts/ip-and-dns-addresses
- MagicDNS: https://tailscale.com/docs/features/magicdns
- Machine names: https://tailscale.com/docs/concepts/machine-names
- Tailscale Serve: https://tailscale.com/docs/reference/tailscale-cli/serve
- HTTPS certificates: https://tailscale.com/docs/how-to/set-up-https-certificates
- Tailscale Services: https://tailscale.com/docs/features/tailscale-services
- Grants: https://tailscale.com/docs/features/access-control/grants

---

## Implementation notes

Where this profile lives in the repository:

| Concern | Location |
|---|---|
| Origin identity, signed route updates, pairing invitations, origin proofs, Watch enrollment requests | `Packages/ShellControlCore/Sources/Security/OriginIdentity.swift`, `OriginRouting.swift`, `WatchReviewer.swift` |
| Pinned-origin trust, route recovery (section 24), gateway API calls | `Packages/ShellControlCore/Sources/Client/OriginTrust.swift`, `GatewayAPI.swift` |
| `shell-watch-gateway/1` framing, iPhone router, Watch client | `Packages/ShellControlCore/Sources/Client/WatchGatewayProtocol.swift`, `WatchGatewayRouter.swift`, `WatchGatewayClient.swift` |
| Mac-local broker: origin proofs, pairings, Watch reviewers, gateway authorization, relay outbox | `services/shell-control/Sources/ShellControlBroker/BrokerStore+Gateway.swift`, `BrokerService.swift` |
| Tailscale detection, Serve configuration and validation, origin key lifecycle, pairing and route QRs | `cmd/Sources/ShellControlManagement/TailscaleConfiguration.swift`, `LifecycleCoordinator.swift`, `PairingRenderer.swift` |
| iPhone | `shell/Features/Control/ControlOriginTrust.swift`, `ControlTailnetTransport.swift`, `ControlGatewaySession.swift`, `ControlWatchGateway.swift`, `ControlRouteStore.swift`, `ControlPushCapability.swift`, `ControlPairingSession.swift` |
| Watch | `ShellWatch/Services/WatchGatewayClient.swift`, `GatewayCache.swift`, `WatchDecisionJournal.swift`, `ControlSession.swift` |
| Push Relay | `services/push-relay/` |

Decisions taken where this document leaves room:

- The origin ID is the same UUID as the daemon's origin credential, so approval
  specs, proofs, and relay hints name one origin.
- An iPhone pairing claim reuses the existing enrollment and RFC 8628 device-grant
  machinery: the claim proves the pairing secret (HMAC) and the new key
  (signature), after which the Mac-local `shell-control confirm` and the phone's
  poll/complete run unchanged. Direct `POST /v1/enrollments` is closed whenever
  the broker holds an origin identity.
- Watch reviewer grants are `requests.read-via-gateway`, `approvals.decide`,
  `notifications.read-via-gateway`, and `notifications.ack`; the Mac strips any
  standalone read grant on confirmation. Confirming a request from a new iPhone
  for an already-enrolled Watch key is the explicit re-binding of section 10.5.
- A losing route, a Tailscale outage, or an origin-proof mismatch never clears
  credentials. Only a revoked device or a spent refresh token returns the iPhone
  to pairing, and the pinned origin survives either.
- A missing origin key with a recorded fingerprint stops `setup`/`up`;
  `setup --reset-origin-key` is the explicit replacement.
- The Cloudflare tunnel modes are removed (Phase 6): the CLI offers `tailscale`
  and, for simulator development only, `loopback`. An installation from an
  earlier release migrates to `tailscale` on the next `setup`, which withdraws
  the old cloudflared launchd job and its files.
