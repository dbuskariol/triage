import XCTest
@testable import Triage

final class WorkspacePresentationCacheTests: XCTestCase {
    func testCacheIsolatedByAccountAndOrganization() {
        let accountA = AccountID(rawValue: "account-a")!
        let accountB = AccountID(rawValue: "account-b")!
        let organizationA = OrganizationID(rawValue: "organization-a")!
        let organizationB = OrganizationID(rawValue: "organization-b")!
        var cache = WorkspacePresentationCache<String>()

        cache[accountA, organizationA] = "account-a organization-a"
        cache[accountA, organizationB] = "account-a organization-b"
        cache[accountB, organizationA] = "account-b organization-a"

        XCTAssertEqual(cache[accountA, organizationA], "account-a organization-a")
        XCTAssertEqual(cache[accountA, organizationB], "account-a organization-b")
        XCTAssertEqual(cache[accountB, organizationA], "account-b organization-a")
    }

    func testRemovingAnAccountEvictsOnlyItsSnapshots() {
        let accountA = AccountID(rawValue: "account-a")!
        let accountB = AccountID(rawValue: "account-b")!
        let organizationID = OrganizationID(rawValue: "organization-a")!
        var cache = WorkspacePresentationCache<String>()

        cache[accountA, organizationID] = "account-a"
        cache[accountB, organizationID] = "account-b"
        cache.removeAll(for: accountA)

        XCTAssertNil(cache[accountA, organizationID])
        XCTAssertEqual(cache[accountB, organizationID], "account-b")
    }
}
