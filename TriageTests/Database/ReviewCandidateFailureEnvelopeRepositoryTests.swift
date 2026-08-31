import Foundation
import GRDB
import XCTest
@testable import Triage

final class ReviewCandidateFailureEnvelopeRepositoryTests: XCTestCase {
    func testPublishesAccumulatedPagesPerRequestIdentityAndAdvancesScheduleAtomically() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let publication = fixture.publication(
            pages: [
                fixture.page(requestKey: "reviews?page", ordinal: 2, endpoint: "acme/repo/pulls/7/reviews?page=2"),
                fixture.page(requestKey: "requested-reviewers", ordinal: 1, endpoint: "acme/repo/pulls/7/requested_reviewers"),
                fixture.page(requestKey: "reviews?page", ordinal: 1, endpoint: "acme/repo/pulls/7/reviews?page=1")
            ]
        )

        try await fixture.repository.publish(publication)

        let envelopes = try await fixture.repository.envelopes(
            scope: fixture.scope,
            feature: .reviews,
            candidateNodeID: fixture.candidate.nodeID
        )
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes[0].id, publication.id)
        XCTAssertEqual(envelopes[0].classification, .rateLimited)
        XCTAssertEqual(envelopes[0].rawSnapshotIDs.count, 3)
        XCTAssertEqual(envelopes[0].rawSnapshotIDs, publication.rawPages.sorted {
            ($0.requestIdentity.requestKey, $0.ordinal) < ($1.requestIdentity.requestKey, $1.ordinal)
        }.map(\.rawSnapshotID))
        let counts = try await fixture.counts()
        XCTAssertEqual(counts.envelopes, 1)
        XCTAssertEqual(counts.pages, 3)
        XCTAssertEqual(counts.rawSnapshots, 3)
        XCTAssertEqual(counts.scheduleShards, 2)
    }

    func testRejectsGapWithinOneRequestIdentityWithoutPublishingAnything() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let publication = fixture.publication(pages: [
            fixture.page(requestKey: "reviews?page", ordinal: 1, endpoint: "acme/repo/pulls/7/reviews?page=1"),
            fixture.page(requestKey: "reviews?page", ordinal: 3, endpoint: "acme/repo/pulls/7/reviews?page=3")
        ])

        do {
            try await fixture.repository.publish(publication)
            XCTFail("A missing accumulated page must fail closed.")
        } catch let error as ReviewCandidateFailureEnvelopeRepositoryError {
            XCTAssertEqual(error, .invalidRawPages)
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .zero)
    }

    func testStaleScopeDoesNotPublishTerminalEnvelopeOrAdvanceCursor() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        try await fixture.rotateCredential()

        do {
            try await fixture.repository.publish(fixture.publication(pages: []))
            XCTFail("Stale authority must not produce failure provenance.")
        } catch let error as ReviewCandidateFailureEnvelopeRepositoryError {
            XCTAssertEqual(error, .staleSynchronizationScope)
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .zero)
    }

    func testRejectsSensitiveHeaderMaterialFromDiagnosticBeforeSavingRawPages() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let source = fixture.publication(pages: [
            fixture.page(requestKey: "reviews?page", ordinal: 1, endpoint: "acme/repo/pulls/7/reviews?page=1")
        ])
        let publication = ReviewCandidateFailurePublication(
            id: source.id,
            scope: source.scope,
            feature: source.feature,
            streamID: source.streamID,
            candidate: source.candidate,
            requestIdentity: source.requestIdentity,
            parserVersion: source.parserVersion,
            attemptedAt: source.attemptedAt,
            terminalAt: source.terminalAt,
            classification: source.classification,
            redactedDiagnostic: "Authorization: Bearer secret",
            rawPages: source.rawPages
        )

        do {
            try await fixture.repository.publish(publication)
            XCTFail("Failure diagnostics must never retain credential-bearing headers.")
        } catch let error as ReviewCandidateFailureEnvelopeRepositoryError {
            XCTAssertEqual(error, .invalidRedactedDiagnostic)
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .zero)
    }

    func testRejectsPublicationWhoseDeclaredTerminalRequestDiffersFromLastRawPage() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let pages = [
            fixture.page(requestKey: "reviews?page", ordinal: 1, endpoint: "acme/repo/pulls/7/reviews?page=1")
        ]
        let source = fixture.publication(pages: pages)
        let invalid = ReviewCandidateFailurePublication(
            id: source.id, scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate,
            requestIdentity: .init(scope: source.scope, feature: .reviews, streamID: source.streamID, requestKey: "requested-reviewers"),
            parserVersion: source.parserVersion, attemptedAt: source.attemptedAt, terminalAt: source.terminalAt,
            classification: source.classification, redactedDiagnostic: source.redactedDiagnostic,
            rawPages: pages
        )

        do {
            try await fixture.repository.publish(invalid)
            XCTFail("A terminal envelope must bind its terminal request to the final raw response.")
        } catch let error as ReviewCandidateFailureEnvelopeRepositoryError {
            XCTAssertEqual(error, .invalidRawPages)
        }
    }

    func testAllowsExplicitZeroRawTransportFailureOnly() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let source = fixture.publication(pages: [])
        let transport = ReviewCandidateFailurePublication(
            id: source.id, scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate, requestIdentity: source.requestIdentity,
            parserVersion: source.parserVersion, attemptedAt: source.attemptedAt, terminalAt: source.terminalAt,
            classification: .transportFailure, redactedDiagnostic: source.redactedDiagnostic,
            rawProvenance: .zeroRawTransportFailure, rawPages: []
        )

        try await fixture.repository.publish(transport)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts.envelopes, 1)
        XCTAssertEqual(counts.rawSnapshots, 0)
    }

    func testRejectsZeroRawProvenanceForNonTransportClassification() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let source = fixture.publication(pages: [])
        let invalid = ReviewCandidateFailurePublication(
            id: source.id, scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate, requestIdentity: source.requestIdentity,
            parserVersion: source.parserVersion, attemptedAt: source.attemptedAt, terminalAt: source.terminalAt,
            classification: .rateLimited, redactedDiagnostic: source.redactedDiagnostic,
            rawProvenance: .zeroRawTransportFailure, rawPages: []
        )

        do {
            try await fixture.repository.publish(invalid)
            XCTFail("A zero-raw publication is reserved for transport failures.")
        } catch let error as ReviewCandidateFailureEnvelopeRepositoryError {
            XCTAssertEqual(error, .invalidRawPages)
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts, .zero)
    }

    func testAllowsOnlyExplicitBodylessAccessHTTPFailuresWithoutRawPages() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let source = fixture.publication(pages: [])
        let bodylessNotFound = ReviewCandidateFailurePublication(
            id: source.id, scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate, requestIdentity: source.requestIdentity,
            parserVersion: source.parserVersion, attemptedAt: source.attemptedAt, terminalAt: source.terminalAt,
            classification: .unavailableOrPermission, redactedDiagnostic: source.redactedDiagnostic,
            rawProvenance: .zeroRawBodylessHTTPAccessFailure(statusCode: 404), rawPages: []
        )
        try await fixture.repository.publish(bodylessNotFound)

        let invalid = ReviewCandidateFailurePublication(
            scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate, requestIdentity: source.requestIdentity,
            parserVersion: source.parserVersion, attemptedAt: source.attemptedAt, terminalAt: source.terminalAt,
            classification: .unavailableOrPermission, redactedDiagnostic: source.redactedDiagnostic,
            rawProvenance: .zeroRawBodylessHTTPAccessFailure(statusCode: 500), rawPages: []
        )
        do {
            try await fixture.repository.publish(invalid)
            XCTFail("Only GitHub access-denied HTTP status codes can omit raw terminal evidence.")
        } catch let error as ReviewCandidateFailureEnvelopeRepositoryError {
            XCTAssertEqual(error, .invalidRawPages)
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts.envelopes, 1)
        XCTAssertEqual(counts.rawSnapshots, 0)
    }

    func testAllowsOnlyExplicitBodylessSelectedOrganizationSSOFailureWithoutRawPages() async throws {
        let fixture = try await ReviewFailureEnvelopeFixture()
        defer { fixture.remove() }
        let source = fixture.publication(pages: [])
        let publication = ReviewCandidateFailurePublication(
            id: source.id, scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate, requestIdentity: source.requestIdentity,
            parserVersion: source.parserVersion, attemptedAt: source.attemptedAt, terminalAt: source.terminalAt,
            classification: .ssoRequired, redactedDiagnostic: source.redactedDiagnostic,
            rawProvenance: .zeroRawBodylessSelectedOrganizationSSOFailure, rawPages: []
        )
        try await fixture.repository.publish(publication)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts.envelopes, 1)
        XCTAssertEqual(counts.rawSnapshots, 0)
    }
}

private final class ReviewFailureEnvelopeFixture: @unchecked Sendable {
    struct Counts: Equatable {
        let envelopes: Int
        let pages: Int
        let rawSnapshots: Int
        let scheduleShards: Int

        static let zero = Counts(envelopes: 0, pages: 0, rawSnapshots: 0, scheduleShards: 0)
    }

    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "failure-envelope-org")!
    let repositoryID = RepositoryID(rawValue: "failure-envelope-repository")!
    let streamID = SyncStreamID(rawValue: "failure-envelope-reviews")!
    let date = Date(timeIntervalSinceReferenceDate: 5_000)
    let vault: AccountVault
    let repository: ReviewCandidateFailureEnvelopeRepository

    let candidate = PullRequestReviewCandidate(
        nodeID: GitHubNodeID(rawValue: "FAILURE_ENVELOPE_PR")!,
        repositoryID: RepositoryID(rawValue: "failure-envelope-repository")!,
        repository: try! GitHubRepositoryPath(owner: "acme", repository: "repo"),
        number: 7
    )

    var scope: SynchronizationScope {
        .init(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let key = try VaultKey.generate()
        vault = try await VaultRegistry(rootDirectory: directory).open(accountID: accountID, vaultKey: key)
        repository = ReviewCandidateFailureEnvelopeRepository(vault: vault)
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 17,
                nodeID: GitHubNodeID(rawValue: "FAILURE_ENVELOPE_USER")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await AccountRepository(vault: vault).save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 17,
                nodeID: GitHubNodeID(rawValue: "FAILURE_ENVELOPE_ORG")!,
                login: "acme"
            ),
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            ),
            selectedAt: date
        )
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: streamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: .reviews,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: nil,
                status: .partial,
                failureDetail: nil
            )
        )
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id,
                        owner_login, name, is_private, is_archived, has_discussions,
                        html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, NULL)
                    """,
                arguments: [
                    repositoryID.rawValue, organizationID.rawValue, "failure-envelope-github-repository",
                    "FAILURE_ENVELOPE_REPOSITORY", "acme", "repo",
                    "https://github.com/acme/repo", Self.milliseconds(date)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms)
                    VALUES (?, ?, 'available', ?)
                    """,
                arguments: [accountID.rawValue, repositoryID.rawValue, Self.milliseconds(date)]
            )
            try database.execute(
                sql: """
                    INSERT INTO github_nodes (
                        github_node_id, account_id, organization_id, repository_id, kind,
                        numeric_id, number, title, state, html_url, body_markdown, author_id,
                        created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                        source_revision, last_observed_at_ms, accessibility_state
                    ) VALUES (?, ?, ?, ?, 'pull_request', NULL, 7, 'PR', 'open', ?, NULL, NULL, ?, ?, NULL, NULL, 'rev', ?, 'accessible')
                    """,
                arguments: [
                    candidate.nodeID.rawValue, accountID.rawValue, organizationID.rawValue,
                    repositoryID.rawValue, "https://github.com/acme/repo/pull/7",
                    Self.milliseconds(date), Self.milliseconds(date), Self.milliseconds(date)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO pull_requests (
                        github_node_id, is_draft, mergeable_state, head_ref, base_ref,
                        review_decision, unresolved_thread_count, latest_commit_at_ms, updated_at_ms
                    ) VALUES (?, 0, NULL, NULL, NULL, NULL, 0, NULL, ?)
                    """,
                arguments: [candidate.nodeID.rawValue, Self.milliseconds(date)]
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func page(requestKey: String, ordinal: Int, endpoint: String) -> ReviewCandidateFailureRawPage {
        .init(
            ordinal: ordinal,
            rawSnapshotID: .make(),
            requestIdentity: .init(scope: scope, feature: .reviews, streamID: streamID, requestKey: requestKey),
            endpoint: endpoint,
            eTag: "etag-\(requestKey)-\(ordinal)",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            payload: Data("{\"page\":\(ordinal)}".utf8)
        )
    }

    func publication(pages: [ReviewCandidateFailureRawPage]) -> ReviewCandidateFailurePublication {
        .init(
            scope: scope,
            feature: .reviews,
            streamID: streamID,
            candidate: candidate,
            requestIdentity: pages.last?.requestIdentity ?? .init(
                scope: scope,
                feature: .reviews,
                streamID: streamID,
                requestKey: "review-candidate-attempt/\(candidate.nodeID.rawValue)"
            ),
            parserVersion: 1,
            attemptedAt: date,
            terminalAt: date.addingTimeInterval(1),
            classification: .rateLimited,
            redactedDiagnostic: "GitHub rate limit prevented review candidate traversal.",
            rawPages: pages
        )
    }

    func rotateCredential() async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?",
                arguments: [accountID.rawValue]
            )
        }
    }

    func counts() async throws -> Counts {
        try await vault.read { database in
            Counts(
                envelopes: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_envelopes") ?? -1,
                pages: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_pages") ?? -1,
                rawSnapshots: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots") ?? -1,
                scheduleShards: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_shards") ?? -1
            )
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
