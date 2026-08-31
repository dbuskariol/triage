import Foundation
import XCTest
@testable import Triage

final class DailyActiveAccountIdentityRefreshServiceTests: XCTestCase {
    func testNotDueDoesNotPerformIdentityOrInventoryRequests() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let calls = DailyIdentityCallRecorder()
        let service = fixture.service(
            calls: calls,
            now: fixture.observedAt.addingTimeInterval(60),
            user: fixture.user(),
            inventory: fixture.inventory(),
            inventoryLastValidatedAt: fixture.observedAt
        )

        let outcome = try await service.refreshIfDue(for: fixture.account)

        guard case .notDue = outcome else {
            return XCTFail("A recently validated active account must not refresh early.")
        }
        let userCalls = await calls.userCalls()
        let inventoryCalls = await calls.inventoryCalls()
        XCTAssertEqual(userCalls, 0)
        XCTAssertEqual(inventoryCalls, 0)
    }

    func testDailyIdentityMismatchRevokesCredentialWithoutReplacingProfile() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let calls = DailyIdentityCallRecorder()
        let mismatched = GitHubUserDTO(
            id: 2,
            nodeID: "U_2",
            login: "different-user",
            name: "Different User",
            avatarURL: nil
        )
        let service = fixture.service(
            calls: calls,
            now: fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval),
            user: mismatched,
            inventory: fixture.inventory()
        )

        let outcome = try await service.refreshIfDue(for: fixture.account)

        guard case let .credentialRevoked(account) = outcome else {
            return XCTFail("A different immutable GitHub identity must revoke the credential.")
        }
        XCTAssertEqual(account.credentialStatus, .revoked)
        XCTAssertEqual(account.login, fixture.account.login)
        let inventoryCalls = await calls.inventoryCalls()
        XCTAssertEqual(inventoryCalls, 0)
        let persistedAccounts = try await AccountRepository(vault: fixture.vault).accounts()
        let persisted = try XCTUnwrap(persistedAccounts.first)
        XCTAssertEqual(persisted.credentialStatus, .revoked)
        XCTAssertEqual(persisted.login, fixture.account.login)
    }

    func testInventoryFailureKeepsExistingOrganizationsAndDoesNotSynthesizeCompletion() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let calls = DailyIdentityCallRecorder()
        let service = fixture.service(
            calls: calls,
            now: fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval),
            user: fixture.user(),
            inventoryFails: true
        )

        let outcome = try await service.refreshIfDue(for: fixture.account)

        guard case let .inventoryUnavailable(snapshot) = outcome else {
            return XCTFail("An inventory failure must not be treated as a complete refresh.")
        }
        XCTAssertEqual(snapshot.organizations, [fixture.organization])
        let persistedOrganizations = try await AccountRepository(vault: fixture.vault)
            .organizations(for: fixture.account.id)
        let userCalls = await calls.userCalls()
        let inventoryCalls = await calls.inventoryCalls()
        XCTAssertEqual(persistedOrganizations, [fixture.organization])
        XCTAssertEqual(userCalls, 1)
        XCTAssertEqual(inventoryCalls, 1)
    }

    func testInventoryFailurePreservesUserValidationButRemainsDueForVisibilityRetry() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let calls = DailyIdentityCallRecorder()
        let now = fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval)
        let service = fixture.service(
            calls: calls,
            now: now,
            user: fixture.user(),
            inventoryFails: true,
            inventoryLastValidatedAt: fixture.observedAt
        )

        let first = try await service.refreshIfDue(for: fixture.account)
        let persistedAccounts = try await AccountRepository(vault: fixture.vault).accounts()
        let persisted = try XCTUnwrap(persistedAccounts.first)
        let second = try await service.refreshIfDue(for: persisted)

        guard case .inventoryUnavailable = first, case .inventoryUnavailable = second else {
            return XCTFail("A failed inventory must remain incomplete and retryable.")
        }
        XCTAssertEqual(persisted.lastValidatedAt, now)
        let userCalls = await calls.userCalls()
        let inventoryCalls = await calls.inventoryCalls()
        XCTAssertEqual(userCalls, 2)
        XCTAssertEqual(inventoryCalls, 2)
    }

    func testCrossAccountRequestIsRejectedBeforeNetworkWork() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let calls = DailyIdentityCallRecorder()
        let service = fixture.service(
            calls: calls,
            now: fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval),
            user: fixture.user(),
            inventory: fixture.inventory()
        )
        let otherAccount = GitHubAccount(
            id: AccountID.make(),
            githubUserID: fixture.account.githubUserID,
            nodeID: fixture.account.nodeID,
            login: fixture.account.login,
            authenticationKind: .oauth,
            credentialID: fixture.account.credentialID,
            credentialStatus: .active,
            createdAt: fixture.observedAt,
            lastValidatedAt: fixture.observedAt
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.refreshIfDue(for: otherAccount)
        } verify: { error in
            XCTAssertEqual(error as? DailyActiveAccountIdentityRefreshError, .accountScopeMismatch)
        }
        let userCalls = await calls.userCalls()
        let inventoryCalls = await calls.inventoryCalls()
        XCTAssertEqual(userCalls, 0)
        XCTAssertEqual(inventoryCalls, 0)
    }

    func testCredentialRevisionChangeDuringInventoryIsNotPublished() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let calls = DailyIdentityCallRecorder()
        let rotatedRevision = CredentialRevision(rawValue: "daily-rotated-revision")!
        let service = DailyActiveAccountIdentityRefreshService(
            vault: fixture.vault,
            loadAuthenticatedUser: {
                await calls.recordUserCall()
                return fixture.user()
            },
            loadOrganizationInventory: { _, _ in
                await calls.recordInventoryCall()
                try await AccountRepository(vault: fixture.vault).save(
                    fixture.account,
                    credentialRevision: rotatedRevision
                )
                return fixture.inventory()
            },
            clock: {
                fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval)
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.refreshIfDue(for: fixture.account)
        } verify: { error in
            XCTAssertEqual(error as? DailyActiveAccountIdentityRefreshError, .staleAccountAuthority)
        }
        let userCalls = await calls.userCalls()
        let inventoryCalls = await calls.inventoryCalls()
        let persistedOrganizations = try await AccountRepository(vault: fixture.vault)
            .organizations(for: fixture.account.id)
        XCTAssertEqual(userCalls, 1)
        XCTAssertEqual(inventoryCalls, 1)
        XCTAssertEqual(persistedOrganizations, [fixture.organization])
    }

    func testStaleAuthenticatedUserReceiptAuthorityIsNeverPublished() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let service = DailyActiveAccountIdentityRefreshService(
            vault: fixture.vault,
            loadAuthenticatedUser: {
                throw AuthenticatedUserReplayReceiptRepositoryError.staleAuthority
            },
            loadOrganizationInventory: { _, _ in
                throw CancellationError()
            },
            clock: {
                fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval)
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.refreshIfDue(for: fixture.account)
        } verify: { error in
            XCTAssertEqual(error as? DailyActiveAccountIdentityRefreshError, .staleAccountAuthority)
        }
        let persisted = try await AccountRepository(vault: fixture.vault).accounts()
        XCTAssertEqual(persisted, [fixture.account])
    }

    func testStaleOrganizationInventoryReceiptAuthorityIsNeverPublished() async throws {
        let fixture = try await DailyIdentityFixture()
        defer { fixture.remove() }
        let service = DailyActiveAccountIdentityRefreshService(
            vault: fixture.vault,
            loadAuthenticatedUser: { fixture.user() },
            loadOrganizationInventory: { _, _ in
                throw PostAccountIdentityReplayReceiptRepositoryError.staleAuthority
            },
            clock: {
                fixture.observedAt.addingTimeInterval(RefreshCadence.dailyCapabilityProbe.baseInterval)
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.refreshIfDue(for: fixture.account)
        } verify: { error in
            XCTAssertEqual(error as? DailyActiveAccountIdentityRefreshError, .staleAccountAuthority)
        }
        let persisted = try await AccountRepository(vault: fixture.vault).accounts()
        XCTAssertEqual(persisted, [fixture.account])
    }
}

private final class DailyIdentityFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let observedAt = Date(timeIntervalSinceReferenceDate: 10_000)
    let credentialRevision = CredentialRevision(rawValue: "daily-credential-revision")!

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".triage-daily-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        account = GitHubAccount(
            id: AccountID.make(),
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            displayName: "Octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        organization = GitHubOrganization(
            id: OrganizationID(rawValue: "O_1")!,
            githubOrganizationID: 1,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "acme"
        )
        vault = try await VaultRegistry(rootDirectory: root).open(
            accountID: account.id,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        try await repository.save(account, credentialRevision: credentialRevision)
        try await repository.save(
            organization,
            access: OrganizationAccess(
                accountID: account.id,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "daily-capability-revision")!,
                capabilities: [],
                checkedAt: observedAt
            )
        )
    }

    func user() -> GitHubUserDTO {
        GitHubUserDTO(
            id: account.githubUserID,
            nodeID: account.nodeID.rawValue,
            login: account.login,
            name: account.displayName,
            avatarURL: account.avatarURL
        )
    }

    func inventory() -> GitHubOrganizationInventory {
        let dto = GitHubOrganizationDTO(
            id: organization.githubOrganizationID,
            nodeID: organization.nodeID.rawValue,
            login: organization.login,
            avatarURL: organization.avatarURL
        )
        return GitHubOrganizationInventory(
            organizations: [dto],
            pages: [GitHubOrganizationInventoryPage(
                page: GitHubPage(
                    values: [dto],
                    payload: Data(#"[{"id":1,"node_id":"O_1","login":"acme"}]"#.utf8),
                    nextPageURL: nil,
                    linkHeader: nil,
                    etag: "\"daily-inventory\"",
                    lastModified: nil,
                    ssoHeader: nil
                ),
                requestKey: "GET /user/orgs?per_page=100",
                nextRequestKey: nil
            )],
            ssoHeaders: []
        )
    }

    func service(
        calls: DailyIdentityCallRecorder,
        now: Date,
        user: GitHubUserDTO,
        inventory: GitHubOrganizationInventory? = nil,
        inventoryFails: Bool = false,
        inventoryLastValidatedAt: Date? = nil
    ) -> DailyActiveAccountIdentityRefreshService {
        DailyActiveAccountIdentityRefreshService(
            vault: vault,
            loadAuthenticatedUser: {
                await calls.recordUserCall()
                return user
            },
            loadOrganizationInventory: { _, _ in
                await calls.recordInventoryCall()
                if inventoryFails { throw URLError(.notConnectedToInternet) }
                return inventory!
            },
            loadOrganizationInventoryValidatedAt: { _, _ in inventoryLastValidatedAt },
            clock: { now },
            newCredentialRevision: { CredentialRevision(rawValue: "daily-revoked-revision")! }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor DailyIdentityCallRecorder {
    private var users = 0
    private var inventories = 0

    func recordUserCall() { users += 1 }
    func recordInventoryCall() { inventories += 1 }
    func userCalls() -> Int { users }
    func inventoryCalls() -> Int { inventories }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
