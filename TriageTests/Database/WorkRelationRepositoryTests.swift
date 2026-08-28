import XCTest
@testable import Triage

final class WorkRelationRepositoryTests: XCTestCase {
    func testReplacingRelationsPersistsEvidenceAndRemovesStaleRelations() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let workItemRepository = WorkItemRepository(vault: fixture.vault)
        let workItemID = try await workItemRepository.ensureWorkItem(for: fixture.node)
        let relation = fixture.relation
        let repository = WorkRelationRepository(vault: fixture.vault)

        try await repository.replace(
            [relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID
        )

        let persisted = try await workItemRepository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].id, workItemID)
        XCTAssertEqual(persisted[0].relations, [relation])

        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID
        )
        let relationCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        let evidenceCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
        }
        XCTAssertEqual(relationCount, 0)
        XCTAssertEqual(evidenceCount, 0)
    }

    func testRejectsRelationsForAnotherVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        do {
            try await WorkRelationRepository(vault: fixture.vault).replace(
                [fixture.relation],
                accountID: AccountID.make(),
                subjectNodeID: fixture.node.nodeID
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .accountScopeMismatch)
        }
    }

    func testRejectsRelationsForANodeOutsideTheVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        do {
            try await WorkRelationRepository(vault: fixture.vault).replace(
                [],
                accountID: fixture.accountID,
                subjectNodeID: GitHubNodeID(rawValue: "MDU6SXNzdWU5OTk=")!
            )
            XCTFail("Expected a source node scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .subjectNodeScopeMismatch)
        }
    }

    func testRawAPISnapshotsRoundTripWithinTheirAccountScope() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: "/repos/github/triage/issues/1",
            eTag: "\"revision-1\"",
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"number\":1}".utf8)
        )
        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        try await repository.save(snapshot)

        XCTAssertEqual(
            try await repository.snapshots(for: fixture.accountID),
            [snapshot]
        )

        do {
            try await repository.save(
                RawAPISnapshot(
                    id: RawAPISnapshotID.make(),
                    accountID: AccountID.make(),
                    githubNodeID: fixture.node.nodeID,
                    endpoint: snapshot.endpoint,
                    eTag: nil,
                    parserVersion: 1,
                    observedAt: fixture.date,
                    payload: snapshot.payload
                )
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .accountScopeMismatch)
        }
    }

    func testRawAPISnapshotCompactionPreservesReplayAndFailureProvenance() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        let endpoint = "/repos/github/triage/issues/1"
        let oldest = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: endpoint,
            eTag: "\"revision-1\"",
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"revision\":1}".utf8)
        )
        let failedSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: endpoint,
            eTag: "\"revision-2\"",
            parserVersion: 1,
            observedAt: fixture.date.addingTimeInterval(60),
            payload: Data("{\"revision\":2}".utf8)
        )
        let newest = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: endpoint,
            eTag: "\"revision-3\"",
            parserVersion: 1,
            observedAt: fixture.date.addingTimeInterval(120),
            payload: Data("{\"revision\":3}".utf8)
        )
        for snapshot in [oldest, failedSnapshot, newest] {
            try await repository.save(snapshot)
        }
        try await NormalizationFailureRepository(vault: fixture.vault).record(
            NormalizationFailure(
                id: UUID(),
                accountID: fixture.accountID,
                rawSnapshotID: failedSnapshot.id,
                githubNodeID: fixture.node.nodeID,
                endpoint: endpoint,
                parserVersion: 1,
                occurredAt: failedSnapshot.observedAt,
                redactedDiagnostic: "Unknown issue state."
            )
        )

        XCTAssertEqual(
            try await repository.compact(
                accountID: fixture.accountID,
                before: fixture.date.addingTimeInterval(180)
            ),
            1
        )
        XCTAssertEqual(
            try await repository.snapshots(for: fixture.accountID),
            [newest, failedSnapshot]
        )
    }

    func testNormalizationFailuresRetainAccountScopedSnapshotProvenance() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: "/repos/github/triage/issues/1",
            eTag: nil,
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"number\":1}".utf8)
        )
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        let failure = NormalizationFailure(
            id: UUID(),
            accountID: fixture.accountID,
            rawSnapshotID: snapshot.id,
            githubNodeID: fixture.node.nodeID,
            endpoint: snapshot.endpoint,
            parserVersion: snapshot.parserVersion,
            occurredAt: fixture.date,
            redactedDiagnostic: "Unknown issue state."
        )
        let repository = NormalizationFailureRepository(vault: fixture.vault)
        try await repository.record(failure)

        XCTAssertEqual(try await repository.failures(for: fixture.accountID), [failure])

        do {
            try await repository.record(
                NormalizationFailure(
                    id: UUID(),
                    accountID: fixture.accountID,
                    rawSnapshotID: RawAPISnapshotID.make(),
                    githubNodeID: fixture.node.nodeID,
                    endpoint: failure.endpoint,
                    parserVersion: failure.parserVersion,
                    occurredAt: failure.occurredAt,
                    redactedDiagnostic: failure.redactedDiagnostic
                )
            )
            XCTFail("Expected a snapshot scope mismatch.")
        } catch {
            XCTAssertEqual(error as? NormalizationFailureRepositoryError, .snapshotScopeMismatch)
        }
    }

    func testConditionalRequestValidatorsRoundTripAndAreAccountScoped() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let validator = ConditionalRequestValidator(
            requestKey: "GET /repos/github/triage/issues?state=open",
            accountID: fixture.accountID,
            eTag: "\"revision-1\"",
            lastModified: "Fri, 28 Aug 2026 00:00:00 GMT",
            observedAt: fixture.date
        )
        let repository = ConditionalRequestCacheRepository(vault: fixture.vault)
        try await repository.save(validator)
        XCTAssertEqual(
            try await repository.validator(
                for: validator.requestKey,
                accountID: fixture.accountID
            ),
            validator
        )

        do {
            _ = try await repository.validator(
                for: validator.requestKey,
                accountID: AccountID.make()
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .accountScopeMismatch)
        }
    }

    func testSyncShardsRequireAnAccountOwnedParentStream() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "search-discovery")!
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                repositoryID: nil,
                feature: .issues,
                streamID: streamID,
                intervalStart: fixture.date,
                intervalEnd: fixture.date.addingTimeInterval(60),
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.date
        )
        let shard = SyncShard(
            id: SyncShardID.make(),
            streamID: streamID,
            queryKind: "involvement-open",
            intervalStart: fixture.date,
            intervalEnd: fixture.date.addingTimeInterval(60),
            pageCursor: "page:2",
            state: .running,
            completedAt: nil
        )
        let repository = SyncShardRepository(vault: fixture.vault)
        try await repository.save(shard, accountID: fixture.accountID)
        XCTAssertEqual(
            try await repository.shards(for: streamID, accountID: fixture.accountID),
            [shard]
        )

        do {
            try await repository.save(shard, accountID: AccountID.make())
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .accountScopeMismatch)
        }
    }

    func testSyncShardsRejectMalformedCheckpointsAndUnknownStreams() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "search-discovery")!
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                repositoryID: nil,
                feature: .issues,
                streamID: streamID,
                intervalStart: fixture.date,
                intervalEnd: fixture.date.addingTimeInterval(60),
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.date
        )
        let repository = SyncShardRepository(vault: fixture.vault)

        do {
            try await repository.save(
                SyncShard(
                    id: SyncShardID.make(),
                    streamID: streamID,
                    queryKind: "involvement-open",
                    intervalStart: fixture.date.addingTimeInterval(60),
                    intervalEnd: fixture.date,
                    pageCursor: nil,
                    state: .pending,
                    completedAt: nil
                ),
                accountID: fixture.accountID
            )
            XCTFail("Expected an invalid interval.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .invalidInterval)
        }

        do {
            try await repository.save(
                SyncShard(
                    id: SyncShardID.make(),
                    streamID: streamID,
                    queryKind: "involvement-open",
                    intervalStart: nil,
                    intervalEnd: nil,
                    pageCursor: nil,
                    state: .running,
                    completedAt: fixture.date
                ),
                accountID: fixture.accountID
            )
            XCTFail("Expected an invalid completion state.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .invalidCompletionState)
        }

        do {
            try await repository.save(
                SyncShard(
                    id: SyncShardID.make(),
                    streamID: SyncStreamID(rawValue: "unknown-stream")!,
                    queryKind: "involvement-open",
                    intervalStart: nil,
                    intervalEnd: nil,
                    pageCursor: nil,
                    state: .pending,
                    completedAt: nil
                ),
                accountID: fixture.accountID
            )
            XCTFail("Expected an unknown stream failure.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .streamScopeMismatch)
        }
    }

    func testSyncStreamsReadAndUpdateAccountOwnedCoverageStream() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "search-discovery")!
        let coverage = CoverageRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .roleDiscovery,
            streamID: streamID,
            intervalStart: fixture.date,
            intervalEnd: fixture.date.addingTimeInterval(60),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: nil
        )
        try await CoverageRepository(vault: fixture.vault).save(coverage, attemptedAt: fixture.date)

        let repository = SyncStreamRepository(vault: fixture.vault)
        let initial = try XCTUnwrap(
            try await repository.stream(withID: streamID, accountID: fixture.accountID)
        )
        XCTAssertEqual(initial.status, .partial)
        XCTAssertEqual(initial.highWater, coverage.intervalEnd)
        XCTAssertEqual(initial.lastAttemptAt, fixture.date)

        let completed = SyncStream(
            id: streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            feature: .roleDiscovery,
            highWater: fixture.date.addingTimeInterval(120),
            lastSuccessfulAt: fixture.date.addingTimeInterval(120),
            lastAttemptAt: fixture.date.addingTimeInterval(120),
            status: .complete,
            failureDetail: nil
        )
        try await repository.save(completed)
        XCTAssertEqual(
            try await repository.stream(withID: streamID, accountID: fixture.accountID),
            completed
        )

        do {
            _ = try await repository.stream(withID: streamID, accountID: AccountID.make())
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? SyncStreamRepositoryError, .accountScopeMismatch)
        }
    }

    func testSynchronizationScopeUsesCurrentCredentialAndCapabilityRevisions() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let scope = try await AccountRepository(vault: fixture.vault).synchronizationScope(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )

        XCTAssertEqual(scope.accountID, fixture.accountID)
        XCTAssertEqual(scope.organizationID, fixture.organizationID)
        XCTAssertEqual(scope.credentialRevision, CredentialRevision(rawValue: "credential-1"))
        XCTAssertEqual(scope.capabilityRevision, CapabilityRevision(rawValue: "capability-1"))
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault
        let node: NormalizedGitHubNode
        let relation: WorkRelation

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            let accountNodeID = GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!
            let account = GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: accountNodeID,
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
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            )
            let accountRepository = AccountRepository(vault: vault)
            try await accountRepository.save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            try await accountRepository.save(organization, access: access, selectedAt: date)

            node = NormalizedGitHubNode(
                nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "1",
                number: 1,
                title: "Fix work item projection",
                state: .open,
                url: URL(string: "https://github.com/github/triage/issues/1")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: date,
                updatedAt: date,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "revision-1",
                observedAt: date,
                accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(node)
            relation = WorkRelation(
                kind: .assigned,
                subjectNodeID: node.nodeID,
                objectNodeID: accountNodeID,
                confidence: .confirmed,
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "assignment-1")!,
                        source: .restSearch,
                        nodeID: node.nodeID,
                        sourceRevision: node.sourceRevision,
                        observedAt: date,
                        excerpt: "assignee:octocat"
                    )
                ],
                observedAt: date
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
