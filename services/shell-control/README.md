# shell-control (broker)

The durable broker described in [`docs/specs/control-protocol.md`](../../docs/specs/control-protocol.md)
section 2: enrollment, authorization policy, immutable request documents,
resolution and dispatch records, the ordered change log, idempotency records,
and the push outbox.

Under [`docs/specs/control-protocol.md`](../../docs/specs/control-protocol.md) it runs on
the execution Mac as the sole authority, on loopback, published only inside the
tailnet by Tailscale Serve. Given an origin identity (`origin_id` plus
`origin_key_file`) it additionally:

- answers `GET /v1/origin/proof?nonce=` with the nonce signed by the origin key,
  so a route can prove it reaches the pinned origin;
- mints one-use pairings (`POST /v1/admin/pairings`, loopback admin only) and
  accepts `POST /v1/pairings/{id}/claim`, which proves the pairing secret by HMAC
  and the new key by signature, then waits for explicit confirmation on the Mac;
- closes the unauthenticated `POST /v1/enrollments` path, so no device is
  enrolled without the setup QR and no Watch ever gets its own HTTPS credential;
- enrolls Watch reviewers bound to one gateway iPhone
  (`POST /v1/gateways/me/watch-reviewers`, confirmed on the Mac) and serves their
  proxied snapshot, changes, approval, review-challenge, command, and
  command-status calls under `/v1/gateways/me/watch-reviewers/{id}/…`, checking
  the gateway credential, the binding, revocation, and the grant on every call
  and verifying the Watch's own JWS;
- stores relay push capabilities (`PUT /v1/devices/me/push-capability`) and sends
  approval hints to the Shell Push Relay;
- serves each iPhone's own remote-alert preference
  (`GET`/`PUT /v1/devices/me/notification-preference`, compare-and-set on
  `expected_version`, 409 when stale). Off suppresses relay and direct-APNs sends
  to that device and deletes its delivery material; later registrations are
  refused until the iPhone opts in again. It changes delivery, never authority,
  and is advertised as `notification.preference.v1` in `/v1/capabilities`.

It also serves the optional `shell-agent/1` extension of
[`docs/specs/agent-relay.md`](../../docs/specs/agent-relay.md) under `/v1/agent/*`:
agent session registration, immutable typed inputs, signed `input.respond`
commands (first valid response wins), one-time input consume permits bound to
the exact native wait, detailed `agent.delivery.v1` receipts, informational
agent events, and a separate agent change feed. Agent approvals ride the base
approval ledger with the `agent.tool.v1` operation. The same store, commit,
idempotency, and signature rules serve both; the extension is not a second
authority. `POST /v1/admin/devices/{id}/agent-grants` (loopback admin) adds or
removes one device's agent grants.

## Trust boundary

V1 trusts the broker operator — in the gateway profile, the Mac itself. TLS protects transport, device signatures bind
control commands, and durable records support audit — but this is **not**
end-to-end encryption, and the broker can read request details. A signed
decision is not proof of biometric authentication and says nothing about whether
the command is safe.

APNs provider credentials live here and nowhere else: never on the Watch, the
iPhone, or a job host.

## Running it

```sh
swift build -c release
SHELL_CONTROL_ACCOUNT_ID=<lowercase-uuid> \
SHELL_CONTROL_ADMIN_SECRET=<high-entropy-secret> \
SHELL_CONTROL_APNS_TOPICS=dev.chr33s.shell.watchkitapp,dev.chr33s.shell \
SHELL_CONTROL_VERIFICATION_URI=https://control.example/activate \
.build/release/shell-control-broker
```

Managed installs pass `--config /absolute/path/broker.service.json`. The process
runs in the foreground, binds loopback unless explicitly configured otherwise,
holds a singleton lock next to the ledger, and stops the listener on SIGTERM.
`GET /v1/capabilities` and `GET /v1/admin/health` are `Cache-Control: no-store`.
The health route is loopback-admin only and does not mint work.

| Variable | Meaning |
|---|---|
| `SHELL_CONTROL_PORT` | Listen port (default 8443). |
| `SHELL_CONTROL_STATE` | Durable state file (default `~/.local/state/shell-control/broker.json`). |
| `SHELL_CONTROL_ACCOUNT_ID` | The account administrative confirmations bind to. |
| `SHELL_CONTROL_ADMIN_SECRET` | Presented as `Authorization: Admin <secret>` to confirm an enrollment or change policy. |
| `SHELL_CONTROL_CURSOR_SECRET` | Key for authenticating snapshot tokens and change cursors; set it so cursors survive a restart. |
| `SHELL_CONTROL_APNS_TOPICS` | Comma-separated allowlist of APNs topics a device may register. Registration fails closed when it is unset, so no device can register at all. |
| `SHELL_CONTROL_VERIFICATION_URI` | Where the RFC 8628 user code is confirmed. |
| `SHELL_CONTROL_APNS_KEY_ID`, `SHELL_CONTROL_APNS_TEAM_ID`, `SHELL_CONTROL_APNS_KEY_FILE` | Legacy direct-APNs credentials. Absent, the broker still records everything and only the push hint is missing. |
| `SHELL_CONTROL_ORIGIN_ID`, `SHELL_CONTROL_ORIGIN_KEY_FILE` | The Mac's origin identity: a UUID and a P-256 PEM key. Setting them enables the iPhone-gateway profile. |
| `SHELL_CONTROL_PUSH_RELAY_URL` | HTTPS base URL of the Shell Push Relay that approval hints are sent to. |

**The listener speaks plain HTTP and must sit behind TLS termination** —
Tailscale Serve in the gateway profile — or on loopback for development. Devices
refuse a non-HTTPS route that is not loopback. Admin routes answer only a
loopback `Host` with no proxy headers (including Tailscale Serve's), on top of
the admin secret.

## Platform

The broker builds and runs on macOS: it depends on CryptoKit through
`ShellControlSecurity`. Porting that module to `swift-crypto` is what a Linux
deployment needs.

## Confirming an enrollment

`/v1/oauth/confirm` is where a device sends the user. A browser gets a page that
asks for the administration secret and then shows the device label, platform,
key fingerprint, and requested permissions before anything is approved; an API
client gets the JSON envelope. Nothing about the pending enrollment is disclosed
until the credential is accepted.

The page is a working default, not a product: a real deployment replaces it with
its own console and session handling. What must not change is that confirming
requires account administration — an ordinary decision credential never suffices
— and that the fingerprint is shown for comparison against the device.

## Storage

`FileBrokerPersistence` writes the whole state atomically — write, `fsync`,
rename — before any mutation is reported as recorded, with a single logical
writer (the store actor) preserving per-request and per-job ordering. That is
the v1 durability contract; PostgreSQL is the scale path, and any replacement
must keep the same serialization.

Restoring an old state file cannot reactivate spent authority: tombstones,
idempotency records, and claims come back with everything else. An
administrative reset must rotate the service and enrollment identities.
