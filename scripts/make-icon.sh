#!/usr/bin/env bash
# Draw the Disklessly app icon and build Resources/AppIcon.icns.
#
# The icon is the blue rounded "256" tile from the dashboard header. A small
# Swift script draws the 1024 px master with CoreGraphics and CoreText (no
# Python, no image editor), sips scales it into an .iconset, and iconutil packs
# the .icns. The outputs are committed, so a normal build does not need this;
# scripts/build-app.sh runs it only when Resources/AppIcon.icns is missing.
#
#   Resources/AppIcon-1024.png   master image
#   Resources/AppIcon.icns       copied into the app bundle (CFBundleIconFile)
#
# Usage: scripts/make-icon.sh [OUTPUT_DIR]     (default <repo>/Resources)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/Resources}"
[[ "$(uname -s)" == Darwin ]] || { echo "make-icon: needs macOS" >&2; exit 69; }
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/draw.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import CoreText
import Foundation

let output = CommandLine.arguments[1]
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("make-icon: could not create a bitmap context")
}
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                            CGFloat(hex & 0xff) / 255, alpha])!
}

// macOS icon grid: an 824 px tile centred on the 1024 canvas, corner radius about 22.5%.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.30))
ctx.addPath(path)
ctx.setFillColor(rgb(0x0A7AFF))
ctx.fillPath()
ctx.restoreGState()

// Blue vertical gradient around the dashboard tile colour (#0A7AFF).
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x4DA3FF), rgb(0x0A7AFF), rgb(0x0060DF)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
// A faint highlight along the top edge.
let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.midY), options: [])
ctx.restoreGState()

// "256" in heavy rounded white type, sized to fill most of the tile width.
let base = NSFont.systemFont(ofSize: 100, weight: .heavy)
let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
func line(_ pointSize: CGFloat) -> CTLine {
    let f = NSFont(descriptor: descriptor, size: pointSize) ?? base
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white, .kern: -pointSize * 0.02]
    return CTLineCreateWithAttributedString(NSAttributedString(string: "256", attributes: attrs))
}
let probe = CTLineGetBoundsWithOptions(line(100), .useGlyphPathBounds)
let text = line(100 * (tile.width * 0.72) / probe.width)
let bounds = CTLineGetBoundsWithOptions(text, .useGlyphPathBounds)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x00306E, 0.35))
ctx.textPosition = CGPoint(x: tile.midX - bounds.width / 2 - bounds.minX, y: tile.midY - bounds.height / 2 - bounds.minY)
CTLineDraw(text, ctx)
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("make-icon: no image") }
guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("make-icon: PNG encoding failed")
}
try png.write(to: URL(fileURLWithPath: output))
SWIFT

MASTER="$OUT/AppIcon-1024.png"
/usr/bin/swift "$WORK/draw.swift" "$MASTER"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for pt in 16 32 128 256 512; do
  /usr/bin/sips -s format png -z "$pt" "$pt" "$MASTER" --out "$SET/icon_${pt}x${pt}.png" >/dev/null
  px=$((pt * 2))
  /usr/bin/sips -s format png -z "$px" "$px" "$MASTER" --out "$SET/icon_${pt}x${pt}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
echo "wrote $MASTER and $OUT/AppIcon.icns"
