import Foundation
import GRDB
import XCTest
@testable import Triage

final class TimelineEventRepositoryTests: XCTestCase {
    func testMalformedLaterPagePreservesExistingTimelineEvents() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let secondPage = URL(
            string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2"
        )!
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["Link": "<\(secondPage)>; rel=\"next\""]
                ),
                "/repos/github/triage/issues/1/timeline?page=2": (
                    Data(#"[{"id":"new-final","event":"mentioned"}]"#.utf8),
                    [:]
                )
            ])),
            credential: SecretValue("token")
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: restClient),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.refreshedTimelineNodeIDs, [])
        XCTAssertEqual(result.incompleteTimelineNodeIDs, [fixture.nodeID])
        let persistedEventIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_event_id FROM timeline_events WHERE subject_node_id = ?",
                arguments: [fixture.nodeID.rawValue]
            )
        }
        XCTAssertEqual(persistedEventIDs, ["old-event"])

        let recoveredService = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?page=2": (
                        Data(#"[{"id":"new-final","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                        [:]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
        let recovered = try await recoveredService.refresh(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(recovered.refreshedTimelineNodeIDs, [fixture.nodeID])
        let recoveredEventIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_event_id FROM timeline_events ORDER BY github_event_id"
            )
        }
        XCTAssertEqual(recoveredEventIDs, ["new-event", "new-final"])
    }

    func testCrossRepositoryLinkPreservesTimelineAndLeavesCoverageIncomplete() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    [
                        "Link": "<https://api.github.com/repos/github/other/issues/1/timeline?page=2>; rel=\"next\""
                    ]
                )
            ])),
            credential: SecretValue("token")
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: restClient),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.incompleteTimelineNodeIDs, [fixture.nodeID])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(state.0, "old-event")
        XCTAssertEqual(state.1, CoverageStatus.partial.rawValue)
    }

    func testMalformedTerminalLinkPreservesTimelineAndDoesNotComplete() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                        ["Link": "not a valid Link header"]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.refreshedTimelineNodeIDs, [])
        XCTAssertEqual(result.incompleteTimelineNodeIDs, [fixture.nodeID])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(state.0, "old-event")
        XCTAssertEqual(state.1, CoverageStatus.partial.rawValue)
    }

    func testCancellationAfterSinglePageDoesNotCompleteTimeline() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: CancellingTimelineSession()),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
        let refreshTask = Task {
            try await service.refresh(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                currentUserID: ActorID(rawValue: "U_current")!,
                candidates: [fixture.candidate],
                observedAt: fixture.observedAt
            )
        }

        do {
            _ = try await refreshTask.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
        }

        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_streams")
            )
        }
        XCTAssertEqual(state.0, "old-event")
        XCTAssertEqual(state.1, 0)
    }
}

private final class TimelineFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let repositoryID = RepositoryID(rawValue: "repo-1")!
    let nodeID = GitHubNodeID(rawValue: "I_1")!
    let observedAt = Date(timeIntervalSince1970: 1_767_225_600)
    let vault: AccountVault
    let candidate: TimelineCandidate

    init() async throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".timeline-event-test-\(UUID().uuidString)", isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision,
                        created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, '1', 'U_account', 'octocat', NULL, NULL, 'oauth', 'credential', 'active',
                              'credential-1', ?, ?, NULL)
                    """,
                arguments: [accountID.rawValue, milliseconds(observedAt), milliseconds(observedAt)]
            )
            try database.execute(
                sql: """
                    INSERT INTO organizations (
                        id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                    ) VALUES (?, '2', 'O_1', 'github', NULL, NULL, ?)
                    """,
                arguments: [organizationID.rawValue, milliseconds(observedAt)]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_organizations (
                        account_id, organization_id, access_state, capability_revision, checked_at_ms, selected_at_ms
                    ) VALUES (?, ?, 'available', 'capability-1', ?, ?)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue,
                    milliseconds(observedAt), milliseconds(observedAt)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, '3', 'R_1', 'github', 'triage', 1, 0, 0, ?, ?, NULL)
                    """,
                arguments: [
                    repositoryID.rawValue, organizationID.rawValue,
                    "https://github.com/github/triage", milliseconds(observedAt)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO github_nodes (
                        github_node_id, account_id, organization_id, repository_id, kind, numeric_id, number,
                        title, state, html_url, body_markdown, author_id, created_at_ms, updated_at_ms,
                        closed_at_ms, merged_at_ms, source_revision, last_observed_at_ms, accessibility_state
                    ) VALUES (?, ?, ?, ?, 'issue', '1', 1, 'Timeline fixture', 'open', ?, NULL, NULL, ?, ?,
                              NULL, NULL, 'revision-1', ?, 'accessible')
                    """,
                arguments: [
                    nodeID.rawValue, accountID.rawValue, organizationID.rawValue, repositoryID.rawValue,
                    "https://github.com/github/triage/issues/1",
                    milliseconds(observedAt), milliseconds(observedAt), milliseconds(observedAt)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO issues (
                        github_node_id, locked, comments_count, assignee_node_ids_json, label_node_ids_json,
                        milestone_node_id, updated_at_ms
                    ) VALUES (?, 0, 0, '[]', '[]', NULL, ?)
                    """,
                arguments: [nodeID.rawValue, milliseconds(observedAt)]
            )
        }
        candidate = TimelineCandidate(
            nodeID: nodeID,
            repositoryID: repositoryID,
            repository: try GitHubRepositoryPath(owner: "github", repository: "triage"),
            number: 1,
            sourceRevision: "revision-1"
        )
    }

    func event(id: String, payload: String) -> NormalizedGitHubTimelineEvent {
        NormalizedGitHubTimelineEvent(
            id: GitHubEventID(rawValue: id)!,
            kind: .assigned,
            actor: nil,
            occurredAt: observedAt,
            payload: Data(payload.utf8)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private actor TimelineRefreshSession: HTTPSession {
    private let responses: [String: (Data, [String: String])]

    init(responses: [String: (Data, [String: String])]) {
        self.responses = responses
    }

    private actor CancellingTimelineSession: HTTPSession {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            withUnsafeCurrentTask { $0?.cancel() }
            return (
                Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[pathAndQuery] else { throw URLError(.resourceUnavailable) }
        return (
            response.0,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: response.1
            )!
        )
    }
}
