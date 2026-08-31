import XCTest
@testable import Triage

final class WorkDetailAccessibilityPolicyTests: XCTestCase {
    func testDetailSectionsHaveStableHeadingOrder() {
        XCTAssertEqual(
            WorkDetailPresentation.detailSectionHeadings,
            [
                "Source",
                "Sync and coverage",
                "Why this is here",
                "Action items",
                "Related content",
                "Review state",
                "Project context",
                "Timeline",
                "Evidence and provenance"
            ]
        )
    }

    func testEveryWorkflowMutationUsesTheExplicitLocalOnlyHint() {
        XCTAssertEqual(
            WorkDetailPresentation.localWorkflowAccessibilityHint,
            "Changes only Triage’s encrypted local workflow; does not modify GitHub."
        )
    }

    func testManualGroupingControlsDeclareTheirEncryptedLocalOnlyScope() {
        XCTAssertEqual(
            WorkDetailPresentation.localGroupingAccessibilityHint,
            "Saves only Triage’s encrypted local grouping decision; does not modify GitHub."
        )
    }

    func testInspectorFocusMovesToFirstActionThenReturnsToToggle() {
        XCTAssertEqual(
            WorkDetailPresentation.inspectorFocusTarget(isPresented: true),
            .inspectorFirstWorkflowAction
        )
        XCTAssertEqual(
            WorkDetailPresentation.inspectorFocusTarget(isPresented: false),
            .inspectorToggle
        )
    }

    func testInspectorCommandsRequireASelectedWorkItem() {
        XCTAssertFalse(WorkDetailPresentation.inspectorIsAvailable(hasSelection: false))
        XCTAssertTrue(WorkDetailPresentation.inspectorIsAvailable(hasSelection: true))
    }
}
