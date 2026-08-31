import XCTest
@testable import Triage

final class AccountRepositoryTests: XCTestCase {
    func testAccountAndOrganizationUpsertsPreserveAccountScopedAccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
            login: "github"
        )
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "cap-1")!,
            capabilities: [
                CapabilityAvailability(
                    capability: .privateRepositories,
                    status: .available,
                    checkedAt: date,
                    detail: "private repositories confirmed"
                )
            ],
            checkedAt: date
        )

        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "cred-1")!)
        try await repository.save(organization, access: access, selectedAt: date)

        let counts = try await vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM accounts")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_organizations")!
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        let restoredAccesses = try await repository.organizationAccesses(for: accountID)
        XCTAssertEqual(restoredAccesses[organizationID], access)

        let remoteRepository = GitHubRepositoryDTO(
            id: 3,
            nodeID: "MDEwOlJlcG9zaXRvcnkz",
            name: "triage",
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            htmlURL: URL(string: "https://github.com/github/triage")!,
            updatedAt: date,
            owner: .init(login: "github")
        )
        _ = try await repository.save(
            repository: remoteRepository,
            organizationID: organizationID,
            accountID: accountID
        )
        let updatedRepository = GitHubRepositoryDTO(
            id: remoteRepository.id,
            nodeID: remoteRepository.nodeID,
            name: remoteRepository.name,
            isPrivate: remoteRepository.isPrivate,
            isArchived: remoteRepository.isArchived,
            hasDiscussions: false,
            htmlURL: remoteRepository.htmlURL,
            updatedAt: remoteRepository.updatedAt.addingTimeInterval(1),
            owner: remoteRepository.owner
        )
        let summary = try await repository.save(
            repository: updatedRepository,
            organizationID: organizationID,
            accountID: accountID
        )
        XCTAssertFalse(summary.hasDiscussions)
        let repositoryWithOmittedDiscussions = GitHubRepositoryDTO(
            id: updatedRepository.id,
            nodeID: updatedRepository.nodeID,
            name: updatedRepository.name,
            isPrivate: updatedRepository.isPrivate,
            isArchived: updatedRepository.isArchived,
            hasDiscussions: nil,
            htmlURL: updatedRepository.htmlURL,
            updatedAt: updatedRepository.updatedAt.addingTimeInterval(1),
            owner: updatedRepository.owner
        )
        let preservedSummary = try await repository.save(
            repository: repositoryWithOmittedDiscussions,
            organizationID: organizationID,
            accountID: accountID
        )
        XCTAssertFalse(preservedSummary.hasDiscussions)
        XCTAssertTrue(preservedSummary.hasDiscussionsKnown)
        let persistedHasDiscussions = try await vault.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT has_discussions FROM repositories WHERE id = ?",
                arguments: [summary.id.rawValue]
            )
        }
        XCTAssertEqual(persistedHasDiscussions, false)
    }

    func testAccountCapabilitiesArePersistedSeparatelyFromOrganizationAccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let snapshot = AccountCapabilitySnapshot(
            accountID: accountID,
            capabilities: [
                CapabilityAvailability(
                    capability: .notifications,
                    status: .available,
                    checkedAt: date
                )
            ],
            checkedAt: date
        )

        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "cred-1")!)
        try await repository.save(snapshot)

        let restoredSnapshot = try await repository.accountCapabilities(for: accountID)
        XCTAssertEqual(restoredSnapshot, snapshot)
        let count = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_capabilities")!
        }
        XCTAssertEqual(count, 1)
    }

    func testAccountScopedOperationsRejectAnotherVaultAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultAccountID = AccountID.make()
        let foreignAccountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: vaultAccountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let foreignAccount = GitHubAccount(
            id: foreignAccountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: .now,
            lastValidatedAt: .now
        )

        do {
            try await repository.save(
                foreignAccount,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? AccountRepositoryError, .accountScopeMismatch)
        }
        let accounts = try await repository.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testPostCredentialInventoryRejectsAnOlderRevisionWithoutWritingOrganizations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let account = testAccount(accountID: accountID)
        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "credential-current")!)

        do {
            try await repository.reconcilePostCredentialOrganizationInventory(
                [testOrganization(id: "O_stale", githubID: 12, login: "stale")],
                accountID: accountID,
                expectedCredentialRevision: CredentialRevision(rawValue: "credential-superseded")!,
                observedAt: .now
            )
            XCTFail("Expected the stale replay to be rejected.")
        } catch {
            XCTAssertEqual(error as? AccountRepositoryError, .staleCredentialRevision)
        }

        let count = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM organizations")!
        }
        XCTAssertEqual(count, 0)
    }

    func testStaleMetadataScopeCannotCreateOrResetItsStream() async throws {
        let fixture = try await metadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receipts = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        let streamID = try await receipts.ensureMetadataStream(for: fixture.scope)
        try await SyncStreamRepository(vault: fixture.vault).save(
            SyncStream(
                id: streamID,
                accountID: fixture.account.id,
                organizationID: fixture.organization.id,
                feature: .organizationMetadata,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: .now,
                status: .failed,
                failureDetail: "preserve this state"
            )
        )
        try await fixture.accounts.save(
            fixture.account,
            credentialRevision: CredentialRevision(rawValue: "credential-rotated")!
        )

        do {
            _ = try await receipts.ensureMetadataStream(for: fixture.scope)
            XCTFail("Expected a stale scope failure.")
        } catch {
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .staleAuthority)
        }

        let stream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: streamID,
            accountID: fixture.account.id
        )
        XCTAssertEqual(stream?.status, .failed)
        XCTAssertEqual(stream?.failureDetail, "preserve this state")
    }

    func testCancelledMetadataReplacementDoesNotPersistEvidence() async throws {
        let fixture = try await metadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receipts = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        let streamID = try await receipts.ensureMetadataStream(for: fixture.scope)
        let identity = OrganizationMetadataReplayIdentity(
            scope: fixture.scope,
            streamID: streamID,
            requestKey: "GET /orgs/\(fixture.organization.login)"
        )
        let response = metadataResponse(for: fixture.organization)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await receipts.replaceMetadata(
                response,
                for: identity,
                organization: fixture.organization,
                observedAt: .now
            )
        }

        do {
            try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected: cancellation is checked before the transaction mutates.
        }

        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM organization_metadata_replay_receipts")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testMetadataReplayRejectsCrossNodeRawEvidence() async throws {
        let fixture = try await metadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receipts = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        let streamID = try await receipts.ensureMetadataStream(for: fixture.scope)
        let identity = OrganizationMetadataReplayIdentity(
            scope: fixture.scope,
            streamID: streamID,
            requestKey: "GET /orgs/\(fixture.organization.login)"
        )
        try await receipts.replaceMetadata(
            metadataResponse(for: fixture.organization),
            for: identity,
            organization: fixture.organization,
            observedAt: .now
        )
        try await fixture.vault.write { database in
            try database.execute(sql: "DROP TRIGGER organization_metadata_replay_protect_snapshot_update")
            try database.execute(
                sql: "UPDATE raw_api_snapshots SET github_node_id = ?",
                arguments: ["O_other"]
            )
        }

        let replay = try await receipts.validatedMetadata(
            for: identity,
            organization: fixture.organization,
            validatedAt: .now
        )
        XCTAssertNil(replay)
    }

    func testInventoryReceiptRejectsEmptyNodeOrLoginBeforePublishingAuthority() async throws {
        let fixture = try await metadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let dto = GitHubOrganizationDTO(id: 77, nodeID: " ", login: "inventory", avatarURL: nil)
        let page = GitHubPage(
            values: [dto],
            payload: try JSONEncoder().encode([dto]),
            nextPageURL: nil,
            linkHeader: nil,
            etag: "\"inventory\"",
            lastModified: nil,
            ssoHeader: nil
        )
        let inventory = GitHubOrganizationInventory(
            organizations: [dto],
            pages: [GitHubOrganizationInventoryPage(
                page: page,
                requestKey: AccountOrganizationInventoryReplayIdentity.requestKey,
                nextRequestKey: nil
            )],
            ssoHeaders: []
        )
        let identity = AccountOrganizationInventoryReplayIdentity(
            accountID: fixture.account.id,
            credentialRevision: fixture.scope.credentialRevision
        )

        do {
            try await PostAccountIdentityReplayReceiptRepository(vault: fixture.vault).replaceInventory(
                inventory,
                for: identity,
                observedAt: .now
            )
            XCTFail("Expected malformed inventory evidence to be rejected.")
        } catch {
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .invalidReceipt)
        }
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_organization_inventory_replay_receipts")!
        }
        XCTAssertEqual(count, 0)
    }

    func testMetadataReceiptRejectsPayloadOverTheContractBudgetBeforePersistence() async throws {
        let fixture = try await metadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receipts = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        let streamID = try await receipts.ensureMetadataStream(for: fixture.scope)
        let identity = OrganizationMetadataReplayIdentity(
            scope: fixture.scope,
            streamID: streamID,
            requestKey: "GET /orgs/\(fixture.organization.login)"
        )
        let valid = metadataResponse(for: fixture.organization)
        let oversized = GitHubResponse(
            value: valid.value,
            payload: Data(repeating: 0, count: PostAccountIdentityReplayReceiptRepository.maximumMetadataRawPayloadBytes + 1),
            etag: valid.etag,
            lastModified: valid.lastModified,
            ssoHeader: nil
        )

        do {
            try await receipts.replaceMetadata(
                oversized,
                for: identity,
                organization: fixture.organization,
                observedAt: .now
            )
            XCTFail("Expected oversized metadata evidence to be rejected.")
        } catch {
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .invalidRawEvidence)
        }
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM organization_metadata_replay_receipts")!
        }
        XCTAssertEqual(count, 0)
    }

    private func metadataFixture() async throws -> (
        directory: URL,
        vault: AccountVault,
        accounts: AccountRepository,
        account: GitHubAccount,
        organization: GitHubOrganization,
        scope: SynchronizationScope
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        let account = testAccount(accountID: accountID)
        let organization = testOrganization(id: "O_metadata", githubID: 42, login: "metadata")
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organization.id,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "capability-current")!,
            capabilities: [],
            checkedAt: .now
        )
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential-current")!)
        try await accounts.save(organization, access: access)
        let scope = try await accounts.synchronizationScope(for: accountID, organizationID: organization.id)
        return (directory, vault, accounts, account, organization, scope)
    }

    private func testAccount(accountID: AccountID) -> GitHubAccount {
        GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_test")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: .now,
            lastValidatedAt: .now
        )
    }

    private func testOrganization(id: String, githubID: UInt64, login: String) -> GitHubOrganization {
        GitHubOrganization(
            id: OrganizationID(rawValue: id)!,
            githubOrganizationID: githubID,
            nodeID: GitHubNodeID(rawValue: id)!,
            login: login
        )
    }

    private func metadataResponse(for organization: GitHubOrganization) -> GitHubResponse<GitHubOrganizationDTO> {
        let payload = Data("{\"id\":\(organization.githubOrganizationID),\"node_id\":\"\(organization.nodeID.rawValue)\",\"login\":\"\(organization.login)\"}".utf8)
        return GitHubResponse(
            value: GitHubOrganizationDTO(
                id: organization.githubOrganizationID,
                nodeID: organization.nodeID.rawValue,
                login: organization.login,
                avatarURL: nil
            ),
            payload: payload,
            etag: "\"metadata\"",
            lastModified: nil,
            ssoHeader: nil
        )
    }
}
