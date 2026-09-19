# Shell Control native host tools

The signed release contains three prebuilt macOS executables:

- `shell-control` — native management command tree and adapter client
- `shell-controld` — per-user origin daemon
- `shell-control-broker` — local broker

Runtime installation does not use Node, npm, a compiler, or a checkout. From the mounted signed disk image:

```sh
bin/shell-control setup                     # iPhone-gateway profile over Tailscale
bin/shell-control setup --mode loopback --no-watch   # local development with the simulator
```

Tailscale is the only way a phone reaches the Mac. The default `tailscale` mode is the iPhone-gateway profile of
[`spec.iphone-gateway.md`](../spec.iphone-gateway.md): it checks that Tailscale is
installed, connected, and has MagicDNS; keeps the broker on `127.0.0.1`; points
Tailscale Serve's HTTPS 443 at it; verifies the resulting Serve state (and refuses
Funnel); creates the Mac's origin signing key under `credentials/`; and prints a
one-use pairing QR that pins the origin identity. There is no public listener,
hostname, tunnel, or reverse proxy. `loopback` mode serves `http://127.0.0.1` for
the simulator only.

`setup` copies the complete verified bundle to `~/.local/lib/chr33s-shell/<release-id>/`, publishes `~/.local/bin/shell-control` without replacing unrelated files, and starts launchd jobs in the current graphical user domain. Closing the CLI does not stop them.

## Commands

```text
shell-control setup [--no-watch] [--mode tailscale|loopback] [--port N] [--tailscale-path PATH] [--reset-origin-key]
shell-control up
shell-control down
shell-control restart broker|daemon|all
shell-control service install|uninstall
shell-control status [--check] [--text]
shell-control logs [broker|daemon] [--follow]
shell-control pair [--watch]
shell-control route
shell-control confirm <USER-CODE> [--yes]
shell-control revoke <DEVICE-ID>
shell-control push configure --relay-url https://relay.example
shell-control push configure --key-id ID --team-id ID --key-file /absolute/key.p8
shell-control push disable
shell-control notify --title TEXT [options]
shell-control request --spec-file /absolute/request.json [--wait]
shell-control receipt --run-capability CAP --result RESULT [options]
```

Use `--state-dir /absolute/path` before or after a subcommand, or `SHELL_CONTROL_STATE_DIR`, for an isolated native installation. The production default is `~/.local/state/shell-control`. Non-interactive `confirm` requires `--yes`.

`pair` mints a fresh one-use, ten-minute pairing and prints its QR; `confirm`
approves the iPhone pairing or Watch reviewer the phone or Watch displays, after
showing its label, key fingerprint, and permissions (a Watch also shows its
gateway iPhone). `route` prints the origin-signed route-update QR for the current
Tailscale name: scanning it changes routing only, never trust. `up` re-reads the
MagicDNS name, so a renamed Mac is a route change, not a re-pairing. The origin
key is never regenerated silently: if it goes missing, setup stops, and
`--reset-origin-key` is the explicit way to mint a new one (every device must then
pair again). `revoke` disables an iPhone (and with it the transport of every
Watch it gateways for) or a single Watch reviewer. `push configure --relay-url`
sends approval hints through the stateless Shell Push Relay; the Mac then holds
no APNs credential.

Login persistence requires tailscale mode. `down` commits stopped intent, disables and unloads every owned job, and survives logout/login. `service uninstall` removes future-login registration without interrupting current jobs.

An installation made by an earlier release with a Cloudflare tunnel mode is migrated to `tailscale` by the next `setup`, which also stops and removes the old cloudflared job and its files. Devices paired against the old public URL must pair again from the new QR.

Adapter stdout is JSON. Permission authority remains the structured `shell-control/1` permit and exact run/request context—not an exit status. `request --wait` exits 0/10/11/12/13 for approved/rejected/expired/cancelled/unavailable.

## Development and release

```sh
swift test --package-path cmd
./scripts/test-lifecycle.sh
./scripts/build-control-release.sh arm64
./scripts/build-control-release.sh x86_64
DEVELOPER_ID_APPLICATION='Developer ID Application: …' NOTARYTOOL_PROFILE=shell \
  ./scripts/package-control-dmg.sh .derivedData/shell-control-1.0.0-arm64
```

`swift-argument-parser` is pinned and vendored under `vendor/`. Release manifests bind architecture, minimum OS, toolchain, release identity, and hashes of all three executables. CI must run the native tests on each advertised macOS 26 architecture and retain notarization/Gatekeeper evidence; physical Watch gates remain separate release evidence.
