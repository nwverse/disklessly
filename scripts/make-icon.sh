#!/usr/bin/env bash
# Draw the Disklessly app icon and build Resources/AppIcon.icns.
#
# The icon is the menu-bar glyph on a blue tile: a white outline drive with a
# solid cloud at its lower left, cut out from the drive by a small gap. The paths
# are our own drawing of that shape (SF Symbols may not be used in app icons). A small Swift script draws the 1024 px
# master with CoreGraphics (no Python, no image editor), sips scales it into an
# .iconset, and iconutil packs the .icns. The outputs are committed, so a normal build does not need this;
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
import Foundation

let output = CommandLine.arguments[1]
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha])!
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

// Tile on the macOS icon grid.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x2A6FF2)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([(0x5FBBFF, 1, 0), (0x2B78FF, 1, 0.55), (0x1A4CD6, 1, 1)]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.26, 0), (0xFFFFFF, 0, 1)]), startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 980), endRadius: 600, options: [])
ctx.restoreGState()

// The glyph is laid out in a 1120 x 702 design box (y down) and placed centred on the tile.
let box = CGRect(x: 115, y: 123, width: 1120, height: 702)
let k: CGFloat = 640 / box.width
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: 512 + (x - box.midX) * k, y: 512 + (box.midY - y) * k)
}
func R(_ r: CGFloat) -> CGFloat { r * k }
let stroke = R(62)

// Drive: the top (a trapezoid whose sides lean out) and the front slab with its light.
let top = CGMutablePath()
top.move(to: P(412, 440))
top.addLine(to: P(476, 228))
top.addQuadCurve(to: P(612, 150), control: P(505, 150))
top.addLine(to: P(936, 150))
top.addQuadCurve(to: P(1072, 228), control: P(1043, 150))
top.addLine(to: P(1180, 500))
top.addQuadCurve(to: P(1203, 613), control: P(1203, 550))
let slab = CGPath(roundedRect: CGRect(x: P(300, 758).x, y: P(300, 758).y, width: R(1203 - 300), height: R(758 - 469)),
                  cornerWidth: R(144.5), cornerHeight: R(144.5), transform: nil)
let dot = CGRect(x: P(1000, 662).x, y: P(1000, 662).y, width: R(98), height: R(98))

// Cloud, filled.
let cloud = CGMutablePath()
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) { cloud.addEllipse(in: CGRect(x: P(cx - r, cy + r).x, y: P(cx - r, cy + r).y, width: R(2 * r), height: R(2 * r))) }
circle(235, 712, 113)
circle(272, 612, 80)
circle(410, 628, 155)
circle(515, 722, 103)
cloud.addRect(CGRect(x: P(235, 825).x, y: P(235, 825).y, width: R(280), height: R(125)))

// Draw the glyph in its own layer so the gap around the cloud cuts through the drive only.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x08236E, 0.38))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.addPath(top); ctx.strokePath()
ctx.addPath(slab); ctx.strokePath()
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: dot)
// Gap: clear the cloud grown by the gap width.
ctx.setBlendMode(.clear)
ctx.addPath(cloud); ctx.fillPath()
ctx.addPath(cloud.copy(strokingWithWidth: R(100), lineCap: .round, lineJoin: .round, miterLimit: 1)); ctx.fillPath()
ctx.setBlendMode(.normal)
ctx.addPath(cloud); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("png") }
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
