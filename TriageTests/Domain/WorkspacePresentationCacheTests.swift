import XCTest
@testable import Triage

final class WorkspacePresentationCacheTests: XCTestCase {
    func testCacheIsolatedByAccountOrganizationAndRevision() {
        let accountA = AccountID(rawValue: "account-a")!
        let accountB = AccountID(rawValue: "account-b")!
        let organizationA = OrganizationID(rawValue: "organization-a")!
        let organizationB = OrganizationID(rawValue: "organization-b")!
        var cache = WorkspacePresentationCache<String>()

        let accountAOrganizationA = scope(account: accountA, organization: organizationA)
        let accountAOrganizationB = scope(account: accountA, organization: organizationB)
        let accountBOrganizationA = scope(account: accountB, organization: organizationA)
        cache[accountAOrganizationA] = "account-a organization-a"
        cache[accountAOrganizationB] = "account-a organization-b"
        cache[accountBOrganizationA] = "account-b organization-a"

        XCTAssertEqual(cache[accountAOrganizationA], "account-a organization-a")
        XCTAssertEqual(cache[accountAOrganizationB], "account-a organization-b")
        XCTAssertEqual(cache[accountBOrganizationA], "account-b organization-a")
    }

    func testRemovingAnAccountEvictsOnlyItsSnapshots() {
        let accountA = AccountID(rawValue: "account-a")!
        let accountB = AccountID(rawValue: "account-b")!
        let organizationID = OrganizationID(rawValue: "organization-a")!
        var cache = WorkspacePresentationCache<String>()

        let accountAScope = scope(account: accountA, organization: organizationID)
        let accountBScope = scope(account: accountB, organization: organizationID)
        cache[accountAScope] = "account-a"
        cache[accountBScope] = "account-b"
        cache.removeAll(for: accountA)

        XCTAssertNil(cache[accountAScope])
        XCTAssertEqual(cache[accountBScope], "account-b")
    }

    func testCredentialRotationCannotReadPriorRevision() {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let prior = scope(account: accountID, organization: organizationID, credential: "credential-a")
        let rotated = scope(account: accountID, organization: organizationID, credential: "credential-b")
        var cache = WorkspacePresentationCache<String>()

        cache[prior] = "prior credential"

        XCTAssertNil(cache[rotated])
        cache[rotated] = "rotated credential"
        XCTAssertEqual(cache[prior], "prior credential")
        XCTAssertEqual(cache[rotated], "rotated credential")
    }

    func testCapabilityRotationCannotReadPriorRevision() {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let prior = scope(account: accountID, organization: organizationID, capability: "capability-a")
        let rotated = scope(account: accountID, organization: organizationID, capability: "capability-b")
        var cache = WorkspacePresentationCache<String>()

        cache[prior] = "prior capability"

        XCTAssertNil(cache[rotated])
        cache[rotated] = "rotated capability"
        XCTAssertEqual(cache[prior], "prior capability")
        XCTAssertEqual(cache[rotated], "rotated capability")
    }

    private func scope(
        account: AccountID,
        organization: OrganizationID,
        credential: String = "credential",
        capability: String = "capability"
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: account,
            organizationID: organization,
            credentialRevision: CredentialRevision(rawValue: credential)!,
            capabilityRevision: CapabilityRevision(rawValue: capability)!
        )
    }
}
