# shell-control/1

The published wire contract for the Shell Watch companion, as specified in
[`../spec.watch.md`](../spec.watch.md). This is a Shell-specific application
protocol; it is not SSH, tmux control mode, or any existing "Shell protocol".

## Invariant

> A Watch decision authorizes one identified request at one identified
> permission gate; a notification, terminal location, local tap, or broker
> acknowledgement alone never proves execution.

## Layout

```text
schemas/    JSON Schema (2020-12) for the documents that carry authority
fixtures/   Interoperability vectors, generated independently of the Swift code
```

`fixtures/approval-spec.jcs.txt` and `fixtures/approval-spec.hash.txt` are the
RFC 8785 encoding and `sha256:` digest of `fixtures/approval-spec.json`. Any
implementation that computes a different digest for that document is wrong;
`Packages/ShellControlCore` checks itself against these files.

## Runtime endpoints

| Endpoint | Caller |
|---|---|
| `GET /v1/capabilities` | anyone; discovery is not authorization |
| `PUT /v1/devices/me/push` | device |
| `GET /v1/snapshot` | device, origin |
| `GET /v1/changes?cursor=C&limit=100&wait=0` | device, origin (`wait` for long polling) |
| `GET /v1/approvals/{request_id}` | device, origin |
| `POST /v1/review-challenges` | device |
| `POST /v1/commands` | device, with `Idempotency-Key: <command_id>` |
| `GET /v1/commands/{command_id}` | the submitting device |
| `PUT /v1/origins/me/runs/{run_id}` | origin |
| `POST /v1/origins/me/heartbeat` | origin |
| `POST /v1/notifications` | origin |
| `POST /v1/approvals` | origin |
| `POST /v1/approvals/{id}/withdraw` | origin |
| `POST /v1/approvals/{id}/consume` | origin |
| `POST /v1/receipts` | origin |

Enrollment adds `POST /v1/enrollments`, `POST /v1/enrollments/{id}/complete`,
and the RFC 8628 pair `POST /v1/oauth/device_authorization` and
`POST /v1/oauth/token`, plus the authenticated confirmation surface at
`/v1/oauth/confirm`.

## The iPhone-gateway profile

[`../spec.iphone-gateway.md`](../spec.iphone-gateway.md) runs the same protocol
on a Mac-local broker reached over Tailscale, and adds:

| Endpoint | Caller |
|---|---|
| `GET /v1/origin/proof?nonce=N` | anyone; returns `N` signed by the origin key |
| `POST /v1/pairings/{pairing_id}/claim` | a new iPhone holding the setup QR |
| `PUT /v1/devices/me/push-capability` | iPhone |
| `POST /v1/gateways/me/watch-reviewers` | iPhone gateway, for its Watch |
| `GET /v1/gateways/me/watch-reviewers/{watch_id}` | that gateway |
| `GET …/{watch_id}/snapshot`, `GET …/{watch_id}/changes` | that gateway, as the Watch |
| `GET …/{watch_id}/approvals/{request_id}` | that gateway, as the Watch |
| `POST …/{watch_id}/review-challenges` | that gateway, as the Watch |
| `POST …/{watch_id}/commands`, `GET …/{watch_id}/commands/{command_id}` | that gateway, carrying the Watch's JWS unchanged |

In this profile `POST /v1/enrollments` is closed: an iPhone enrolls only by
claiming a one-use pairing, and a Watch only through its gateway.

Signed documents (`shell-control.origin-proof`, `shell-control.route-update`)
are flat JSON objects whose `signature` member is ES256 (`R || S`, base64url)
over the JCS encoding of every other member; `type` is the domain separator.
The setup QR (`shell-control.pairing`) and route QR travel as
`shell-control://pair?invite=` and `shell-control://route?update=` links whose
value is the base64url JCS document. A route update changes routing only.

`shell-watch-gateway/1` frames Watch ↔ iPhone WatchConnectivity messages: at
most 64 KiB, strict JSON (no duplicate names, no unknown members, known `type`
values only), `message_id` for gateway idempotency, and a named
`watch_device_id` that must match the iPhone's binding. Interactive operations
(`enrollment.request`, `enrollment.status`, `snapshot.fetch`, `changes.fetch`,
`approval.fetch`, `review.challenge`, `command.submit`, `command.query`) use
`sendMessageData` only. Background channels carry a `gateway.context` summary and
never a command.

## Rules an implementation cannot skip

- **Digests.** `request_hash = "sha256:" + lowercase_hex(SHA256(JCS(spec)))`,
  computed from the full spec by both the origin and the reviewing device.
  An advertised hash is never substituted for that computation.
- **Fail closed.** Duplicate JSON names, invalid Unicode, unknown command or
  operation types, and unsupported `required_features` are errors for
  mutations, not values to ignore.
- **One decision, one claim.** A non-pending resolution is immutable, and only
  one `consume_id` may ever claim an approved request. Retrying the same
  consume id returns the same permit and deadline.
- **Signatures.** JWS compact serialization, `alg=ES256` only, `kid=<device_id>`,
  `typ=shell-control+jws`, 64-byte `R || S` signatures, JCS-encoded payload
  bytes. `none`, key URLs, embedded keys, and unknown critical headers are
  rejected.
- **Idempotency.** `(account, device_id, command_id)` with a canonical payload
  hash. The recorded result is looked up before expiry is evaluated, so a
  legitimate retry after expiry retrieves the outcome instead of re-executing.
- **Push is a hint.** APNs carries identifiers and minimal display metadata
  only, and clients reconcile the snapshot and change stream after opening any
  notification.
