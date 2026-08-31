import XCTest
@testable import Triage

final class GitHubNotificationSynchronizationServiceTests: XCTestCase {
    func testValidated304PublishesUnchangedWithoutPersistingOrFailure() async throws {
        let scope = fixtureScope
        let identity = notificationIdentity(scope: scope)
        let store = RecordingNotificationStore(
            validator: .init(identity: identity, eTag: "\"v1\"", lastModified: nil, observedAt: fixtureDate),
            hasReceipt: true
        )
        let service = try makeService(responses: [(Data(), [:], 304)], store: store)

        let result = try await service.refresh(
            scope: scope,
            organizationLogin: "acme",
            streamID: streamID,
            previousHighWater: nil,
            observedAt: fixtureDate
        )

        XCTAssertEqual(result.status, .unchanged)
        XCTAssertEqual(result.coverage.status, .complete)
        let persistCount = await store.persistCount()
        let failureCount = await store.failureCount()
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(failureCount, 0)
    }

    func testUnvalidated304MakesOneUnconditionalRecoveryBeforePersisting() async throws {
        let scope = fixtureScope
        let identity = notificationIdentity(scope: scope)
        let store = RecordingNotificationStore(
            validator: .init(identity: identity, eTag: "\"v1\"", lastModified: nil, observedAt: fixtureDate),
            hasReceipt: false
        )
        let service = try makeService(responses: [
            (Data(), [:], 304),
            (Data("[\(notification())]".utf8), ["ETag": "\"v2\""], 200)
        ], store: store)

        let result = try await service.refresh(
            scope: scope,
            organizationLogin: "acme",
            streamID: streamID,
            previousHighWater: nil,
            observedAt: fixtureDate
        )

        XCTAssertEqual(result.status, .refreshed)
        XCTAssertTrue(result.usedUnconditionalRecovery)
        let persistCount = await store.persistCount()
        let failureCount = await store.failureCount()
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(failureCount, 0)
    }

    func testSecond304AfterUnvalidatedReceiptRecordsFailedIntegrityCoverage() async throws {
        let scope = fixtureScope
        let identity = notificationIdentity(scope: scope)
        let store = RecordingNotificationStore(
            validator: .init(identity: identity, eTag: "\"v1\"", lastModified: nil, observedAt: fixtureDate),
            hasReceipt: false
        )
        let service = try makeService(responses: [(Data(), [:], 304), (Data(), [:], 304)], store: store)

        let result = try await service.refresh(
            scope: scope,
            organizationLogin: "acme",
            streamID: streamID,
            previousHighWater: nil,
            observedAt: fixtureDate
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.coverage.status, .failed)
        let persistCount = await store.persistCount()
        let failureClassifications = await store.failureClassifications()
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(failureClassifications, [.integrity])
    }

    private func makeService(
        responses: [(Data, [String: String], Int)],
        store: RecordingNotificationStore
    ) throws -> GitHubNotificationSynchronizationService {
        let client = GitHubNotificationClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: NotificationSequenceSession(responses: responses)),
            credential: SecretValue("token")
        ))
        return .init(client: client, repository: store)
    }

    private func notificationIdentity(scope: SynchronizationScope) -> ConditionalRequestIdentity {
        .init(
            scope: scope,
            feature: .notifications,
            streamID: streamID,
            requestKey: GitHubNotificationClient.firstPageRequestKey
        )
    }

    private func notification() -> String {
        """
        {"id":"n-1","unread":true,"reason":"comment","updated_at":"2026-08-30T12:00:00Z",
        "last_read_at":null,"repository":{"id":1,"node_id":"R_1","name":"widget","full_name":"acme/widget","owner":{"login":"acme"}},
        "subject":{"title":"Comment","url":"https://api.github.com/repos/acme/widget/issues/1","latest_comment_url":null,"type":"Issue"}}
        """
    }

    private var fixtureScope: SynchronizationScope {
        .init(
            accountID: AccountID(rawValue: "account-notification")!,
            organizationID: OrganizationID(rawValue: "organization-notification")!,
            credentialRevision: CredentialRevision(rawValue: "credential-revision")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-revision")!
        )
    }

    private var streamID: SyncStreamID { SyncStreamID(rawValue: "notifications-stream")! }
    private var fixtureDate: Date { Date(timeIntervalSince1970: 1_788_000_000) }
}

private actor RecordingNotificationStore: GitHubNotificationSourcePersisting {
    private let cachedValidator: ConditionalRequestValidator?
    private let receipt: Bool
    private var persisted = 0
    private var failures = [GitHubNotificationFailureClassification]()

    init(validator: ConditionalRequestValidator?, hasReceipt: Bool) {
        cachedValidator = validator
        receipt = hasReceipt
    }

    func validator(for identity: ConditionalRequestIdentity) -> ConditionalRequestValidator? {
        cachedValidator
    }

    func hasValidatedUnchangedReceipt(
        for validator: ConditionalRequestValidator,
        observedAt: Date
    ) -> Bool { receipt }

    func persist(
        _ inventory: GitHubNotificationInventory,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        organizationLogin: String,
        coverage: CoverageRecord,
        observedAt: Date
    ) { persisted += 1 }

    func recordFailure(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        organizationLogin: String,
        pages: [GitHubNotificationPage],
        classification: GitHubNotificationFailureClassification,
        coverage: CoverageRecord,
        observedAt: Date
    ) { failures.append(classification) }

    func persistCount() -> Int { persisted }
    func failureCount() -> Int { failures.count }
    func failureClassifications() -> [GitHubNotificationFailureClassification] { failures }
}

private actor NotificationSequenceSession: HTTPSession {
    private var responses: [(Data, [String: String], Int)]

    init(responses: [(Data, [String: String], Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        let response = responses.removeFirst()
        return (
            response.0,
            HTTPURLResponse(url: url, statusCode: response.2, httpVersion: nil, headerFields: response.1)!
        )
    }
}
