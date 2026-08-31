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
}
