# push-relay (Shell Push Relay)

The optional, stateless APNs sender of
[`../../spec.iphone-gateway.md`](../../spec.iphone-gateway.md) section 16. It is
not a control broker: it stores and decides nothing — no approvals, decisions,
consumes, receipts, jobs, run state, origin presence, or terminal data — and it
depends only on the portable protocol and signing code, never on approval-state
storage. A deployment without it is fully correct; it only lacks prompt remote
alerts while the Shell iOS app is suspended.

## Flow

1. The iPhone sends its APNs token, topic, and environment to
   `POST /v1/capabilities` and receives a **push capability**: a relay-signed
   (`ES256`) token holding the APNs token, topic, environment, capability ID,
   expiry (30 days), rate class, and the one notification schema it allows.
2. The iPhone hands the capability to its Mac over Tailscale
   (`PUT /v1/devices/me/push-capability`). The relay never learns which Mac.
3. When a request is published, the Mac posts `POST /v1/push` with the
   capability, event (`approval.created`), request and origin IDs, collapse ID,
   and presentation class. The relay verifies its own signature, expiry, and a
   per-capability rate limit, **builds the generic payload itself**, and sends it
   only to the token and topic sealed in the capability. It accepts no topic and
   no alert text from the caller.

The notification is a hint. Tapping it opens a review that fetches live state
from the Mac; the payload authorizes nothing.

## Running it

```sh
swift build -c release
SHELL_RELAY_SIGNING_KEY_FILE=/absolute/relay-signing-key.pem \
SHELL_RELAY_APNS_TOPICS=dev.chr33s.shell \
SHELL_RELAY_APNS_KEY_ID=ABC123DEFG SHELL_RELAY_APNS_TEAM_ID=TEAM123456 \
SHELL_RELAY_APNS_KEY_FILE=/absolute/AuthKey.p8 \
.build/release/shell-push-relay
```

| Variable | Meaning |
|---|---|
| `SHELL_RELAY_SIGNING_KEY_FILE` | P-256 PEM key that signs capabilities. Rotating it invalidates every capability; phones re-register on their next token callback. |
| `SHELL_RELAY_APNS_TOPICS` | Comma-separated app topics a capability may be minted for. |
| `SHELL_RELAY_APNS_KEY_ID`, `SHELL_RELAY_APNS_TEAM_ID`, `SHELL_RELAY_APNS_KEY_FILE` | APNs provider token credentials. They live here and nowhere else. |
| `SHELL_RELAY_PORT` | Listen port (default 8080). |
| `SHELL_RELAY_BIND` | `any` to listen beyond loopback; otherwise it binds `127.0.0.1` behind a TLS front end. |
| `SHELL_RELAY_CLIENT_ADDRESS_HEADER` | The header the TLS front end sets to the client address (e.g. `x-forwarded-for`), so capability requests are rate-limited per client. The last entry is used: it is the one the front end appended, so the front end must append rather than pass the client's header through. Without it a non-loopback peer is the client; a loopback peer is the proxy, and all clients share one wider bucket. |

The listener speaks plain HTTP and must sit behind TLS termination. Point the
Mac at it with `shell-control push configure --relay-url https://…` and the phone
with `SHELL_CONTROL_PUSH_RELAY_URL` (see the repository README).
