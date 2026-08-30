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
        copilotAvailable: false,
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
    let firstResult = await first.result
    XCTAssertEqual(error(from: firstResult), .operationCancelled)
    await transport.waitUntilTerminated()
  }

  func testCancellationTerminatesTransportAndShutsDownClient() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let transport = BlockingFrameTransport()
    let client = CopilotHelperClient(transport: transport)
    let operation = Task {
      try await client.health(CopilotHealthRequest(organizationID: organizationID))
    }

    await transport.waitUntilReadStarted()
    operation.cancel()
    let operationResult = await operation.result
    XCTAssertEqual(error(from: operationResult), .operationCancelled)
    await transport.waitUntilTerminated()

    do {
      _ = try await client.models(CopilotModelsRequest(organizationID: organizationID))
      XCTFail("Expected the shut-down client to reject new work.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .shutDown)
    }
  }

  func testCancelRequestTerminatesMatchingAnalysis() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let evidenceID = try XCTUnwrap(EvidenceID(rawValue: "evidence-1"))
    let candidateID = try XCTUnwrap(AIRequestID(rawValue: "candidate-1"))
    let requestID = UUID()
    let transport = BlockingFrameTransport()
    let client = CopilotHelperClient(transport: transport)
    let analysis = Task {
      try await client.analyze(
        CopilotAnalyzeRequest(
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
      )
    }

    await transport.waitUntilReadStarted()
    let cancellation = try await client.cancel(
      CopilotCancelRequest(
        organizationID: organizationID,
        targetRequestID: requestID
      )
    )
    XCTAssertEqual(cancellation.cancelledRequestID, requestID)
    let analysisResult = await analysis.result
    XCTAssertEqual(error(from: analysisResult), .operationCancelled)
    await transport.waitUntilTerminated()
  }

  func testDeadlineTerminatesTransportAndReportsTimeout() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let evidenceID = try XCTUnwrap(EvidenceID(rawValue: "evidence-1"))
    let candidateID = try XCTUnwrap(AIRequestID(rawValue: "candidate-1"))
    let transport = BlockingFrameTransport()
    let client = CopilotHelperClient(transport: transport)
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
      deadline: .now.addingTimeInterval(0.1)
    )

    do {
      _ = try await client.analyze(request)
      XCTFail("Expected the deadline to expire.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .operationTimedOut)
    }
    await transport.waitUntilTerminated()
  }

  func testHealthRejectsResponseWithUnexpectedFields() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    let response = Data(
      """
      {"protocol_version":1,"request_id":"\(requestID.uuidString.lowercased())","organization_id":"org-1","status":"health","health":{"helper_version":"1.0.0","copilot_available":false,"tool_policy":"deny_all"},"unexpected":true}
      """.utf8
    )
    let client = CopilotHelperClient(
      transport: FakeFrameTransport(responses: [response])
    )

    do {
      _ = try await client.health(
        CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
      )
      XCTFail("Expected an unrecognized response field to be rejected.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidResponse)
    }
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

  private func error<T>(from result: Result<T, Error>) -> CopilotXPCError? {
    guard case let .failure(error) = result else { return nil }
    return error as? CopilotXPCError
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
  private var terminated = false

  func writeFrame(_ payload: Data) async throws {}

  func readFrame(maximumBytes: Int) async throws -> Data {
    readStarted = true
    while !terminated {
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CopilotXPCError.operationCancelled
  }

  func terminate() async {
    terminated = true
  }

  func waitUntilReadStarted() async {
    while !readStarted {
      await Task.yield()
    }
  }

  func waitUntilTerminated() async {
    while !terminated {
      await Task.yield()
    }
  }
}
