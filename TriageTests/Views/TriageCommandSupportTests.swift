import SwiftUI
import XCTest
@testable import Triage

@MainActor
final class TriageCommandSupportTests: XCTestCase {
    func testMenuLabelAbbreviationCollapsesWhitespaceAndRespectsLimit() {
        let label = TriageMenuLabel.abbreviated("  Review   a private pull request title  ", limit: 20)

        XCTAssertEqual(label, "Review a private pu…")
        XCTAssertLessThanOrEqual(label.count, 20)
    }

    func testMenuLabelAbbreviationHandlesTinyLimits() {
        XCTAssertEqual(TriageMenuLabel.abbreviated("Long title", limit: 0), "")
        XCTAssertEqual(TriageMenuLabel.abbreviated("Long title", limit: 1), "…")
        XCTAssertEqual(TriageMenuLabel.abbreviated("Long title", limit: 2), "L…")
    }

    func testMenuLabelAbbreviationUsesTheDefaultThirtyCharacterLimit() {
        let label = TriageMenuLabel.abbreviated(
            "A deliberately long private work title for the menu bar"
        )

        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertLessThanOrEqual(label.count, 30)
    }

    func testFocusedValuesRouteSearchAndInspectorBindingsIndependently() {
        var searchIsFocused = false
        var inspectorIsVisible = false
        let searchBinding = Binding(
            get: { searchIsFocused },
            set: { searchIsFocused = $0 }
        )
        let inspectorBinding = Binding(
            get: { inspectorIsVisible },
            set: { inspectorIsVisible = $0 }
        )

        TriageFocusedCommandRouting.focusSearch(searchBinding)
        TriageFocusedCommandRouting.toggleInspector(inspectorBinding)

        XCTAssertTrue(searchIsFocused)
        XCTAssertTrue(inspectorIsVisible)

        TriageFocusedCommandRouting.toggleInspector(inspectorBinding)
        TriageFocusedCommandRouting.focusSearch(nil)
        TriageFocusedCommandRouting.toggleInspector(nil)

        XCTAssertTrue(searchIsFocused)
        XCTAssertFalse(inspectorIsVisible)
    }

    func testExternalNavigationRequiresHTTPSConfirmationBeforeOpening() {
        let coordinator = ExternalNavigationConfirmationCoordinator()
        let secureGitHubURL = URL(string: "https://github.com/example/repository/issues/1")!

        coordinator.requestOpen(URL(string: "http://github.com/example/repository/issues/1")!)
        XCTAssertNil(coordinator.pendingURL)

        coordinator.requestOpen(secureGitHubURL)
        XCTAssertEqual(coordinator.pendingURL, secureGitHubURL)
        XCTAssertEqual(coordinator.confirmOpen(), secureGitHubURL)
        XCTAssertNil(coordinator.pendingURL)

        coordinator.requestOpen(secureGitHubURL)
        coordinator.cancel()
        XCTAssertNil(coordinator.pendingURL)
    }

    func testAvailabilityFailsClosedWithoutSelection() {
        let availability = TriageWorkflowCommandAvailability(item: nil)

        XCTAssertFalse(availability.canOpenSource)
        XCTAssertFalse(availability.canArchive)
        XCTAssertFalse(availability.canUnarchive)
        XCTAssertFalse(availability.canSnooze)
        XCTAssertFalse(availability.canClearSnooze)
        XCTAssertFalse(availability.canMarkWaiting)
    }

    func testArchivedSelectionDisablesIrreversibleWorkflowCommands() {
        let item = makeWorkItem(
            sourceURL: URL(string: "https://github.com/example/repository/issues/1"),
            workflow: WorkflowState(
                status: .archived,
                snoozedUntil: Date(timeIntervalSinceReferenceDate: 10_000),
                updatedAt: .now
            )
        )

        let availability = TriageWorkflowCommandAvailability(item: item)

        XCTAssertTrue(availability.canOpenSource)
        XCTAssertFalse(availability.canArchive)
        XCTAssertTrue(availability.canUnarchive)
        XCTAssertFalse(availability.canSnooze)
        XCTAssertTrue(availability.canClearSnooze)
        XCTAssertFalse(availability.canMarkWaiting)
        XCTAssertFalse(availability.canClearWaiting)
    }

    func testWaitingSelectionDisablesMarkWaitingAndEnablesStopWaiting() {
        let item = makeWorkItem(
            workflow: WorkflowState(status: .waiting, updatedAt: .now)
        )

        let availability = TriageWorkflowCommandAvailability(item: item)

        XCTAssertTrue(availability.canArchive)
        XCTAssertTrue(availability.canSnooze)
        XCTAssertFalse(availability.canMarkWaiting)
        XCTAssertTrue(availability.canClearWaiting)
    }

    func testWaitingKeyboardCommandUsesNoFollowUpAndTogglesWaitingState() {
        let active = WorkflowState(status: .active, updatedAt: .now)
        let waiting = WorkflowState(status: .waiting, updatedAt: .now)

        guard case let .markWaiting(followUpAt) = WorkDetailPresentation.waitingAction(for: active) else {
            return XCTFail("The command should mark active work Waiting.")
        }
        XCTAssertNil(followUpAt)
        guard case .clearWaiting? = WorkDetailPresentation.waitingAction(for: waiting) else {
            return XCTFail("The command should stop waiting work.")
        }
        XCTAssertNil(WorkDetailPresentation.waitingAction(for: WorkflowState(status: .archived, updatedAt: .now)))
    }

    func testActiveSelectionKeepsExternalAndLocalCommandAvailabilitySeparate() {
        let item = makeWorkItem(
            workflow: WorkflowState(status: .active, updatedAt: .now)
        )

        let availability = TriageWorkflowCommandAvailability(item: item)

        XCTAssertFalse(availability.canOpenSource)
        XCTAssertTrue(availability.canArchive)
        XCTAssertFalse(availability.canUnarchive)
        XCTAssertTrue(availability.canSnooze)
        XCTAssertFalse(availability.canClearSnooze)
        XCTAssertTrue(availability.canMarkWaiting)
        XCTAssertFalse(availability.canClearWaiting)
    }

    func testInsecureSourceURLDisablesTheOpenCommand() {
        let item = makeWorkItem(
            sourceURL: URL(string: "http://github.com/example/repository/issues/1"),
            workflow: WorkflowState(status: .active, updatedAt: .now)
        )

        XCTAssertFalse(TriageWorkflowCommandAvailability(item: item).canOpenSource)
    }

    private func makeWorkItem(sourceURL: URL? = nil, workflow: WorkflowState) -> WorkItem {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        return WorkItem(
            id: WorkItemID.make(),
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "organization")!,
            primaryNodeID: GitHubNodeID(rawValue: "I_kwDOExample")!,
            title: "Example",
            state: .active,
            sourceKind: .issue,
            sourceURL: sourceURL,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: [],
            workflow: workflow,
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }
}
