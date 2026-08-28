import XCTest
@testable import Triage

final class KeychainSecretStoreTests: XCTestCase {
    func testVaultKeyRequiresExactly256Bits() throws {
        XCTAssertThrowsError(try VaultKey(data: Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(error as? SecretStoreError, .invalidVaultKeyLength)
        }
        XCTAssertNoThrow(try VaultKey(data: Data(repeating: 0, count: 32)))
    }

    func testGeneratedVaultKeysHaveRequiredLengthAndFreshEntropy() throws {
        let first = try VaultKey.generate()
        let second = try VaultKey.generate()

        XCTAssertEqual(first.data.count, VaultKey.byteCount)
        XCTAssertEqual(second.data.count, VaultKey.byteCount)
        XCTAssertNotEqual(first, second)
    }
}
