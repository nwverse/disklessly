import Foundation
import XCTest

/// Checks the release assets that live in the repository rather than in code:
/// the app icon, its build wiring, and the user-facing docs.
final class ReleaseAssetsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // IsenoughCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func data(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func bigEndian32(_ bytes: Data, at offset: Int) -> UInt32 {
        bytes[bytes.startIndex + offset ..< bytes.startIndex + offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    func testIcnsIsWellFormedAndHasRetinaSizes() throws {
        let icns = try data("Resources/AppIcon.icns")
        XCTAssertGreaterThan(icns.count, 8)
        XCTAssertEqual(String(decoding: icns.prefix(4), as: UTF8.self), "icns")
        XCTAssertEqual(Int(bigEndian32(icns, at: 4)), icns.count, "icns header length does not match the file size")

        var types: Set<String> = []
        var offset = 8
        while offset + 8 <= icns.count {
            let type = String(decoding: icns[icns.startIndex + offset ..< icns.startIndex + offset + 4], as: UTF8.self)
            let length = Int(bigEndian32(icns, at: offset + 4))
            XCTAssertGreaterThanOrEqual(length, 8, "bad length for \(type)")
            guard length >= 8 else { return }
            types.insert(type)
            offset += length
        }
        XCTAssertEqual(offset, icns.count, "icns entries do not add up to the file size")
        // ic10 is 512@2x (1024 px), ic09 512, ic08 256, ic07 128.
        for required in ["ic10", "ic09", "ic08", "ic07"] {
            XCTAssertTrue(types.contains(required), "AppIcon.icns lacks \(required); has \(types.sorted())")
        }
    }

    func testMasterIconIs1024PNG() throws {
        let png = try data("Resources/AppIcon-1024.png")
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(String(decoding: png[png.startIndex + 12 ..< png.startIndex + 16], as: UTF8.self), "IHDR")
        XCTAssertEqual(bigEndian32(png, at: 16), 1024)
        XCTAssertEqual(bigEndian32(png, at: 20), 1024)
    }

    func testBuildScriptBundlesTheIcon() throws {
        let script = try text("scripts/build-app.sh")
        XCTAssertTrue(script.contains("Resources/AppIcon.icns"))
        XCTAssertTrue(script.contains("Contents/Resources/AppIcon.icns"))
        XCTAssertTrue(script.contains("CFBundleIconFile"))
        XCTAssertTrue(script.contains("scripts/make-icon.sh"), "build-app.sh should regenerate a missing icon")

        let maker = root.appendingPathComponent("scripts/make-icon.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: maker.path), "scripts/make-icon.sh must be executable")
        let source = try text("scripts/make-icon.sh")
        XCTAssertTrue(source.contains("iconutil -c icns"))
        XCTAssertFalse(source.contains("python"), "the icon is drawn without Python")
    }

    func testUserGuideCoversTheEverydayCommandsInBothLanguages() throws {
        let guide = try text("docs/user-guide.md")
        for command in ["isenough init", "isenough recommend", "isenough pack", "isenough launch", "isenough pin",
                        "isenough evict", "isenough unpack", "isenough doctor", "isenough backend add", "isenough devices",
                        "isenough ui --open", "isenough gc", "isenough resolve"] {
            XCTAssertTrue(guide.contains(command), "user guide does not mention \(command)")
        }
        for topic in ["smb", "webdav", "openlist", "iCloud", "Open Dashboard", "App Management",
                      "Application Support/256isenough", "Caches/256isenough"] {
            XCTAssertTrue(guide.contains(topic), "user guide does not mention \(topic)")
        }
        XCTAssertTrue(guide.contains("使用指南"), "Chinese section missing")
        XCTAssertTrue(guide.contains("## English"), "English section missing")
        XCTAssertTrue(guide.contains("没有遥测") && guide.contains("No telemetry"), "privacy note missing")
        XCTAssertTrue(guide.contains("isenough sessions"), "user guide does not cover isenough sessions")
    }

    func testReadmeLinksTheGuideAndRelativeLinksResolve() throws {
        let readme = try text("README.md")
        XCTAssertTrue(readme.contains("docs/user-guide.md"))
        XCTAssertTrue(readme.contains("中文简介"), "keep the Chinese intro")
        XCTAssertFalse(readme.lowercased().contains("placeholder command"))

        let pattern = try NSRegularExpression(pattern: #"\]\(([^)#:\s]+)(#[^)]*)?\)|src="([^"]+)""#)
        for (file, base) in [("README.md", root), ("docs/user-guide.md", root.appendingPathComponent("docs"))] {
            let body = try text(file)
            for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let group = match.range(at: 1).location != NSNotFound ? 1 : 3
                guard let range = Range(match.range(at: group), in: body) else { continue }
                let target = String(body[range])
                guard !target.hasPrefix("http") else { continue }
                let resolved = base.appendingPathComponent(target).standardizedFileURL
                XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path), "\(file) links to missing \(target)")
            }
        }
    }

    func testUninstallStepsWarnBeforeTheRepoIsDeleted() throws {
        let guide = try text("docs/user-guide.md")
        func section(_ start: String, _ end: String) throws -> String {
            let from = try XCTUnwrap(guide.range(of: start), "missing \(start)")
            let to = try XCTUnwrap(guide.range(of: end, range: from.upperBound..<guide.endIndex), "missing \(end)")
            return String(guide[from.upperBound..<to.lowerBound])
        }
        let zh = try section("## 卸载 256isenough", "## 隐私")
        let en = try section("### Uninstall", "### Privacy")
        for (name, body, warning) in [("zh", zh, "永久丢失"), ("en", en, "destroys data for good")] {
            XCTAssertTrue(body.contains(warning), "\(name) uninstall must warn that deleting the repo is permanent")
            XCTAssertTrue(body.contains("isenough unpack"), "\(name) uninstall must say to unpack apps first")
            let restore = try XCTUnwrap(body.range(of: "isenough sessions restore"), "\(name) uninstall must mention sessions restore")
            let repoStep = try XCTUnwrap(body.range(of: name == "zh" ? "才删除仓库文件夹" : "5. Delete the repo folder"))
            XCTAssertLessThan(restore.lowerBound, repoStep.lowerBound, "\(name): restore sessions before deleting the repo")
        }
        let readme = try text("README.md")
        XCTAssertTrue(readme.contains("isenough sessions restore"), "README uninstall must mention sessions restore")
    }

    /// The "landing now" sections are temporary. Once the CHANGELOG 0.1.0 entry is
    /// dated (released), they must have been folded into the normal docs.
    func testLandingNowSectionsAreGoneOnceReleased() throws {
        let changelog = try text("CHANGELOG.md")
        let released = !changelog.contains("## [0.1.0] - Unreleased")
        guard released else { return }
        for (file, marker) in [("README.md", "landing now"), ("CHANGELOG.md", "landing now"),
                               ("docs/user-guide.md", "landing now"), ("docs/user-guide.md", "本版本新增")] {
            XCTAssertFalse(try text(file).contains(marker), "\(file) still has the \(marker) section; see docs/release-checklist.md")
        }
    }

    func testChangelogHas010Entry() throws {
        let changelog = try text("CHANGELOG.md")
        XCTAssertTrue(changelog.contains("## [0.1.0]"))
        XCTAssertTrue(changelog.contains("AppIcon.icns"))
        XCTAssertTrue(changelog.contains("docs/user-guide.md"))
    }
}
