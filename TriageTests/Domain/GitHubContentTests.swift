import XCTest
@testable import Triage

final class GitHubContentTests: XCTestCase {
    func testRepositoryFullNameAndContentSummariesRoundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let repository = RepositorySummary(
            id: RepositoryID(rawValue: "repository-1")!,
            nodeID: GitHubNodeID(rawValue: "R_kgDOExample")!,
            ownerLogin: "github",
            name: "triage",
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            url: URL(string: "https://github.com/github/triage")!
        )
        let author = ActorSummary(
            id: ActorID(rawValue: "actor-1")!,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            displayName: "The Octocat",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1")
        )
        let content = GitHubContentSummary(
            id: GitHubNodeID(rawValue: "I_kwDOExample")!,
            kind: .issue,
            repository: repository,
            number: 42,
            title: "Harden encrypted cache",
            state: .open,
            author: author,
            url: URL(string: "https://github.com/github/triage/issues/42")!,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil
        )
        let review = PullRequestReviewSummary(
            id: GitHubNodeID(rawValue: "PRR_kwDOExample")!,
            pullRequestNodeID: GitHubNodeID(rawValue: "PR_kwDOExample")!,
            author: author,
            state: .changesRequested,
            submittedAt: date,
            url: URL(string: "https://github.com/github/triage/pull/42#pullrequestreview-1"),
            body: "Please add tests."
        )
        let projectItem = ProjectItemSummary(
            id: GitHubNodeID(rawValue: "PVTI_kwDOExample")!,
            projectNodeID: GitHubNodeID(rawValue: "PVT_kwDOExample")!,
            contentNodeID: content.id,
            contentKind: .issue,
            updatedAt: date,
            fieldValues: [
                ProjectFieldValue(
                    fieldName: "Status",
                    displayValue: "In progress",
                    dateValue: nil,
                    actorNodeID: author.nodeID
                )
            ]
        )

        XCTAssertEqual(repository.fullName, "github/triage")
        try assertRoundTrip(repository)
        try assertRoundTrip(author)
        try assertRoundTrip(content)
        try assertRoundTrip(review)
        try assertRoundTrip(projectItem)
    }

    func testUnknownRawEnumValuesAreRejected() {
        assertUnknownCaseRejected(GitHubContentKind.self)
        assertUnknownCaseRejected(GitHubItemState.self)
        assertUnknownCaseRejected(TimelineEventKind.self)
        assertUnknownCaseRejected(ReviewState.self)
    }

    private func assertRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: encoded), value, file: file, line: line)
    }

    private func assertUnknownCaseRejected<T: Decodable>(
        _ type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(T.self, from: Data("\"future-case\"".utf8)),
            file: file,
            line: line
        )
    }
}
