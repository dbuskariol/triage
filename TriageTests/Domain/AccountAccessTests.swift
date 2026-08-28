import XCTest
@testable import Triage

final class AccountAccessTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 100)

    func testClassicPersonalAccessTokensCannotAuthenticateCopilotDirectly() {
        XCTAssertTrue(AuthenticationKind.oauth.supportsDirectCopilotAuthentication)
        XCTAssertTrue(AuthenticationKind.fineGrainedPersonalAccessToken.supportsDirectCopilotAuthentication)
        XCTAssertFalse(AuthenticationKind.classicPersonalAccessToken.supportsDirectCopilotAuthentication)
    }

    func testAccessReturnsUnknownForAnUnprobedCapability() {
        let access = OrganizationAccess(
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "revision-1")!,
            capabilities: [
                CapabilityAvailability(
                    capability: .privateRepositories,
                    status: .available,
                    checkedAt: date
                )
            ],
            checkedAt: date
        )

        XCTAssertEqual(access.status(for: .privateRepositories), .available)
        XCTAssertEqual(access.status(for: .discussions), .unknown)
    }
}
