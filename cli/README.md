# `@chr33s/shell`

Mac onboarding for the Shell control companion. The CLI is a management and
enrollment interface, not a network relay. Once setup reports readiness, closing
the terminal does not stop the broker, origin daemon, or managed tunnel.

```sh
npx @chr33s/shell
```

Starts (or reuses) a loopback broker, an HTTPS tunnel, and `shell-controld`,
then prints a pairing QR and a short pairing code. Pending iPhone/Watch
enrollments are listed with their key fingerprint; type `y` to approve. There is
no auto-approve: a public tunnel would otherwise enrol strangers.

Non-TTY setup prints the `confirm` command and returns after readiness.

## Commands

```sh
npx @chr33s/shell setup --no-watch
npx @chr33s/shell pair --watch
npx @chr33s/shell status
npx @chr33s/shell status --check
npx @chr33s/shell logs broker --follow
npx @chr33s/shell down          # stays down until up
npx @chr33s/shell up
npx @chr33s/shell restart broker|daemon|tunnel|all
```

`status` is read-only JSON and never prints the pairing token. Use `pair` for
that. `down` disables automatic relaunch as well as unloading jobs.

## Persistent setup

Quick tunnels get a random `*.trycloudflare.com` hostname and are for
development. Login persistence requires a stable HTTPS address:

```sh
npx @chr33s/shell setup --tunnel-mode named \
  --public-url https://control.example.com \
  --tunnel-config /absolute/path/cloudflared.yml --no-watch
npx @chr33s/shell service install
npx @chr33s/shell pair --watch
```

`--tunnel-mode external-proxy` is the same public identity without a
Shell-owned tunnel process. `service install` writes per-user launchd agents
under `~/Library/LaunchAgents/` that resume after login (not before login).
`service uninstall` removes those agents and keeps configuration, enrollment,
and journals.

A dead quick-tunnel URL is never replaced silently. Use `setup --rotate-url`
and re-pair every device.

## Layout

State lives in `~/.local/state/shell-control/` (override with
`SHELL_CONTROL_STATE_DIR`). Installed binaries live in
`~/.local/lib/chr33s-shell/`. Services log under `logs/`; rotating those files
never touches `broker.json` or `dispatch-journal.ndjson`.

Requires macOS, Node 24+ (runs TypeScript natively), Swift 6.2 (first run builds
the native tools from this tree), and
[`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
for a public URL. Without `cloudflared` the broker stays on `http://127.0.0.1`,
which a physical Watch cannot reach.

On the phone: **Settings → Control → Scan QR**. The pairing code on the phone
should match the token printed by `pair`.
