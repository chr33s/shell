#!/bin/bash
# Generates the ShellWatch app icon from icon.svg.
#
# The watch masks its icon to a circle, so the square artwork cannot be used
# full-bleed: the corners of the terminal frame fall outside the circle. This
# script re-composes the same drawing over a solid backdrop, scaled down so the
# whole frame clears the mask, and rasterises the result.
#
# Usage: scripts/generate-watch-icon.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="icon.svg"
OUT="ShellWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fraction of the square the artwork is scaled to. The outermost stroked frame
# sits at radius 546 of a 1024 canvas, so it needs at most 512/546 to clear the
# circular mask; the value below leaves a little margin beyond that.
SCALE=0.86
# The artwork's own Blackboard background, extended to the full square.
BACKDROP="#0C1021"

python3 - "$SOURCE" "$WORK/watch.svg" "$SCALE" "$BACKDROP" <<'PY'
import re, sys

source, dest, scale, backdrop = sys.argv[1:5]
svg = open(source, encoding="utf-8").read()

# The whole top-level <g id="shell"> element, kept intact so that the
# fill/stroke defaults it carries still apply.
artwork = svg[svg.index('<g id="shell"'):svg.rindex("</g>") + len("</g>")]

open(dest, "w", encoding="utf-8").write(
    f'<?xml version="1.0" encoding="UTF-8"?>\n'
    f'<svg width="1024px" height="1024px" viewBox="0 0 1024 1024" version="1.1"'
    f' xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n'
    f'    <title>shell watch</title>\n'
    f'    <rect x="0" y="0" width="1024" height="1024" fill="{backdrop}"/>\n'
    f'    <g transform="translate(512, 512) scale({scale}) translate(-512, -512)">'
    f'{artwork}</g>\n'
    f'</svg>\n'
)
PY

mkdir -p "$(dirname "$OUT")"
cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let side = Int(CommandLine.arguments[3])!

guard let image = NSImage(contentsOfFile: source) else {
    fatalError("could not read \(source)")
}
image.size = NSSize(width: side, height: side)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
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

swift "$WORK/render.swift" "$WORK/watch.svg" "$OUT" 1024
echo "wrote $OUT"
