import XCTest

@testable import Triage

final class CopilotHelperClientTests: XCTestCase {
  func testTerminatingPendingFrameWipesItBeforeInvalidatingService() async throws {
    let service = InvalidationRecordingService()
    let wipe = PendingFrameWipeRecorder()
    let transport = CopilotXPCFrameTransport(
      service: service,
      pendingFrameWiper: { frame in
        wipe.recordBeforeWipe(frame)
        frame.resetBytes(in: frame.startIndex..<frame.endIndex)
        frame.removeAll(keepingCapacity: false)
        wipe.recordAfterWipe(frame)
      }
    )
    let secret = "gho_pending-frame-must-be-wiped"

    try await transport.writeFrame(Data(secret.utf8))
    await transport.terminate()

    let invalidated = await service.wasInvalidated()
    XCTAssertTrue(invalidated)
    XCTAssertTrue(wipe.sawSecretFrame)
    XCTAssertTrue(wipe.wasEmptyAfterWipe)
    do {
      _ = try await transport.readFrame(maximumBytes: CopilotIPC.maximumResponseBytes)
      XCTFail("The discarded frame must not remain available after termination.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidResponse)
    }
  }

  func testHealthUsesFramedTransportAndMatchesRequest() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let request = CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
    let response = CopilotHealthResponse(
      header: CopilotResponseHeader(
        wireResponse: CopilotWireResponse(
          protocolVersion: CopilotIPC.version,
          requestID: requestID,
          accountID: copilotTestAccountID,
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
    XCTAssertEqual(requestObject["account_id"] as? String, copilotTestAccountID.rawValue)
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

  func testAnalysisRejectsActionWithoutStructuredClaims() async throws {
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
    let response = Data(
      """
      {"protocol_version":2,"request_id":"\(requestID.uuidString.lowercased())","account_id":"\(copilotTestAccountID.rawValue)","organization_id":"\(organizationID.rawValue)","status":"analysis","summary":"Review this source.","state":"open","confidence":0.95,"evidence_ids":["\(evidenceID.rawValue)"],"action_items":[{"id":"reply","text":"Reply","confidence":0.95,"evidence_ids":["\(evidenceID.rawValue)"]}],"model_id":"model-a","prompt_provenance":"triage-copilot-v2"}
      """.utf8
    )
    let client = CopilotHelperClient(transport: FakeFrameTransport(responses: [response]))

    do {
      _ = try await client.analyze(request)
      XCTFail("An action missing its claims array must not cross the wire boundary.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidResponse)
    }
  }

  func testAnalysisRejectsResponseFromDifferentSelectedModel() async throws {
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
      modelID: "selected-model",
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
      confidence: 0.95,
      evidenceIDs: [evidenceID],
      actionItems: [],
      nextAction: nil,
      modelID: "different-model",
      promptProvenance: "v1"
    )
    let client = CopilotHelperClient(
      transport: FakeFrameTransport(responses: [try encode(response)])
    )

    do {
      _ = try await client.analyze(request)
      XCTFail("A selected model must match the model that produced the response.")
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

  func testCancellationTerminatesCurrentTransportOperationAndShutsDownClient() async throws {
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
    let terminationCount = await transport.terminationCount()
    XCTAssertEqual(terminationCount, 1)
    await transport.waitUntilTerminated()

    do {
      _ = try await client.models(CopilotModelsRequest(organizationID: organizationID))
      XCTFail("Expected the shut-down client to reject new work.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .shutDown)
    }
  }

  func testServiceCancellationSynchronouslyTerminatesCurrentTransportOperation() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let transport = ServiceCancellationFrameTransport()
    let client = CopilotHelperClient(transport: transport)

    do {
      _ = try await client.health(CopilotHealthRequest(organizationID: organizationID))
      XCTFail("Expected service cancellation to be reported.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .operationCancelled)
    }

    // `health` must not return the cancellation result until the helper has
    // been synchronously fenced and reaped.
    let terminationCount = await transport.terminationCount()
    XCTAssertEqual(terminationCount, 1)
    do {
      _ = try await client.models(CopilotModelsRequest(organizationID: organizationID))
      XCTFail("Expected the cancelled client to reject new work.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .shutDown)
    }
  }

  func testDelayedCancellationForOldRequestCannotTerminateNewExchange() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let firstExchangeID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    let retryExchangeID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    let healthRequest = CopilotHealthRequest(
      organizationID: organizationID,
      requestID: requestID
    )
    let retryRequest = CopilotHealthRequest(
      organizationID: organizationID,
      requestID: requestID
    )
    let healthResponse = CopilotHealthResponse(
      header: responseHeader(
        requestID: healthRequest.header.requestID,
        organizationID: organizationID,
        status: .health
      ),
      health: CopilotHealth(
        helperVersion: "1.0.0",
        copilotAvailable: false,
        toolPolicy: "deny_all"
      )
    )
    let transport = StaleCancellationInterleavingFrameTransport(
      firstResponse: try encode(healthResponse),
      secondResponse: try encode(healthResponse)
    )
    let exchangeIDs = ExchangeIDSequence([firstExchangeID, retryExchangeID])
    let client = CopilotHelperClient(
      transport: transport,
      exchangeIDGenerator: { exchangeIDs.next() }
    )

    _ = try await client.health(healthRequest)
    let nextOperation = Task { try await client.health(retryRequest) }
    await transport.waitUntilSecondReadStarted()

    // This models an `onCancel` task queued for the completed first exchange.
    // The retry intentionally uses the same protocol request ID, so only the
    // local exchange token can distinguish it from the stale cancellation.
    await client.cancelRunningProcess(matching: firstExchangeID)
    let terminations = await transport.terminationCount()
    XCTAssertEqual(terminations, 0)

    await transport.releaseSecondResponse()
    _ = try await nextOperation.value
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

  func testExplicitCancelNormalizesOnlyTheTerminatedExchangeTransportFailure() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let evidenceID = try XCTUnwrap(EvidenceID(rawValue: "evidence-1"))
    let candidateID = try XCTUnwrap(AIRequestID(rawValue: "candidate-1"))
    let requestID = UUID()
    let transport = InvalidatingFrameTransport()
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
    _ = try await client.cancel(
      CopilotCancelRequest(organizationID: organizationID, targetRequestID: requestID)
    )

    let analysisResult = await analysis.result
    XCTAssertEqual(error(from: analysisResult), .operationCancelled)
  }

  func testDeadlineTerminatesTransportAndReportsTimeout() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let evidenceID = try XCTUnwrap(EvidenceID(rawValue: "evidence-1"))
    let candidateID = try XCTUnwrap(AIRequestID(rawValue: "candidate-1"))
    let transport = BlockingFrameTransport()
    let timeout = TimeoutGate()
    let client = CopilotHelperClient(
      transport: transport,
      waitForTimeout: { _ in await timeout.wait() }
    )
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
      deadline: .now.addingTimeInterval(60)
    )

    let analysis = Task { try await client.analyze(request) }
    await transport.waitUntilReadStarted()
    await timeout.fire()
    let result = await analysis.result
    XCTAssertEqual(error(from: result), .operationTimedOut)
    await transport.waitUntilTerminated()
  }

  func testHealthRejectsResponseWithUnexpectedFields() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    let response = Data(
      """
      {"protocol_version":2,"request_id":"\(requestID.uuidString.lowercased())","account_id":"\(copilotTestAccountID.rawValue)","organization_id":"org-1","status":"health","health":{"helper_version":"1.0.0","copilot_available":false,"tool_policy":"deny_all"},"unexpected":true}
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

  func testHelperFailureMustEchoTheActiveAccountAndRequest() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    let response = Data(
      """
      {"protocol_version":2,"request_id":"\(requestID.uuidString.lowercased())","account_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","organization_id":"org-1","status":"failure","failure":{"code":"stale","message":"must not escape"}}
      """.utf8
    )
    let client = CopilotHelperClient(transport: FakeFrameTransport(responses: [response]))

    do {
      _ = try await client.health(
        CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
      )
      XCTFail("A cross-account failure must not be attributed to this request.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .responseMismatch)
    }
  }

  func testHelperFailureWithWrongProtocolIsRejectedBeforeItsMessageEscapes() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    let response = Data(
      """
      {"protocol_version":1,"request_id":"\(requestID.uuidString.lowercased())","account_id":"\(copilotTestAccountID.rawValue)","organization_id":"org-1","status":"failure","failure":{"code":"stale","message":"must not escape"}}
      """.utf8
    )
    let client = CopilotHelperClient(transport: FakeFrameTransport(responses: [response]))

    do {
      _ = try await client.health(
        CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
      )
      XCTFail("An incompatible failure frame must be rejected.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidProtocolVersion)
    }
  }

  func testBoundHelperFailureSurfacesOnlyForTheActiveRequest() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    let response = failureFrame(
      protocolVersion: CopilotIPC.version,
      requestID: requestID,
      accountID: copilotTestAccountID.rawValue,
      organizationID: organizationID.rawValue,
      status: "failure"
    )
    let client = CopilotHelperClient(transport: FakeFrameTransport(responses: [response]))

    do {
      _ = try await client.health(
        CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
      )
      XCTFail("Expected the bound helper failure.")
    } catch {
      XCTAssertEqual(
        error as? CopilotXPCError,
        .helperFailure(.init(code: "stale", message: "must not escape"))
      )
    }
  }

  func testHelperFailureWithWrongRequestOrganizationOrStatusIsRejected() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    let invalidFrames = [
      failureFrame(
        protocolVersion: CopilotIPC.version,
        requestID: UUID(),
        accountID: copilotTestAccountID.rawValue,
        organizationID: organizationID.rawValue,
        status: "failure"
      ),
      failureFrame(
        protocolVersion: CopilotIPC.version,
        requestID: requestID,
        accountID: copilotTestAccountID.rawValue,
        organizationID: "another-org",
        status: "failure"
      ),
      failureFrame(
        protocolVersion: CopilotIPC.version,
        requestID: requestID,
        accountID: copilotTestAccountID.rawValue,
        organizationID: organizationID.rawValue,
        status: "health"
      ),
    ]

    for frame in invalidFrames {
      let client = CopilotHelperClient(transport: FakeFrameTransport(responses: [frame]))
      do {
        _ = try await client.health(
          CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
        )
        XCTFail("An unbound helper failure must be rejected.")
      } catch {
        XCTAssertEqual(error as? CopilotXPCError, .responseMismatch)
      }
    }
  }

  func testHelperFailureRejectsSuccessFieldsInItsEnvelope() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID()
    var frame = failureFrame(
      protocolVersion: CopilotIPC.version,
      requestID: requestID,
      accountID: copilotTestAccountID.rawValue,
      organizationID: organizationID.rawValue,
      status: "failure"
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    object["health"] = ["helper_version": "1.0.0", "copilot_available": false, "tool_policy": "deny_all"]
    frame = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let client = CopilotHelperClient(transport: FakeFrameTransport(responses: [frame]))

    do {
      _ = try await client.health(
        CopilotHealthRequest(organizationID: organizationID, requestID: requestID)
      )
      XCTFail("A failure envelope must not carry success fields.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidResponse)
    }
  }

  func testRejectsNonOpaqueAccountIdentityBeforeWritingToTransport() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let transport = FakeFrameTransport(responses: [])
    let client = CopilotHelperClient(transport: transport)

    do {
      _ = try await client.health(
        CopilotHealthRequest(
          accountID: try XCTUnwrap(AccountID(rawValue: "not-an-opaque-account")),
          organizationID: organizationID
        )
      )
      XCTFail("Expected a non-opaque account ID to be rejected.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidAccountID)
    }

    let writtenPayloads = await transport.writtenPayloads
    XCTAssertTrue(writtenPayloads.isEmpty)
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
        accountID: copilotTestAccountID,
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

  private func failureFrame(
    protocolVersion: Int,
    requestID: UUID,
    accountID: String,
    organizationID: String,
    status: String
  ) -> Data {
    Data(
      """
      {"protocol_version":\(protocolVersion),"request_id":"\(requestID.uuidString.lowercased())","account_id":"\(accountID)","organization_id":"\(organizationID)","status":"\(status)","failure":{"code":"stale","message":"must not escape"}}
      """.utf8
    )
  }

  private func error<T>(from result: Result<T, Error>) -> CopilotXPCError? {
    guard case let .failure(error) = result else { return nil }
    return error as? CopilotXPCError
  }

  func testXPCServiceErrorMappingAllowsOnlyStableFailClosedIdentities() {
    let domain = "com.triage.mac.copilot-xpc"
    XCTAssertEqual(
      CopilotXPCServiceClient.mapServiceError(NSError(domain: domain, code: 14)),
      .runtimeUnavailable
    )
    XCTAssertEqual(
      CopilotXPCServiceClient.mapServiceError(NSError(domain: domain, code: 15)),
      .runtimeCorrupt
    )
    XCTAssertEqual(
      CopilotXPCServiceClient.mapServiceError(NSError(domain: domain, code: 10)),
      .operationCancelled
    )
    XCTAssertEqual(
      CopilotXPCServiceClient.mapServiceError(NSError(domain: domain, code: 11)),
      .operationTimedOut
    )
    XCTAssertEqual(
      CopilotXPCServiceClient.mapServiceError(NSError(domain: domain, code: 1)),
      .helperUnavailable
    )
    XCTAssertEqual(
      CopilotXPCServiceClient.mapServiceError(NSError(domain: "untrusted.domain", code: 14)),
      .helperUnavailable
    )
  }
}

private let copilotTestAccountID = AccountID(
  rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
)!

private final class ExchangeIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID]

  init(_ values: [UUID]) {
    self.values = values
  }

  func next() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    precondition(!values.isEmpty)
    return values.removeFirst()
  }
}

private extension CopilotHealthRequest {
  init(organizationID: OrganizationID, requestID: UUID = UUID()) {
    self.init(accountID: copilotTestAccountID, organizationID: organizationID, requestID: requestID)
  }
}

private extension CopilotModelsRequest {
  init(organizationID: OrganizationID, requestID: UUID = UUID()) {
    self.init(accountID: copilotTestAccountID, organizationID: organizationID, requestID: requestID)
  }
}

private extension CopilotAnalyzeRequest {
  init(
    organizationID: OrganizationID,
    input: CopilotAnalysisInput,
    modelID: String? = nil,
    deadline: Date,
    requestID: UUID = UUID()
  ) {
    self.init(
      accountID: copilotTestAccountID,
      organizationID: organizationID,
      input: input,
      modelID: modelID,
      deadline: deadline,
      requestID: requestID
    )
  }
}

private extension CopilotCancelRequest {
  init(
    organizationID: OrganizationID,
    targetRequestID: UUID,
    requestID: UUID = UUID()
  ) {
    self.init(
      accountID: copilotTestAccountID,
      organizationID: organizationID,
      targetRequestID: targetRequestID,
      requestID: requestID
    )
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

private actor InvalidationRecordingService: CopilotXPCFrameService {
  private var invalidated = false

  func exchange(frame _: Data) async throws -> Data {
    throw CopilotXPCError.helperUnavailable
  }

  func invalidate() async {
    invalidated = true
  }

  func wasInvalidated() -> Bool {
    invalidated
  }
}

private final class PendingFrameWipeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var before = Data()
  private var afterWasEmpty = false

  var sawSecretFrame: Bool {
    lock.lock()
    defer { lock.unlock() }
    return String(data: before, encoding: .utf8)?.contains("gho_pending-frame-must-be-wiped") == true
  }

  var wasEmptyAfterWipe: Bool {
    lock.lock()
    defer { lock.unlock() }
    return afterWasEmpty
  }

  func recordBeforeWipe(_ frame: Data) {
    lock.lock()
    before = frame
    lock.unlock()
  }

  func recordAfterWipe(_ frame: Data) {
    lock.lock()
    afterWasEmpty = frame.isEmpty
    lock.unlock()
  }
}

private actor BlockingFrameTransport: CopilotFrameTransport {
  private var readStarted = false
  private var terminated = false
  private var terminations = 0

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
    terminations += 1
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

  func terminationCount() -> Int {
    terminations
  }
}

private actor TimeoutGate {
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !fired else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func fire() {
    fired = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

private actor ServiceCancellationFrameTransport: CopilotFrameTransport {
  private var terminated = 0

  func writeFrame(_ payload: Data) async throws {}

  func readFrame(maximumBytes: Int) async throws -> Data {
    throw CopilotXPCError.operationCancelled
  }

  func terminate() async {
    terminated += 1
  }

  func terminationCount() -> Int {
    terminated
  }
}

/// Models NSXPC invalidation: the connection reports an unrelated-looking
/// helper-unavailable failure after the exact local exchange initiated its
/// own termination.
private actor InvalidatingFrameTransport: CopilotFrameTransport {
  private var readStarted = false
  private var terminated = false

  func writeFrame(_ payload: Data) async throws {}

  func readFrame(maximumBytes: Int) async throws -> Data {
    readStarted = true
    while !terminated {
      await Task.yield()
    }
    throw CopilotXPCError.helperUnavailable
  }

  func terminate() async {
    terminated = true
  }

  func waitUntilReadStarted() async {
    while !readStarted {
      await Task.yield()
    }
  }
}

private actor StaleCancellationInterleavingFrameTransport: CopilotFrameTransport {
  private let firstResponse: Data
  private let secondResponse: Data
  private var readCount = 0
  private var secondReadStarted = false
  private var shouldReleaseSecondResponse = false
  private var terminated = 0

  init(firstResponse: Data, secondResponse: Data) {
    self.firstResponse = firstResponse
    self.secondResponse = secondResponse
  }

  func writeFrame(_ payload: Data) async throws {}

  func readFrame(maximumBytes: Int) async throws -> Data {
    defer { readCount += 1 }
    guard readCount == 1 else { return firstResponse }
    secondReadStarted = true
    while !shouldReleaseSecondResponse {
      await Task.yield()
    }
    return secondResponse
  }

  func terminate() async {
    terminated += 1
  }

  func waitUntilSecondReadStarted() async {
    while !secondReadStarted {
      await Task.yield()
    }
  }

  func releaseSecondResponse() {
    shouldReleaseSecondResponse = true
  }

  func terminationCount() -> Int {
    terminated
  }
}
