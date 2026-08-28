import XCTest

@testable import Triage

final class WaitingAttentionRuleTests: XCTestCase {
  private let awaitedActor = GitHubNodeID(rawValue: "awaited-actor")!
  private let otherActor = GitHubNodeID(rawValue: "other-actor")!
  private let now = Date(timeIntervalSinceReferenceDate: 10_000)

  func testOnlyAwaitedActorResponsesAfterWaitingBeganTriggerWithEvidence() {
    let beganAt = now.addingTimeInterval(-100)
    let result = WaitingAttentionRule().evaluate(
      input: input(
        beganAt: beganAt,
        responses: [
          response(id: "unrelated", actor: otherActor, at: now),
          response(id: "at-boundary", actor: awaitedActor, at: beganAt),
          response(id: "awaited", actor: awaitedActor, at: beganAt.addingTimeInterval(1)),
        ]
      ),
      context: context()
    )

    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [WaitingAttentionRuleID.awaitedActorResponded.rawValue]
    )
    XCTAssertEqual(result.reasons.first?.evidence.map(\.id.rawValue), ["awaited"])
    XCTAssertTrue(
      WaitingAttentionRule().evaluate(
        input: input(
          status: .active, beganAt: beganAt,
          responses: [response(id: "awaited", actor: awaitedActor, at: now)]),
        context: context()
      ).reasons.isEmpty
    )
  }

  func testFollowUpTriggersAtDueBoundaryAndReasonsHaveStableStrengthOrder() {
    let result = WaitingAttentionRule().evaluate(
      input: input(
        beganAt: now.addingTimeInterval(-1),
        followUpAt: now,
        responses: [response(id: "response", actor: awaitedActor, at: now)]
      ),
      context: context()
    )

    XCTAssertEqual(
      result.reasons.map(\.ruleID),
      [
        WaitingAttentionRuleID.awaitedActorResponded.rawValue,
        WaitingAttentionRuleID.followUpDue.rawValue,
      ]
    )
    XCTAssertEqual(result.reasons.map(\.strength), [750, 650])
    XCTAssertEqual(result.reasons[0].id, "awaitedActorResponded-response")
    XCTAssertEqual(result.reasons[1].id, "followUpDue-waiting")
    XCTAssertEqual(result.reasons[1].evidence.map(\.id.rawValue), ["waiting"])
    XCTAssertTrue(
      WaitingAttentionRule().evaluate(
        input: input(followUpAt: now.addingTimeInterval(1)),
        context: context()
      ).reasons.isEmpty
    )
  }

  private func context() -> WaitingRuleContext {
    WaitingRuleContext(evaluatedAt: now)
  }

  private func input(
    status: LocalWorkStatus = .waiting,
    beganAt: Date? = nil,
    followUpAt: Date? = nil,
    responses: [AwaitedActorResponseEvidence] = []
  ) -> WaitingRuleInput {
    WaitingRuleInput(
      workflow: WaitingWorkflowEvidence(
        status: status,
        beganAt: beganAt,
        followUpAt: followUpAt,
        evidence: evidence(id: "waiting")
      ),
      awaitedActorNodeID: awaitedActor,
      responses: responses
    )
  }

  private func response(
    id: String,
    actor: GitHubNodeID,
    at: Date
  ) -> AwaitedActorResponseEvidence {
    AwaitedActorResponseEvidence(
      actorNodeID: actor,
      occurredAt: at,
      evidence: evidence(id: id)
    )
  }

  private func evidence(id: String) -> EvidenceReference {
    EvidenceReference(
      id: EvidenceID(rawValue: id)!,
      source: .restTimeline,
      observedAt: now
    )
  }
}
