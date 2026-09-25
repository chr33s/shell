#!/bin/bash
# Mint a one-use pairing on the development broker and print the
# `shell-control://pair?invite=` link for the iPhone simulator.
#
# Usage: ./scripts/dev-pair.sh [port]
#
# The invitation pins the dev broker's origin key and a loopback route, the
# same shape `shell-control setup` prints for a Tailscale route
# (docs/specs/control-protocol.md section 5.2). Paste the link into Settings → Control
# in the simulator, then confirm the code with ./scripts/dev-confirm.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8443}"
# shellcheck disable=SC1090
. "$ROOT/.derivedData/dev-broker.env"
KEY="$ROOT/.derivedData/dev-origin-key.pem"

PAIRING="$(curl -sS -X POST -H "Authorization: Admin ${SHELL_CONTROL_ADMIN_SECRET}" \
    "http://127.0.0.1:${PORT}/v1/admin/pairings")"
PUBLIC_HEX="$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 64 | xxd -p -c 128)"

python3 - "$PAIRING" "$PUBLIC_HEX" "$SHELL_CONTROL_ORIGIN_ID" "$PORT" <<'PY'
import base64, hashlib, json, sys
pairing, public_hex, origin_id, port = json.loads(sys.argv[1]), bytes.fromhex(sys.argv[2]), sys.argv[3], sys.argv[4]
b64 = lambda data: base64.urlsafe_b64encode(data).rstrip(b"=").decode()
jwk = {"crv": "P-256", "kty": "EC", "x": b64(public_hex[:32]), "y": b64(public_hex[32:])}
invite = {
    "v": 1, "type": "shell-control.pairing", "origin_id": origin_id, "origin_public_jwk": jwk,
    "route": f"http://127.0.0.1:{port}", "pairing_id": pairing["pairing_id"],
    "pairing_secret": pairing["pairing_secret"], "expires_at": pairing["expires_at"],
}
canonical = json.dumps(jwk, separators=(",", ":"), sort_keys=True).encode()
print("fingerprint SHA256:" + hashlib.sha256(canonical).hexdigest())
print("expires     " + pairing["expires_at"])
print("shell-control://pair?invite=" + b64(json.dumps(invite, separators=(",", ":"), sort_keys=True).encode()))
PY
