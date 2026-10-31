import XCTest
import Foundation
@testable import DisklesslyCore
#if os(macOS)
import Security
#endif

/// Round-trips a synchronizable item through the real Keychain. Uses a unique
/// service name and removes it in tearDown. Skips when no keychain is usable
/// (CI without a login keychain, locked keychain).
final class KeychainSyncTests: XCTestCase {
    private let service = "io.github.s546126.disklessly.tests.keychain-sync.\(UUID().uuidString)"
    private let accounts = ["segment-key-test", "segment-key-current"]

    override func tearDown() {
        #if os(macOS)
        let store = KeychainSecretStore()
        for account in accounts { store.delete(service: service, account: account) }
        #endif
        super.tearDown()
    }

    func testSynchronizableSaveLoadOverwrite() throws {
        #if os(macOS)
        let store = KeychainSecretStore()
        do {
            try store.save(service: service, account: accounts[0], secret: "first", synchronizable: true)
        } catch let error as DisklesslyError {
            throw XCTSkip("keychain unavailable: \(error.errorDescription ?? "")")
        }
        guard let outcome = store.lastSaveOutcome else { return XCTFail("save did not report an outcome") }
        switch outcome {
        case .synchronizable, .localFallback(status: KeychainSecretStore.missingEntitlement):
            break
        default:
            XCTFail("unexpected outcome \(outcome)")
        }
        XCTAssertEqual(try store.load(service: service, account: accounts[0]), "first")

        try store.save(service: service, account: accounts[0], secret: "second", synchronizable: true)
        XCTAssertEqual(try store.load(service: service, account: accounts[0]), "second")

        // A synchronizable item is replaced by a later local save, not duplicated.
        try store.save(service: service, account: accounts[0], secret: "third")
        XCTAssertEqual(store.lastSaveOutcome, .local)
        XCTAssertEqual(try store.load(service: service, account: accounts[0]), "third")

        store.delete(service: service, account: accounts[0])
        XCTAssertNil(try store.load(service: service, account: accounts[0]))
        #else
        throw XCTSkip("Keychain is macOS only")
        #endif
    }
}
