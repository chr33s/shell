#!/bin/bash
# Regenerate the app icon artwork from icon.svg, the source of truth.
#
# Writes three files:
#   AppIcon.icon/Assets/shell.png                           2048 px Icon Composer layer
#   shell/Assets.xcassets/AppIcon.appiconset/icon-1024.png  1024 px iOS marketing icon
#   icon.png                                                1024 px README logo
#
# The first two share a full-bleed intermediate layer. The README logo instead
# renders icon.svg untouched, keeping the rounded rectangle and the transparent
# margin around it so the logo sits on the page rather than filling a square.
#
# AppIcon.icon holds a single full-bleed layer built from icon.svg. Two of the
# SVG's paths are swapped for a full-canvas rect: the soft outer shape and the
# dark rounded rectangle. They sit inside a transparent margin, so keeping them
# would nest a second, smaller rounded square inside the system's icon mask.
# The replacement rect paints the same background edge to edge and the mask rounds it.
#
# The background is baked into the layer rather than left to icon.json's
# fill-specializations. The original reason — actool flattening .icon bundles
# for a pre-26 deployment target, where a fill-only background renders
# transparent — no longer applies at a 26 floor, but flattened representations
# may still be produced; verify the rendered icon before removing the baked rect.
#
# Usage: ./scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/icon.svg"
OUT="$ROOT/AppIcon.icon/Assets/shell.png"
IOS_OUT="$ROOT/shell/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
README_OUT="$ROOT/icon.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# Swap the two background paths for a full-canvas rect of the same background colour.
python3 - "$SRC" "$WORK/layer.svg" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
BACKGROUND = '#0C1021'
s = open(src).read()
for colour in ('#1E2840', BACKGROUND):
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

# Both remaining PNGs render through AppKit rather than qlmanage, which flattens
# every thumbnail onto opaque white. render.swift takes a trailing "opaque" or
# "alpha" argument to pick the bitmap format.
#
# The iOS marketing icon is the same full-bleed square at 1024 px, but must ship
# without an alpha channel or App Store validation rejects it, so it renders
# opaque. iOS applies its own corner mask, so the artwork stays square here.
cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let side = Int(CommandLine.arguments[3])!

guard let image = NSImage(contentsOfFile: source) else {
    fatalError("could not read \(source)")
}
image.size = NSSize(width: side, height: side)

// "opaque" renders onto a 32 bpp bitmap with the alpha byte skipped, not 24:
// CGBitmapContext has no 24 bpp layout, and asking for one yields a nil context
// that silently renders black. "alpha" keeps the SVG's transparent margin.
let opaque = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "opaque"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: opaque ? 3 : 4, hasAlpha: !opaque, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
) else { fatalError("could not allocate bitmap") }
rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: destination))
SWIFT

mkdir -p "$(dirname "$IOS_OUT")"
swift "$WORK/render.swift" "$WORK/layer.svg" "$IOS_OUT" 1024 opaque
echo "wrote $IOS_OUT ($(sips -g pixelWidth "$IOS_OUT" | tail -1 | tr -d ' '))"

# The README logo renders icon.svg as authored, so it keeps the rounded corners
# and the transparent margin around them. It renders with alpha so the margin
# stays transparent and the logo sits on the page in either GitHub theme.
swift "$WORK/render.swift" "$SRC" "$README_OUT" 1024 alpha
echo "wrote $README_OUT ($(sips -g pixelWidth "$README_OUT" | tail -1 | tr -d ' '))"
