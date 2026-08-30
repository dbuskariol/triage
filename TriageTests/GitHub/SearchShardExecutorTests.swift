import XCTest
@testable import Triage

final class SearchShardExecutorTests: XCTestCase {
    func testSearchAtExactResultCapBisectsAndPersistsCompletedShards() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let client = SearchClient { query, _ in
            let rootRange = "updated:1970-01-01T00:00:00Z..1970-01-01T00:02:00Z"
            let isRoot = query.value.contains(rootRange)
            return GitHubResponse(
                value: GitHubIssueSearchPage(
                    totalCount: isRoot ? 1_000 : 1,
                    incompleteResults: false,
                    items: []
                ),
                payload: Data(),
                etag: nil,
                lastModified: nil,
                ssoHeader: nil
            )
        }
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        try await executor.execute(
            query: query,
            range: SearchTimeRange(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 120)
            ),
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { _, _, _ in .empty }
        )

        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(shards.count, 3)
        XCTAssertTrue(shards.allSatisfy { $0.state == .completed })
        XCTAssertEqual(
            shards.filter { $0.pageCursor == "1" }.count,
            2
        )
    }

    func testLaterIncompletePageIsRetainedAndRepartitioned() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let recorder = CommitRecorder()
        let rootRange = "updated:1970-01-01T00:00:00Z..1970-01-01T00:02:00Z"
        let client = SearchClient { query, page in
            let isRoot = query.value.contains(rootRange)
            return GitHubResponse(
                value: GitHubIssueSearchPage(
                    totalCount: isRoot ? 200 : 1,
                    incompleteResults: isRoot && page == 2,
                    items: []
                ),
                payload: Data((isRoot && page == 2 ? "incomplete-control" : "complete").utf8),
                etag: nil,
                lastModified: nil,
                ssoHeader: nil
            )
        }
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        try await executor.execute(
            query: query,
            range: SearchTimeRange(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 120)
            ),
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            prepareControlPage: { response, controlQuery, page in
                let identity = try GitHubIssueSearchRequestIdentity(
                    query: controlQuery,
                    page: page,
                    scope: fixture.scope,
                    streamID: fixture.streamID
                )
                let snapshot = RawAPISnapshot(
                    id: RawAPISnapshotID.make(),
                    accountID: fixture.accountID,
                    githubNodeID: nil,
                    endpoint: identity.endpoint,
                    eTag: nil,
                    parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                    observedAt: fixture.date,
                    payload: response.payload,
                    requestIdentity: fixture.requestIdentity(for: identity)
                )
                return PreparedSearchShardPageWrite(
                    write: { database in
                        try RawAPISnapshotRepository.save(snapshot, in: database)
                    },
                    didCommit: {
                        await recorder.recordCommit()
                    }
                )
            },
            preparePage: { _, _, _ in .empty }
        )

        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(shards.count, 3)
        XCTAssertTrue(shards.allSatisfy { $0.state == .completed })
        XCTAssertEqual(shards.filter { $0.pageCursor == "partitioned" }.count, 1)
        let snapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        XCTAssertEqual(snapshots.map(\.payload), [Data("incomplete-control".utf8)])
        let didCommit = await recorder.didCommit()
        XCTAssertTrue(didCommit)
    }

    func testCachedPageOneAndLaterPageReplayWithoutCreatingRawDuplicates() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let boundedQuery = try query.bounded(to: range)
        let firstETag = "\"page-1\""
        let secondETag = "\"page-2\""
        let payload = Data(
            #"{"total_count":200,"incomplete_results":false,"items":[]}"#.utf8
        )
        let firstSnapshot = try await fixture.seedReplay(
            query: boundedQuery,
            page: 1,
            payload: payload,
            eTag: firstETag
        )
        let secondSnapshot = try await fixture.seedReplay(
            query: boundedQuery,
            page: 2,
            payload: payload,
            eTag: secondETag
        )
        let client = ConditionalSearchClient { _, _, validators in
            guard validators == httpValidators(eTag: firstETag)
                || validators == httpValidators(eTag: secondETag)
            else {
                throw TestPageWriteError.unexpectedRequest
            }
            return .notModified(ssoHeader: nil)
        }
        let recorder = ReplayPageRecorder()
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date.addingTimeInterval(1) }
        )

        try await executor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { response, _, page in
                PreparedSearchShardPageWrite(
                    write: { _ in },
                    didCommit: {
                        await recorder.record(page: page, source: response.source)
                    }
                )
            }
        )

        let requests = await client.requests()
        XCTAssertEqual(
            requests,
            [
                ConditionalSearchRequest(page: 1, validators: httpValidators(eTag: firstETag)),
                ConditionalSearchRequest(page: 2, validators: httpValidators(eTag: secondETag))
            ]
        )
        let replayedPages = await recorder.pages()
        XCTAssertEqual(replayedPages.map(\.page), [1, 2])
        XCTAssertEqual(
            replayedPages.map(\.source),
            [.replay(firstSnapshot.id), .replay(secondSnapshot.id)]
        )
        let snapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        XCTAssertEqual(Set(snapshots.map(\.id)), Set([firstSnapshot.id, secondSnapshot.id]))
    }

    func testCachedIncompleteControlPageIsReplayedOnlyToRepartition() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let boundedQuery = try query.bounded(to: range)
        let eTag = "\"incomplete-control\""
        let snapshot = try await fixture.seedReplay(
            query: boundedQuery,
            page: 1,
            payload: Data(
                #"{"total_count":1,"incomplete_results":true,"items":[]}"#.utf8
            ),
            eTag: eTag
        )
        let completePayload = Data(
            #"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8
        )
        let client = ConditionalSearchClient { _, _, validators in
            if validators == httpValidators(eTag: eTag) {
                return .notModified(ssoHeader: nil)
            }
            return .response(
                GitHubResponse(
                    value: GitHubIssueSearchPage(
                        totalCount: 0,
                        incompleteResults: false,
                        items: []
                    ),
                    payload: completePayload,
                    etag: nil,
                    lastModified: nil,
                    ssoHeader: nil
                )
            )
        }
        let controlRecorder = ReplayPageRecorder()
        let candidateRecorder = ReplayPageRecorder()
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date.addingTimeInterval(1) }
        )

        try await executor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            prepareControlPage: { response, _, page in
                PreparedSearchShardPageWrite(
                    write: { _ in },
                    didCommit: {
                        await controlRecorder.record(page: page, source: response.source)
                    }
                )
            },
            preparePage: { response, _, page in
                PreparedSearchShardPageWrite(
                    write: { _ in },
                    didCommit: {
                        await candidateRecorder.record(page: page, source: response.source)
                    }
                )
            }
        )

        let controls = await controlRecorder.pages()
        XCTAssertEqual(controls, [.init(page: 1, source: .replay(snapshot.id))])
        let candidates = await candidateRecorder.pages()
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.source == .network })
        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(shards.count, 3)
        XCTAssertTrue(shards.allSatisfy { $0.state == .completed })
    }

    func testLastModifiedOnlyCachedPageReplaysOn304() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let snapshot = try await fixture.seedReplay(
            query: try query.bounded(to: range),
            page: 1,
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
            lastModified: lastModified
        )
        let client = ConditionalSearchClient { _, _, validators in
            XCTAssertEqual(validators, httpValidators(eTag: nil, lastModified: lastModified))
            return .notModified(ssoHeader: nil)
        }
        let recorder = ReplayPageRecorder()
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date.addingTimeInterval(1) }
        )

        try await executor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { response, _, page in
                PreparedSearchShardPageWrite(
                    write: { _ in },
                    didCommit: { await recorder.record(page: page, source: response.source) }
                )
            }
        )

        let requests = await client.requests()
        let replayedPages = await recorder.pages()
        XCTAssertEqual(
            requests,
            [ConditionalSearchRequest(
                page: 1,
                validators: httpValidators(eTag: nil, lastModified: lastModified)
            )]
        )
        XCTAssertEqual(replayedPages, [.init(page: 1, source: .replay(snapshot.id))])
    }

    func testETagTakesPrecedenceWhenCachedReplayAlsoHasLastModified() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let eTag = "\"both-validators\""
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let snapshot = try await fixture.seedReplay(
            query: try query.bounded(to: range),
            page: 1,
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
            eTag: eTag,
            lastModified: lastModified
        )
        let client = ConditionalSearchClient { _, _, validators in
            XCTAssertEqual(validators?.eTag, eTag)
            XCTAssertEqual(validators?.lastModified, lastModified)
            return .notModified(ssoHeader: nil)
        }
        let recorder = ReplayPageRecorder()
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date.addingTimeInterval(1) }
        )

        try await executor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { response, _, page in
                PreparedSearchShardPageWrite(
                    write: { _ in },
                    didCommit: { await recorder.record(page: page, source: response.source) }
                )
            }
        )

        let requests = await client.requests()
        let replayedPages = await recorder.pages()
        XCTAssertEqual(
            requests,
            [ConditionalSearchRequest(
                page: 1,
                validators: httpValidators(eTag: eTag, lastModified: lastModified)
            )]
        )
        XCTAssertEqual(replayedPages, [.init(page: 1, source: .replay(snapshot.id))])
    }

    func testFailedCursorReplaysCommittedPagesBeforeResumingLaterPage() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let boundedQuery = try query.bounded(to: range)
        let pagePayload = Data(
            #"{"total_count":200,"incomplete_results":false,"items":[]}"#.utf8
        )
        let pageOneETag = "\"resume-page-1\""
        let firstClient = ConditionalSearchClient { _, page, _ in
            if page == 1 {
                return .response(
                    GitHubResponse(
                        value: GitHubIssueSearchPage(
                            totalCount: 200,
                            incompleteResults: false,
                            items: []
                        ),
                        payload: pagePayload,
                        etag: pageOneETag,
                        lastModified: nil,
                        ssoHeader: nil
                    )
                )
            }
            return .undecodable(
                GitHubUndecodableResponse(
                    payload: Data("malformed".utf8),
                    linkHeader: nil,
                    etag: nil,
                    lastModified: nil,
                    ssoHeader: nil
                )
            )
        }
        let firstExecutor = SearchShardExecutor(
            client: firstClient,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let pageOneIdentity = try GitHubIssueSearchRequestIdentity(
            query: boundedQuery,
            page: 1,
            scope: fixture.scope,
            streamID: fixture.streamID
        )
        let pageOneSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: pageOneIdentity.endpoint,
            eTag: pageOneETag,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            observedAt: fixture.date,
            payload: pagePayload,
            requestIdentity: fixture.requestIdentity(for: pageOneIdentity)
        )
        let pageOneReplay = fixture.replay(
            identity: pageOneIdentity,
            snapshot: pageOneSnapshot
        )

        do {
            try await firstExecutor.execute(
                query: query,
                range: range,
                streamID: fixture.streamID,
                accountID: fixture.accountID,
                accessibleRepositoryNames: [],
                prepareUndecodablePage: { _, _, _ in .empty },
                preparePage: { _, _, page in
                    XCTAssertEqual(page, 1)
                    return PreparedSearchShardPageWrite(
                        write: { database in
                            try RawAPISnapshotRepository.save(pageOneSnapshot, in: database)
                            try RoleSearchPageReplayRepository.save(
                                pageOneReplay,
                                expectedAccountID: fixture.accountID,
                                in: database
                            )
                        },
                        didCommit: {}
                    )
                }
            )
            XCTFail("Expected the later malformed page to leave a resumable failed shard.")
        } catch is GitHubIssueSearchUndecodableResponseError {
            // Expected after page one and its cursor were committed.
        }

        let recorder = ReplayPageRecorder()
        let secondClient = ConditionalSearchClient { _, page, validators in
            if page == 1 {
                XCTAssertEqual(validators, httpValidators(eTag: pageOneETag))
                return .notModified(ssoHeader: nil)
            }
            XCTAssertNil(validators)
            return .response(
                GitHubResponse(
                    value: GitHubIssueSearchPage(
                        totalCount: 200,
                        incompleteResults: false,
                        items: []
                    ),
                    payload: pagePayload,
                    etag: nil,
                    lastModified: nil,
                    ssoHeader: nil
                )
            )
        }
        let secondExecutor = SearchShardExecutor(
            client: secondClient,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date.addingTimeInterval(1) }
        )

        try await secondExecutor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { response, _, page in
                PreparedSearchShardPageWrite(
                    write: { _ in },
                    didCommit: {
                        await recorder.record(page: page, source: response.source)
                    }
                )
            }
        )

        let replayedPages = await recorder.pages()
        XCTAssertEqual(replayedPages.map(\.page), [1, 2])
        XCTAssertEqual(replayedPages.first?.source, .replay(pageOneSnapshot.id))
        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(shards.map(\.state), [.completed])
        XCTAssertEqual(shards.first?.pageCursor, "2")
    }

    func testCorruptMappedPayloadRetriesExactlyOnceWithoutValidator() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let boundedQuery = try query.bounded(to: range)
        let eTag = "\"corrupt-page\""
        _ = try await fixture.seedReplay(
            query: boundedQuery,
            page: 1,
            payload: Data("not-json".utf8),
            eTag: eTag
        )
        let client = ConditionalSearchClient { _, _, validators in
            if validators != nil {
                return .notModified(ssoHeader: nil)
            }
            return .response(
                GitHubResponse(
                    value: GitHubIssueSearchPage(
                        totalCount: 0,
                        incompleteResults: false,
                        items: []
                    ),
                    payload: Data(
                        #"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8
                    ),
                    etag: nil,
                    lastModified: nil,
                    ssoHeader: nil
                )
            )
        }
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date }
        )

        try await executor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { _, _, _ in .empty }
        )

        let requests = await client.requests()
        XCTAssertEqual(
            requests,
            [
                ConditionalSearchRequest(page: 1, validators: httpValidators(eTag: eTag)),
                ConditionalSearchRequest(page: 1, validators: nil)
            ]
        )
        let identity = try GitHubIssueSearchRequestIdentity(
            query: boundedQuery,
            page: 1,
            scope: fixture.scope,
            streamID: fixture.streamID
        )
        let removed = try await RoleSearchPageReplayRepository(vault: fixture.vault).entry(
            requestKey: identity.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNil(removed)
    }

    func testCancellationAfter304PreventsCorruptReplayInvalidationAndRetry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let boundedQuery = try query.bounded(to: range)
        let eTag = "\"cancelled-corrupt-page\""
        _ = try await fixture.seedReplay(
            query: boundedQuery,
            page: 1,
            payload: Data("not-json".utf8),
            eTag: eTag
        )
        let client = ConditionalSearchClient { _, _, validators in
            XCTAssertEqual(validators, httpValidators(eTag: eTag))
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return .notModified(ssoHeader: nil)
        }
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date }
        )

        do {
            try await executor.execute(
                query: query,
                range: range,
                streamID: fixture.streamID,
                accountID: fixture.accountID,
                accessibleRepositoryNames: [],
                preparePage: { _, _, _ in .empty }
            )
            XCTFail("Cancellation must stop replay repair before any mutation or retry.")
        } catch is CancellationError {
            // Expected.
        }

        let requests = await client.requests()
        XCTAssertEqual(
            requests,
            [ConditionalSearchRequest(page: 1, validators: httpValidators(eTag: eTag))]
        )
        let identity = try GitHubIssueSearchRequestIdentity(
            query: boundedQuery,
            page: 1,
            scope: fixture.scope,
            streamID: fixture.streamID
        )
        let retained = try await RoleSearchPageReplayRepository(vault: fixture.vault).entry(
            requestKey: identity.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNotNil(retained)
    }

    func testNotModifiedWithoutMappingFailsClosedAndDoesNotCreateEmptySuccess() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let client = ConditionalSearchClient { _, _, _ in
            .notModified(ssoHeader: nil)
        }
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            replayCache: RoleSearchPageReplayCache(
                repository: RoleSearchPageReplayRepository(vault: fixture.vault),
                scope: fixture.scope
            ),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        do {
            try await executor.execute(
                query: query,
                range: SearchTimeRange(
                    start: Date(timeIntervalSince1970: 0),
                    end: Date(timeIntervalSince1970: 120)
                ),
                streamID: fixture.streamID,
                accountID: fixture.accountID,
                accessibleRepositoryNames: [],
                preparePage: { _, _, _ in .empty }
            )
            XCTFail("A 304 without exact replay content must not become an empty page.")
        } catch let error as SearchShardExecutorError {
            XCTAssertEqual(error, .notModifiedWithoutReplay)
        }

        let requests = await client.requests()
        XCTAssertEqual(requests, [ConditionalSearchRequest(page: 1, validators: nil)])
        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(shards.map(\.state), [.failed])
        XCTAssertNil(shards.first?.pageCursor)
    }

    func testFailedPreparedPageWriteRollsBackSnapshotAndCursor() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let recorder = CommitRecorder()
        let executor = SearchShardExecutor(
            client: SearchClient { _, _ in
                GitHubResponse(
                    value: GitHubIssueSearchPage(
                        totalCount: 1,
                        incompleteResults: false,
                        items: []
                    ),
                    payload: Data(),
                    etag: nil,
                    lastModified: nil,
                    ssoHeader: nil
                )
            },
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let identity = try GitHubIssueSearchRequestIdentity(
            query: try query.bounded(to: range),
            page: 1,
            scope: fixture.scope,
            streamID: fixture.streamID
        )
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: identity.endpoint,
            eTag: "\"rollback\"",
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            observedAt: fixture.date,
            payload: Data("response".utf8),
            requestIdentity: fixture.requestIdentity(for: identity)
        )
        let replay = fixture.replay(identity: identity, snapshot: snapshot)

        do {
            try await executor.execute(
                query: query,
                range: range,
                streamID: fixture.streamID,
                accountID: fixture.accountID,
                accessibleRepositoryNames: [],
                preparePage: { _, _, _ in
                    PreparedSearchShardPageWrite(
                        write: { database in
                            try RawAPISnapshotRepository.save(snapshot, in: database)
                            try RoleSearchPageReplayRepository.save(
                                replay,
                                expectedAccountID: fixture.accountID,
                                in: database
                            )
                            throw TestPageWriteError.persistenceFailed
                        },
                        didCommit: {
                            await recorder.recordCommit()
                        }
                    )
                }
            )
            XCTFail("Expected the prepared page write to fail.")
        } catch TestPageWriteError.persistenceFailed {
            // Expected.
        }

        let snapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertTrue(snapshots.isEmpty)
        let replayEntry = try await RoleSearchPageReplayRepository(vault: fixture.vault).entry(
            requestKey: replay.requestKey,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertNil(replayEntry)
        XCTAssertEqual(shards.count, 1)
        XCTAssertEqual(shards[0].pageCursor, nil)
        XCTAssertEqual(shards[0].state, .failed)
        let didCommit = await recorder.didCommit()
        XCTAssertFalse(didCommit)
    }

    func testSuccessfulPreparedPageWritePersistsSnapshotBeforeCommitPublication() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let recorder = CommitRecorder()
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: "Atomic discovery page",
            state: .open,
            url: URL(string: "https://github.com/github/triage/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: fixture.date,
            updatedAt: fixture.date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: fixture.date.ISO8601Format(),
            observedAt: fixture.date,
            accessibility: .accessible
        )
        let executor = SearchShardExecutor(
            client: SearchClient { _, _ in
                GitHubResponse(
                    value: GitHubIssueSearchPage(
                        totalCount: 1,
                        incompleteResults: false,
                        items: []
                    ),
                    payload: Data(),
                    etag: nil,
                    lastModified: nil,
                    ssoHeader: nil
                )
            },
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let identity = try GitHubIssueSearchRequestIdentity(
            query: try query.bounded(to: range),
            page: 1,
            scope: fixture.scope,
            streamID: fixture.streamID
        )
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: identity.endpoint,
            eTag: nil,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            observedAt: fixture.date,
            payload: Data("response".utf8),
            requestIdentity: fixture.requestIdentity(for: identity)
        )

        try await executor.execute(
            query: query,
            range: range,
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            preparePage: { _, _, _ in
                PreparedSearchShardPageWrite(
                    write: { database in
                        try RawAPISnapshotRepository.save(snapshot, in: database)
                        try GitHubNodeRepository.save(node, in: database)
                        _ = try WorkItemRepository.ensureWorkItem(for: node, in: database)
                    },
                    didCommit: {
                        await recorder.recordCommit()
                    }
                )
            }
        )

        let snapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        let workItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(snapshots.map(\.id), [snapshot.id])
        XCTAssertEqual(workItems.map(\.primaryNodeID), [node.nodeID])
        XCTAssertEqual(shards.count, 1)
        XCTAssertEqual(shards[0].pageCursor, "1")
        XCTAssertEqual(shards[0].state, .completed)
        let didCommit = await recorder.didCommit()
        XCTAssertTrue(didCommit)
    }

    func testUndecodableSearchPagePersistsRawFailureAndFailedShardAtomically() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let privatePayload = Data(#"{"token":"ghp_privateMalformedSearch""#.utf8)
        let undecodable = GitHubUndecodableResponse(
            payload: privatePayload,
            linkHeader: nil,
            etag: "malformed-search-etag",
            lastModified: nil,
            ssoHeader: nil
        )
        let executor = SearchShardExecutor(
            client: SearchClient(undecodableResponse: undecodable),
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 120)
        )
        let identity = try GitHubIssueSearchRequestIdentity(
            query: try query.bounded(to: range),
            page: 1,
            scope: fixture.scope,
            streamID: fixture.streamID
        )
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: identity.endpoint,
            eTag: undecodable.etag,
            lastModified: undecodable.lastModified,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            observedAt: fixture.date,
            payload: privatePayload,
            requestIdentity: fixture.requestIdentity(for: identity)
        )
        let failure = NormalizationFailure(
            id: UUID(),
            accountID: fixture.accountID,
            rawSnapshotID: snapshot.id,
            githubNodeID: nil,
            endpoint: snapshot.endpoint,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            occurredAt: fixture.date,
            redactedDiagnostic: "GitHub search returned an undecodable response."
        )

        do {
            try await executor.execute(
                query: query,
                range: range,
                streamID: fixture.streamID,
                accountID: fixture.accountID,
                accessibleRepositoryNames: [],
                prepareUndecodablePage: { response, _, page in
                    XCTAssertEqual(response.payload, privatePayload)
                    XCTAssertEqual(page, 1)
                    return PreparedSearchShardPageWrite(
                        write: { database in
                            try RawAPISnapshotRepository.save(snapshot, in: database)
                            try NormalizationFailureRepository.record(failure, in: database)
                        },
                        didCommit: {}
                    )
                },
                preparePage: { _, _, _ in .empty }
            )
            XCTFail("Expected the undecodable search page to fail the shard.")
        } catch let error as GitHubIssueSearchUndecodableResponseError {
            XCTAssertNil(error.ssoHeader)
        }

        let snapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        let failures = try await NormalizationFailureRepository(vault: fixture.vault).failures(
            for: fixture.accountID
        )
        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(snapshots.map(\.payload), [privatePayload])
        XCTAssertEqual(failures.map(\.rawSnapshotID), [snapshot.id])
        XCTAssertFalse(failures[0].redactedDiagnostic.contains("ghp_privateMalformedSearch"))
        XCTAssertEqual(shards.map(\.state), [.failed])
        XCTAssertNil(shards[0].pageCursor)
    }
}

private enum TestPageWriteError: Error {
    case persistenceFailed
    case unexpectedRequest
}

private actor CommitRecorder {
    private var committed = false

    func recordCommit() {
        committed = true
    }

    func didCommit() -> Bool {
        committed
    }
}

private func httpValidators(
    eTag: String?,
    lastModified: String? = nil
) -> GitHubHTTPValidators? {
    guard eTag != nil || lastModified != nil else {
        return nil
    }
    return try! GitHubHTTPValidators(eTag: eTag, lastModified: lastModified)
}

private struct ConditionalSearchRequest: Equatable, Sendable {
    let page: Int
    let validators: GitHubHTTPValidators?
}

private actor ConditionalSearchClient: GitHubIssueSearchExecuting {
    typealias ResultFactory = @Sendable (
        GitHubIssueSearchQuery,
        Int,
        GitHubHTTPValidators?
    ) throws -> GitHubIssueSearchResult

    private let resultFactory: ResultFactory
    private var recordedRequests = [ConditionalSearchRequest]()

    init(resultFactory: @escaping ResultFactory) {
        self.resultFactory = resultFactory
    }

    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page: Int,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubIssueSearchResult {
        recordedRequests.append(
            ConditionalSearchRequest(page: page, validators: validators)
        )
        return try resultFactory(query, page, validators)
    }

    func requests() -> [ConditionalSearchRequest] {
        recordedRequests
    }
}

private actor ReplayPageRecorder {
    struct Page: Equatable, Sendable {
        let page: Int
        let source: GitHubResponseSource
    }

    private var recordedPages = [Page]()

    func record(page: Int, source: GitHubResponseSource) {
        recordedPages.append(Page(page: page, source: source))
    }

    func pages() -> [Page] {
        recordedPages
    }
}

private actor SearchClient: GitHubIssueSearchExecuting {
    typealias ResponseFactory = @Sendable (
        GitHubIssueSearchQuery,
        Int
    ) -> GitHubResponse<GitHubIssueSearchPage>

    private let responseFactory: ResponseFactory?
    private let undecodableResponse: GitHubUndecodableResponse?

    init(responseFactory: @escaping ResponseFactory) {
        self.responseFactory = responseFactory
        undecodableResponse = nil
    }

    init(undecodableResponse: GitHubUndecodableResponse) {
        responseFactory = nil
        self.undecodableResponse = undecodableResponse
    }

    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page: Int,
        validators _: GitHubHTTPValidators?
    ) async throws -> GitHubIssueSearchResult {
        if let undecodableResponse {
            return .undecodable(undecodableResponse)
        }
        return .response(try XCTUnwrap(responseFactory)(query, page))
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let streamID = SyncStreamID(rawValue: "issues-discovery")!
    let credentialRevision = CredentialRevision(rawValue: "credential-1")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    let vault: AccountVault

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
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
            capabilityRevision: capabilityRevision,
            capabilities: [],
            checkedAt: date
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: credentialRevision)
        try await accounts.save(organization, access: access, selectedAt: date)
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .roleDiscovery,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: date
        )
    }

    func seedReplay(
        query: GitHubIssueSearchQuery,
        page: Int,
        payload: Data,
        eTag: String? = nil,
        lastModified: String? = nil
    ) async throws -> RawAPISnapshot {
        let identity = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: page,
            scope: scope,
            streamID: streamID
        )
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: identity.endpoint,
            eTag: eTag,
            lastModified: lastModified,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            observedAt: date,
            payload: payload,
            requestIdentity: requestIdentity(for: identity)
        )
        try await RawAPISnapshotRepository(vault: vault).save(snapshot)
        try await RoleSearchPageReplayRepository(vault: vault).save(
            replay(identity: identity, snapshot: snapshot)
        )
        return snapshot
    }

    func replay(
        identity: GitHubIssueSearchRequestIdentity,
        snapshot: RawAPISnapshot
    ) -> RoleSearchPageReplay {
        RoleSearchPageReplay(
            requestKey: identity.requestKey,
            accountID: accountID,
            organizationID: organizationID,
            streamID: streamID,
            queryValue: identity.queryValue,
            page: identity.page,
            endpoint: identity.endpoint,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            rawSnapshotID: snapshot.id,
            eTag: snapshot.eTag,
            lastModified: snapshot.lastModified,
            parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
            lastValidatedAt: date
        )
    }

    func requestIdentity(
        for identity: GitHubIssueSearchRequestIdentity
    ) -> ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: scope,
            feature: .roleDiscovery,
            streamID: streamID,
            requestKey: identity.requestKey
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
