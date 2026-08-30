import XCTest
@testable import Triage

@MainActor
final class SSOAuthorizationCoordinatorTests: XCTestCase {
    func testOnlyRequiredAuthorizationHeadersAreEligibleForBrowserRecovery() {
        let coordinator = SSOAuthorizationCoordinator()
        XCTAssertFalse(coordinator.authorizeInBrowser(.partialResults(Set([1]))))
        XCTAssertFalse(coordinator.authorizeInBrowser(.malformed))
    }
}
