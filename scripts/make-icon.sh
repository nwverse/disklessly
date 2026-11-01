#!/usr/bin/env bash
# Draw the Disklessly app icon and build Resources/AppIcon.icns.
#
# The icon follows the menu-bar symbol (a drive with a cloud) in the macOS icon
# style: one centred glyph, a white cloud behind a translucent glass drive, light
# from above, soft shadows and no outlines. A small Swift script draws the 1024 px
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
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
func vertical(_ path: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: extend)
    ctx.restoreGState()
}
/// A light rim just inside the top edge of `path`, fading out downward: the specular edge of glass.
func rim(_ path: CGPath, width: CGFloat, top: CGFloat, bottom: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(path.copy(strokingWithWidth: width * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, alpha, 0), (0xFFFFFF, 0, 1)]), start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
}

// 1. Tile: the macOS icon grid, 824 pt square with continuous-looking corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x2A6FF2)); ctx.fillPath()
ctx.restoreGState()
vertical(tilePath, gradient([(0x6CC4FF, 1, 0), (0x2F7BFF, 1, 0.55), (0x1B4FD8, 1, 1)]), top: tile.maxY, bottom: tile.minY)
// Light from above.
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.30, 0), (0xFFFFFF, 0, 1)]), startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
ctx.restoreGState()
rim(tilePath, width: 5, top: tile.maxY, bottom: tile.midY, alpha: 0.45)

let dy: CGFloat = -22   // shifts the whole glyph so it sits optically centred

// 2. Cloud, behind: solid white, soft shadow, no outline.
func cloudPath() -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: CGRect(x: 252, y: 452 + dy, width: 520, height: 196), cornerWidth: 98, cornerHeight: 98)
    p.addEllipse(in: CGRect(x: 322, y: 540 + dy, width: 196, height: 196))
    p.addEllipse(in: CGRect(x: 418, y: 512 + dy, width: 300, height: 300))
    return p
}
let cloud = cloudPath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: rgb(0x0A2A7A, 0.32))
ctx.addPath(cloud); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
vertical(cloud, gradient([(0xFFFFFF, 1, 0), (0xF2F7FF, 1, 0.6), (0xD9E7FF, 1, 1)]), top: 812 + dy, bottom: 452 + dy)

// 3. Drive, in front: a glass slab. Translucent, so the cloud shows through its top
//    and the blue through its bottom; a bright top edge and a soft shadow lift it.
let drive = CGRect(x: 232, y: 268 + dy, width: 560, height: 236)
let drivePath = CGPath(roundedRect: drive, cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 44, color: rgb(0x061F66, 0.40))
ctx.addPath(drivePath); ctx.setFillColor(rgb(0xFFFFFF, 0.01)); ctx.fillPath()
ctx.restoreGState()
// Frosted body: a cool white wash that is denser at the top.
vertical(drivePath, gradient([(0xFFFFFF, 0.80, 0), (0xF0F6FF, 0.66, 0.5), (0xD2E3FF, 0.58, 1)]), top: drive.maxY, bottom: drive.minY)
// A faint darker band along the bottom gives the slab thickness.
ctx.saveGState(); ctx.addPath(drivePath); ctx.clip()
ctx.drawLinearGradient(gradient([(0x0B2C8A, 0.0, 0), (0x0B2C8A, 0.12, 1)]), start: CGPoint(x: 0, y: drive.minY + 60), end: CGPoint(x: 0, y: drive.minY), options: [])
ctx.restoreGState()
rim(drivePath, width: 4, top: drive.maxY, bottom: drive.minY + 40, alpha: 1.0)
// A hairline all round so the glass edge reads against the blue.
ctx.saveGState()
ctx.addPath(drivePath); ctx.clip()
ctx.addPath(drivePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
ctx.restoreGState()
// Front face details: a slim status bar and a light.
let bar = CGRect(x: drive.minX + 72, y: drive.minY + 96, width: 168, height: 30)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 15, cornerHeight: 15, transform: nil))
ctx.setFillColor(rgb(0x2457D6, 0.42)); ctx.fillPath()
ctx.restoreGState()
let led = CGRect(x: drive.maxX - 72 - 34, y: drive.minY + 94, width: 34, height: 34)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x38E0A0, 0.95))
ctx.setFillColor(rgb(0x3BE6A6)); ctx.fillEllipse(in: led)
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
