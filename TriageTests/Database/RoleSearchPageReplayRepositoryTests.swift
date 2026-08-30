import XCTest
import GRDB
@testable import Triage

final class RoleSearchPageReplayRepositoryTests: XCTestCase {
    func testReplayRoundTripsOnlyForExactScopeAndRevisions() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot(id: "search-page-1", eTag: "\"search-v1\"")
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        let replay = fixture.replay(snapshot: snapshot)
        let repository = RoleSearchPageReplayRepository(vault: fixture.vault)

        try await repository.save(replay)

        let restored = try await repository.entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertEqual(restored?.replay, replay)
        XCTAssertEqual(restored?.snapshot, snapshot)
        let staleCredential = try await repository.entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNil(staleCredential)
        let staleCapability = try await repository.entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
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
        let snapshot = try fixture.snapshot(id: "search-page-1", eTag: "\"search-v1\"")
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
            XCTAssertEqual(error, .snapshotValidatorMismatch)
        }
    }

    func testReplayMappingProtectsRequiredRawPageFromCompaction() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let mapped = try fixture.snapshot(
            id: "search-page-mapped",
            eTag: "\"search-v1\"",
            observedAt: fixture.observedAt
        )
        let newer = try fixture.snapshot(
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
        let mapped = try fixture.snapshot(
            id: "search-page-mapped",
            eTag: "\"search-v1\"",
            observedAt: fixture.observedAt
        )
        let newer = try fixture.snapshot(
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
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
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

    func testReplayCacheRemovesMappingsFromSupersededRevisions() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot(id: "stale-revision-page", eTag: "\"stale\"")
        let repository = RoleSearchPageReplayRepository(vault: fixture.vault)
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        let staleReplay = fixture.replay(snapshot: snapshot)
        try await repository.save(staleReplay)
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let currentScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-current")!,
            capabilityRevision: fixture.capabilityRevision
        )
        try await fixture.setCurrentAuthority(
            credentialRevision: currentScope.credentialRevision,
            capabilityRevision: currentScope.capabilityRevision
        )

        let currentEntry = try await RoleSearchPageReplayCache(
            repository: repository,
            scope: currentScope
        ).entry(for: query, page: 1, streamID: fixture.streamID)

        XCTAssertNil(currentEntry)
        let staleBindingExists = try await fixture.replayBindingExists(staleReplay.requestKey)
        XCTAssertFalse(staleBindingExists)
    }

    func testStaleCacheCleanupCannotDeleteCurrentRevisionBinding() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let currentCredentialRevision = CredentialRevision(rawValue: "credential-current")!
        let currentCapabilityRevision = CapabilityRevision(rawValue: "capability-current")!
        try await fixture.setCurrentAuthority(
            credentialRevision: currentCredentialRevision,
            capabilityRevision: currentCapabilityRevision
        )
        let currentScope = fixture.synchronizationScope(
            credentialRevision: currentCredentialRevision,
            capabilityRevision: currentCapabilityRevision
        )
        let snapshot = try fixture.snapshot(
            id: "current-revision-page",
            eTag: "\"current-revision\"",
            scope: currentScope
        )
        let replay = fixture.replay(snapshot: snapshot)
        let repository = RoleSearchPageReplayRepository(vault: fixture.vault)
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        try await repository.save(replay)

        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let staleCache = RoleSearchPageReplayCache(
            repository: repository,
            scope: fixture.synchronizationScope()
        )
        let staleEntry = try await staleCache.entry(
            for: query,
            page: 1,
            streamID: fixture.streamID
        )
        XCTAssertNil(staleEntry)

        let retained = try await repository.entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: currentCredentialRevision,
            capabilityRevision: currentCapabilityRevision
        )
        XCTAssertEqual(retained?.replay, replay)
    }

    func testParserVersionCleanupRetiresOnlyCurrentStreamAndRevisionObsoleteBindings() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let repository = RoleSearchPageReplayRepository(vault: fixture.vault)
        let currentSnapshot = try fixture.snapshot(
            id: "current-parser-page",
            eTag: "\"current-parser\""
        )
        let currentReplay = fixture.replay(snapshot: currentSnapshot)
        let otherStreamID = SyncStreamID(rawValue: "role-discovery:parser-other")!
        try await fixture.saveRoleDiscoveryStream(otherStreamID)
        let obsoleteCurrentStreamKey = "role-search:obsolete-parser-current-stream"
        let obsoleteOtherStreamKey = "role-search:obsolete-parser-other-stream"
        let obsoleteOtherRevisionKey = "role-search:obsolete-parser-other-revision"
        try await fixture.insertLegacyReplayBinding(
            requestKey: obsoleteCurrentStreamKey,
            streamID: fixture.streamID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion - 1,
            endpoint: currentSnapshot.endpoint
        )
        try await RawAPISnapshotRepository(vault: fixture.vault).save(currentSnapshot)
        try await repository.save(currentReplay)
        let obsoleteCurrentBindingExistsBeforeCleanup = try await fixture.replayBindingExists(
            obsoleteCurrentStreamKey
        )
        let currentBindingExistsBeforeCleanup = try await fixture.replayBindingExists(
            currentReplay.requestKey
        )
        XCTAssertTrue(obsoleteCurrentBindingExistsBeforeCleanup)
        XCTAssertTrue(currentBindingExistsBeforeCleanup)

        try await fixture.insertLegacyReplayBinding(
            requestKey: obsoleteOtherStreamKey,
            streamID: otherStreamID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion - 1
        )
        try await fixture.insertLegacyReplayBinding(
            requestKey: obsoleteOtherRevisionKey,
            streamID: fixture.streamID,
            credentialRevision: CredentialRevision(rawValue: "credential-obsolete")!,
            capabilityRevision: fixture.capabilityRevision,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion - 1
        )

        try await fixture.vault.write { database in
            try RoleSearchPageReplayRepository.removeStaleParserVersions(
                streamID: fixture.streamID,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                credentialRevision: fixture.credentialRevision,
                capabilityRevision: fixture.capabilityRevision,
                expectedAccountID: fixture.accountID,
                in: database
            )
        }

        let currentBindingExistsAfterCleanup = try await fixture.replayBindingExists(currentReplay.requestKey)
        let obsoleteCurrentBindingExistsAfterCleanup = try await fixture.replayBindingExists(
            obsoleteCurrentStreamKey
        )
        let obsoleteOtherStreamBindingExists = try await fixture.replayBindingExists(
            obsoleteOtherStreamKey
        )
        let obsoleteOtherRevisionBindingExists = try await fixture.replayBindingExists(
            obsoleteOtherRevisionKey
        )
        XCTAssertTrue(currentBindingExistsAfterCleanup)
        XCTAssertFalse(obsoleteCurrentBindingExistsAfterCleanup)
        XCTAssertTrue(obsoleteOtherStreamBindingExists)
        XCTAssertTrue(obsoleteOtherRevisionBindingExists)
    }

    func testLastModifiedOnlyReplayRoundTripsWithExactRawAuthority() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot(
            id: "search-page-last-modified",
            eTag: nil,
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
        )
        let replay = fixture.replay(snapshot: snapshot)
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        let replayRepository = RoleSearchPageReplayRepository(vault: fixture.vault)

        try await rawRepository.save(snapshot)
        try await replayRepository.save(replay)

        let restored = try await replayRepository.entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertEqual(restored?.replay.eTag, nil)
        XCTAssertEqual(restored?.replay.lastModified, snapshot.lastModified)
        XCTAssertEqual(restored?.snapshot.requestIdentity, snapshot.requestIdentity)
    }

    func testSamePageUnderDistinctRoleStreamsCannotCrossReadOrInvalidate() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let otherStreamID = SyncStreamID(rawValue: "role-discovery:other")!
        try await SyncStreamRepository(vault: fixture.vault).save(
            SyncStream(
                id: otherStreamID,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                feature: .roleDiscovery,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: fixture.observedAt,
                status: .partial,
                failureDetail: nil
            )
        )
        let firstSnapshot = try fixture.snapshot(id: "stream-one-page", eTag: "\"one\"")
        let otherSnapshot = try fixture.snapshot(
            id: "stream-two-page",
            eTag: "\"two\"",
            streamID: otherStreamID
        )
        let firstReplay = fixture.replay(snapshot: firstSnapshot)
        let otherReplay = fixture.replay(snapshot: otherSnapshot)
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        let replayRepository = RoleSearchPageReplayRepository(vault: fixture.vault)
        try await rawRepository.save(firstSnapshot)
        try await rawRepository.save(otherSnapshot)
        try await replayRepository.save(firstReplay)
        try await replayRepository.save(otherReplay)

        XCTAssertNotEqual(firstReplay.requestKey, otherReplay.requestKey)
        let crossStream = try await replayRepository.entry(
            requestKey: firstReplay.requestKey,
            streamID: otherStreamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNil(crossStream)

        try await replayRepository.remove(
            requestKey: firstReplay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        let otherRestored = try await replayRepository.entry(
            requestKey: otherReplay.requestKey,
            streamID: otherStreamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertEqual(otherRestored?.replay, otherReplay)
    }

    func testReplayRejectsRawSnapshotBoundToAnotherStream() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let otherStreamID = SyncStreamID(rawValue: "role-discovery:untrusted")!
        let snapshot = try fixture.snapshot(
            id: "wrong-stream-authority",
            eTag: "\"wrong-stream\"",
            streamID: otherStreamID
        )
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)

        do {
            try await RoleSearchPageReplayRepository(vault: fixture.vault).save(
                RoleSearchPageReplay(
                    requestKey: snapshot.requestIdentity!.requestKey,
                    accountID: fixture.accountID,
                    organizationID: fixture.organizationID,
                    streamID: fixture.streamID,
                    queryValue: "org:github is:open involves:octocat",
                    page: 1,
                    endpoint: snapshot.endpoint,
                    credentialRevision: fixture.credentialRevision,
                    capabilityRevision: fixture.capabilityRevision,
                    rawSnapshotID: snapshot.id,
                    eTag: snapshot.eTag,
                    lastModified: snapshot.lastModified,
                    parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                    lastValidatedAt: fixture.observedAt
                )
            )
            XCTFail("Cross-stream raw authority must not authorize replay.")
        } catch let error as RoleSearchPageReplayRepositoryError {
            XCTAssertEqual(error, .snapshotRequestAuthorityMismatch)
        }
    }

    func testCacheInvalidatesBindingWhenSnapshotLaterHasNormalizationFailure() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.snapshot(
            id: "failed-normalization-page",
            eTag: "\"failed-normalization\""
        )
        let replay = fixture.replay(snapshot: snapshot)
        let replayRepository = RoleSearchPageReplayRepository(vault: fixture.vault)
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        try await replayRepository.save(replay)
        try await NormalizationFailureRepository(vault: fixture.vault).record(
            NormalizationFailure(
                id: UUID(),
                accountID: fixture.accountID,
                rawSnapshotID: snapshot.id,
                githubNodeID: nil,
                endpoint: snapshot.endpoint,
                parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                occurredAt: fixture.observedAt,
                redactedDiagnostic: "Bounded test failure."
            )
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        let cached = try await RoleSearchPageReplayCache(
            repository: replayRepository,
            scope: SynchronizationScope(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                credentialRevision: fixture.credentialRevision,
                capabilityRevision: fixture.capabilityRevision
            )
        ).entry(for: query, page: 1, streamID: fixture.streamID)

        XCTAssertNil(cached)
        let removed = try await replayRepository.entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNil(removed)
    }

    func testRawSnapshotRoundTripsLastModifiedAndExactRequestAuthority() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let scope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        let identity = ConditionalRequestIdentity(
            scope: scope,
            feature: .roleDiscovery,
            streamID: SyncStreamID(rawValue: "role-discovery:test")!,
            requestKey: "GET /search/issues?q=org%3Agithub&page=1"
        )
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "search-page-authority")!,
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=org%3Agithub&page=1",
            eTag: "\"search-v1\"",
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
            parserVersion: 1,
            observedAt: fixture.observedAt,
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
            requestIdentity: identity
        )
        let repository = RawAPISnapshotRepository(vault: fixture.vault)

        try await repository.save(snapshot)

        let restored = try await repository.snapshots(for: fixture.accountID)
        XCTAssertEqual(restored, [snapshot])
    }

    func testRawSnapshotRejectsStaleOrUnsafeRequestAuthority() async throws {
        let fixture = try await ReplayFixture()
        defer { fixture.remove() }
        let staleScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: fixture.capabilityRevision
        )
        let staleIdentity = ConditionalRequestIdentity(
            scope: staleScope,
            feature: .roleDiscovery,
            streamID: SyncStreamID(rawValue: "role-discovery:test")!,
            requestKey: "GET /search/issues?q=org%3Agithub&page=1"
        )
        let staleSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "search-page-stale")!,
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=org%3Agithub&page=1",
            eTag: nil,
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
            parserVersion: 1,
            observedAt: fixture.observedAt,
            payload: Data(),
            requestIdentity: staleIdentity
        )
        let unsafeSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "search-page-unsafe")!,
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=org%3Agithub&page=1",
            eTag: nil,
            lastModified: "unsafe\r\nheader",
            parserVersion: 1,
            observedAt: fixture.observedAt,
            payload: Data()
        )
        let repository = RawAPISnapshotRepository(vault: fixture.vault)

        do {
            try await repository.save(staleSnapshot)
            XCTFail("Expected stale raw request authority to be rejected.")
        } catch let error as RawAPISnapshotRepositoryError {
            XCTAssertEqual(error, .requestAuthorityScopeMismatch)
        }
        do {
            try await repository.save(unsafeSnapshot)
            XCTFail("Expected an unsafe raw validator to be rejected.")
        } catch let error as RawAPISnapshotRepositoryError {
            XCTAssertEqual(error, .invalidValidator)
        }
    }
}

private final class ReplayFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "org-replay")!
    let streamID = SyncStreamID(rawValue: "role-discovery:test")!
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
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: streamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: .roleDiscovery,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: observedAt,
                status: .partial,
                failureDetail: nil
            )
        )
    }

    func snapshot(
        id: String,
        eTag: String?,
        lastModified: String? = nil,
        streamID: SyncStreamID? = nil,
        observedAt: Date? = nil,
        scope: SynchronizationScope? = nil
    ) throws -> RawAPISnapshot {
        let resolvedStreamID = streamID ?? self.streamID
        let resolvedScope = scope ?? synchronizationScope()
        let identity = try requestIdentity(
            streamID: resolvedStreamID,
            scope: resolvedScope
        )
        return RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: id)!,
            accountID: accountID,
            githubNodeID: nil,
            endpoint: identity.endpoint,
            eTag: eTag,
            lastModified: lastModified,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            observedAt: observedAt ?? self.observedAt,
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
            requestIdentity: ConditionalRequestIdentity(
                scope: resolvedScope,
                feature: .roleDiscovery,
                streamID: resolvedStreamID,
                requestKey: identity.requestKey
            )
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
            requestKey: snapshot.requestIdentity!.requestKey,
            accountID: accountID ?? self.accountID,
            organizationID: organizationID ?? self.organizationID,
            streamID: snapshot.requestIdentity!.streamID,
            queryValue: "org:github is:open involves:octocat",
            page: 1,
            endpoint: snapshot.endpoint,
            credentialRevision: snapshot.requestIdentity!.scope.credentialRevision,
            capabilityRevision: snapshot.requestIdentity!.scope.capabilityRevision,
            rawSnapshotID: rawSnapshotID ?? snapshot.id,
            eTag: eTag ?? snapshot.eTag,
            lastModified: snapshot.lastModified,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            lastValidatedAt: observedAt
        )
    }

    func synchronizationScope(
        credentialRevision: CredentialRevision? = nil,
        capabilityRevision: CapabilityRevision? = nil
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision ?? self.credentialRevision,
            capabilityRevision: capabilityRevision ?? self.capabilityRevision
        )
    }

    private func requestIdentity(
        streamID: SyncStreamID,
        scope: SynchronizationScope
    ) throws -> GitHubIssueSearchRequestIdentity {
        try GitHubIssueSearchRequestIdentity(
            query: GitHubIssueSearchQuery(
                organizationLogin: "github",
                userLogin: "octocat",
                state: .open,
                relationship: .involves
            ),
            page: 1,
            scope: scope,
            streamID: streamID
        )
    }

    func setCurrentAuthority(
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_revision = ? WHERE id = ?",
                arguments: [credentialRevision.rawValue, accountID.rawValue]
            )
            try database.execute(
                sql: """
                    UPDATE account_organizations
                    SET capability_revision = ?
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [
                    capabilityRevision.rawValue,
                    accountID.rawValue,
                    organizationID.rawValue
                ]
            )
        }
    }

    func saveRoleDiscoveryStream(_ streamID: SyncStreamID) async throws {
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: streamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: .roleDiscovery,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: observedAt,
                status: .partial,
                failureDetail: nil
            )
        )
    }

    func insertLegacyReplayBinding(
        requestKey: String,
        streamID: SyncStreamID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision,
        parserVersion: Int,
        endpoint: String? = nil
    ) async throws {
        let snapshotID = RawAPISnapshotID.make()
        let resolvedEndpoint = endpoint ?? "/search/issues?legacy-binding=\(requestKey)"
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO raw_api_snapshots (
                        id, account_id, github_node_id, endpoint, etag, last_modified,
                        authority_organization_id, authority_feature, authority_stream_id,
                        authority_request_key, authority_credential_revision,
                        authority_capability_revision, parser_version, observed_at_ms, payload
                    ) VALUES (?, ?, NULL, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?)
                    """,
                arguments: [
                    snapshotID.rawValue,
                    accountID.rawValue,
                    resolvedEndpoint,
                    "\"legacy\"",
                    parserVersion,
                    Int64(observedAt.timeIntervalSince1970 * 1_000),
                    Data()
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO role_search_page_replays (
                        account_id, organization_id, feature, stream_id, request_key,
                        query_value, page, endpoint, credential_revision, capability_revision,
                        raw_snapshot_id, etag, last_modified, parser_version,
                        last_validated_at_ms
                    ) VALUES (?, ?, 'roleDiscovery', ?, ?, ?, 1, ?, ?, ?, ?, ?, NULL, ?, ?)
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    streamID.rawValue,
                    requestKey,
                    "legacy parser binding",
                    resolvedEndpoint,
                    credentialRevision.rawValue,
                    capabilityRevision.rawValue,
                    snapshotID.rawValue,
                    "\"legacy\"",
                    parserVersion,
                    Int64(observedAt.timeIntervalSince1970 * 1_000)
                ]
            )
        }
    }

    func replayBindingExists(_ requestKey: String) async throws -> Bool {
        try await vault.read { database in
            (try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM role_search_page_replays WHERE request_key = ?",
                arguments: [requestKey]
            ) ?? 0) == 1
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
