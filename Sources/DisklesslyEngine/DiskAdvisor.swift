import Foundation
import DisklesslyCore

/// Things that can probably go, each with the check that makes it safe to suggest: folders apps
/// download again (`KnownLocations.redownloadable`) and SIP-protected system assets. Only
/// well-known locations; nothing specific to one person's folders.
public enum DiskAdvisor {
    /// Folder that macOS keeps downloaded system assets in. Protected by System Integrity Protection.
    public static let assetsFolder = "/System/Volumes/Data/System/Library/AssetsV2"
    /// SIP-protected asset groups worth naming, matched by folder-name prefix, with a cleanup id and an
    /// English title. The page shows the `sip_<id>` string instead (`sip-font` → `sip_font`).
    /// With SIP on they are listed for information only. With SIP off each group gets a delete button.
    public static let sipAssetGroups: [(id: String, prefix: String, title: String)] = [
        ("sip-siri", "com_apple_MobileAsset_UAF_Siri_", "Siri offline models"),
        ("sip-speech", "com_apple_MobileAsset_UAF_Speech_", "Offline dictation models"),
        ("sip-linguistic", "com_apple_MobileAsset_UAF_LinguisticData", "Language data"),
        ("sip-translation", "com_apple_MobileAsset_UAF_Translation_", "Offline translation models"),
        ("sip-devdocs", "com_apple_MobileAsset_AppleDeveloperDocumentation", "Apple developer documentation"),
        ("sip-font", "com_apple_MobileAsset_Font", "Extra fonts"),
        ("sip-dictionary", "com_apple_MobileAsset_DictionaryServices_", "Dictionaries"),
        ("sip-ttsax", "com_apple_MobileAsset_TTSAXResourceModelAssets", "Accessibility voices"),
        ("sip-macintalk", "com_apple_MobileAsset_MacinTalkVoiceAssets", "System voices"),
    ]

    /// The page string key of a group's title.
    public static func titleKey(_ groupId: String) -> String { groupId.replacingOccurrences(of: "-", with: "_") }
    /// SIP rows are shown from this size; a single asset group is often under the 1 GiB big-item floor.
    public static let sipMinBytes: UInt64 = 256 << 20

    /// The group for an asset folder name, or nil when it is not one we name.
    public static func sipGroup(for folder: String) -> (id: String, prefix: String, title: String)? {
        sipAssetGroups.first { folder.hasPrefix($0.prefix) }
    }

    /// Whether `csrutil status` output says the filesystem is no longer protected:
    /// SIP fully off, or a custom configuration with filesystem protections off.
    public static func sipFilesystemOff(csrutilOutput text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("status: disabled") { return true }
        return lower.contains("filesystem protections: disabled")
    }

    /// Reads `csrutil status`. Unknown (tool missing or failed) counts as protected.
    public static func sipFilesystemOff() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && sipFilesystemOff(csrutilOutput: String(decoding: data, as: UTF8.self))
    }

    /// The asset folders of one group, as absolute paths directly inside `assetsFolder`.
    public static func sipFolders(groupId: String, assetsFolder: String = assetsFolder) -> [String] {
        guard let group = sipAssetGroups.first(where: { $0.id == groupId }) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: assetsFolder)) ?? []
        return names.filter { $0.hasPrefix(group.prefix) && !$0.contains("/") }
            .sorted().map { assetsFolder + "/" + $0 }
    }

    /// Deletes one asset group with a macOS administrator prompt. Refuses while SIP protects the files.
    public static func deleteSipGroup(_ groupId: String) throws -> String {
        guard sipAssetGroups.contains(where: { $0.id == groupId }) else { throw DisklesslyError.usage("unknown system asset group: \(groupId)") }
        guard sipFilesystemOff() else {
            throw DisklesslyError.unsupported("System Integrity Protection is on; these system assets can only be removed with SIP off")
        }
        let folders = sipFolders(groupId: groupId)
        guard !folders.isEmpty else { return "Nothing to remove" }
        try AdminShell.remove(folders)
        return "Removed \(folders.count) system asset folder(s)"
    }
}

extension DisklesslyEngine {
    /// Advice rows for `bigItems`. Reads only.
    func adviceItems(home: String) -> [BigItem] {
        let homeURL = URL(fileURLWithPath: home)
        let fm = FileManager.default
        var items: [BigItem] = []
        func add(id: String, title: String, titleKey: String, url: URL, reason: String, minimum: UInt64 = BigItems.minBytes) {
            let size = AllocatedSize.tree(url)
            guard size >= minimum else { return }
            var item = BigItem(id: id, kind: "advice", title: title, path: url.path, bytes: size, action: .review, target: url.path, reason: reason)
            item.titleKey = titleKey
            item.fileActions = fileOffloadRefusal(url.path) == nil
            items.append(item)
        }

        for location in KnownLocations.redownloadable {
            let url = homeURL.appendingPathComponent(location.relativePath)
            guard fm.fileExists(atPath: url.path) else { continue }
            add(id: "advice:\(location.id)", title: location.title, titleKey: location.titleKey, url: url, reason: location.id)
        }

        // SIP-protected system assets, grouped by kind so small siblings add up to one row each.
        // With SIP off the row gets a delete button (administrator prompt); with it on, information only.
        let sipOff = DiskAdvisor.sipFilesystemOff()
        for group in DiskAdvisor.sipAssetGroups {
            let folders = DiskAdvisor.sipFolders(groupId: group.id)
            let size = folders.reduce(UInt64(0)) { $0 + AllocatedSize.tree(URL(fileURLWithPath: $1)) }
            guard size >= DiskAdvisor.sipMinBytes else { continue }
            let path = folders.count == 1 ? folders[0] : DiskAdvisor.assetsFolder
            var item = BigItem(id: "advice:\(group.id)", kind: "advice", title: "\(group.title) (SIP)", path: path, bytes: size,
                               action: sipOff ? .clean : .review, target: sipOff ? group.id : path,
                               reason: sipOff ? "adviceSipOff" : "adviceSip")
            item.titleKey = DiskAdvisor.titleKey(group.id)
            items.append(item)
        }
        return items
    }
}
