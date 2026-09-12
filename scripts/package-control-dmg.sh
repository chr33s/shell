#!/bin/bash
# Create, sign, notarize, and staple the native Shell Control disk image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:?usage: package-control-dmg.sh <release-bundle> [output.dmg]}"
BUNDLE="${BUNDLE%/}"
OUT="${2:-$BUNDLE.dmg}"
: "${DEVELOPER_ID_APPLICATION:?set DEVELOPER_ID_APPLICATION}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/shell-control-pkg.XXXXXX")"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rmdir "$MOUNT" 2>/dev/null || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
cp -a "$BUNDLE" "$STAGE/bundle"
BIN="$STAGE/bundle/bin"
for binary in shell-control shell-controld shell-control-broker; do
  path="$BIN/$binary"
  [[ -f "$path" ]] || { echo "missing $path" >&2; exit 2; }
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$path"
done
python3 - "$BIN" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
manifest_path = os.path.join(root, 'release-manifest.json')
with open(manifest_path) as handle:
    manifest = json.load(handle)
names = ('shell-control', 'shell-controld', 'shell-control-broker')
hashes = {name: hashlib.sha256(open(os.path.join(root, name), 'rb').read()).hexdigest() for name in names}
version = os.environ.get('VERSION') or str(manifest.get('release_id', '1.0.0')).rsplit('-', 1)[0]
arch = manifest.get('architecture', '')
release = hashlib.sha256(('shell-control.native-release/1\n' + arch + '\n' + version + '\n' + ''.join(f'{name}:{hashes[name]}\n' for name in sorted(hashes))).encode()).hexdigest()
manifest['executables'] = hashes
manifest['release_id'] = f'{version}-{release[:16]}'
with open(manifest_path, 'w') as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write('\n')
PY
TEMP="${OUT%.dmg}.rw.dmg"; rm -f "$TEMP" "$OUT"
hdiutil create -quiet -fs APFS -volname "Shell Control" -srcfolder "$STAGE/bundle" "$TEMP"
hdiutil convert -quiet "$TEMP" -format UDZO -o "$OUT"; rm -f "$TEMP"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$OUT"
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$OUT"
  spctl --assess --type open --context context:primary-signature -v "$OUT"
  MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/shell-control-dmg.XXXXXX")"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$OUT"
  for binary in "$MOUNT/bin/shell-control" "$MOUNT/bin/shell-controld" "$MOUNT/bin/shell-control-broker"; do
    codesign --verify --deep --strict --verbose=2 "$binary"
    spctl --assess --type execute --verbose=2 "$binary"
  done
else
  echo "NOTARYTOOL_PROFILE is required for a distributable artifact" >&2; exit 2
fi
shasum -a 256 "$OUT" > "$OUT.sha256"
echo "$OUT"
