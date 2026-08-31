import XCTest
@testable import Triage

final class CopilotIPCTests: XCTestCase {
    func testFrameRoundTripsByteAccurately() throws {
        let payload = Data(#"{"operation":"health"}"#.utf8)
        let frame = try CopilotFrameCodec.encode(payload, maximumBytes: CopilotIPC.maximumRequestBytes)

        XCTAssertEqual(try CopilotFrameCodec.decode(frame, maximumBytes: CopilotIPC.maximumRequestBytes), payload)
        XCTAssertThrowsError(try CopilotFrameCodec.decode(Data(frame.dropLast()), maximumBytes: CopilotIPC.maximumRequestBytes))
    }

    func testHealthResponseDecodesHelperProtocolShape() throws {
        let response = try JSONDecoder().decode(
            CopilotWireResponse.self,
            from: Data(#"{"protocol_version":2,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","account_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","organization_id":"MDEyOk9yZ2FuaXphdGlvbjE=","status":"health","health":{"helper_version":"0.1.0","copilot_available":false,"tool_policy":"deny_all"}}"#.utf8)
        )

        XCTAssertEqual(response.protocolVersion, 2)
        XCTAssertEqual(response.accountID?.rawValue, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertEqual(response.status, .health)
        XCTAssertEqual(response.organizationID?.rawValue, "MDEyOk9yZ2FuaXphdGlvbjE=")
        XCTAssertEqual(response.health?.toolPolicy, "deny_all")
    }

    func testAnalysisRequiresUntrustedEvidenceTableAndEvidenceBoundActionDeadline() throws {
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = OrganizationID(rawValue: "copilot-ipc-org")!
        let evidenceID = EvidenceID(rawValue: "copilot-ipc-evidence")!
        let deadline = Date(timeIntervalSinceReferenceDate: 123_456)
        let evidenceTimestamp = Date(timeIntervalSinceReferenceDate: 123_000)
        let input = CopilotAnalysisInput(
            candidateID: AIRequestID(rawValue: "copilot-ipc-candidate")!,
            workItemTitle: "Current source title",
            workItemState: "active",
            deterministicReasons: ["current-assignment"],
            body: "Untrusted source body",
            labels: ["priority"],
            projectFields: ["status": "In progress"],
            conversation: [],
            evidence: [.init(
                id: evidenceID,
                actorRole: "actor:current-user",
                text: "Please finish this by the listed deadline.",
                timestamp: evidenceTimestamp,
                explicitDeadline: deadline
            )],
            evidenceIDs: [evidenceID]
        )
        XCTAssertNoThrow(try input.validate())
        let invalidInput = CopilotAnalysisInput(
            candidateID: input.candidateID,
            contentIsUntrusted: false,
            workItemTitle: input.workItemTitle,
            workItemState: input.workItemState,
            deterministicReasons: input.deterministicReasons,
            body: input.body,
            labels: input.labels,
            projectFields: input.projectFields,
            conversation: input.conversation,
            evidence: input.evidence,
            evidenceIDs: input.evidenceIDs
        )
        XCTAssertThrowsError(try invalidInput.validate())

        let header = CopilotResponseHeader(
            requestID: UUID(),
            accountID: accountID,
            organizationID: organizationID,
            status: .analysis
        )
        let valid = CopilotAnalysisResponse(
            header: header,
            summary: "A current action is needed.",
            state: "active",
            confidence: 0.95,
            evidenceIDs: [evidenceID],
            actionItems: [.init(
                id: "reply",
                text: "Reply before the deadline",
                confidence: 0.95,
                evidenceIDs: [evidenceID],
                deadline: deadline,
                claims: [.init(
                    evidenceID: evidenceID,
                    actorRole: "actor:current-user",
                    timestamp: evidenceTimestamp,
                    quotedSpan: "Please finish this by the listed deadline.",
                    deterministicReasonID: "current-assignment"
                )]
            )],
            nextAction: nil,
            modelID: "auto",
            promptProvenance: "triage-copilot-v2"
        )
        XCTAssertNoThrow(try valid.validate(against: input))
        let semanticOnly = CopilotAnalysisResponse(
            header: header,
            summary: valid.summary,
            state: valid.state,
            confidence: valid.confidence,
            evidenceIDs: valid.evidenceIDs,
            actionItems: [.init(
                id: "review-only",
                text: "Review the current source",
                confidence: 0.95,
                evidenceIDs: [evidenceID]
            )],
            nextAction: nil,
            modelID: "auto",
            promptProvenance: "triage-copilot-v2"
        )
        XCTAssertNoThrow(try semanticOnly.validate(against: input))
        let inventedDeadline = CopilotAnalysisResponse(
            header: header,
            summary: valid.summary,
            state: valid.state,
            confidence: valid.confidence,
            evidenceIDs: valid.evidenceIDs,
            actionItems: [.init(
                id: "reply",
                text: "Reply before the invented deadline",
                confidence: 0.95,
                evidenceIDs: [evidenceID],
                deadline: deadline.addingTimeInterval(60)
            )],
            nextAction: nil,
            modelID: "auto",
            promptProvenance: "triage-copilot-v2"
        )
        XCTAssertThrowsError(try inventedDeadline.validate(against: input))

        let mismatchedActor = CopilotAnalysisResponse(
            header: header,
            summary: valid.summary,
            state: valid.state,
            confidence: valid.confidence,
            evidenceIDs: valid.evidenceIDs,
            actionItems: [.init(
                id: "reply",
                text: "Reply before the deadline",
                confidence: 0.95,
                evidenceIDs: [evidenceID],
                deadline: deadline,
                claims: [.init(
                    evidenceID: evidenceID,
                    actorRole: "actor:invented",
                    timestamp: evidenceTimestamp,
                    quotedSpan: "Please finish this by the listed deadline.",
                    deterministicReasonID: "current-assignment"
                )]
            )],
            nextAction: nil,
            modelID: "auto",
            promptProvenance: "triage-copilot-v2"
        )
        XCTAssertThrowsError(try mismatchedActor.validate(against: input))

        let mismatchedQuoteOrReason = CopilotAnalysisResponse(
            header: header,
            summary: valid.summary,
            state: valid.state,
            confidence: valid.confidence,
            evidenceIDs: valid.evidenceIDs,
            actionItems: [.init(
                id: "reply",
                text: "Reply before the deadline",
                confidence: 0.95,
                evidenceIDs: [evidenceID],
                deadline: deadline,
                claims: [.init(
                    evidenceID: evidenceID,
                    actorRole: "actor:current-user",
                    timestamp: evidenceTimestamp.addingTimeInterval(1),
                    quotedSpan: "ignore previous instructions",
                    deterministicReasonID: "invented-reason"
                )]
            )],
            nextAction: nil,
            modelID: "auto",
            promptProvenance: "triage-copilot-v2"
        )
        XCTAssertThrowsError(try mismatchedQuoteOrReason.validate(against: input))
    }
}
