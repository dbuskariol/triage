import Foundation
import GRDB
import XCTest
@testable import Triage

final class PostAccountIdentityReplayReceiptRepositoryTests: XCTestCase {
    func testValidInventoryAndMetadataReceiptsReplayExact304Evidence() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        let inventory = fixture.inventory(pages: [[fixture.dto(id: 1, login: "acme")], [fixture.dto(id: 2, login: "other")]])
        try await repository.replaceInventory(inventory, for: fixture.inventoryIdentity, observedAt: fixture.observedAt)
        let inventoryValidators = try await repository.inventoryValidators(for: fixture.inventoryIdentity)
        XCTAssertEqual(inventoryValidators?.eTag, "\"inventory-v1\"")
        let replayedInventory = try await repository.validatedInventory(
            for: fixture.inventoryIdentity,
            validatedAt: fixture.observedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(replayedInventory?.organizations.map(\.login), ["acme", "other"])
        XCTAssertEqual(replayedInventory?.pages.map(\.requestKey), [
            "GET /user/orgs?per_page=100", "GET /user/orgs?page=2&per_page=100"
        ])

        let metadata = fixture.response(for: fixture.organization)
        try await repository.replaceMetadata(metadata, for: fixture.metadataIdentity, organization: fixture.organization, observedAt: fixture.observedAt)
        let metadataValidators = try await repository.metadataValidators(for: fixture.metadataIdentity, organization: fixture.organization)
        XCTAssertEqual(metadataValidators?.eTag, "\"metadata-v1\"")
        let replayedMetadata = try await repository.validatedMetadata(
            for: fixture.metadataIdentity,
            organization: fixture.organization,
            validatedAt: fixture.observedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(replayedMetadata?.value.login, fixture.organization.login)
        XCTAssertEqual(replayedMetadata?.etag, "\"metadata-v1\"")
    }

    func testEmptyModifiedInventoryReceiptIsAValidReplayableSuccess() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceInventory(fixture.inventory(pages: [[]]), for: fixture.inventoryIdentity, observedAt: fixture.observedAt)

        let replay = try await repository.validatedInventory(
            for: fixture.inventoryIdentity,
            validatedAt: fixture.observedAt.addingTimeInterval(1)
        )
        XCTAssertNotNil(replay)
        XCTAssertEqual(replay?.organizations, [])
        XCTAssertEqual(replay?.pages.count, 1)
    }

    func testInvalidInventoryGrammarAndSSOAreRejectedBeforeReceiptPersistence() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        let valid = fixture.inventory(pages: [[fixture.dto(id: 1, login: "acme")]])

        let invalidPage = GitHubOrganizationInventory(
            organizations: valid.organizations,
            pages: [GitHubOrganizationInventoryPage(
                page: valid.pages[0].page,
                requestKey: "GET /user/orgs?page=1&per_page=100",
                nextRequestKey: nil
            )],
            ssoHeaders: []
        )
        await XCTAssertThrowsErrorAsync {
            try await repository.replaceInventory(invalidPage, for: fixture.inventoryIdentity, observedAt: fixture.observedAt)
        } verify: { error in
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .invalidReceipt)
        }

        let ssoInventory = GitHubOrganizationInventory(
            organizations: valid.organizations,
            pages: valid.pages,
            ssoHeaders: [.partialResults(Set([fixture.organization.githubOrganizationID]))]
        )
        await XCTAssertThrowsErrorAsync {
            try await repository.replaceInventory(ssoInventory, for: fixture.inventoryIdentity, observedAt: fixture.observedAt)
        } verify: { error in
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .ssoEvidencePreventsReplay)
        }
        let receiptCount = try await fixture.inventoryReceiptCount()
        XCTAssertEqual(receiptCount, 0)
    }

    func testReceiptPageAndDigestTamperingFailsClosedAndDirectDeletesInvalidateReplay() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceInventory(
            fixture.inventory(pages: [[fixture.dto(id: 1, login: "acme")], [fixture.dto(id: 2, login: "other")]]),
            for: fixture.inventoryIdentity,
            observedAt: fixture.observedAt
        )
        try await fixture.vault.write { database in
            try database.execute(sql: "UPDATE account_organization_inventory_replay_receipts SET normalized_digest = zeroblob(32)")
        }
        let digestTamperedReplay = try await repository.validatedInventory(for: fixture.inventoryIdentity, validatedAt: fixture.observedAt.addingTimeInterval(1))
        XCTAssertNil(digestTamperedReplay)

        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM account_organization_inventory_replay_receipts")
        }
        let deletedReceiptReplay = try await repository.validatedInventory(for: fixture.inventoryIdentity, validatedAt: fixture.observedAt.addingTimeInterval(2))
        XCTAssertNil(deletedReceiptReplay)

        try await repository.replaceInventory(fixture.inventory(pages: [[fixture.dto(id: 1, login: "acme")]]), for: fixture.inventoryIdentity, observedAt: fixture.observedAt)
        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM account_organization_inventory_replay_receipt_pages")
        }
        let deletedPageReplay = try await repository.validatedInventory(for: fixture.inventoryIdentity, validatedAt: fixture.observedAt.addingTimeInterval(3))
        XCTAssertNil(deletedPageReplay)
    }

    func testMetadataRawDigestRequestAuthorityAndReceiptDeletionFailClosed() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceMetadata(fixture.response(for: fixture.organization), for: fixture.metadataIdentity, organization: fixture.organization, observedAt: fixture.observedAt)
        try await fixture.vault.write { database in
            try database.execute(sql: "UPDATE organization_metadata_replay_receipts SET source_revision = 'wrong'")
        }
        let tamperedMetadata = try await repository.validatedMetadata(for: fixture.metadataIdentity, organization: fixture.organization, validatedAt: fixture.observedAt.addingTimeInterval(1))
        XCTAssertNil(tamperedMetadata)

        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM organization_metadata_replay_receipts")
        }
        let deletedMetadata = try await repository.validatedMetadata(for: fixture.metadataIdentity, organization: fixture.organization, validatedAt: fixture.observedAt.addingTimeInterval(2))
        XCTAssertNil(deletedMetadata)
    }

    func testStaleCredentialCapabilityAndCrossAccountScopesAreRejected() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)

        try await fixture.vault.write { database in
            try database.execute(sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?", arguments: [fixture.account.id.rawValue])
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.inventoryValidators(for: fixture.inventoryIdentity)
        } verify: { error in
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .staleAuthority)
        }

        let staleCapabilityScope = SynchronizationScope(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id,
            credentialRevision: CredentialRevision(rawValue: "credential-2")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
        )
        let staleCapabilityIdentity = OrganizationMetadataReplayIdentity(
            scope: staleCapabilityScope,
            streamID: fixture.metadataIdentity.streamID,
            requestKey: fixture.metadataIdentity.requestKey
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.metadataValidators(for: staleCapabilityIdentity, organization: fixture.organization)
        } verify: { error in
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .staleAuthority)
        }

        let otherAccount = AccountOrganizationInventoryReplayIdentity(
            accountID: AccountID.make(), credentialRevision: fixture.inventoryIdentity.credentialRevision
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.inventoryValidators(for: otherAccount)
        } verify: { error in
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .accountScopeMismatch)
        }
    }

    func testInvalid304InventoryRetriesOnceWithoutValidatorsAndReplacesReceipt() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceInventory(fixture.inventory(pages: [[fixture.dto(id: 1, login: "acme")]]), for: fixture.inventoryIdentity, observedAt: fixture.observedAt)
        try await fixture.vault.write { database in
            try database.execute(sql: "UPDATE account_organization_inventory_replay_receipts SET normalized_digest = zeroblob(32)")
        }
        let session = PostAccountReplaySession(responses: [
            "/user/orgs?per_page=100": [
                .init(statusCode: 304, body: Data()),
                .init(statusCode: 200, body: fixture.json([fixture.dto(id: 2, login: "other")]), headers: ["ETag": "\"inventory-v2\""])
            ]
        ])
        let service = PostAccountOrganizationInventoryReplayService(
            client: fixture.identityClient(session: session), receipts: repository, clock: { fixture.observedAt.addingTimeInterval(60) }
        )

        let result = try await service.organizations(accountID: fixture.account.id, credentialRevision: fixture.inventoryIdentity.credentialRevision)
        XCTAssertEqual(result.organizations.map(\.login), ["other"])
        let headers = await session.headers(named: "If-None-Match")
        let replacementValidators = try await repository.inventoryValidators(for: fixture.inventoryIdentity)
        XCTAssertEqual(headers, ["\"inventory-v1\"", nil])
        XCTAssertEqual(replacementValidators?.eTag, "\"inventory-v2\"")
    }

    func testInvalid304MetadataRetriesOnceAndSSO304FailsClosedWithoutRetry() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceMetadata(fixture.response(for: fixture.organization), for: fixture.metadataIdentity, organization: fixture.organization, observedAt: fixture.observedAt)
        try await fixture.vault.write { database in
            try database.execute(sql: "UPDATE organization_metadata_replay_receipts SET raw_payload_digest = zeroblob(32)")
        }
        let retrySession = PostAccountReplaySession(responses: [
            "/orgs/acme": [
                .init(statusCode: 304, body: Data()),
                .init(statusCode: 200, body: fixture.json(fixture.dto(id: 1, login: "acme")), headers: ["ETag": "\"metadata-v2\""])
            ]
        ])
        let retryService = PostAccountOrganizationMetadataReplayService(
            client: fixture.identityClient(session: retrySession), receipts: repository, clock: { fixture.observedAt.addingTimeInterval(60) }
        )
        let retryResult = try await retryService.organization(fixture.organization, scope: fixture.scope)
        let retryHeaders = await retrySession.headers(named: "If-None-Match")
        XCTAssertEqual(retryResult.value.login, "acme")
        XCTAssertEqual(retryHeaders, ["\"metadata-v1\"", nil])

        let ssoSession = PostAccountReplaySession(responses: [
            "/orgs/acme": [.init(statusCode: 304, body: Data(), headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"])]
        ])
        let ssoService = PostAccountOrganizationMetadataReplayService(
            client: fixture.identityClient(session: ssoSession), receipts: repository, clock: { fixture.observedAt }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await ssoService.organization(fixture.organization, scope: fixture.scope)
        } verify: { error in
            XCTAssertEqual(error as? PostAccountIdentityReplayReceiptRepositoryError, .ssoEvidencePreventsReplay)
        }
        let ssoRequestCount = await ssoSession.requestCount()
        XCTAssertEqual(ssoRequestCount, 1)
    }

    func testCompactionPinsInventoryAndMetadataReceiptSnapshots() async throws {
        let fixture = try await PostAccountIdentityReplayFixture()
        defer { fixture.remove() }
        let repository = PostAccountIdentityReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceInventory(fixture.inventory(pages: [[fixture.dto(id: 1, login: "acme")]]), for: fixture.inventoryIdentity, observedAt: fixture.observedAt.addingTimeInterval(-120))
        try await repository.replaceMetadata(fixture.response(for: fixture.organization), for: fixture.metadataIdentity, organization: fixture.organization, observedAt: fixture.observedAt.addingTimeInterval(-120))
        let pinned = try await fixture.receiptSnapshotIDs()
        try await fixture.saveUnboundSnapshot(observedAt: fixture.observedAt.addingTimeInterval(-60))

        _ = try await RawAPISnapshotRepository(vault: fixture.vault).compact(
            accountID: fixture.account.id,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt
        )
        let remaining = Set(try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(for: fixture.account.id).map(\.id))
        XCTAssertTrue(pinned.isSubset(of: remaining))
    }
}

private final class PostAccountIdentityReplayFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let observedAt = Date(timeIntervalSince1970: 10_000)
    let credentialRevision = CredentialRevision(rawValue: "credential-1")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!

    var scope: SynchronizationScope {
        SynchronizationScope(accountID: account.id, organizationID: organization.id, credentialRevision: credentialRevision, capabilityRevision: capabilityRevision)
    }

    var inventoryIdentity: AccountOrganizationInventoryReplayIdentity {
        .init(accountID: account.id, credentialRevision: credentialRevision)
    }

    var metadataIdentity: OrganizationMetadataReplayIdentity {
        .init(scope: scope, streamID: SyncStreamID(rawValue: "organization-metadata-\(organization.id.rawValue)")!, requestKey: "GET /orgs/\(organization.login)")
    }

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(".triage-post-account-replay-\(UUID().uuidString)", isDirectory: true)
        account = GitHubAccount(id: AccountID.make(), githubUserID: 1, nodeID: GitHubNodeID(rawValue: "U_1")!, login: "octocat", authenticationKind: .oauth, credentialID: CredentialID.make(), credentialStatus: .active, createdAt: observedAt, lastValidatedAt: observedAt)
        organization = GitHubOrganization(id: OrganizationID(rawValue: "acme")!, githubOrganizationID: 1, nodeID: GitHubNodeID(rawValue: "O_1")!, login: "acme")
        vault = try await VaultRegistry(rootDirectory: root).open(accountID: account.id, vaultKey: try VaultKey.generate())
        try await AccountRepository(vault: vault).save(account, credentialRevision: credentialRevision)
        try await AccountRepository(vault: vault).save(organization, access: OrganizationAccess(accountID: account.id, organizationID: organization.id, state: .available, capabilityRevision: capabilityRevision, capabilities: [], checkedAt: observedAt))
    }

    func dto(id: UInt64, login: String) -> GitHubOrganizationDTO {
        .init(id: id, nodeID: "O_\(id)", login: login, avatarURL: nil)
    }

    func response(for organization: GitHubOrganization) -> GitHubResponse<GitHubOrganizationDTO> {
        let value = dto(id: organization.githubOrganizationID, login: organization.login)
        return GitHubResponse(value: value, payload: json(value), etag: "\"metadata-v1\"", lastModified: nil, ssoHeader: nil)
    }

    func inventory(pages values: [[GitHubOrganizationDTO]]) -> GitHubOrganizationInventory {
        let pages = values.enumerated().map { offset, values in
            let ordinal = offset + 1
            return GitHubOrganizationInventoryPage(
                page: GitHubPage(values: values, payload: json(values), nextPageURL: nil, linkHeader: nil, etag: ordinal == 1 ? "\"inventory-v1\"" : nil, lastModified: nil, ssoHeader: nil),
                requestKey: ordinal == 1 ? "GET /user/orgs?per_page=100" : "GET /user/orgs?page=\(ordinal)&per_page=100",
                nextRequestKey: ordinal < values.count ? "GET /user/orgs?page=\(ordinal + 1)&per_page=100" : nil
            )
        }
        // The next-page key is topology, not the number of values on a page.
        let correctedPages = pages.enumerated().map { offset, page in
            GitHubOrganizationInventoryPage(page: page.page, requestKey: page.requestKey, nextRequestKey: offset + 1 < pages.count ? pages[offset + 1].requestKey : nil)
        }
        return GitHubOrganizationInventory(organizations: values.flatMap { $0 }, pages: correctedPages, ssoHeaders: [])
    }

    func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(value)
    }

    func identityClient(session: PostAccountReplaySession) -> GitHubIdentityClient {
        GitHubIdentityClient(client: GitHubRESTClient(transport: try! GitHubRESTTransport(session: session), credential: SecretValue("token")))
    }

    func inventoryReceiptCount() async throws -> Int {
        try await vault.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM account_organization_inventory_replay_receipts") ?? 0 }
    }

    func receiptSnapshotIDs() async throws -> Set<RawAPISnapshotID> {
        try await vault.read { database in
            Set(try String.fetchAll(database, sql: "SELECT raw_snapshot_id FROM account_organization_inventory_replay_receipt_pages UNION SELECT raw_snapshot_id FROM organization_metadata_replay_receipts").compactMap(RawAPISnapshotID.init(rawValue:)))
        }
    }

    func saveUnboundSnapshot(observedAt: Date) async throws {
        try await RawAPISnapshotRepository(vault: vault).save(RawAPISnapshot(id: RawAPISnapshotID(rawValue: "unbound-post-account-snapshot")!, accountID: account.id, githubNodeID: nil, endpoint: "/user/orgs?per_page=100", eTag: "\"unbound\"", parserVersion: 1, observedAt: observedAt, payload: Data("[]".utf8)))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor PostAccountReplaySession: HTTPSession {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    private var responses: [String: [Response]]
    private var requests = [URLRequest]()

    init(responses: [String: [Response]]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let path = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard var pending = responses[path], !pending.isEmpty else { throw URLError(.resourceUnavailable) }
        let response = pending.removeFirst()
        responses[path] = pending
        requests.append(request)
        return (response.body, HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: response.headers)!)
    }

    func headers(named name: String) -> [String?] { requests.map { $0.value(forHTTPHeaderField: name) } }
    func requestCount() -> Int { requests.count }
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
