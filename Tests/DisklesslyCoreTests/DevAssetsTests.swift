import XCTest
@testable import DisklesslyCore

final class DevAssetsTests: XCTestCase {
    let runtimeJSON = """
    {
      "3ACD217D": {
        "build": "24B8117", "deletable": true, "identifier": "3ACD217D",
        "kind": "Patchable Cryptex Disk Image",
        "path": "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/7a06.asset/AssetData",
        "platformIdentifier": "com.apple.platform.iphonesimulator",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
        "sizeBytes": 8315434484, "state": "Ready", "version": "27.2"
      },
      "7FB98C97": {
        "build": "24B91016s", "deletable": true, "identifier": "7FB98C97",
        "kind": "Disk Image",
        "path": "/Library/Developer/CoreSimulator/Images/7FB98C97.dmg",
        "platformIdentifier": "com.apple.platform.iphonesimulator",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
        "sizeBytes": 8338867041, "state": "Ready", "version": "27.2"
      }
    }
    """

    let deviceJSON = """
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
        {"udid": "F043", "name": "iPhone 18 Pro", "state": "Shutdown", "isAvailable": true,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "dataPathSize": 2872033280},
        {"udid": "1FC0", "name": "iPhone 18 Pro Max", "state": "Booted", "isAvailable": true,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max", "dataPathSize": 3000000000}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4": []
    }}
    """

    func testParsesRuntimesNewestBuildFirst() throws {
        let runtimes = try SimRuntime.parse(Data(runtimeJSON.utf8))
        XCTAssertEqual(runtimes.map(\.build), ["24B91016s", "24B8117"])
        XCTAssertEqual(runtimes[1].title, "iOS 27.2 (24B8117)")
        XCTAssertTrue(runtimes[1].isCryptex)
        XCTAssertEqual(runtimes[1].sizeBytes, 8315434484)
    }

    func testSourceImageForDiskImageAndCryptex() throws {
        let runtimes = try SimRuntime.parse(Data(runtimeJSON.utf8))
        let plain = runtimes.first { $0.build == "24B91016s" }!
        XCTAssertEqual(plain.sourceImage(listing: { _ in [] }), "/Library/Developer/CoreSimulator/Images/7FB98C97.dmg")
        let cryptex = runtimes.first { $0.build == "24B8117" }!
        XCTAssertEqual(cryptex.sourceImage(listing: { path in
            path.hasSuffix("/Restore") ? ["141-80522-035.dmg", "BuildManifest.plist", "Firmware"] : []
        }), cryptex.path + "/Restore/141-80522-035.dmg")
        // Two images or none: refuse to guess.
        XCTAssertNil(cryptex.sourceImage(listing: { _ in ["a.dmg", "b.dmg"] }))
        XCTAssertNil(cryptex.sourceImage(listing: { _ in [] }))
    }

    func testParsesDevicesLargestFirst() throws {
        let devices = try SimDevice.parse(Data(deviceJSON.utf8))
        XCTAssertEqual(devices.map(\.udid), ["1FC0", "F043"])
        XCTAssertEqual(devices[0].runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        XCTAssertTrue(devices[0].booted)
    }

    func testGuardsRefuseBootedUsers() throws {
        let runtimes = try SimRuntime.parse(Data(runtimeJSON.utf8))
        let devices = try SimDevice.parse(Data(deviceJSON.utf8))
        let release = runtimes.first { $0.build == "24B8117" }!
        let beta = runtimes.first { $0.build == "24B91016s" }!
        guard case .busy(let message)? = DevAssetGuard.runtime(release, devices: devices) else { return XCTFail("booted device must block") }
        XCTAssertTrue(message.contains("iPhone 18 Pro Max"))
        XCTAssertNil(DevAssetGuard.runtime(beta, devices: devices))
        var locked = beta
        locked.deletable = false
        XCTAssertNotNil(DevAssetGuard.runtime(locked, devices: devices))
        XCTAssertNotNil(DevAssetGuard.simulator(devices[0]))
        XCTAssertNil(DevAssetGuard.simulator(devices[1]))
    }

    func testRecordRoundTripAndPaths() throws {
        let sha = String(repeating: "ab", count: 32)
        let record = DevAssetRecord(kind: .runtime, sha256: sha.uppercased(), size: 42, title: "iOS 27.2 (24B8117)", host: "mac",
                                    details: ["build": "24B8117", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2"],
                                    offloadedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(record.id, "abababababababab")
        XCTAssertEqual(record.sha256, sha)
        XCTAssertEqual(record.image, "devassets/runtimes/abababababababab.dmg")
        XCTAssertEqual(DevAssets.recordPath(.simulator, id: "x"), "devassets/simulators/x.json")
        XCTAssertEqual(try DevAssetRecord.decode(try record.encode()), record)

        let runtimes = try SimRuntime.parse(Data(runtimeJSON.utf8))
        XCTAssertTrue(record.present(in: runtimes))
        XCTAssertFalse(record.present(in: runtimes.filter { $0.build != "24B8117" }))
        var simulator = record
        simulator.kind = .simulator
        XCTAssertFalse(simulator.present(in: runtimes))
    }
}
