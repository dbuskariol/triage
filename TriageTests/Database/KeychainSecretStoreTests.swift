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

    func testSuccessfulSecretCacheIsScopedAndInvalidatedByMutation() {
        var cache = KeychainSecretStoreCache()
        let firstAccount = AccountID.make()
        let secondAccount = AccountID.make()
        let credentialID = CredentialID.make()
        let firstValue = Data("first".utf8)
        let secondValue = Data("second".utf8)

        XCTAssertNil(cache.value(kind: .vaultKey, accountID: firstAccount, credentialID: nil))
        XCTAssertNil(cache.accountIDs())

        cache.store(firstValue, kind: .vaultKey, accountID: firstAccount, credentialID: nil)
        cache.store(secondValue, kind: .oauthAccessToken, accountID: firstAccount, credentialID: credentialID)
        XCTAssertEqual(cache.value(kind: .vaultKey, accountID: firstAccount, credentialID: nil), firstValue)
        XCTAssertEqual(
            cache.value(kind: .oauthAccessToken, accountID: firstAccount, credentialID: credentialID),
            secondValue
        )
        XCTAssertNil(cache.value(kind: .vaultKey, accountID: secondAccount, credentialID: nil))

        cache.storeAccountIDs([firstAccount])
        cache.store(Data("other".utf8), kind: .vaultKey, accountID: secondAccount, credentialID: nil)
        XCTAssertEqual(cache.accountIDs(), [firstAccount, secondAccount].sorted { $0.rawValue < $1.rawValue })

        cache.remove(kind: .oauthAccessToken, accountID: firstAccount, credentialID: credentialID)
        XCTAssertNil(cache.value(kind: .oauthAccessToken, accountID: firstAccount, credentialID: credentialID))
        XCTAssertNil(cache.accountIDs())

        cache.storeAccountIDs([firstAccount, secondAccount])
        cache.removeAll(for: firstAccount)
        XCTAssertNil(cache.value(kind: .vaultKey, accountID: firstAccount, credentialID: nil))
        XCTAssertEqual(cache.accountIDs(), [secondAccount])
    }
}
