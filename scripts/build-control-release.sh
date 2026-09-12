#!/bin/bash
# Build a precompiled, architecture-specific Shell Control release bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
VERSION="${VERSION:-1.0.0}"
OUT="${2:-$ROOT/.derivedData/shell-control-$VERSION-$ARCH}"
case "$ARCH" in arm64|x86_64) ;; *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;; esac
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/licenses"
swift build -c release --arch "$ARCH" --package-path "$ROOT/cmd"
swift build -c release --arch "$ARCH" --package-path "$ROOT/services/shell-control"
HOST="$ROOT/cmd/.build/$ARCH-apple-macosx/release"
BROKER="$ROOT/services/shell-control/.build/$ARCH-apple-macosx/release/shell-control-broker"
cp "$HOST/shell-control" "$HOST/shell-controld" "$BROKER" "$OUT/bin/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$OUT/licenses/"
cp "$ROOT/cmd/README.md" "$OUT/README.md"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  for binary in shell-control shell-controld shell-control-broker; do
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$OUT/bin/$binary"
  done
fi
python3 - "$OUT/bin" "$ARCH" "$VERSION" <<'PY'
import hashlib,json,os,sys
root,arch,version=sys.argv[1:]
hashes={n:hashlib.sha256(open(os.path.join(root,n),'rb').read()).hexdigest() for n in ('shell-control','shell-controld','shell-control-broker')}
release=hashlib.sha256(('shell-control.native-release/1\n'+arch+'\n'+version+'\n'+''.join(f'{n}:{hashes[n]}\n' for n in sorted(hashes))).encode()).hexdigest()
json.dump({'release_id':f'{version}-{release[:16]}','architecture':arch,'minimum_os':'26.0','toolchain':os.popen('swift --version').read().splitlines()[0],'executables':hashes},open(os.path.join(root,'release-manifest.json'),'w'),indent=2,sort_keys=True);open(os.path.join(root,'release-manifest.json'),'a').write('\n')
PY
echo "$OUT"
