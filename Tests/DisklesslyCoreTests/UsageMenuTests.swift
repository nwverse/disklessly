import XCTest
@testable import DisklesslyEngine

final class UsageMenuTests: XCTestCase {
    func testFolderBoxesCarryTheirPathAndRefusal() {
        var input = UsageInputs(totalBytes: 100 << 30, freeBytes: 10 << 30)
        var code = UsageInputs.Entry(name: "code", bytes: 5 << 30, kind: .personal)
        code.path = "/Users/me/code"
        var docs = UsageInputs.Entry(name: "Documents", bytes: 4 << 30, kind: .personal)
        docs.path = "/Users/me/Documents"
        input.personal = [code, docs]
        let tree = UsageMap.annotate(UsageMap.assemble(input)) { $0.hasSuffix("/Documents") ? "is a standard folder" : nil }
        let personal = tree.children.first { $0.key == "personal" }!
        let codeNode = personal.children.first { $0.name == "code" }!
        let docsNode = personal.children.first { $0.name == "Documents" }!
        XCTAssertEqual(codeNode.jsonObject()["path"] as? String, "/Users/me/code")
        XCTAssertNil(codeNode.jsonObject()["refusal"])
        XCTAssertEqual(docsNode.jsonObject()["refusal"] as? String, "is a standard folder")
        XCTAssertNil(personal.jsonObject()["path"], "a group box is not one folder")
    }
}
