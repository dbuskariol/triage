import XCTest
@testable import Triage

final class RoleSearchPageReplayRepositoryTests: XCTestCase {
    func testReplayRoundTripsOnlyForExactScopeAndRevisions() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let snapshot = fixture.snapshot(id: "search-page-1", eTag: "\"search-v1\"")
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        let replay = fixture.replay(snapshot: snapshot)
        let repository = RoleSearchPageReplayRepository(vault: fixture.vault)

        try await repository.save(replay)

        let restored = try await repository.entry(
            requestKey: replay.requestKey,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertEqual(restored?.replay, replay)
        XCTAssertEqual(restored?.snapshot, snapshot)
        let staleCredential = try await repository.entry(
            requestKey: replay.requestKey,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNil(staleCredential)
        let staleCapability = try await repository.entry(
            requestKey: replay.requestKey,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: CapabilityRevision(rawValue: "capability-stale")!
        )
        XCTAssertNil(staleCapability)
    }

    func testReplayRejectsAccountOrganizationSnapshotAndETagScopeMismatches() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let snapshot = fixture.snapshot(id: "search-page-1", eTag: "\"search-v1\"")
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        let repository = RoleSearchPageReplayRepository(vault: fixture.vault)

        do {
            try await repository.save(
                fixture.replay(
                    snapshot: snapshot,
                    accountID: AccountID.make()
                )
            )
            XCTFail("Expected account scope mismatch.")
        } catch let error as RoleSearchPageReplayRepositoryError {
            XCTAssertEqual(error, .accountScopeMismatch)
        }
        do {
            try await repository.save(
                fixture.replay(
                    snapshot: snapshot,
                    organizationID: OrganizationID(rawValue: "unselected-org")!
                )
            )
            XCTFail("Expected organization scope mismatch.")
        } catch let error as RoleSearchPageReplayRepositoryError {
            XCTAssertEqual(error, .organizationScopeMismatch)
        }
        do {
            try await repository.save(
                fixture.replay(
                    snapshot: snapshot,
                    rawSnapshotID: RawAPISnapshotID(rawValue: "missing-snapshot")!
                )
            )
            XCTFail("Expected snapshot scope mismatch.")
        } catch let error as RoleSearchPageReplayRepositoryError {
            XCTAssertEqual(error, .snapshotScopeMismatch)
        }
        do {
            try await repository.save(
                fixture.replay(snapshot: snapshot, eTag: "\"different\"")
            )
            XCTFail("Expected snapshot ETag mismatch.")
        } catch let error as RoleSearchPageReplayRepositoryError {
            XCTAssertEqual(error, .snapshotETagMismatch)
        }
    }

    func testReplayMappingProtectsRequiredRawPageFromCompaction() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let mapped = fixture.snapshot(
            id: "search-page-mapped",
            eTag: "\"search-v1\"",
            observedAt: fixture.observedAt
        )
        let newer = fixture.snapshot(
            id: "search-page-newer",
            eTag: "\"search-v2\"",
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        try await rawRepository.save(mapped)
        try await rawRepository.save(newer)
        try await RoleSearchPageReplayRepository(vault: fixture.vault).save(
            fixture.replay(snapshot: mapped)
        )

        let removed = try await rawRepository.compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt.addingTimeInterval(120)
        )

        XCTAssertEqual(removed, 0)
        let snapshots = try await rawRepository.snapshots(for: fixture.accountID)
        XCTAssertEqual(Set(snapshots.map(\.id)), Set([mapped.id, newer.id]))
    }

    func testRemovingReplayAllowsSupersededRawPageToCompact() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let mapped = fixture.snapshot(
            id: "search-page-mapped",
            eTag: "\"search-v1\"",
            observedAt: fixture.observedAt
        )
        let newer = fixture.snapshot(
            id: "search-page-newer",
            eTag: "\"search-v2\"",
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        try await rawRepository.save(mapped)
        try await rawRepository.save(newer)
        let replay = fixture.replay(snapshot: mapped)
        let replayRepository = RoleSearchPageReplayRepository(vault: fixture.vault)
        try await replayRepository.save(replay)
        try await replayRepository.remove(
            requestKey: replay.requestKey,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )

        let removed = try await rawRepository.compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt.addingTimeInterval(120)
        )

        XCTAssertEqual(removed, 1)
        let snapshots = try await rawRepository.snapshots(for: fixture.accountID)
        XCTAssertEqual(snapshots.map(\.id), [newer.id])
    }
}

private final class ReplayFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "org-replay")!
    let credentialRevision = CredentialRevision(rawValue: "credential-replay")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-replay")!
    let observedAt = Date(timeIntervalSince1970: 2_000)
    let vault: AccountVault

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".role-search-replay-\(UUID().uuidString)", isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_replay")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_replay")!,
            login: "github"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
    }

    func snapshot(
        id: String,
        eTag: String,
        observedAt: Date? = nil
    ) -> RawAPISnapshot {
        RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: id)!,
            accountID: accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=org%3Agithub&page=1",
            eTag: eTag,
            parserVersion: 1,
            observedAt: observedAt ?? self.observedAt,
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
        )
    }

    func replay(
        snapshot: RawAPISnapshot,
        accountID: AccountID? = nil,
        organizationID: OrganizationID? = nil,
        rawSnapshotID: RawAPISnapshotID? = nil,
        eTag: String? = nil
    ) -> RoleSearchPageReplay {
        RoleSearchPageReplay(
            requestKey: "role-search:scope-query-page-1",
            accountID: accountID ?? self.accountID,
            organizationID: organizationID ?? self.organizationID,
            queryValue: "org:github is:open involves:octocat",
            page: 1,
            endpoint: snapshot.endpoint,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            rawSnapshotID: rawSnapshotID ?? snapshot.id,
            eTag: eTag ?? snapshot.eTag!,
            parserVersion: 1,
            lastValidatedAt: observedAt
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
