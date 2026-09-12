# shell-controld and shell-control

The host side: a per-user service that keeps a program blocked at its permission
gate until a decision arrives, and the CLI an adapter calls
([`../spec.watch.md`](../spec.watch.md) section 17).

## Platform

The daemon and CLI build and run on macOS today. The socket and IPC code is
written for macOS or Linux, but `ShellControlSecurity` uses CryptoKit, so a
Linux host needs that module ported to `swift-crypto` first; until then, do not
claim Linux support for an origin.

## Daemon

```sh
swift build -c release
SHELL_CONTROL_BROKER_URL=https://control.example \
SHELL_CONTROL_ORIGIN_ID=<lowercase-uuid> \
SHELL_CONTROL_ORIGIN_SECRET=<per-origin-secret> \
.build/release/shell-controld
```

Managed installs pass `--config /absolute/path/daemon.service.json` instead of
secrets on the command line. The process runs in the foreground (launchd owns
its lifetime), holds a singleton lock on the state directory, and refuses to
unlink a control socket that another live instance is serving. SIGTERM stops
accepting work, cancels heartbeats, and exits; a fifteen-second cooperative
budget is the target before the service manager kills the process.

A separate `health.sock` answers a same-user, read-only JSON snapshot. It does
not register a job or mint a run. After a restart, recovery receipts and
withdrawals are persisted with their original mutation IDs *before* the network
write and stay queued until the broker acknowledges them. Uncertain post-claim
effects are reported `unknown` and never replayed.

It listens on a Unix-domain socket under a private state directory (directory
mode 0700, socket mode 0600), verifies the peer's uid, and issues a per-run
unguessable capability. Frames are a four-byte big-endian length followed by one
UTF-8 JSON document of at most 64 KiB — never newline-delimited terminal data,
and never the PTY.

The origin credential is provisioned per host and is never distributed to
watchOS clients.

On start it reconciles its journal: anything claimed but never receipted is
reported `unknown` rather than replayed, and any request still unresolved from a
previous process is withdrawn, because safe continuation of the exact prior wait
cannot be proven. Those recovery writes are retried with the same identifiers
until acknowledged.

## CLI

```sh
shell-control notify --job "$JOB_ID" --title "Build finished"
shell-control request --spec-file request.json --wait --output json
shell-control receipt --run-capability "$CAP" --request "$ID" --result applied
```

stdout is machine-readable JSON only; diagnostics go to stderr. Exit codes are
`0` approved, `10` rejected, `11` expired, `12` cancelled, `13`
unavailable/unknown — and a zero status is not standing permission: the adapter
must validate the structured result and report what it applied by receipt.

See [`../adapters/`](../adapters) for two worked integrations.
