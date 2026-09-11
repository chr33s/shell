# `@chr33s/shell`

Mac onboarding for the Shell control companion.

```sh
# from a chr33s/shell checkout (or npx github:chr33s/shell, which clones it)
npx @chr33s/shell
```

Starts a loopback broker, an HTTPS Cloudflare quick tunnel, and `shell-controld`,
prints a pairing QR and a short pairing code. Pending iPhone/Watch enrollments
are listed with their key fingerprint; type `y` to approve. There is no
auto-approve: a public tunnel would otherwise enrol strangers.

`npx @chr33s/shell down` stops the processes.

Requires macOS, Node 24+ (runs TypeScript natively), Swift 6.2 (first run builds the native tools from this tree),
and [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).
Without `cloudflared` the broker stays on `http://127.0.0.1`.

On the phone: **Settings → Control → Scan QR**. The pairing code on the phone
should match the token printed in the terminal.
