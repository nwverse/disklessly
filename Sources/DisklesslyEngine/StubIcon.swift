import Foundation
import DisklesslyCore
#if os(macOS)
import AppKit
#endif

/// Copies an app icon into a stub and keeps a 256×256 PNG for the UI and other Macs.
enum StubIcon {
    static let resourceName = "AppIcon.icns"

    #if os(macOS)
    /// Writes the PNG cache without a stub bundle. A failure is a warning.
    static func cacheOnly(from app: URL, imageId: String, stateDir: String, publish: (Data) -> Void) {
        let info = readPlist(app.appendingPathComponent("Contents/Info.plist")) ?? [:]
        let keys = AppIcon.plistKeys(info)
        if let file = keys.file, let icns = AppIcon.icnsURL(app: app, fileKey: file), let image = NSImage(contentsOf: icns) {
            storePNG(image, imageId: imageId, stateDir: stateDir, publish: publish)
        } else {
            storePNG(NSWorkspace.shared.icon(forFile: app.path), imageId: imageId, stateDir: stateDir, publish: publish)
        }
    }

    /// Best-effort. A failure is a warning and does not fail pack or refresh.
    static func capture(from app: URL, into stub: URL, imageId: String, stateDir: String, publish: (Data) -> Void) {
        do {
            try install(from: app, into: stub, imageId: imageId, stateDir: stateDir, publish: publish)
        } catch {
            warn("could not copy the app icon from \(app.path): \(error.localizedDescription)")
        }
    }

    /// Fills a stub that has no `.icns`. Uses a mounted or on-disk original, then the cached PNG.
    static func backfill(stub: URL, imageId: String, stateDir: String, originals: [URL], publish: (Data) -> Void) {
        if hasIconFile(stub) {
            ensureCache(from: stub, imageId: imageId, stateDir: stateDir, publish: publish)
            return
        }
        for original in originals where isRealApp(original) {
            capture(from: original, into: stub, imageId: imageId, stateDir: stateDir, publish: publish)
            if hasIconFile(stub) { return }
        }
        guard let cache = AppIcon.cacheURL(stateDir: stateDir, imageId: imageId),
              FileManager.default.fileExists(atPath: cache.path),
              let image = NSImage(contentsOf: cache) else {
            warn("stub \(stub.path) has no icon")
            return
        }
        do {
            let dest = stub.appendingPathComponent("Contents/Resources").appendingPathComponent(resourceName)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeICNS(cloudBadged(image), to: dest)
            try setIconFile(stub)
            touch(stub)
        } catch {
            warn("could not rebuild the stub icon from \(cache.path): \(error.localizedDescription)")
        }
    }

    /// Rebuilds the stub's `AppIcon.icns` from the cached 256 px PNG, always with the cloud badge.
    /// Returns false when there is no cached PNG to rebuild from.
    static func rebadgeFromCache(stub: URL, imageId: String, stateDir: String) throws -> Bool {
        guard let cache = AppIcon.cacheURL(stateDir: stateDir, imageId: imageId),
              FileManager.default.fileExists(atPath: cache.path),
              let image = NSImage(contentsOf: cache) else { return false }
        let dest = stub.appendingPathComponent("Contents/Resources").appendingPathComponent(resourceName)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeICNS(cloudBadged(image), to: dest)
        try setIconFile(stub)
        touch(stub)
        return true
    }

    static func touch(_ bundle: URL) {
        let now = Date()
        let fm = FileManager.default
        for path in [bundle.path, bundle.appendingPathComponent("Contents").path, bundle.appendingPathComponent("Contents/Info.plist").path] {
            try? fm.setAttributes([.modificationDate: now], ofItemAtPath: path)
        }
    }

    static func register(_ bundle: URL) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        do {
            try ProcessRunner.run(tool, ["-f", bundle.path])
        } catch {
            warn("lsregister failed: \(error.localizedDescription)")
        }
    }

    static func originals(mountRoot: String, imageId: String, stub: URL, recordedPath: String?) -> [URL] {
        var urls: [URL] = []
        let mount = URL(fileURLWithPath: mountRoot).appendingPathComponent(imageId)
        if let children = try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: children.filter { $0.pathExtension == "app" })
        }
        urls.append(stub.deletingPathExtension().appendingPathExtension("256orig.app"))
        if let recordedPath, !recordedPath.isEmpty {
            urls.append(URL(fileURLWithPath: recordedPath))
        }
        return urls
    }

    private static func install(from app: URL, into stub: URL, imageId: String, stateDir: String, publish: (Data) -> Void) throws {
        let info = readPlist(app.appendingPathComponent("Contents/Info.plist")) ?? [:]
        let keys = AppIcon.plistKeys(info)
        let resources = stub.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let dest = resources.appendingPathComponent(resourceName)
        if let file = keys.file, let icns = AppIcon.icnsURL(app: app, fileKey: file) {
            if let image = NSImage(contentsOf: icns) {
                // The stub shows the cloud badge in Finder and Launchpad.
                try writeICNS(cloudBadged(image), to: dest)
                storePNG(image, imageId: imageId, stateDir: stateDir, publish: publish)
            } else {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: icns, to: dest)
                warn("copied \(icns.lastPathComponent) but could not render a PNG cache")
            }
        } else {
            let image = NSWorkspace.shared.icon(forFile: app.path)
            try writeICNS(cloudBadged(image), to: dest)
            storePNG(image, imageId: imageId, stateDir: stateDir, publish: publish)
        }
        try setIconFile(stub)
        touch(stub)
    }

    private static func ensureCache(from stub: URL, imageId: String, stateDir: String, publish: (Data) -> Void) {
        guard AppIcon.cacheURL(stateDir: stateDir, imageId: imageId).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? false else { return }
        guard let file = readPlist(stub.appendingPathComponent("Contents/Info.plist")).flatMap({ AppIcon.plistKeys($0).file }),
              let icns = AppIcon.icnsURL(app: stub, fileKey: file),
              let image = NSImage(contentsOf: icns) else { return }
        storePNG(image, imageId: imageId, stateDir: stateDir, publish: publish)
    }

    private static func storePNG(_ image: NSImage, imageId: String, stateDir: String, publish: (Data) -> Void) {
        guard let png = pngData(image, pixels: 256), let destination = AppIcon.cacheURL(stateDir: stateDir, imageId: imageId) else {
            warn("could not render a 256×256 icon for \(imageId)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            publish(png)
        } catch {
            warn("could not store the icon cache: \(error.localizedDescription)")
        }
    }

    /// The app's icon with a small white disc and a blue cloud in the lower-right corner.
    /// Gives an offloaded folder's cold folder a folder icon with the cloud badge, so the link
    /// left at the old path looks offloaded in Finder (Finder shows a link with its target's icon).
    static func badgeColdFolder(_ folder: URL) {
        let base = NSWorkspace.shared.icon(for: .folder)
        base.size = NSSize(width: 512, height: 512)
        NSWorkspace.shared.setIcon(cloudBadged(base), forFile: folder.path, options: [])
    }

    static func cloudBadged(_ image: NSImage) -> NSImage {
        let side: CGFloat = 1024
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        let d: CGFloat = 360
        let x = side - d - 16, y: CGFloat = 16
        let cx = x + d / 2, cy = y + d / 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
        NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.92, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: cx - 120, y: cy - 70, width: 240, height: 80)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx - 130, y: cy - 30, width: 100, height: 100)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx - 60, y: cy - 10, width: 130, height: 130)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx + 10, y: cy - 40, width: 110, height: 110)).fill()
        out.unlockFocus()
        return out
    }

    private static func writeICNS(_ image: NSImage, to dest: URL) throws {
        let iconset = dest.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
        if FileManager.default.fileExists(atPath: iconset.path) { try FileManager.default.removeItem(at: iconset) }
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let sizes = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for (name, pixels) in sizes {
            guard let png = pngData(image, pixels: pixels) else {
                throw DisklesslyError.failure("could not render \(name)")
            }
            try png.write(to: iconset.appendingPathComponent(name))
        }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try ProcessRunner.run("/usr/bin/iconutil", ["-c", "icns", "-o", dest.path, iconset.path])
        try? FileManager.default.removeItem(at: iconset)
    }

    private static func pngData(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)), from: .zero, operation: .sourceOver, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }

    private static func setIconFile(_ stub: URL) throws {
        let plistURL = stub.appendingPathComponent("Contents/Info.plist")
        var info = readPlist(plistURL) ?? [:]
        info["CFBundleIconFile"] = "AppIcon"
        info.removeValue(forKey: "CFBundleIconName")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private static func hasIconFile(_ stub: URL) -> Bool {
        guard let file = readPlist(stub.appendingPathComponent("Contents/Info.plist")).flatMap({ AppIcon.plistKeys($0).file }) else { return false }
        return AppIcon.icnsURL(app: stub, fileKey: file) != nil
    }

    private static func isRealApp(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let info = readPlist(url.appendingPathComponent("Contents/Info.plist")),
              let bundleId = info["CFBundleIdentifier"] as? String else { return false }
        return !bundleId.hasSuffix(".256stub")
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("disklessly: \(message)\n".utf8))
    }
    #endif
}
