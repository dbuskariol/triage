import Foundation
import Testing
@testable import Triage

struct WorkInsightsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        _ id: String, number: Int = 1, repository: String = "octo/widgets", body: String = "",
        comments: [ActivityFact] = [], createdDaysAgo: Double = 1, updatedDaysAgo: Double = 1,
        disposition: TriageDisposition = .review, priority: Int = 50, effort: TriageEffort? = nil,
        local: LocalStatus = .active
    ) -> TriageEntry {
        let item = PersonalWorkItem(
            id: GitHubNodeID(rawValue: id)!, kind: .issue, repository: repository, number: number, title: id,
            url: URL(string: "https://github.com/\(repository)/issues/\(number)")!, state: .open, author: "alice",
            createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400),
            updatedAt: now.addingTimeInterval(-updatedDaysAgo * 86_400),
            relationships: [.assigned], labels: [], assignees: [], body: body, pullRequest: nil,
            recentActivity: comments
        )
        var decision = TriageDecision(
            itemID: item.id, disposition: disposition, priority: priority, confidence: 0.8, summary: "s",
            reason: "r", nextAction: "Do it", fingerprint: item.fingerprint, modelID: "m", decidedAt: now
        )
        decision.effort = effort
        return TriageEntry(item: item, decision: decision, analysis: .current, local: local)
    }

    @Test func referencesFindShorthandQualifiedAndURLs() {
        let work = entry(
            "A", number: 5,
            body: "Fixes #12 and other/repo#7. See https://github.com/Octo/Gadgets/pull/99, not #5 or foo#3.",
            comments: [ActivityFact(author: "bob", createdAt: now, excerpt: "Also octo/widgets#13")]
        )
        #expect(WorkInsights.references(in: work.item) == ["octo/widgets#12", "other/repo#7", "octo/gadgets#99", "octo/widgets#13"])
    }

    @Test func relatedEntriesAreSymmetric() {
        let issue = entry("I", number: 12)
        let fix = entry("P", number: 30, body: "Closes #12")
        let unrelated = entry("U", number: 40)
        let related = WorkInsights.relatedEntries([issue, fix, unrelated])
        #expect(related[issue.id]?.map(\.id) == [fix.id])
        #expect(related[fix.id]?.map(\.id) == [issue.id])
        #expect(related[unrelated.id] == nil)
    }

    @Test func waitingOnYouIgnoresYourOwnActivity() {
        let work = entry("A", comments: [
            ActivityFact(author: "bob", createdAt: now.addingTimeInterval(-3 * 86_400), excerpt: "?"),
            ActivityFact(author: "me", createdAt: now.addingTimeInterval(-86_400), excerpt: "ok"),
        ], createdDaysAgo: 10)
        #expect(WorkInsights.days(since: WorkInsights.waitingOnYouSince(work.item, viewer: "me"), now: now) == 3)
    }

    @Test func overdueFollowUpsAreStaleWaitingWorkOldestFirst() {
        let fresh = entry("F", updatedDaysAgo: 1)
        let old = entry("O", updatedDaysAgo: 4)
        let older = entry("X", updatedDaysAgo: 9)
        let presentation = WorkspacePresentation(entries: [.waiting: [fresh, old, older]], status: .initial)
        #expect(WorkInsights.overdueFollowUps(in: presentation, days: 3, now: now).map(\.id.rawValue) == ["X", "O"])
        #expect(WorkInsights.overdueFollowUps(in: presentation, days: 0, now: now).isEmpty)
    }

    @Test func groupingKeepsOrderWithinGroupsAndRanksGroups() {
        let deep = entry("D", effort: .deep)
        let quick1 = entry("Q1", effort: .quick)
        let none = entry("N")
        let quick2 = entry("Q2", effort: .quick)
        let groups = WorkspaceGrouping.effort.groups([deep, quick1, none, quick2])
        #expect(groups.map(\.title) == [TriageEffort.quick.title, TriageEffort.deep.title, "Not estimated"])
        #expect(groups.first?.entries.map(\.id.rawValue) == ["Q1", "Q2"])

        let presentation = WorkspacePresentation(entries: [.inbox: [deep, quick1, none, quick2]], status: .initial)
        let visible = presentation.visibleEntries(
            section: .inbox, search: WorkspaceSearch(), doneFilter: .all,
            sortedBy: .recommended, ascending: false, grouping: .effort, viewer: "me"
        )
        #expect(visible.map(\.id.rawValue) == groups.flatMap(\.entries).map(\.id.rawValue))
    }

    @Test func effortSearchMatchesEstimate() {
        #expect(WorkspaceSearch(text: "effort:quick").matches(entry("Q", effort: .quick), viewer: "me"))
        #expect(!WorkspaceSearch(text: "effort:quick").matches(entry("D", effort: .deep), viewer: "me"))
    }

    @Test func briefingCollectsActionQuickWinsFollowUpsAndHandledToday() {
        let act = entry("A", disposition: .act, priority: 90, effort: .deep)
        let quick = entry("Q", priority: 40, effort: .quick)
        let stale = entry("S", updatedDaysAgo: 5)
        let doneToday = entry("D", local: .done(fingerprint: "f", at: now.addingTimeInterval(-60), handledEvidence: nil))
        let presentation = WorkspacePresentation(
            entries: [.inbox: [act, quick], .waiting: [stale], .done: [doneToday]], status: .initial
        )
        let briefing = WorkspaceBriefing(presentation: presentation, viewer: "me", followUpDays: 3, now: now)
        let kinds = Dictionary(uniqueKeysWithValues: briefing.parts.map { ($0.kind, $0.entries.map(\.id.rawValue)) })
        #expect(kinds[.needsAction] == ["A"])
        #expect(kinds[.quickWins] == ["Q"])
        #expect(kinds[.followUps] == ["S"])
        #expect(kinds[.handledToday] == ["D"])
        #expect(briefing.needsActionCount == 1 && briefing.quickWinCount == 1 && briefing.followUpCount == 1)
        #expect(Set(briefing.orderedEntries.map(\.id)).count == briefing.orderedEntries.count)
    }

    @Test func reviewCountsDoneByDayAndFindsStaleWork() {
        let handledByYou = entry("H", local: .done(fingerprint: "f", at: now.addingTimeInterval(-60), handledEvidence: "You commented"))
        let markedDone = entry("M", local: .done(fingerprint: "f", at: now.addingTimeInterval(-2 * 86_400), handledEvidence: nil))
        let stale = entry("S", updatedDaysAgo: 20)
        let presentation = WorkspacePresentation(
            entries: [.inbox: [stale], .done: [handledByYou, markedDone]], status: .initial
        )
        let review = WorkspaceReview(presentation: presentation, viewer: "me", now: now)
        #expect(review.days.count == 7)
        #expect(review.handledThisWeek == 2)
        #expect(review.handledByYouThisWeek == 1)
        #expect(review.stale.map(\.id.rawValue) == ["S"])
        #expect(review.byRepository.first?.repository == "octo/widgets")
    }

    @Test func savedSearchesRoundTripPerOrganization() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorkInsightsTests-\(UUID())"))
        let organization = try #require(OrganizationID(rawValue: "O_1"))
        let other = try #require(OrganizationID(rawValue: "O_2"))
        let saved = SavedSearch(name: "Security", search: WorkspaceSearch(text: "label:security", tokens: [SearchToken(kind: .repo, value: "widgets")]))
        SavedSearchStore(organizationID: organization).save([saved], defaults: defaults)
        #expect(SavedSearchStore(organizationID: organization).load(defaults: defaults) == [saved])
        #expect(SavedSearchStore(organizationID: other).load(defaults: defaults).isEmpty)
    }

    @Test func savedSearchRefinesAcrossAllWork() {
        let saved = WorkspaceSearch(text: "label:security", tokens: [SearchToken(kind: .repo, value: "widgets")])
        let refined = saved.refined(by: WorkspaceSearch(text: "cache", tokens: [SearchToken(kind: .repo, value: "widgets")]))
        #expect(refined.text == "label:security cache")
        #expect(refined.tokens.count == 1)
        #expect(refined.scope == .all)
    }

    // MARK: Attention

    private func undecided(_ id: String) -> TriageEntry {
        var entry = entry(id)
        entry.decision = nil
        return entry
    }

    @Test func attentionTakesABaselineThenAnnouncesOnlyNewActionItems() {
        var tracker = AttentionTracker()
        let existing = entry("A", disposition: .act)
        let pending = undecided("P")
        let empty = tracker.update(with: WorkspacePresentation(entries: [:], status: .initial))
        let baseline = tracker.update(with: WorkspacePresentation(entries: [.inbox: [existing], .analyzing: [pending]], status: .initial))
        #expect(empty.isEmpty && baseline.isEmpty)

        // A baseline item's first decision is not news; a brand-new item is.
        let pendingDecided = entry("P", disposition: .act)
        let fresh = entry("N", disposition: .act)
        let next = WorkspacePresentation(entries: [.inbox: [existing, pendingDecided, fresh]], status: .initial)
        let announced = tracker.update(with: next).map(\.id.rawValue)
        let repeated = tracker.update(with: next)
        #expect(announced == ["N"])
        #expect(repeated.isEmpty)

        // Leaving and returning is news again.
        _ = tracker.update(with: WorkspacePresentation(entries: [.inbox: [existing, pendingDecided]], status: .initial))
        let returned = tracker.update(with: next).map(\.id.rawValue)
        #expect(returned == ["N"])
    }

    @Test func followUpRemindersAreDaily() {
        var tracker = AttentionTracker()
        let none = tracker.followUpReminderDue(count: 0, now: now)
        let first = tracker.followUpReminderDue(count: 2, now: now)
        let sameDay = tracker.followUpReminderDue(count: 2, now: now.addingTimeInterval(60))
        let nextDay = tracker.followUpReminderDue(count: 2, now: now.addingTimeInterval(86_400))
        #expect(!none && first && !sameDay && nextDay)
    }

    @Test func quietHoursWrapPastMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 30, second: 0, of: now)! }
        let overnight = QuietHours(start: 19, end: 8)
        #expect(overnight.contains(at(22), calendar: calendar))
        #expect(overnight.contains(at(3), calendar: calendar))
        #expect(!overnight.contains(at(12), calendar: calendar))
        let daytime = QuietHours(start: 9, end: 17)
        #expect(daytime.contains(at(12), calendar: calendar))
        #expect(!daytime.contains(at(18), calendar: calendar))
    }

    @Test func doneAndSnoozedAreSeparateSectionsInTheirOwnOrder() {
        let later = entry("L", local: .snoozed(until: now.addingTimeInterval(7 * 86_400)))
        let soon = entry("S", local: .snoozed(until: now.addingTimeInterval(3_600)))
        let older = entry("O", local: .done(fingerprint: "f", at: now.addingTimeInterval(-86_400), handledEvidence: nil))
        let newer = entry("N", local: .done(fingerprint: "f", at: now.addingTimeInterval(-60), handledEvidence: "You replied"))
        let presentation = WorkspacePresentation(entries: [later, older, soon, newer], status: .initial, now: now)
        #expect(presentation.entries(in: .snoozed).map(\.id.rawValue) == ["S", "L"])
        #expect(presentation.entries(in: .done).map(\.id.rawValue) == ["N", "O"])
        #expect(presentation.setAsideIDs.count == 4)
        #expect(presentation.entries(in: .done).filter(DoneFilter.byYou.includes).map(\.id.rawValue) == ["N"])
    }
}
