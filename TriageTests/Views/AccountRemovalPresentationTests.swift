import XCTest
@testable import Triage

final class AccountRemovalPresentationTests: XCTestCase {
    func testDestructiveConfirmationDisclosesExternalBackupLimitation() {
        XCTAssertEqual(
            AccountRemovalPresentation.confirmationMessage(accountLogin: "octocat"),
            "This removes octocat, its credentials, and all encrypted local Triage data from this Mac. GitHub content is not changed. Triage cannot erase Time Machine backups, user-created copies, filesystem snapshots, or other external backups."
        )
    }

    func testFallbackDestructiveConfirmationRetainsExternalBackupLimitation() {
        XCTAssertEqual(
            AccountRemovalPresentation.confirmationMessage(accountLogin: nil),
            "This removes the account and its encrypted local data from this Mac. Triage cannot erase Time Machine backups, user-created copies, filesystem snapshots, or other external backups."
        )
    }

    func testKeylessVaultRecoveryDisclosureExplainsLocalDeletionAndResync() {
        XCTAssertEqual(
            AccountRemovalPresentation.unavailableVaultRecoveryMessage,
            "This removes encrypted local Triage data whose vault key is unavailable. GitHub content is not changed. Afterward, reconnect to GitHub to resync. Triage cannot erase Time Machine backups, user-created copies, filesystem snapshots, or other external backups."
        )
    }

    func testRemovalFailuresUseFixedPrivateRecoveryCopy() {
        let ordinary = AccountRemovalPresentation.removalFailureMessage(isUnavailableVault: false)
        let keyless = AccountRemovalPresentation.removalFailureMessage(isUnavailableVault: true)

        XCTAssertEqual(
            ordinary,
            "The account and its encrypted local data were not removed. Try again after resolving the local storage issue."
        )
        XCTAssertEqual(
            keyless,
            "The unavailable account’s encrypted local data were not removed. Try again after resolving the local storage issue."
        )
        XCTAssertFalse(ordinary.contains("/"))
        XCTAssertFalse(keyless.localizedCaseInsensitiveContains("keychain"))
    }
}
