import GRDB
import XCTest
@testable import Triage

final class SourceObservationRepositoryTests: XCTestCase {
    func testObservationFieldsRoundTripAndNewerObservationMovesProjection() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let first = fixture.observation(
            id: "access-1",
            sourceNodeID: fixture.nodeID,
            sourceEventID: fixture.eventID,
            rawSnapshotID: fixture.rawSnapshotID
        )
        let second = fixture.observation(
            id: "access-2",
            source: .query("TriageHydrateNodes"),
            sourceNodeID: fixture.nodeID,
            sourceEventID: fixture.eventID,
            sourceRevision: "revision-2",
            result: .inaccessible,
            reason: .privateNotFound,
            authority: .directProbe,
            confirmation: .provisional,
            observedAt: fixture.date.addingTimeInterval(1)
        )

        let firstProjection = try await repository.record(first)
        let secondProjection = try await repository.record(second)

        XCTAssertEqual(firstProjection.winningObservationID, first.id)
        XCTAssertEqual(secondProjection, SourceAccessProjection(
            scope: second.scope,
            feature: second.feature,
            streamID: second.streamID,
            target: second.target,
            result: second.result,
            winningObservationID: second.id,
            observedAt: second.observedAt
        ))
        let persistedProjection = try await repository.projection(
            for: second.target,
            feature: second.feature,
            streamID: second.streamID,
            scope: fixture.scope
        )
        let history = try await repository.history(
            for: second.target,
            feature: second.feature,
            streamID: second.streamID,
            scope: fixture.scope
        )
        let newest = try await repository.history(
            for: second.target,
            feature: second.feature,
            streamID: second.streamID,
            scope: fixture.scope,
            limit: 1
        )
        XCTAssertEqual(persistedProjection, secondProjection)
        XCTAssertEqual(history, [second, first])
        XCTAssertEqual(newest, [second])
    }

    func testSubmillisecondObservationTimeIsCanonicalAndReplayRemainsIdempotent() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let sourceTime = fixture.date.addingTimeInterval(1.0004)
        let expectedTime = Date(
            timeIntervalSince1970: (
                sourceTime.timeIntervalSince1970 * 1_000
            ).rounded() / 1_000
        )
        let observation = fixture.observation(
            id: "submillisecond",
            observedAt: sourceTime
        )

        let firstProjection = try await repository.record(observation)
        let replayedProjection = try await repository.record(observation)
        let history = try await repository.history(
            for: observation.target,
            feature: observation.feature,
            streamID: observation.streamID,
            scope: fixture.scope
        )

        XCTAssertEqual(firstProjection.observedAt, expectedTime)
        XCTAssertEqual(replayedProjection, firstProjection)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.observedAt, expectedTime)
    }

    func testStaleAndEqualTimeConflictsRollBackWhileExactReplayIsIdempotent() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let current = fixture.observation(id: "current")
        let projection = try await repository.record(current)

        let replayedProjection = try await repository.record(current)
        var counts = try await fixture.counts()
        XCTAssertEqual(replayedProjection, projection)
        XCTAssertEqual(counts, .init(observations: 1, projections: 1))

        await assertThrows(.staleObservation) {
            _ = try await repository.record(
                fixture.observation(id: "older", observedAt: fixture.date.addingTimeInterval(-1))
            )
        }
        await assertThrows(.conflictingObservation) {
            _ = try await repository.record(fixture.observation(id: "equal-time"))
        }
        await assertThrows(.conflictingObservation) {
            _ = try await repository.record(
                fixture.observation(id: "current", sourceRevision: "changed")
            )
        }

        counts = try await fixture.counts()
        let persistedProjection = try await repository.projection(
            for: current.target,
            feature: current.feature,
            streamID: current.streamID,
            scope: fixture.scope
        )
        let history = try await repository.history(
            for: current.target,
            feature: current.feature,
            streamID: current.streamID,
            scope: fixture.scope
        )
        XCTAssertEqual(counts, .init(observations: 1, projections: 1))
        XCTAssertEqual(persistedProjection, projection)
        XCTAssertEqual(history, [current])
    }

    func testRejectsStaleCredentialAndCapabilityRevisionsWithoutPartialWrites() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let staleCredentialScope = SynchronizationScope(
            accountID: fixture.scope.accountID,
            organizationID: fixture.scope.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: fixture.scope.capabilityRevision
        )
        let staleCapabilityScope = SynchronizationScope(
            accountID: fixture.scope.accountID,
            organizationID: fixture.scope.organizationID,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: CapabilityRevision(rawValue: "capability-stale")!
        )

        await assertThrows(.staleSynchronizationScope) {
            _ = try await repository.record(
                fixture.observation(id: "stale-credential", scope: staleCredentialScope)
            )
        }
        await assertThrows(.staleSynchronizationScope) {
            _ = try await repository.record(
                fixture.observation(id: "stale-capability", scope: staleCapabilityScope)
            )
        }

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testCurrentRevisionSupersedesStaleProjectionAtSameCanonicalMillisecond() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let oldObservation = fixture.observation(id: "old-revision")
        _ = try await repository.record(oldObservation)
        let currentScope = try await fixture.rotateScope(
            credentialRevision: CredentialRevision(rawValue: "credential-2")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
        )
        let currentObservation = fixture.observation(
            id: "current-revision",
            scope: currentScope,
            sourceRevision: "revision-2",
            observedAt: oldObservation.observedAt
        )

        let projection = try await repository.record(currentObservation)
        let persistedProjection = try await repository.projection(
            for: currentObservation.target,
            feature: currentObservation.feature,
            streamID: currentObservation.streamID,
            scope: currentScope
        )
        await assertThrows(.staleSynchronizationScope) {
            _ = try await repository.projection(
                for: oldObservation.target,
                feature: oldObservation.feature,
                streamID: oldObservation.streamID,
                scope: oldObservation.scope
            )
        }
        let counts = try await fixture.counts()

        XCTAssertEqual(projection.winningObservationID, currentObservation.id)
        XCTAssertEqual(persistedProjection, projection)
        XCTAssertEqual(counts, .init(observations: 2, projections: 1))
    }

    func testRejectsAccountStreamAndTargetScopeMismatchesWithoutPartialWrites() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let otherAccountScope = SynchronizationScope(
            accountID: AccountID.make(),
            organizationID: fixture.scope.organizationID,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: fixture.scope.capabilityRevision
        )

        await assertThrows(.accountScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(id: "other-account", scope: otherAccountScope)
            )
        }
        await assertThrows(.streamScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(
                    id: "wrong-stream",
                    streamID: SyncStreamID(rawValue: "missing-stream")!
                )
            )
        }
        await assertThrows(.targetScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(
                    id: "wrong-target-kind",
                    target: .repository(RepositoryID(rawValue: fixture.teamID.rawValue)!)
                )
            )
        }

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testPartialCoverageAndPrivateNotFoundCannotAuthorizeDeletion() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let inaccessible = fixture.observation(
            id: "private-404",
            result: .inaccessible,
            reason: .privateNotFound,
            authority: .directProbe,
            confirmation: .confirmed
        )
        _ = try await repository.record(inaccessible)

        let deletionAttempt = fixture.observation(
            id: "partial-coverage-delete",
            sourceRevision: "reconciliation-2",
            result: .authoritativelyDeleted,
            reason: .authoritativeOmission,
            authority: .fullReconciliation,
            confirmation: .confirmed,
            observedAt: fixture.date.addingTimeInterval(1)
        )
        await assertThrows(.authoritativeDeletionContractUnavailable) {
            _ = try await repository.record(deletionAttempt)
        }
        let projection = try await repository.projection(
            for: inaccessible.target,
            feature: inaccessible.feature,
            streamID: inaccessible.streamID,
            scope: inaccessible.scope
        )
        let history = try await repository.history(
            for: inaccessible.target,
            feature: inaccessible.feature,
            streamID: inaccessible.streamID,
            scope: fixture.scope
        )
        let counts = try await fixture.counts()
        XCTAssertEqual(projection?.result, .inaccessible)
        XCTAssertEqual(history, [inaccessible])
        XCTAssertEqual(counts, .init(observations: 1, projections: 1))
    }

    func testInventoryOmissionIsProvisionalUnknownAndNeverDeletion() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let omission = fixture.observation(
            id: "inventory-omission",
            source: .endpoint("/orgs/acme/repos?type=all&per_page=100"),
            result: .unknown,
            reason: .inventoryOmission,
            authority: .fullReconciliation,
            confirmation: .provisional
        )

        let projection = try await repository.record(omission)

        XCTAssertEqual(projection.result, .unknown)
        await assertThrows(.invalidResultReason) {
            _ = try await repository.record(
                fixture.observation(
                    id: "confirmed-inventory-omission",
                    result: .unknown,
                    reason: .inventoryOmission,
                    authority: .fullReconciliation,
                    confirmation: .confirmed,
                    observedAt: fixture.date.addingTimeInterval(1)
                )
            )
        }
        let history = try await repository.history(
            for: omission.target,
            feature: omission.feature,
            streamID: omission.streamID,
            scope: fixture.scope
        )
        let counts = try await fixture.counts()
        XCTAssertEqual(history, [omission])
        XCTAssertEqual(counts, .init(observations: 1, projections: 1))
    }

    func testRawSnapshotMustBelongToObservationAccount() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let foreignRawSnapshotID = try await fixture.seedForeignRawSnapshot()

        await assertThrows(.rawSnapshotScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(id: "foreign-raw", rawSnapshotID: foreignRawSnapshotID)
            )
        }

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testRawSnapshotRequiresExactAuthorityTimestampSourceAndRequestKey() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let wrongAuthorityID = try await fixture.seedRawSnapshot(
            id: "raw-wrong-authority",
            feature: .teams,
            streamID: SyncStreamID(rawValue: "other-authority")!
        )
        let wrongLocatorID = try await fixture.seedRawSnapshot(
            id: "raw-wrong-locator",
            source: .endpoint("/orgs/acme/teams?per_page=100")
        )
        let wrongTimeID = try await fixture.seedRawSnapshot(
            id: "raw-wrong-time",
            observedAt: fixture.date.addingTimeInterval(1)
        )
        let wrongRequestKeyID = try await fixture.seedRawSnapshot(
            id: "raw-wrong-request-key",
            requestKey: "GET /orgs/acme/teams?per_page=100"
        )

        for (id, rawSnapshotID) in [
            ("wrong-authority", wrongAuthorityID),
            ("wrong-locator", wrongLocatorID),
            ("wrong-time", wrongTimeID),
            ("wrong-request-key", wrongRequestKeyID)
        ] {
            await assertThrows(.rawSnapshotScopeMismatch) {
                _ = try await repository.record(
                    fixture.observation(id: id, rawSnapshotID: rawSnapshotID)
                )
            }
        }
        let rejectedCounts = try await fixture.counts()
        XCTAssertEqual(rejectedCounts, .init(observations: 0, projections: 0))

        let endpointSnapshotID = try await fixture.seedRawSnapshot(
            id: "raw-endpoint-authority"
        )
        let endpointObservation = fixture.observation(
            id: "endpoint-authority",
            rawSnapshotID: endpointSnapshotID
        )
        _ = try await repository.record(endpointObservation)

        let querySource = SourceAccessLocator.query("OrganizationRepositoryInventory")
        let querySnapshotID = try await fixture.seedRawSnapshot(
            id: "raw-query-authority",
            source: querySource,
            observedAt: fixture.date.addingTimeInterval(1)
        )
        let queryObservation = fixture.observation(
            id: "query-authority",
            source: querySource,
            rawSnapshotID: querySnapshotID,
            observedAt: fixture.date.addingTimeInterval(1)
        )
        _ = try await repository.record(queryObservation)

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 2, projections: 1))
    }

    func testSourceNodeAndEventMustHaveProvableExactScopeAndRelationship() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)

        await assertThrows(.sourceProvenanceScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(
                    id: "missing-source-node",
                    sourceNodeID: GitHubNodeID(rawValue: "missing-node")!
                )
            )
        }
        await assertThrows(.sourceProvenanceScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(
                    id: "missing-source-event",
                    sourceEventID: GitHubEventID(rawValue: "missing-event")!
                )
            )
        }
        await assertThrows(.sourceProvenanceScopeMismatch) {
            _ = try await repository.record(
                fixture.observation(
                    id: "mismatched-node-event",
                    sourceNodeID: GitHubNodeID(rawValue: fixture.repositoryID.rawValue)!,
                    sourceEventID: fixture.eventID
                )
            )
        }

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testTimelineEventDeletionPreservesImmutableSourceEventProvenance() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let observation = fixture.observation(
            id: "durable-source-event",
            sourceNodeID: fixture.nodeID,
            sourceEventID: fixture.eventID
        )
        _ = try await repository.record(observation)

        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM timeline_events WHERE github_event_id = ?",
                arguments: [fixture.eventID.rawValue]
            )
        }

        let history = try await repository.history(
            for: observation.target,
            feature: observation.feature,
            streamID: observation.streamID,
            scope: observation.scope
        )
        XCTAssertEqual(history, [observation])
        XCTAssertEqual(history.first?.sourceEventID, fixture.eventID)
    }

    func testRawSnapshotCompactionNullsOptionalLinkWithoutRemovingEvidence() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let observation = fixture.observation(
            id: "snapshot-compaction",
            rawSnapshotID: fixture.rawSnapshotID
        )
        _ = try await repository.record(observation)

        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM raw_api_snapshots WHERE id = ?",
                arguments: [fixture.rawSnapshotID.rawValue]
            )
        }

        let history = try await repository.history(
            for: observation.target,
            feature: observation.feature,
            streamID: observation.streamID,
            scope: fixture.scope
        )
        let projection = try await repository.projection(
            for: observation.target,
            feature: observation.feature,
            streamID: observation.streamID,
            scope: fixture.scope
        )
        let expected = SourceAccessObservation(
            id: observation.id,
            scope: observation.scope,
            feature: observation.feature,
            streamID: observation.streamID,
            target: observation.target,
            source: observation.source,
            sourceNodeID: observation.sourceNodeID,
            sourceEventID: observation.sourceEventID,
            sourceRevision: observation.sourceRevision,
            rawSnapshotID: nil,
            result: observation.result,
            reason: observation.reason,
            authority: observation.authority,
            confirmation: observation.confirmation,
            observedAt: observation.observedAt
        )
        XCTAssertEqual(history, [expected])
        XCTAssertEqual(projection?.winningObservationID, observation.id)
    }

    func testCompleteCoverageAndRawReceiptCannotSupplyDeletionContract() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let accessible = fixture.observation(id: "prior-access")
        _ = try await repository.record(accessible)
        let deletionTime = fixture.date.addingTimeInterval(1)
        let receiptID = try await fixture.seedRawSnapshot(
            id: "raw-durable-deletion-receipt",
            observedAt: deletionTime
        )
        try await fixture.saveCoverage(
            status: .complete,
            lastSuccessfulAt: deletionTime
        )
        let deletion = fixture.observation(
            id: "durable-deletion-receipt",
            sourceRevision: "reconciliation-receipt",
            rawSnapshotID: receiptID,
            result: .authoritativelyDeleted,
            reason: .authoritativeOmission,
            authority: .fullReconciliation,
            confirmation: .confirmed,
            observedAt: deletionTime
        )
        await assertThrows(.authoritativeDeletionContractUnavailable) {
            _ = try await repository.record(deletion)
        }
        let projection = try await repository.projection(
            for: accessible.target,
            feature: accessible.feature,
            streamID: accessible.streamID,
            scope: accessible.scope
        )
        let history = try await repository.history(
            for: accessible.target,
            feature: accessible.feature,
            streamID: accessible.streamID,
            scope: accessible.scope
        )
        let receiptCount = try await fixture.vault.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM raw_api_snapshots WHERE id = ?",
                arguments: [receiptID.rawValue]
            ) ?? 0
        }
        XCTAssertEqual(receiptCount, 1)
        XCTAssertEqual(projection?.result, .accessible)
        XCTAssertEqual(history, [accessible])
        let retainedCounts = try await fixture.counts()
        XCTAssertEqual(retainedCounts, .init(observations: 1, projections: 1))
    }

    func testPriorCredentialOrCapabilityRevisionCannotAuthorizeACurrentRawObservation() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let currentScope = try await fixture.rotateScope(
            credentialRevision: CredentialRevision(rawValue: "credential-2")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
        )
        let observation = fixture.observation(
            id: "prior-revision-raw",
            scope: currentScope,
            rawSnapshotID: fixture.rawSnapshotID
        )

        await assertThrows(.rawSnapshotScopeMismatch) {
            _ = try await repository.record(observation)
        }

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testFeatureAndStreamAuthoritiesHaveIndependentCurrentProjections() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let secondRepositoryStream = SyncStreamID(rawValue: "repositories-secondary")!
        let issueStream = SyncStreamID(rawValue: "issues-primary")!
        try await fixture.ensureStream(feature: .repositories, streamID: secondRepositoryStream)
        try await fixture.ensureStream(feature: .issues, streamID: issueStream)
        let observations = [
            fixture.observation(id: "authority-default"),
            fixture.observation(
                id: "authority-second-stream",
                streamID: secondRepositoryStream
            ),
            fixture.observation(
                id: "authority-second-feature",
                feature: .issues,
                streamID: issueStream
            )
        ]

        for observation in observations {
            _ = try await repository.record(observation)
        }

        for observation in observations {
            let projection = try await repository.projection(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: observation.scope
            )
            let history = try await repository.history(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: observation.scope
            )
            XCTAssertEqual(projection?.winningObservationID, observation.id)
            XCTAssertEqual(history, [observation])
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 3, projections: 3))
    }

    func testReplayingOlderExactObservationReturnsNewerCurrentProjection() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let older = fixture.observation(id: "older-exact")
        let newer = fixture.observation(
            id: "newer-current",
            sourceRevision: "revision-2",
            observedAt: fixture.date.addingTimeInterval(1)
        )
        _ = try await repository.record(older)
        let newerProjection = try await repository.record(newer)

        let replayProjection = try await repository.record(older)
        let counts = try await fixture.counts()

        XCTAssertEqual(replayProjection, newerProjection)
        XCTAssertEqual(replayProjection.winningObservationID, newer.id)
        XCTAssertEqual(counts, .init(observations: 2, projections: 1))
    }

    func testExtremeDatesFailClosedWithoutTrappingOrPartialWrites() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let dates = [
            Date(timeIntervalSince1970: Double(Int64.max) / 1_000),
            Date(timeIntervalSince1970: Double(Int64.min) / 1_000 - 10_000),
            Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
        ]

        for (index, date) in dates.enumerated() {
            await assertThrows(.invalidTimestamp) {
                _ = try await repository.record(
                    fixture.observation(id: "extreme-date-\(index)", observedAt: date)
                )
            }
        }

        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testOrganizationAndAccountErasureCascadeAccessEvidence() async throws {
        let organizationFixture = try await SourceObservationFixture()
        defer { organizationFixture.remove() }
        let organizationRepository = SourceAccessObservationRepository(
            vault: organizationFixture.vault
        )
        _ = try await organizationRepository.record(
            organizationFixture.observation(id: "organization-erasure")
        )
        try await organizationFixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM account_organizations WHERE account_id = ? AND organization_id = ?",
                arguments: [
                    organizationFixture.account.id.rawValue,
                    organizationFixture.organization.id.rawValue
                ]
            )
        }
        var counts = try await organizationFixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))

        let accountFixture = try await SourceObservationFixture()
        defer { accountFixture.remove() }
        let accountRepository = SourceAccessObservationRepository(vault: accountFixture.vault)
        _ = try await accountRepository.record(
            accountFixture.observation(id: "account-erasure")
        )
        try await accountFixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM accounts WHERE id = ?",
                arguments: [accountFixture.account.id.rawValue]
            )
        }
        counts = try await accountFixture.counts()
        XCTAssertEqual(counts, .init(observations: 0, projections: 0))
    }

    func testStreamResetPreservesImmutableHistoryAndProjection() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let observation = fixture.observation(id: "survives-stream-reset")
        let expectedProjection = try await repository.record(observation)

        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM sync_streams WHERE id = ?",
                arguments: [fixture.streamID.rawValue]
            )
        }

        let history = try await repository.history(
            for: observation.target,
            feature: observation.feature,
            streamID: observation.streamID,
            scope: observation.scope
        )
        let projection = try await repository.projection(
            for: observation.target,
            feature: observation.feature,
            streamID: observation.streamID,
            scope: observation.scope
        )
        XCTAssertEqual(history, [observation])
        XCTAssertEqual(projection, expectedProjection)
    }

    func testProjectionRejectsPersistedWinnerMismatch() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let observation = fixture.observation(id: "projection-mismatch")
        _ = try await repository.record(observation)
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    UPDATE source_access_projections
                    SET result = 'unknown'
                    WHERE account_id = ? AND organization_id = ?
                      AND feature = ? AND stream_id = ?
                      AND target_kind = ? AND target_id = ?
                    """,
                arguments: [
                    observation.scope.accountID.rawValue,
                    observation.scope.organizationID.rawValue,
                    observation.feature.rawValue,
                    observation.streamID.rawValue,
                    observation.target.kind.rawValue,
                    observation.target.rawValue
                ]
            )
        }

        await assertThrows(.invalidPersistedData) {
            _ = try await repository.projection(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: observation.scope
            )
        }
    }

    func testTargetKindsWithTheSameRawIdentifierHaveIndependentProjections() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let targets = try await fixture.seedSharedTargets()
        let observations = [
            fixture.observation(id: "shared-repository", target: targets.repository),
            fixture.observation(id: "shared-node", target: targets.node),
            fixture.observation(id: "shared-team", target: targets.team)
        ]

        for observation in observations {
            _ = try await repository.record(observation)
        }

        for observation in observations {
            let projection = try await repository.projection(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: fixture.scope
            )
            let history = try await repository.history(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: fixture.scope
            )
            XCTAssertEqual(
                projection?.winningObservationID,
                observation.id
            )
            XCTAssertEqual(history, [observation])
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .init(observations: 3, projections: 3))
    }

    func testReadRejectsInvalidPersistedTypedValueAndHistoryIsBounded() async throws {
        let fixture = try await SourceObservationFixture()
        defer { fixture.remove() }
        let repository = SourceAccessObservationRepository(vault: fixture.vault)
        let observation = fixture.observation(id: "invalid-read")
        _ = try await repository.record(observation)

        await assertThrows(.invalidLimit) {
            _ = try await repository.history(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: fixture.scope,
                limit: SourceAccessObservationRepository.maximumHistoryCount + 1
            )
        }
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE source_access_observations SET source_revision = ' ' WHERE id = ?",
                arguments: [observation.id.rawValue]
            )
        }
        await assertThrows(.invalidPersistedData) {
            _ = try await repository.history(
                for: observation.target,
                feature: observation.feature,
                streamID: observation.streamID,
                scope: fixture.scope
            )
        }
    }
}

private struct SourceAccessCounts: Equatable {
    let observations: Int
    let projections: Int
}

private final class SourceObservationFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let scope: SynchronizationScope
    let streamID = SyncStreamID(rawValue: "access-repositories-acme")!
    let repositoryID = RepositoryID(rawValue: "R_1")!
    let teamID = TeamID(rawValue: "T_1")!
    let nodeID = GitHubNodeID(rawValue: "I_1")!
    let eventID = GitHubEventID(rawValue: "event-1")!
    let rawSnapshotID = RawAPISnapshotID(rawValue: "raw-current")!
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-source-observation-\(UUID().uuidString)", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: root)
        let accountID = AccountID.make()
        vault = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        organization = GitHubOrganization(
            id: OrganizationID(rawValue: "acme")!,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_2")!,
            login: "acme"
        )
        scope = SynchronizationScope(
            accountID: accountID,
            organizationID: organization.id,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
        let accountRepository = AccountRepository(vault: vault)
        try await accountRepository.save(account, credentialRevision: scope.credentialRevision)
        try await accountRepository.save(
            organization,
            access: OrganizationAccess(
                accountID: account.id,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: scope.capabilityRevision,
                capabilities: [],
                checkedAt: date
            )
        )
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: account.id,
                organizationID: organization.id,
                repositoryID: nil,
                feature: .repositories,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: "Access observation fixture."
            ),
            attemptedAt: date
        )
        _ = try await accountRepository.save(
            repository: repositoryDTO(id: 10, nodeID: repositoryID.rawValue, name: "repo"),
            organizationID: organization.id,
            accountID: account.id
        )
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO teams (id, organization_id, github_node_id, slug, name, privacy, updated_at_ms)
                    VALUES (?, ?, ?, 'triage', 'Triage', 'closed', ?)
                    """,
                arguments: [teamID.rawValue, organization.id.rawValue, teamID.rawValue, milliseconds(date)]
            )
        }
        try await GitHubNodeRepository(vault: vault).save(
            normalizedNode(id: nodeID, title: "Issue")
        )
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO timeline_events (
                        github_event_id, subject_node_id, actor_id, kind, occurred_at_ms,
                        payload_json, source_revision
                    ) VALUES (?, ?, NULL, 'mentioned', ?, ?, 'event-revision')
                    """,
                arguments: [
                    eventID.rawValue,
                    nodeID.rawValue,
                    milliseconds(date),
                    Data("{}".utf8)
                ]
            )
        }
        try await RawAPISnapshotRepository(vault: vault).save(
            RawAPISnapshot(
                id: rawSnapshotID,
                accountID: account.id,
                githubNodeID: nil,
                endpoint: "/orgs/acme/repos?type=all&per_page=100",
                eTag: nil,
                parserVersion: 1,
                observedAt: date,
                payload: Data("{}".utf8),
                requestIdentity: ConditionalRequestIdentity(
                    scope: scope,
                    feature: .repositories,
                    streamID: streamID,
                    requestKey: "GET /orgs/acme/repos?type=all&per_page=100"
                )
            )
        )
    }

    func observation(
        id: String,
        scope: SynchronizationScope? = nil,
        feature: CoverageFeature = .repositories,
        streamID: SyncStreamID? = nil,
        target: SourceAccessTarget? = nil,
        source: SourceAccessLocator = .endpoint("/orgs/acme/repos?type=all&per_page=100"),
        sourceNodeID: GitHubNodeID? = nil,
        sourceEventID: GitHubEventID? = nil,
        sourceRevision: String = "revision-1",
        rawSnapshotID: RawAPISnapshotID? = nil,
        result: SourceAccessResult = .accessible,
        reason: SourceAccessReason = .directResponse,
        authority: SourceAccessAuthority = .incremental,
        confirmation: SourceAccessConfirmation = .confirmed,
        observedAt: Date? = nil
    ) -> SourceAccessObservation {
        SourceAccessObservation(
            id: SourceAccessObservationID(rawValue: id)!,
            scope: scope ?? self.scope,
            feature: feature,
            streamID: streamID ?? self.streamID,
            target: target ?? .repository(repositoryID),
            source: source,
            sourceNodeID: sourceNodeID,
            sourceEventID: sourceEventID,
            sourceRevision: sourceRevision,
            rawSnapshotID: rawSnapshotID,
            result: result,
            reason: reason,
            authority: authority,
            confirmation: confirmation,
            observedAt: observedAt ?? date
        )
    }

    func counts() async throws -> SourceAccessCounts {
        try await vault.read { database in
            SourceAccessCounts(
                observations: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM source_access_observations"
                ) ?? 0,
                projections: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM source_access_projections"
                ) ?? 0
            )
        }
    }

    func saveCoverage(
        status: CoverageStatus,
        lastSuccessfulAt: Date?,
        repositoryID: RepositoryID? = nil,
        intervalStart: Date? = nil,
        intervalEnd: Date? = nil
    ) async throws {
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: account.id,
                organizationID: organization.id,
                repositoryID: repositoryID,
                feature: .repositories,
                streamID: streamID,
                intervalStart: intervalStart,
                intervalEnd: intervalEnd,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision,
                status: status,
                lastSuccessfulAt: lastSuccessfulAt,
                failureDetail: nil
            ),
            attemptedAt: lastSuccessfulAt ?? date
        )
    }

    func ensureStream(feature: CoverageFeature, streamID: SyncStreamID) async throws {
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: account.id,
                organizationID: organization.id,
                repositoryID: nil,
                feature: feature,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: "Source observation authority fixture."
            ),
            attemptedAt: date
        )
    }

    func rotateScope(
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) async throws -> SynchronizationScope {
        let accountRepository = AccountRepository(vault: vault)
        try await accountRepository.save(
            account,
            credentialRevision: credentialRevision
        )
        try await accountRepository.save(
            organization,
            access: OrganizationAccess(
                accountID: account.id,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: date
            )
        )
        return SynchronizationScope(
            accountID: account.id,
            organizationID: organization.id,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    func seedRawSnapshot(
        id: String,
        feature: CoverageFeature = .repositories,
        streamID: SyncStreamID? = nil,
        source: SourceAccessLocator = .endpoint(
            "/orgs/acme/repos?type=all&per_page=100"
        ),
        observedAt: Date? = nil,
        requestKey: String? = nil
    ) async throws -> RawAPISnapshotID {
        let snapshotID = RawAPISnapshotID(rawValue: id)!
        let endpoint: String
        switch source {
        case let .endpoint(value): endpoint = value
        case .query: endpoint = "POST /graphql"
        }
        try await RawAPISnapshotRepository(vault: vault).save(
            RawAPISnapshot(
                id: snapshotID,
                accountID: account.id,
                githubNodeID: nil,
                endpoint: endpoint,
                eTag: nil,
                parserVersion: 1,
                observedAt: observedAt ?? date,
                payload: Data("{}".utf8),
                requestIdentity: ConditionalRequestIdentity(
                    scope: scope,
                    feature: feature,
                    streamID: streamID ?? self.streamID,
                    requestKey: requestKey ?? {
                        switch source {
                        case let .endpoint(value): "GET \(value)"
                        case let .query(value): value
                        }
                    }()
                )
            )
        )
        return snapshotID
    }

    func seedForeignRawSnapshot() async throws -> RawAPISnapshotID {
        let otherAccountID = AccountID.make()
        let snapshotID = RawAPISnapshotID(rawValue: "raw-other-account")!
        try await vault.writeTransaction { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status,
                        credential_revision, created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, '99', 'U_99', 'other', NULL, NULL, 'oauth', ?, 'active',
                              'credential-other', ?, ?, NULL)
                    """,
                arguments: [
                    otherAccountID.rawValue,
                    CredentialID.make().rawValue,
                    milliseconds(date),
                    milliseconds(date)
                ]
            )
            try RawAPISnapshotRepository.save(
                RawAPISnapshot(
                    id: snapshotID,
                    accountID: otherAccountID,
                    githubNodeID: nil,
                    endpoint: "GET /user",
                    eTag: nil,
                    parserVersion: 1,
                    observedAt: date,
                    payload: Data("{}".utf8)
                ),
                in: database
            )
        }
        return snapshotID
    }

    func seedSharedTargets() async throws -> (
        repository: SourceAccessTarget,
        node: SourceAccessTarget,
        team: SourceAccessTarget
    ) {
        let rawID = "SHARED_1"
        let repositoryID = RepositoryID(rawValue: rawID)!
        let nodeID = GitHubNodeID(rawValue: rawID)!
        let teamID = TeamID(rawValue: rawID)!
        try await vault.writeTransaction { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login,
                        name, is_private, is_archived, has_discussions,
                        has_discussions_known, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, '11', ?, 'acme', 'shared', 1, 0, 0, 0,
                              'https://github.com/acme/shared', ?, NULL)
                    """,
                arguments: [rawID, organization.id.rawValue, rawID, milliseconds(date)]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (
                        account_id, repository_id, access_state, observed_at_ms
                    ) VALUES (?, ?, 'available', ?)
                    """,
                arguments: [account.id.rawValue, rawID, milliseconds(date)]
            )
            try database.execute(
                sql: """
                    INSERT INTO teams (
                        id, organization_id, github_node_id, slug, name, privacy, updated_at_ms
                    ) VALUES (?, ?, ?, 'shared', 'Shared', 'closed', ?)
                    """,
                arguments: [rawID, organization.id.rawValue, rawID, milliseconds(date)]
            )
            try GitHubNodeRepository.save(
                normalizedNode(id: nodeID, title: "Shared node"),
                in: database
            )
        }
        return (.repository(repositoryID), .githubNode(nodeID), .team(teamID))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func repositoryDTO(id: UInt64, nodeID: String, name: String) -> GitHubRepositoryDTO {
        GitHubRepositoryDTO(
            id: id,
            nodeID: nodeID,
            name: name,
            isPrivate: true,
            isArchived: false,
            hasDiscussions: false,
            htmlURL: URL(string: "https://github.com/acme/\(name)")!,
            updatedAt: date,
            owner: .init(login: "acme")
        )
    }

    private func normalizedNode(id: GitHubNodeID, title: String) -> NormalizedGitHubNode {
        NormalizedGitHubNode(
            nodeID: id,
            accountID: account.id,
            organizationID: organization.id,
            repositoryID: nil,
            kind: .issue,
            numericID: nil,
            number: 1,
            title: title,
            state: .open,
            url: URL(string: "https://github.com/acme/repo/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "node-revision",
            observedAt: date,
            accessibility: .accessible
        )
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private func assertThrows(
    _ expected: SourceAccessObservationRepositoryError,
    operation: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? SourceAccessObservationRepositoryError,
            expected,
            file: file,
            line: line
        )
    }
}
