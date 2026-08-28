import XCTest
@testable import Triage

final class GitHubHydrationBatchMetricRepositoryTests: XCTestCase {
    func testRecordsAndReturnsMetricsInReverseChronologicalOrder() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = GitHubHydrationBatchMetricRepository(vault: fixture.vault)
        let older = fixture.metric(
            requestedNodeCount: 25,
            responseBytes: 1_024,
            queryCost: 10,
            observedAt: fixture.date
        )
        let newer = fixture.metric(
            requestedNodeCount: 30,
            responseBytes: 2_048,
            queryCost: 20,
            observedAt: fixture.date.addingTimeInterval(1)
        )

        try await repository.record(older)
        try await repository.record(newer)

        XCTAssertEqual(
            try await repository.recentMetrics(for: fixture.accountID),
            [newer, older]
        )
    }

    func testRejectsMetricsForAnotherVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = GitHubHydrationBatchMetricRepository(vault: fixture.vault)
        var metric = fixture.metric(
            requestedNodeCount: 25,
            responseBytes: 1,
            queryCost: 0,
            observedAt: fixture.date
        )
        metric = GitHubHydrationBatchMetric(
            accountID: AccountID.make(),
            requestedNodeCount: metric.requestedNodeCount,
            responseBytes: metric.responseBytes,
            queryCost: metric.queryCost,
            rateLimitRemaining: metric.rateLimitRemaining,
            rateLimitResetAt: metric.rateLimitResetAt,
            observedAt: metric.observedAt
        )

        do {
            try await repository.record(metric)
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? GitHubHydrationBatchMetricRepositoryError, .accountScopeMismatch)
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            try await AccountRepository(vault: vault).save(
                GitHubAccount(
                    id: accountID,
                    githubUserID: 1,
                    nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
                    login: "octocat",
                    authenticationKind: .oauth,
                    credentialID: CredentialID.make(),
                    credentialStatus: .active,
                    createdAt: date,
                    lastValidatedAt: date
                ),
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
        }

        func metric(
            requestedNodeCount: Int,
            responseBytes: Int,
            queryCost: Int,
            observedAt: Date
        ) -> GitHubHydrationBatchMetric {
            GitHubHydrationBatchMetric(
                accountID: accountID,
                requestedNodeCount: requestedNodeCount,
                responseBytes: responseBytes,
                queryCost: queryCost,
                rateLimitRemaining: 490,
                rateLimitResetAt: date.addingTimeInterval(3_600),
                observedAt: observedAt
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
