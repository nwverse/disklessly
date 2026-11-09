import Foundation
import DisklesslyCore

/// Offload and restore Xcode simulator runtimes and simulator devices.
/// Nothing here needs an administrator: simctl does the privileged parts.
public struct DevAssetsReport {
    public var runtimes: [SimRuntime]
    public var simulators: [SimDevice]
    public var offloaded: [DevAssetRecord]
    /// Set when simctl is missing or failed; the lists are then empty.
    public var unavailable: String?

    public func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = [
            "runtimes": runtimes.map { r -> [String: Any] in
                ["id": r.id, "title": r.title, "build": r.build, "version": r.version, "platform": r.platformName,
                 "runtimeIdentifier": r.runtimeIdentifier, "bytes": NSNumber(value: r.sizeBytes), "state": r.state,
                 "deletable": r.deletable, "lastUsedAt": r.lastUsedAt ?? "",
                 "blocked": DevAssetGuard.runtime(r, devices: simulators)?.errorDescription ?? "",
                 "inUseBy": simulators.filter { $0.booted && $0.runtimeIdentifier == r.runtimeIdentifier }.map(\.name)]
            },
            "simulators": simulators.map { d -> [String: Any] in
                ["udid": d.udid, "name": d.name, "runtimeIdentifier": d.runtimeIdentifier, "bytes": NSNumber(value: d.dataBytes),
                 "state": d.state, "lastUsedAt": d.lastUsedAt ?? "",
                 "blocked": DevAssetGuard.simulator(d)?.errorDescription ?? ""]
            },
            "offloaded": offloaded.map { r -> [String: Any] in
                ["id": r.id, "kind": r.kind.rawValue, "title": r.title, "bytes": NSNumber(value: r.size),
                 "offloadedAt": iso.string(from: r.offloadedAt), "host": r.host, "details": r.details,
                 "present": r.present(in: runtimes)]
            },
        ]
        if let unavailable { object["unavailable"] = unavailable }
        return object
    }
}

public struct DevAssetResult {
    public var record: DevAssetRecord
    public var uploaded: Bool
    /// Something that worked only in part, e.g. space macOS did not give back.
    public var warning: String?
    /// The new device a simulator restore created.
    public var udid: String?

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["ok": true, "id": record.id, "kind": record.kind.rawValue, "title": record.title,
                                     "bytes": NSNumber(value: record.size), "uploaded": uploaded]
        if let warning { object["warning"] = warning }
        if let udid { object["udid"] = udid }
        return object
    }
}

extension DisklesslyEngine {
    static var devicesFolder: String { NSHomeDirectory() + "/" + KnownLocations.simulatorDevices }
    var devAssetsDir: URL { URL(fileURLWithPath: config.cacheDir).appendingPathComponent("devassets") }

    // MARK: reading

    public func devAssets() -> DevAssetsReport {
        var report = DevAssetsReport(runtimes: [], simulators: [], offloaded: [], unavailable: nil)
        do {
            report.runtimes = try SimRuntime.parse(try simctl(["runtime", "list", "-j"]))
            report.simulators = try SimDevice.parse(try simctl(["list", "devices", "-j"]))
            // simctl leaves dataPathSize out until it has measured a device,
            // e.g. right after a restore. Measure those here.
            for index in report.simulators.indices where report.simulators[index].dataBytes == 0 {
                let data = URL(fileURLWithPath: Self.devicesFolder).appendingPathComponent(report.simulators[index].udid)
                report.simulators[index].dataBytes = AllocatedSize.tree(data)
            }
            report.simulators.sort { $0.dataBytes > $1.dataBytes }
        } catch {
            report.unavailable = error.localizedDescription
        }
        report.offloaded = (try? offloadedDevAssets()) ?? []
        return report
    }

    public func offloadedDevAssets() throws -> [DevAssetRecord] {
        let backend = try repo
        var records: [DevAssetRecord] = []
        for kind in DevAssets.Kind.allCases {
            let folder = DevAssets.folder(kind)
            guard (try? backend.stat(folder)) != nil else { continue }
            for name in (try? backend.list(folder)) ?? [] where name.hasSuffix(".json") {
                if let data = try? backend.get("\(folder)/\(name)", range: nil), let record = try? DevAssetRecord.decode(data) {
                    records.append(record)
                }
            }
        }
        return records.sorted { $0.offloadedAt > $1.offloadedAt }
    }

    func devAssetRecord(_ id: String) throws -> DevAssetRecord {
        let matches = try offloadedDevAssets().filter { $0.id == id || $0.id.hasPrefix(id) }
        guard matches.count == 1 else {
            throw DisklesslyError.usage(matches.isEmpty ? "No offloaded runtime or simulator \(id)" : "\(id) matches more than one record")
        }
        return matches[0]
    }

    // MARK: runtimes

    /// Uploads the runtime's image unchanged, then has simctl delete it.
    public func offloadRuntime(_ id: String) throws -> DevAssetResult {
        let runtimes = try SimRuntime.parse(try simctl(["runtime", "list", "-j"]))
        guard let runtime = runtimes.first(where: { $0.id == id || $0.build == id }) else {
            throw DisklesslyError.usage("No simulator runtime \(id). See: disklessly dev list")
        }
        if let blocked = DevAssetGuard.runtime(runtime, devices: try SimDevice.parse(try simctl(["list", "devices", "-j"]))) { throw blocked }
        let listing: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        guard let source = runtime.sourceImage(listing: listing) else {
            throw DisklesslyError.unsupported("Could not find the disk image of \(runtime.title) under \(runtime.path)")
        }
        let details = ["build": runtime.build, "version": runtime.version, "runtimeIdentifier": runtime.runtimeIdentifier, "platform": runtime.platformName]
        var result = try upload(URL(fileURLWithPath: source), kind: .runtime, title: runtime.title, details: details)

        do {
            _ = try simctl(["runtime", "delete", runtime.id])
        } catch {
            // simctl can remove the runtime yet keep its MobileAsset. Registering
            // it again and deleting that copy is what simctl itself suggests.
            _ = try? simctl(["runtime", "scan-and-mount"])
            let again = (try? SimRuntime.parse(try simctl(["runtime", "list", "-j"]))) ?? []
            for twin in again where twin.build == runtime.build && twin.runtimeIdentifier == runtime.runtimeIdentifier {
                _ = try? simctl(["runtime", "delete", twin.id])
            }
        }
        let after = (try? SimRuntime.parse(try simctl(["runtime", "list", "-j"]))) ?? []
        if after.contains(where: { $0.id == runtime.id }) {
            throw DisklesslyError.failure("\(runtime.title) was uploaded but simctl did not delete it. Try: xcrun simctl runtime delete \(runtime.id)")
        }
        if FileManager.default.fileExists(atPath: source) {
            result.warning = "\(runtime.title) is gone from Xcode, but macOS kept its files at \(runtime.path) for now, so the space may come back later."
        }
        return result
    }

    /// Downloads the image and hands it to `simctl runtime add`.
    public func restoreRuntime(_ id: String) throws -> DevAssetResult {
        let record = try devAssetRecord(id)
        guard record.kind == .runtime else { throw DisklesslyError.usage("\(record.title) is a simulator; use: disklessly dev restore-simulator \(record.id)") }
        let runtimes = try SimRuntime.parse(try simctl(["runtime", "list", "-j"]))
        if record.present(in: runtimes) { return DevAssetResult(record: record, uploaded: false, warning: "\(record.title) is already installed") }
        let file = try fetch(record)
        defer { try? FileManager.default.removeItem(at: file) }
        // --move: simctl clones or takes the file instead of copying 8 GB again.
        _ = try simctl(["runtime", "add", "--move", file.path])
        return DevAssetResult(record: record, uploaded: false)
    }

    // MARK: simulators

    public func offloadSimulator(_ udid: String) throws -> DevAssetResult {
        let devices = try SimDevice.parse(try simctl(["list", "devices", "-j"]))
        guard let device = devices.first(where: { $0.udid == udid || $0.name == udid }) else {
            throw DisklesslyError.usage("No simulator \(udid). See: disklessly dev list")
        }
        if let blocked = DevAssetGuard.simulator(device) { throw blocked }
        let folder = URL(fileURLWithPath: Self.devicesFolder).appendingPathComponent(device.udid)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("device.plist").path) else {
            throw DisklesslyError.unsupported("\(device.name) has no folder at \(folder.path)")
        }
        try FileManager.default.createDirectory(at: devAssetsDir, withIntermediateDirectories: true)
        let staging = devAssetsDir.appendingPathComponent("sim-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: staging) }
        try tool("/usr/bin/hdiutil", ["create", "-quiet", "-format", "ULFO", "-srcfolder", folder.path, "-volname", device.udid, staging.path])
        let details = ["udid": device.udid, "deviceType": device.deviceType, "runtimeIdentifier": device.runtimeIdentifier, "name": device.name]
        let result = try upload(staging, kind: .simulator, title: device.name, details: details)
        _ = try simctl(["delete", device.udid])
        return result
    }

    /// Shuts a running simulator down so it can be offloaded (and its runtime with it).
    public func shutdownSimulator(_ udid: String) throws {
        let devices = try SimDevice.parse(try simctl(["list", "devices", "-j"]))
        guard let device = devices.first(where: { $0.udid == udid }) else {
            throw DisklesslyError.usage("No simulator \(udid). See: disklessly dev list")
        }
        guard device.booted else { return }
        _ = try simctl(["shutdown", device.udid])
    }

    /// Creates a twin device and moves the saved data into it. The twin has a new udid.
    public func restoreSimulator(_ id: String) throws -> DevAssetResult {
        let record = try devAssetRecord(id)
        guard record.kind == .simulator, let runtime = record.details["runtimeIdentifier"], let type = record.details["deviceType"] else {
            throw DisklesslyError.usage("\(record.title) is not a simulator record")
        }
        func runtimeReady() throws -> Bool {
            let runtimeObjects = (try? JSONSerialization.jsonObject(with: try simctl(["list", "runtimes", "-j"])) as? [String: Any])?["runtimes"] as? [[String: Any]] ?? []
            return runtimeObjects.contains { ($0["identifier"] as? String) == runtime && ($0["isAvailable"] as? Bool) == true }
        }
        if try !runtimeReady() {
            // The simulator needs its runtime. If that runtime was offloaded too, bring it back first.
            let available = try SimRuntime.parse(try simctl(["runtime", "list", "-j"]))
            guard let saved = try offloadedDevAssets().first(where: { $0.kind == .runtime && $0.details["runtimeIdentifier"] == runtime && !$0.present(in: available) }) else {
                throw DisklesslyError.unsupported("\(record.title) needs the runtime \(runtime), which is not installed and has no saved copy here.")
            }
            _ = try restoreRuntime(saved.id)
            guard try runtimeReady() else {
                throw DisklesslyError.unsupported("\(record.title) needs the runtime \(runtime), which is still not available after restoring \(saved.title).")
            }
        }
        let file = try fetch(record)
        defer { try? FileManager.default.removeItem(at: file) }
        let name = record.details["name"] ?? record.title
        let created = String(decoding: try simctl(["create", name, type, runtime]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !created.isEmpty else { throw DisklesslyError.failure("simctl create returned no udid") }
        var done = false
        defer { if !done { _ = try? simctl(["delete", created]) } }

        let target = URL(fileURLWithPath: Self.devicesFolder).appendingPathComponent(created)
        let mount = devAssetsDir.appendingPathComponent("mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        try LiveDiskImage.attach(image: file, mountPoint: mount)
        defer { try? LiveDiskImage.detach(mountPoint: mount, force: true) }
        // The twin's own device.plist stays: it names the new udid.
        for entry in try FileManager.default.contentsOfDirectory(atPath: mount.path) where entry != "device.plist" && !entry.hasPrefix(".") {
            let destination = target.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try tool("/usr/bin/ditto", [mount.appendingPathComponent(entry).path, destination.path])
        }
        done = true
        return DevAssetResult(record: record, uploaded: false, udid: created)
    }

    // MARK: repo

    /// Removes an offloaded image and its record from the repo.
    public func forgetDevAsset(_ id: String) throws -> DevAssetRecord {
        let record = try devAssetRecord(id)
        let backend = try repo
        try backend.delete(record.image)
        try backend.delete(DevAssets.recordPath(record.kind, id: record.id))
        return record
    }

    // MARK: DerivedData

    /// Moves everything in Xcode's DerivedData to the Trash. Xcode rebuilds it.
    public func trashDerivedData() throws -> (items: Int, bytes: UInt64) {
        #if !os(macOS)
        throw DisklesslyError.unsupported("DerivedData is an Xcode folder on macOS")
        #else
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/" + KnownLocations.derivedData)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var bytes: UInt64 = 0, items = 0
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            let size = AllocatedSize.tree(entry)
            try FileManager.default.trashItem(at: entry, resultingItemURL: nil)
            bytes += size
            items += 1
        }
        return (items, bytes)
        #endif
    }

    // MARK: helpers

    private func upload(_ file: URL, kind: DevAssets.Kind, title: String, details: [String: String]) throws -> DevAssetResult {
        let size = try ChunkedIO.byteCount(file)
        let sha = try SHA256Digest.hexFile(file)
        let record = DevAssetRecord(kind: kind, sha256: sha, size: size, title: title, host: LiveDeviceFacts.current().hostname, details: details)
        let backend = try repo
        if backend.localRoot() != nil { try? backend.ensureCollection(DevAssets.folder(kind)) }
        let written = try WriteOnce.putFile(backend: backend, path: record.image, file: file, sha256: sha)
        guard let stat = try backend.stat(record.image), stat.size == size else {
            throw DisklesslyError.integrity("The uploaded image of \(title) has the wrong size; nothing was deleted")
        }
        let recordPath = DevAssets.recordPath(kind, id: record.id)
        // The same image offloaded again keeps its first record.
        if (try? backend.stat(recordPath)) == nil { try backend.put(recordPath, data: try record.encode()) }
        if case .written = written { return DevAssetResult(record: record, uploaded: true) }
        return DevAssetResult(record: record, uploaded: false)
    }

    private func fetch(_ record: DevAssetRecord) throws -> URL {
        try FileManager.default.createDirectory(at: devAssetsDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: devAssetsDir.path)
        if free < record.size + config.minFreeBytes {
            throw DisklesslyError.noSpace("\(record.title) needs \(record.size) bytes free to come back; \(free) are free")
        }
        let destination = devAssetsDir.appendingPathComponent("\(record.id).dmg")
        try CacheFetcher.materialize(backend: try repo, remote: record.image, destination: destination,
                                     partial: devAssetsDir.appendingPathComponent("\(record.id).partial"),
                                     expectedSize: record.size, expectedSHA256: record.sha256)
        return destination
    }

    @discardableResult
    private func simctl(_ arguments: [String]) throws -> Data {
        try tool("/usr/bin/xcrun", ["simctl"] + arguments)
    }

    @discardableResult
    private func tool(_ path: String, _ arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw DisklesslyError.unsupported("\(path) is not available") }
        let process = ParsedCommand.process(path: path, arguments: arguments)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw DisklesslyError.failure("Could not start \(path): \(error.localizedDescription)")
        }
        let errors = LockedBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errors.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisklesslyError.failure("\(([path] + arguments).joined(separator: " ")) failed (exit \(process.terminationStatus))\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return data
    }

    private final class LockedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
