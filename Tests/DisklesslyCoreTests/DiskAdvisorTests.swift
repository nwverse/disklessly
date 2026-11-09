import XCTest
@testable import DisklesslyEngine

final class DiskAdvisorTests: XCTestCase {
    func testSipAssetFoldersMapToReadableGroups() {
        XCTAssertEqual(DiskAdvisor.sipGroup(for: "com_apple_MobileAsset_UAF_Siri_Understanding")?.title, "Siri offline models")
        XCTAssertEqual(DiskAdvisor.sipGroup(for: "com_apple_MobileAsset_UAF_Siri_TextToSpeech")?.id, "sip-siri")
        XCTAssertEqual(DiskAdvisor.sipGroup(for: "com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition")?.title, "Offline dictation models")
        XCTAssertEqual(DiskAdvisor.sipGroup(for: "com_apple_MobileAsset_AppleDeveloperDocumentation")?.title, "Apple developer documentation")
        XCTAssertEqual(DiskAdvisor.sipGroup(for: "com_apple_MobileAsset_Font8")?.title, "Extra fonts")
        XCTAssertNil(DiskAdvisor.sipGroup(for: "com_apple_MobileAsset_MacSoftwareUpdate"), "software updates are not suggested")
    }

    func testSipTitlesAreKeysAndSwiftHasNoPageText() {
        XCTAssertEqual(DiskAdvisor.titleKey("sip-font"), "sip_font")
        for group in DiskAdvisor.sipAssetGroups {
            XCTAssertTrue(group.title.unicodeScalars.allSatisfy(\.isASCII), group.title)
        }
    }

    func testKnownLocationsSkipContainerEnginesAndOwnFolders() {
        let config = RuntimeConfig(repoPath: "/x/repo", cacheDir: "/x/Library/Caches/Disklessly", stateDir: "/x/Library/Application Support/Disklessly", mountRoot: "/x/mnt", stubDir: "/x/Applications")
        let names = KnownLocations.notAppData(home: "/x", config: config)
        for name in ["Disklessly", "CloudDocs", "256isenough", "com.docker.docker", "HUAQ24HBR6.dev.orbstack", "com.apple.container"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(KnownLocations.developerFolder(of: KnownLocations.derivedData), "Xcode")
        XCTAssertEqual(KnownLocations.developerFolder(of: KnownLocations.simulatorDevices), "CoreSimulator")
    }

    func testCsrutilOutputParsing() {
        XCTAssertFalse(DiskAdvisor.sipFilesystemOff(csrutilOutput: "System Integrity Protection status: enabled."))
        XCTAssertTrue(DiskAdvisor.sipFilesystemOff(csrutilOutput: "System Integrity Protection status: disabled."))
        let custom = "System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:\n\tApple Internal: disabled\n\tKext Signing: enabled\n\tFilesystem Protections: disabled\n"
        XCTAssertTrue(DiskAdvisor.sipFilesystemOff(csrutilOutput: custom), "filesystem protections off is enough")
        let customOn = "System Integrity Protection status: unknown (Custom Configuration).\n\tFilesystem Protections: enabled\n\tKext Signing: disabled\n"
        XCTAssertFalse(DiskAdvisor.sipFilesystemOff(csrutilOutput: customOn))
    }

    func testSipGroupsAreKnownCleanups() {
        for group in DiskAdvisor.sipAssetGroups { XCTAssertTrue(UsageCleanup.known(group.id), group.id) }
    }

    func testSipFoldersOnlyMatchTheirGroupInsideTheAssetsFolder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for name in ["com_apple_MobileAsset_Font8", "com_apple_MobileAsset_Font7", "com_apple_MobileAsset_MacSoftwareUpdate"] {
            try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let folders = DiskAdvisor.sipFolders(groupId: "sip-font", assetsFolder: dir.path)
        XCTAssertEqual(folders, [dir.path + "/com_apple_MobileAsset_Font7", dir.path + "/com_apple_MobileAsset_Font8"])
        XCTAssertEqual(DiskAdvisor.sipFolders(groupId: "unknown", assetsFolder: dir.path), [])
    }

    func testDeletingRefusesWhileSipIsOn() throws {
        // This Mac and CI run with SIP on; the delete must refuse before any administrator prompt.
        guard !DiskAdvisor.sipFilesystemOff() else { throw XCTSkip("SIP is off on this Mac") }
        XCTAssertThrowsError(try DiskAdvisor.deleteSipGroup("sip-font"))
    }
}
