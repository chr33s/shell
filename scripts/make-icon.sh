#!/bin/bash
# Regenerate the app icon layer from icon.svg, the source of truth.
#
# AppIcon.icon holds a single full-bleed layer built from icon.svg. Two of the
# SVG's paths are swapped for a full-canvas rect: the soft outer shape and the
# blue rounded rectangle. They sit inside a transparent margin, so keeping them
# would nest a second, smaller rounded square inside the system's icon mask.
# The replacement rect paints the same blue edge to edge and the mask rounds it.
#
# The background is baked into the layer rather than left to icon.json's
# fill-specializations: actool flattens .icon bundles for the pre-26 deployment
# target, and the flattened output composites layers only — a fill-only
# background renders transparent there.
#
# Usage: ./scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/icon.svg"
OUT="$ROOT/AppIcon.icon/Assets/shell.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# Swap the two background paths for a full-canvas rect of the same blue.
python3 - "$SRC" "$WORK/layer.svg" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
BACKGROUND = '#236DF1'
s = open(src).read()
for colour in ('#DDE4EC', BACKGROUND):
    s = re.sub(r'\s*<path [^>]*fill="%s"[^>]*></path>' % colour, '', s)
    if colour in s:
        raise SystemExit("icon.svg: could not remove background path %s" % colour)
rect = '<rect x="0" y="0" width="1024" height="1024" fill="%s"/>' % BACKGROUND
marker = '<g id="shell" stroke="none" fill="none"'
if marker not in s:
    raise SystemExit("icon.svg: root group not found")
open(dst, 'w').write(s.replace(marker, rect + marker, 1))
PY

# 2048 px so the layer renders at 2x on the 1024 pt Icon Composer canvas
# (icon.json pairs this with "scale": 0.5).
qlmanage -t -s 2048 -o "$WORK" "$WORK/layer.svg" >/dev/null 2>&1
[ -f "$WORK/layer.svg.png" ] || { echo "qlmanage produced no thumbnail" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$WORK/layer.svg.png" "$OUT"
echo "wrote $OUT ($(sips -g pixelWidth "$OUT" | tail -1 | tr -d ' '))"
