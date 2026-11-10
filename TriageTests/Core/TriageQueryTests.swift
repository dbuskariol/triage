import Foundation
import Testing
@testable import Triage

struct TriageQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        _ id: String = "A", title: String = "Fix pagination", repository: String = "acme/widgets",
        author: String? = "alice", labels: [String] = [], assignees: [String] = [],
        reviewers: [String] = [], reviews: [ReviewFact] = [], relationships: Set<WorkRelationship> = [.assigned],
        checks: CheckStatus? = nil, additions: Int = 10, deletions: Int = 5, kind: WorkKind = .pullRequest,
        updatedDaysAgo: Double = 1, createdDaysAgo: Double = 3, comments: [ActivityFact] = [],
        decision: (TriageDisposition, Int, TriageEffort?)? = nil, unread: Bool = false
    ) -> TriageEntry {
        let item = PersonalWorkItem(
            id: GitHubNodeID(rawValue: id)!, kind: kind, repository: repository, number: 7, title: title,
            url: URL(string: "https://github.com/\(repository)/pull/7")!, state: .open, author: author,
            createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400), updatedAt: now.addingTimeInterval(-updatedDaysAgo * 86_400),
            relationships: relationships, labels: labels, assignees: assignees,
            body: "Requires a deployment approval before merge.",
            pullRequest: kind == .issue ? nil : PullRequestFacts(
                isDraft: false, reviewDecision: nil, requestedReviewers: reviewers, latestReviews: reviews,
                checks: checks, mergeable: "MERGEABLE", unresolvedReviewThreads: 0, additions: additions, deletions: deletions
            ),
            recentActivity: comments
        )
        var entry = TriageEntry(item: item, decision: nil, analysis: .pending, local: .active)
        if let (disposition, priority, effort) = decision {
            entry.decision = TriageDecision(
                itemID: item.id, disposition: disposition, priority: priority, confidence: 0.9, summary: "Blocked on CI",
                reason: "r", nextAction: nil, fingerprint: item.fingerprint, modelID: "m", decidedAt: now, effort: effort
            )
            entry.analysis = .current
        }
        entry.isUnread = unread
        return entry
    }

    private func query(_ text: String) throws(TriageQueryError) -> TriageQuery { try TriageQuery(parsing: text) }

    private func matches(_ text: String, _ entry: TriageEntry, viewer: String = "me") throws -> Bool {
        try query(text).matches(entry, viewer: viewer, now: now)
    }

    // MARK: Parsing and printing

    @Test(arguments: [
        ("is:review status:failing -author:@me", "is:review status:failing -author:@me"),
        ("IS:Review   STATUS:FAILING", "is:review status:failing"),
        ("repo:acme/* (label:security OR signal:security)", "repo:acme/* (label:security OR signal:security)"),
        ("a OR b OR (c d)", "a OR b OR (c d)"),
        ("((a))", "a"),
        ("--label:x", "label:x"),
        ("-(a OR b) c", "-(a OR b) c"),
        ("title:\"release train\" body:approval", "title:\"release train\" body:approval"),
        ("\"caching layer\"", "\"caching layer\""),
        ("\"OR\"", "\"OR\""),
        ("check:\"unit tests\":failing", "check:\"unit tests\":failing"),
        ("check:build", "check:build"),
        ("updated:>14d size:<=500 priority:>70", "updated:>14d size:<=500 priority:>70"),
        ("is:action", "in:action"),
        ("status:changes-requested", "status:changes"),
        ("topic:\"Compliance approvals\"", "topic:\"Compliance approvals\""),
        ("http://example.com", "\"http://example.com\""),
    ])
    func printsCanonically(input: String, canonical: String) throws {
        let parsed = try query(input)
        #expect(parsed.description == canonical)
        #expect(try query(parsed.description) == parsed)
    }

    @Test func structureRespectsPrecedence() throws {
        let parsed = try query("a b OR c")
        #expect(parsed.root == .any([.all([.text("a"), .text("b")]), .text("c")]))
        #expect(try query("-a").root == .not(.text("a")))
    }

    @Test(arguments: [
        ("", "Enter a filter"),
        ("stauts:failing", "Did you mean “status:”?"),
        ("status:broken", "Use one of: failing"),
        ("repo:", "Add a value after “repo:”"),
        ("(a b", "Close the parenthesis"),
        ("a b)", "Remove the extra “)”"),
        ("a OR", "Add a filter after OR"),
        ("OR a", "Add a filter before OR"),
        ("()", "inside the parentheses"),
        ("updated:14d", "Use a comparison"),
        ("size:big", "needs a number"),
        ("priority:urgent", "high, medium, low"),
    ])
    func reportsSpecificErrors(input: String, message: String) {
        #expect(throws: TriageQueryError.self) { try query(input) }
        do { _ = try query(input) } catch { #expect(error.message.contains(message), "\(error.message)") }
    }

    @Test func errorsPointAtTheProblem() {
        do { _ = try query("is:pr stauts:failing") } catch { #expect(error.position == 6) }
    }

    @Test func codableUsesCanonicalText() throws {
        let original = try query("REPO:acme/widgets -label:wontfix")
        let data = try JSONEncoder().encode(original)
        #expect(String(decoding: data, as: UTF8.self) == "\"repo:acme\\/widgets -label:wontfix\"")
        #expect(try JSONDecoder().decode(TriageQuery.self, from: data) == original)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TriageQuery.self, from: Data("\"stauts:x\"".utf8)) }
    }

    // MARK: Phases

    @Test(arguments: [
        ("repo:acme/widgets status:failing commenter:bot", TriageQuery.Phase.facts),
        ("is:unread", .local),
        ("repo:x OR is:read", .local),
        ("signal:ci-failing", .ai),
        ("-priority:high repo:x", .ai),
        ("in:action", .ai),
        ("effort:quick", .ai),
        ("topic:x", .ai),
        ("caching", .facts),
    ])
    func classifiesPhase(input: String, phase: TriageQuery.Phase) throws {
        #expect(try query(input).phase == phase)
    }

    // MARK: Matching

    @Test func matchesRepositoriesExactlyOrByPattern() throws {
        let work = entry(repository: "acme/widgets")
        #expect(try matches("repo:acme/widgets", work))
        #expect(try matches("repo:ACME/Widgets", work))
        #expect(try matches("repo:widgets", work))
        #expect(try matches("repo:acme/*", work))
        #expect(try matches("repo:*/wid*", work))
        #expect(try !matches("repo:acme/wid", work))
        #expect(try !matches("repo:other/*", work))
    }

    @Test func matchesPeopleAndMe() throws {
        let work = entry(
            author: "me", assignees: ["bob"], reviewers: ["carol", "acme/core"],
            reviews: [ReviewFact(author: "dave", state: "APPROVED", submittedAt: nil)],
            comments: [ActivityFact(author: "github-actions[bot]", createdAt: now, excerpt: "Deployment approval required for env prod")]
        )
        #expect(try matches("author:@me", work))
        #expect(try !matches("-author:@me", work))
        #expect(try matches("assignee:bob", work))
        #expect(try matches("reviewer:carol", work))
        #expect(try matches("reviewer:dave", work))
        #expect(try !matches("reviewer:acme/core", work))
        #expect(try matches("team:core", work))
        #expect(try matches("team:acme/core", work))
        #expect(try matches("commenter:github-actions[bot]", work))
        #expect(try matches("commenter:*[bot]", work))
        #expect(try matches("comment:\"approval required\"", work))
        #expect(try !matches("comment:rollback", work))
    }

    @Test func matchesRelationshipsAndKinds() throws {
        let direct = entry(reviewers: ["me"], relationships: [.reviewRequested])
        let team = entry(reviewers: ["acme/core"], relationships: [.reviewRequested])
        let issue = entry(kind: .issue)
        #expect(try matches("is:review is:direct", direct))
        #expect(try matches("is:team", team))
        #expect(try !matches("is:direct", team))
        #expect(try matches("is:issue", issue))
        #expect(try !matches("is:pr", issue))
        #expect(try matches("is:assigned", issue))
    }

    @Test func matchesStatusAndSize() throws {
        let failing = entry(checks: .failure, additions: 400, deletions: 200)
        #expect(try matches("status:failing", failing))
        #expect(try matches("status:required-failing", failing))
        #expect(try !matches("status:passing", failing))
        #expect(try matches("status:passing", entry(checks: .success)))
        #expect(try matches("status:pending", entry(checks: .expected)))
        #expect(try matches("size:>500", failing))
        #expect(try matches("size:600", failing))
        #expect(try !matches("size:<100", failing))
        #expect(try !matches("size:>0", entry(kind: .issue)))
        #expect(try !matches("check:build", failing))
    }

    @Test func matchesAges() throws {
        let stale = entry(updatedDaysAgo: 20, createdDaysAgo: 40)
        #expect(try matches("updated:>14d", stale))
        #expect(try matches("updated:>2w", stale))
        #expect(try !matches("updated:<2d", stale))
        #expect(try matches("created:>=40d", stale))
        #expect(try matches("updated:<2d", entry(updatedDaysAgo: 1)))
    }

    @Test func matchesCopilotDecisions() throws {
        let decided = entry(decision: (.act, 82, .quick))
        let undecided = entry()
        #expect(try matches("priority:high", decided))
        #expect(try matches("priority:>80", decided))
        #expect(try !matches("priority:<80", decided))
        #expect(try matches("effort:quick", decided))
        #expect(try matches("in:action in:inbox", decided))
        #expect(try !matches("in:waiting", decided))
        #expect(try !matches("priority:high", undecided))
        #expect(try !matches("in:inbox", undecided))
        #expect(try matches("-in:inbox", undecided))
        #expect(try matches("\"blocked on ci\"", decided))
    }

    @Test func matchesSignalsAndTopicsFromDecisions() throws {
        var work = entry(decision: (.act, 50, nil))
        work.decision?.signals = ["approval-gate"]
        work.decision?.topics = ["Compliance approvals"]
        #expect(try matches("signal:approval-gate", work))
        #expect(try matches("topic:\"compliance approvals\"", work))
        #expect(try !matches("signal:ci-failing", work))
    }

    @Test func matchesReadState() throws {
        #expect(try matches("is:unread", entry(unread: true)))
        #expect(try matches("is:read", entry(unread: false)))
    }

    @Test func freeTextSpansFactsAndComments() throws {
        let work = entry(labels: ["security"], comments: [ActivityFact(author: "bob", createdAt: now, excerpt: "Needs FedRAMP sign-off")])
        #expect(try matches("pagination", work))
        #expect(try matches("deployment approval", work))
        #expect(try matches("fedramp", work))
        #expect(try matches("security", work))
        #expect(try !matches("rollback", work))
    }

    @Test func booleanCombinators() throws {
        let work = entry(labels: ["security"], checks: .failure)
        #expect(try matches("label:docs OR status:failing", work))
        #expect(try !matches("label:docs OR -status:failing", work))
        #expect(try matches("-(label:docs OR author:bob) label:security", work))
    }

    @Test func itemOnlyMatchingIgnoresDecisions() throws {
        let work = entry(decision: (.act, 90, nil))
        #expect(try query("repo:widgets").matches(work.item, viewer: "me", now: now))
        #expect(try !query("in:action").matches(work.item, viewer: "me", now: now))
    }
}
