# shell-control (broker)

The durable broker described in [`../../spec.watch.md`](../../spec.watch.md)
section 3: enrollment, authorization policy, immutable request documents,
resolution and dispatch records, the ordered change log, idempotency records,
and the APNs outbox.

## Trust boundary

V1 trusts the broker operator. TLS protects transport, device signatures bind
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
| `SHELL_CONTROL_APNS_KEY_ID`, `SHELL_CONTROL_APNS_TEAM_ID`, `SHELL_CONTROL_APNS_KEY_FILE` | Provider token credentials. Absent, the broker still records everything and only the push hint is missing. |

**The listener speaks plain HTTP and must sit behind TLS termination**, or on
loopback for development. Devices refuse a non-HTTPS base URL that is not
loopback.

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
