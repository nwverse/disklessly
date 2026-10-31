import XCTest
import Crypto
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class LicenseTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private func date(_ s: String) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter(); f.calendar = c; f.timeZone = c.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    private func token(edition: String = "pro", expires: String? = nil, signer: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        try License.issue(LicensePayload(id: "t1", edition: edition, email: "a@b.c", issued: "2026-01-01", expires: expires, updatesUntil: "2027-01-01"), privateKey: signer ?? key)
    }

    func testBuyoutIsLicensedAndUnlimited() throws {
        let state = License.verify(try token(), publicKey: key.publicKey, now: date("2030-01-01"))
        guard case .licensed(let p) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(p.edition, "pro")
        XCTAssertTrue(state.unlimited)
    }

    func testPromoWorksThroughItsLastDayAndThenExpires() throws {
        let t = try token(edition: "promo", expires: "2026-12-31")
        XCTAssertTrue(License.verify(t, publicKey: key.publicKey, now: date("2026-12-31")).unlimited)
        guard case .expired = License.verify(t, publicKey: key.publicKey, now: date("2027-01-01")) else { return XCTFail("should expire") }
        XCTAssertFalse(License.verify(t, publicKey: key.publicKey, now: date("2027-01-01")).unlimited)
    }

    func testPromoWithoutExpiryIsRefused() throws {
        guard case .invalid = License.verify(try token(edition: "promo"), publicKey: key.publicKey) else { return XCTFail("a promo code must expire") }
    }

    func testForgedTamperedAndGarbageCodesAreInvalid() throws {
        let other = Curve25519.Signing.PrivateKey()
        guard case .invalid = License.verify(try token(signer: other), publicKey: key.publicKey) else { return XCTFail("wrong signer") }
        var parts = try token().split(separator: ".").map(String.init)
        parts[1] = License.base64url(Data("{\"v\":1,\"product\":\"disklessly\",\"id\":\"x\",\"edition\":\"pro\",\"issued\":\"2026-01-01\"}".utf8))
        guard case .invalid = License.verify(parts.joined(separator: "."), publicKey: key.publicKey) else { return XCTFail("tampered payload") }
        for junk in ["", "abc", "DSL1.x", "DSL1.!!.@@", "XXX1.a.b"] {
            guard case .invalid = License.verify(junk, publicKey: key.publicKey) else { return XCTFail("garbage: \(junk)") }
        }
    }

    func testWrongProductIsRefused() throws {
        var payload = LicensePayload(id: "t", edition: "pro", issued: "2026-01-01")
        payload.product = "other"
        guard case .invalid = License.verify(try License.issue(payload, privateKey: key), publicKey: key.publicKey) else { return XCTFail("product") }
    }

    func testActivateSavesLoadsAndDeactivateRemoves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lic-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertEqual(License.load(stateDir: dir, publicKey: key.publicKey), .free)
        XCTAssertThrowsError(try License.activate("junk", stateDir: dir, publicKey: key.publicKey))
        XCTAssertEqual(License.load(stateDir: dir, publicKey: key.publicKey), .free, "a refused code writes nothing")
        try License.activate("  \(try token())\n", stateDir: dir, publicKey: key.publicKey)
        XCTAssertTrue(License.load(stateDir: dir, publicKey: key.publicKey).unlimited)
        XCTAssertThrowsError(try License.activate(try token(edition: "promo", expires: "2020-01-01"), stateDir: dir, publicKey: key.publicKey))
        try License.deactivate(stateDir: dir)
        XCTAssertEqual(License.load(stateDir: dir, publicKey: key.publicKey), .free)
    }

    func testFreeLimitCountsOffloadedAppsAndSparesRepacks() throws {
        let two: Set<String> = ["a", "b"]
        XCTAssertNoThrow(try License.checkPack(state: .free, offloaded: [], packing: "a"))
        XCTAssertNoThrow(try License.checkPack(state: .free, offloaded: ["a"], packing: "b"))
        XCTAssertThrowsError(try License.checkPack(state: .free, offloaded: two, packing: "c")) { error in
            guard case DisklesslyError.licenseRequired(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("license activate"))
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 15)
        }
        XCTAssertNoThrow(try License.checkPack(state: .free, offloaded: two, packing: "a"), "re-packing an offloaded app is not a new app")
        let licensed = LicenseState.licensed(LicensePayload(id: "x", edition: "pro", issued: "2026-01-01"))
        XCTAssertNoThrow(try License.checkPack(state: licensed, offloaded: two, packing: "c"))
        let expired = LicenseState.expired(LicensePayload(id: "x", edition: "promo", issued: "2026-01-01", expires: "2026-02-01"))
        XCTAssertThrowsError(try License.checkPack(state: expired, offloaded: two, packing: "c")) { error in
            XCTAssertTrue((error as? DisklesslyError)?.errorDescription?.contains("expired on 2026-02-01") == true)
        }
    }

    func testEmbeddedPublicKeyIsAValidEd25519Key() {
        XCTAssertNotNil(License.publicKey)
    }
}
