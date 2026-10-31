import XCTest
import IsenoughCore
@testable import IsenoughEngine

final class StateStoreTests: XCTestCase {
    func testMigratesV1StateAndKeepsBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = """
        {
          "apps": {
            "com.example": {
              "imageId": "img-1",
              "pinned": true,
              "state": "cached",
              "needsResolution": {"retainedPath": "/tmp/a.app"},
              "lastOutcome": {"name": "restoredOut", "at": "2025-01-01T00:00:00Z", "txid": "R-1"}
            }
          },
          "cache": {"img-1": {"lastUsed": "2025-01-01T00:00:00Z"}},
          "restored": {
            "com.example": {
              "journal": "journals/R-1.json",
              "txid": "R-1",
              "phase": "running",
              "waitReason": "",
              "dest": "/Applications/A.app",
              "staging": "/Applications/.256isenough-staging/R-1",
              "epoch": 1,
              "postQuitRanForEpoch": 0,
              "owner": {"pid": 10, "start": 20}
            }
          },
          "foo": "bar"
        }
        """
        let url = root.appendingPathComponent("state.json")
        try Data(original.utf8).write(to: url)
        let store = StateStore(root.path)
        let loaded = store.load()
        XCTAssertEqual(loaded.apps["com.example"]?.imageId, "img-1")
        XCTAssertEqual(loaded.apps["com.example"]?.pinned, true)
        XCTAssertEqual(loaded.apps["com.example"]?.needsResolution?["retainedPath"]?.string, "/tmp/a.app")
        XCTAssertEqual(loaded.apps["com.example"]?.lastOutcome?.name, "restoredOut")
        XCTAssertEqual(loaded.apps["com.example"]?.lastOutcome?.txid, "R-1")
        XCTAssertNotNil(loaded.cache["img-1"]?.lastUsed)
        XCTAssertEqual(loaded.restored["com.example"]?.epoch, 1)
        XCTAssertEqual(loaded.restored["com.example"]?.owner.pid, 10)
        XCTAssertEqual(loaded.extra["foo"]?.string, "bar")
        _ = try store.update { state in
            state.apps["com.example"]?.state = "cached"
        }
        let written = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        XCTAssertEqual(object?["schema"] as? String, "state/2")
        XCTAssertEqual((object?["foo"] as? String), "bar")
        let backup = root.appendingPathComponent("state.json.v1.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8))
        _ = try store.update { _ in }
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8))
    }

    func testConcurrentUpdatesDoNotLoseWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root.path)
        let gate = NSLock()
        var errors: [String] = []
        let threads = ["a", "b"].map { prefix in
            Thread {
                do {
                    for index in 0..<200 {
                        try store.update { state in
                            state.apps["\(prefix)\(index)"] = AppState(imageId: "\(prefix)\(index)")
                        }
                    }
                } catch {
                    gate.lock()
                    errors.append(String(describing: error))
                    gate.unlock()
                }
            }
        }
        threads.forEach { $0.start() }
        for thread in threads {
            while !thread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertEqual(store.load().apps.count, 400)
    }

    func testNestedUpdateDoesNotDeadlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root.path)
        let start = Date()
        try store.update { state in
            state.apps["outer"] = AppState(imageId: "outer")
            try store.update { inner in
                inner.apps["inner"] = AppState(imageId: "inner")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(store.load().apps.count, 2)
    }

    func testCorruptStateIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.json")
        try Data("{".utf8).write(to: url)
        let store = StateStore(root.path)
        XCTAssertTrue(store.load().apps.isEmpty)
        XCTAssertThrowsError(try store.update { $0.apps["a"] = AppState(imageId: "a") }) { error in
            let failure = error as? IsenoughError
            XCTAssertEqual(failure?.exitCode, 5)
            XCTAssertTrue(failure?.errorDescription?.contains("state.json.corrupt-") == true)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("state.json.corrupt-") })
    }

    func testDictionaryCompatibilityRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root.path)
        let dict: [String: Any] = [
            "schema": "state/1",
            "apps": ["com.example": ["pinned": true, "imageId": "img-1"]],
            "cache": [String: Any](),
        ]
        try store.write(dict)
        let apps = store.read()["apps"] as? [String: [String: Any]]
        XCTAssertEqual(apps?["com.example"]?["pinned"] as? Bool, true)
        XCTAssertEqual(apps?["com.example"]?["imageId"] as? String, "img-1")
    }
}
