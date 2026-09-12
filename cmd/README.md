# Shell Control native host tools

The signed release contains three prebuilt macOS executables:

- `shell-control` — native management command tree and adapter client
- `shell-controld` — per-user origin daemon
- `shell-control-broker` — local broker

Runtime installation does not use Node, npm, a compiler, or a checkout. From the mounted signed disk image:

```sh
bin/shell-control setup                     # quick HTTPS tunnel
bin/shell-control setup --tunnel-mode loopback --no-watch
```

`setup` copies the complete verified bundle to `~/.local/lib/chr33s-shell/<release-id>/`, publishes `~/.local/bin/shell-control` without replacing unrelated files, and starts launchd jobs in the current graphical user domain. Closing the CLI does not stop them.

## Commands

```text
shell-control setup [--no-watch] [address options]
shell-control up [--rotate-url]
shell-control down
shell-control restart broker|daemon|tunnel|all
shell-control service install|uninstall
shell-control status [--check]
shell-control logs [broker|daemon|tunnel] [--follow]
shell-control pair [--watch]
shell-control confirm <USER-CODE> [--yes]
shell-control push configure --key-id ID --team-id ID --key-file /absolute/key.p8
shell-control push disable
shell-control notify --title TEXT [options]
shell-control request --spec-file /absolute/request.json [--wait]
shell-control receipt --run-capability CAP --result RESULT [options]
```

Use `--state-dir /absolute/path` before or after a subcommand, or `SHELL_CONTROL_STATE_DIR`, for an isolated native installation. The production default is `~/.local/state/shell-control`. Non-interactive `confirm` requires `--yes`.

Quick tunnels are development-only. A dead quick tunnel retains its old URL and reports degraded until `up --rotate-url` explicitly authorizes replacement. Login persistence requires named or external-proxy mode. `down` commits stopped intent, disables and unloads every owned job, and survives logout/login. `service uninstall` removes future-login registration without interrupting current jobs.

Named mode takes typed inputs rather than arbitrary YAML:

```sh
shell-control setup --tunnel-mode named \
  --public-url https://control.example \
  --tunnel-id 00000000-0000-0000-0000-000000000000 \
  --tunnel-credentials /absolute/tunnel.json \
  --cloudflared-path /opt/homebrew/bin/cloudflared
```

The CLI copies credentials to protected storage and generates exactly one host ingress rule plus the required 404 catch-all.

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
