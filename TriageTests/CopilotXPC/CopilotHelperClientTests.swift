import XCTest

@testable import Triage

final class CopilotHelperClientTests: XCTestCase {
  func testHealthUsesFramedTransportAndMatchesRequest() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let request = CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
    let response = CopilotHealthResponse(
      header: CopilotResponseHeader(
        wireResponse: CopilotWireResponse(
          protocolVersion: CopilotIPC.version,
          requestID: requestID,
          organizationID: organizationID,
          status: .health,
          health: nil,
          failure: nil
        )
      ),
      health: CopilotHealth(
        helperVersion: "1.0.0",
        copilotAvailable: true,
        toolPolicy: "deny_all"
      )
    )
    let transport = FakeFrameTransport(responses: [try encode(response)])
    let client = CopilotHelperClient(transport: transport)

    let result = try await client.health(request)

    XCTAssertEqual(result.health.helperVersion, "1.0.0")
    let writtenPayloads = await transport.writtenPayloads
    XCTAssertEqual(writtenPayloads.count, 1)
    let requestObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: writtenPayloads[0]) as? [String: Any]
    )
    XCTAssertEqual(requestObject["operation"] as? String, "health")
    XCTAssertNil(requestObject["header"])
  }

  func testAnalysisRejectsInvalidConfidence() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let evidenceID = try XCTUnwrap(EvidenceID(rawValue: "evidence-1"))
    let candidateID = try XCTUnwrap(AIRequestID(rawValue: "candidate-1"))
    let requestID = UUID()
    let request = CopilotAnalyzeRequest(
      organizationID: organizationID,
      input: CopilotAnalysisInput(
        candidateID: candidateID,
        workItemTitle: "Title",
        workItemState: "open",
        deterministicReasons: ["mention"],
        body: "Body",
        conversation: [],
        evidenceIDs: [evidenceID]
      ),
      deadline: .now.addingTimeInterval(60),
      requestID: requestID
    )
    let response = CopilotAnalysisResponse(
      header: responseHeader(
        requestID: requestID,
        organizationID: organizationID,
        status: .analysis
      ),
      summary: "Summary",
      state: "needs_response",
      confidence: 1.1,
      evidenceIDs: [evidenceID],
      actionItems: [],
      nextAction: nil,
      modelID: "auto",
      promptProvenance: "v1"
    )
    let client = CopilotHelperClient(
      transport: FakeFrameTransport(responses: [try encode(response)])
    )

    do {
      _ = try await client.analyze(request)
      XCTFail("Expected invalid analysis to be rejected.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidAnalysis)
    }
  }

  func testSingleFlightRejectsSecondOperation() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let transport = BlockingFrameTransport()
    let client = CopilotHelperClient(transport: transport)
    let first = Task {
      try await client.health(CopilotHealthRequest(organizationID: organizationID))
    }

    await transport.waitUntilReadStarted()
    do {
      _ = try await client.models(CopilotModelsRequest(organizationID: organizationID))
      XCTFail("Expected the concurrent operation to be rejected.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .operationInProgress)
    }

    first.cancel()
    _ = await first.result
  }

  private func responseHeader(
    requestID: UUID,
    organizationID: OrganizationID,
    status: CopilotResponseStatus
  ) -> CopilotResponseHeader {
    CopilotResponseHeader(
      wireResponse: CopilotWireResponse(
        protocolVersion: CopilotIPC.version,
        requestID: requestID,
        organizationID: organizationID,
        status: status,
        health: nil,
        failure: nil
      )
    )
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
}

private actor FakeFrameTransport: CopilotFrameTransport {
  private var responses: [Data]
  private(set) var writtenPayloads: [Data] = []

  init(responses: [Data]) {
    self.responses = responses
  }

  func writeFrame(_ payload: Data) async throws {
    writtenPayloads.append(payload)
  }

  func readFrame(maximumBytes: Int) async throws -> Data {
    guard !responses.isEmpty else { throw CopilotXPCError.processExited }
    return responses.removeFirst()
  }

  func terminate() async {}
}

private actor BlockingFrameTransport: CopilotFrameTransport {
  private var readStarted = false

  func writeFrame(_ payload: Data) async throws {}

  func readFrame(maximumBytes: Int) async throws -> Data {
    readStarted = true
    try await Task.sleep(for: .seconds(60))
    throw CopilotXPCError.processExited
  }

  func terminate() async {}

  func waitUntilReadStarted() async {
    while !readStarted {
      await Task.yield()
    }
  }
}
