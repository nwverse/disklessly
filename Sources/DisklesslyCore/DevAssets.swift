import Foundation

/// Xcode's simulator runtimes and simulator devices, offloaded to the repo the
/// same way apps are: an immutable image plus a small JSON record next to it.
///
/// Runtimes are system-managed disk images. They leave and come back only
/// through `simctl runtime delete` / `simctl runtime add`, which accepts the
/// very image the system keeps, so the image is uploaded unchanged.
/// A simulator device is a folder under ~/Library/Developer/CoreSimulator/Devices.
/// CoreSimulator does not notice a folder put back while it runs, so a restore
/// creates a twin device (same name, type and runtime) and moves the saved data in.
public enum DevAssets {
    public enum Kind: String, Codable, CaseIterable { case runtime, simulator }

    public static let root = "devassets"

    public static func folder(_ kind: Kind) -> String { "\(root)/\(kind.rawValue)s" }
    public static func imagePath(_ kind: Kind, id: String) -> String { "\(folder(kind))/\(id).dmg" }
    public static func recordPath(_ kind: Kind, id: String) -> String { "\(folder(kind))/\(id).json" }

    /// Records are named after the image bytes, so the same runtime offloaded
    /// from two Macs is stored once.
    public static func recordId(sha256: String) -> String { String(sha256.lowercased().prefix(16)) }
}

/// One runtime from `simctl runtime list -j`.
public struct SimRuntime: Equatable {
    public var id: String
    public var build: String
    public var version: String
    public var runtimeIdentifier: String
    public var platform: String
    public var kind: String
    public var path: String
    public var sizeBytes: UInt64
    public var state: String
    public var deletable: Bool
    public var lastUsedAt: String?

    /// "iOS 27.2 (24B8117)".
    public var title: String { "\(platformName) \(version) (\(build))" }

    public var platformName: String {
        let known = ["iphonesimulator": "iOS", "appletvsimulator": "tvOS", "watchsimulator": "watchOS", "xrsimulator": "visionOS"]
        let last = platform.split(separator: ".").last.map(String.init) ?? platform
        return known[last] ?? last
    }

    public var isCryptex: Bool { kind.localizedCaseInsensitiveContains("cryptex") }

    public static func parse(_ data: Data) throws -> [SimRuntime] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DisklesslyError.failure("simctl runtime list returned something other than an object")
        }
        return object.values.compactMap { value -> SimRuntime? in
            guard let item = value as? [String: Any], let id = item["identifier"] as? String else { return nil }
            return SimRuntime(
                id: id,
                build: item["build"] as? String ?? "",
                version: item["version"] as? String ?? "",
                runtimeIdentifier: item["runtimeIdentifier"] as? String ?? "",
                platform: item["platformIdentifier"] as? String ?? "",
                kind: item["kind"] as? String ?? "",
                path: item["path"] as? String ?? "",
                sizeBytes: (item["sizeBytes"] as? NSNumber)?.uint64Value ?? 0,
                state: item["state"] as? String ?? "",
                deletable: item["deletable"] as? Bool ?? false,
                lastUsedAt: item["lastUsedAt"] as? String
            )
        }.sorted { ($0.version, $0.build) > ($1.version, $1.build) }
    }

    /// The image file `simctl runtime add` takes back. A plain disk image is
    /// its own `path`; a cryptex keeps it in `<path>/Restore` as the only .dmg.
    public func sourceImage(listing: (String) -> [String]) -> String? {
        if path.hasSuffix(".dmg") { return path }
        let restore = path + "/Restore"
        let images = listing(restore).filter { $0.hasSuffix(".dmg") }
        return images.count == 1 ? restore + "/" + images[0] : nil
    }
}

/// One device from `simctl list devices -j`.
public struct SimDevice: Equatable {
    public var udid: String
    public var name: String
    public var deviceType: String
    public var runtimeIdentifier: String
    public var state: String
    public var dataBytes: UInt64
    public var available: Bool
    public var lastUsedAt: String?

    public var booted: Bool { state == "Booted" }

    public static func parse(_ data: Data) throws -> [SimDevice] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: Any] else {
            throw DisklesslyError.failure("simctl list devices returned no device list")
        }
        var result: [SimDevice] = []
        for (runtime, list) in devices {
            for case let item as [String: Any] in (list as? [Any]) ?? [] {
                guard let udid = item["udid"] as? String else { continue }
                result.append(SimDevice(
                    udid: udid,
                    name: item["name"] as? String ?? udid,
                    deviceType: item["deviceTypeIdentifier"] as? String ?? "",
                    runtimeIdentifier: runtime,
                    state: item["state"] as? String ?? "",
                    dataBytes: (item["dataPathSize"] as? NSNumber)?.uint64Value ?? 0,
                    available: item["isAvailable"] as? Bool ?? false,
                    lastUsedAt: item["lastUsedAt"] as? String
                ))
            }
        }
        return result.sorted { $0.dataBytes > $1.dataBytes }
    }
}

/// What the repo keeps next to each offloaded image.
public struct DevAssetRecord: Codable, Equatable {
    public var schema = 1
    public var kind: DevAssets.Kind
    public var id: String
    public var title: String
    public var sha256: String
    public var size: UInt64
    public var offloadedAt: Date
    public var host: String
    /// Runtime: build, version, runtimeIdentifier, platform.
    /// Simulator: udid, deviceType, runtimeIdentifier.
    public var details: [String: String]

    public init(kind: DevAssets.Kind, sha256: String, size: UInt64, title: String, host: String, details: [String: String], offloadedAt: Date = Date()) {
        self.kind = kind
        self.id = DevAssets.recordId(sha256: sha256)
        self.title = title
        self.sha256 = sha256.lowercased()
        self.size = size
        self.offloadedAt = offloadedAt
        self.host = host
        self.details = details
    }

    public var image: String { DevAssets.imagePath(kind, id: id) }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DevAssetRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DevAssetRecord.self, from: data)
    }

    /// Whether this Mac already has what the record holds: a runtime with the
    /// same build and identifier. A restored simulator gets a new udid, so
    /// simulators always count as offloaded until their record is removed.
    public func present(in runtimes: [SimRuntime]) -> Bool {
        guard kind == .runtime else { return false }
        return runtimes.contains { $0.build == details["build"] && $0.runtimeIdentifier == details["runtimeIdentifier"] }
    }
}

/// Why an item can't be offloaded right now, or nil when it can.
public enum DevAssetGuard {
    public static func runtime(_ runtime: SimRuntime, devices: [SimDevice]) -> DisklesslyError? {
        guard runtime.deletable else { return .unsupported("\(runtime.title) can't be deleted: Xcode marks it as not deletable") }
        guard runtime.state == "Ready" else { return .unsupported("\(runtime.title) is \(runtime.state), not Ready") }
        let booted = devices.filter { $0.booted && $0.runtimeIdentifier == runtime.runtimeIdentifier }
        if !booted.isEmpty {
            return .busy("\(runtime.title) is in use by \(booted.map(\.name).joined(separator: ", ")). Shut those simulators down first.")
        }
        return nil
    }

    public static func simulator(_ device: SimDevice) -> DisklesslyError? {
        if device.booted { return .busy("\(device.name) is running. Shut it down first.") }
        return nil
    }
}
