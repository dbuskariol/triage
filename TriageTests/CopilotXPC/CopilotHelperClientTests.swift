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

  func testAuthenticationConsumesAndWipesCredentialAfterSuccessfulFrame() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let requestID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let credential = CopilotEphemeralCredential(copying: Data("fixture-token".utf8))
    let response = CopilotAuthenticationResponse(
      header: responseHeader(
        requestID: requestID,
        organizationID: organizationID,
        status: .authentication
      ),
      authentication: CopilotAuthentication(
        host: "github.com",
        login: "fixture-user",
        authenticationType: "token",
        isAuthenticated: true
      )
    )
    let transport = FakeFrameTransport(responses: [try encode(response)])
    let client = CopilotHelperClient(transport: transport)
    let request = CopilotAuthenticateRequest(
      accountID: copilotTestAccountID,
      organizationID: organizationID,
      credential: credential,
      requestID: requestID
    )

    XCTAssertEqual(String(describing: credential), "<redacted>")
    XCTAssertFalse(String(describing: request).contains("fixture-token"))
    let result = try await client.authenticate(request)

    XCTAssertTrue(result.authentication.isAuthenticated)
    XCTAssertTrue(credential.isWipedForTesting)
    let payloads = await transport.writtenPayloads
    let requestObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(payloads.first)) as? [String: Any]
    )
    XCTAssertEqual(requestObject["operation"] as? String, "authenticate")
    XCTAssertEqual(requestObject["credential"] as? String, "fixture-token")
  }

  func testAuthenticationWipesCredentialWhenResponseIsRejected() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let credential = CopilotEphemeralCredential(copying: Data("fixture-token".utf8))
    let client = CopilotHelperClient(
      transport: FakeFrameTransport(responses: [Data("not-json".utf8)])
    )

    do {
      _ = try await client.authenticate(
        CopilotAuthenticateRequest(
          accountID: copilotTestAccountID,
          organizationID: organizationID,
          credential: credential
        )
      )
      XCTFail("Expected the malformed response to be rejected.")
    } catch {
      XCTAssertEqual(error as? CopilotXPCError, .invalidResponse)
    }
    XCTAssertTrue(credential.isWipedForTesting)
  }

  func testAuthenticationWipesCredentialWhenCallerCancels() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let credential = CopilotEphemeralCredential(copying: Data("fixture-token".utf8))
    let transport = BlockingFrameTransport()
    let client = CopilotHelperClient(transport: transport)
    let operation = Task {
      try await client.authenticate(
        CopilotAuthenticateRequest(
          accountID: copilotTestAccountID,
          organizationID: organizationID,
          credential: credential
        )
      )
    }

    await transport.waitUntilReadStarted()
    operation.cancel()
    let result = await operation.result

    XCTAssertEqual(error(from: result), .operationCancelled)
    XCTAssertTrue(credential.isWipedForTesting)
    await transport.waitUntilTerminated()
  }

  func testAuthenticationWipesCredentialWhenTimedOut() async throws {
    let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org-1"))
    let credential = CopilotEphemeralCredential(copying: Data("fixture-token".utf8))
    let transport = BlockingFrameTransport()
    let timeout = TimeoutGate()
    let client = CopilotHelperClient(
      transport: transport,
      waitForTimeout: { _ in await timeout.wait() }
    )
    let operation = Task {
      try await client.authenticate(
        CopilotAuthenticateRequest(
          accountID: copilotTestAccountID,
          organizationID: organizationID,
          credential: credential
        )
      )
    }

    await transport.waitUntilReadStarted()
    await timeout.fire()
    let result = await operation.result

    XCTAssertEqual(error(from: result), .operationTimedOut)
    XCTAssertTrue(credential.isWipedForTesting)
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

extension CopilotHelperClientTests {
  func testTriageWireRoundTripRejectsMissingAndExtraIDs() throws {
    let organization = try XCTUnwrap(OrganizationID(rawValue: "triage-org"))
    let item = CopilotTriageItem(id: "node-1", kind: "issue", repository: "o/r", number: 1, title: "Review", state: "open", author: "octo", updatedAt: Date(), relationships: ["assigned"], labels: [], assignees: [], body: "", pullRequest: nil, recentActivity: [])
    let request = CopilotTriageRequest(accountID: copilotTestAccountID, organizationID: organization, viewerLogin: "octo", items: [item], deadline: Date().addingTimeInterval(30))
    let decision = CopilotTriageItemDecision(id: "node-1", disposition: .review, priority: 50, confidence: 0.8, summary: "Review this item.", reason: "It is assigned to you.", nextAction: "Read it.")
    let header = CopilotResponseHeader(requestID: request.header.requestID, accountID: copilotTestAccountID, organizationID: organization, status: .triage)
    let response = CopilotTriageResponse(header: header, modelID: "auto", decisions: [decision])
    let roundTrip = try JSONDecoder().decode(CopilotTriageResponse.self, from: JSONEncoder().encode(response))
    try roundTrip.validate(against: request)
    let missing = CopilotTriageResponse(header: header, modelID: "auto", decisions: [])
    XCTAssertThrowsError(try missing.validate(against: request))
    let extra = CopilotTriageResponse(header: header, modelID: "auto", decisions: [.init(id: "unknown", disposition: .none, priority: 0, confidence: 1, summary: "No action.", reason: "It is informational.", nextAction: nil)])
    XCTAssertThrowsError(try extra.validate(against: request))
  }
}
