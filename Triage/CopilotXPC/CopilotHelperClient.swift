import Foundation

actor CopilotHelperClient: TriageCopilotHelping {
  private enum TerminationReason: Sendable {
    case callerCancelled
    case timedOut

    var error: CopilotXPCError {
      switch self {
      case .callerCancelled: return .operationCancelled
      case .timedOut: return .operationTimedOut
      }
    }
  }

  private struct ActiveOperation: Sendable {
    /// This is deliberately distinct from the protocol request ID. A caller
    /// may retry with the same request ID, but a cancellation callback belongs
    /// to one particular local exchange and must never terminate its retry.
    let exchangeID: UUID
    let requestID: UUID
    let accountID: AccountID
    let organizationID: OrganizationID
    let operation: CopilotOperation
    var isTerminating = false
    var terminationReason: TerminationReason?
  }

  private let transport: any CopilotFrameTransport
  private let exchangeIDGenerator: @Sendable () -> UUID
  private let waitForTimeout: @Sendable (TimeInterval) async throws -> Void
  private var activeOperation: ActiveOperation?
  private var isShutDown = false

  init(
    transport: any CopilotFrameTransport,
    exchangeIDGenerator: @escaping @Sendable () -> UUID = { UUID() },
    waitForTimeout: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) {
    self.transport = transport
    self.exchangeIDGenerator = exchangeIDGenerator
    self.waitForTimeout = waitForTimeout
  }

  func health(_ request: CopilotHealthRequest) async throws -> CopilotHealthResponse {
    let response: CopilotHealthResponse = try await exchange(
      request,
      expectedStatus: .health,
      timeout: nil
    )
    return response
  }

  func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse {
    try validate(request.header)
    let payload = try CopilotAuthenticationRequestEncoder.encode(request)
    return try await exchangePayload(
      header: request.header,
      expectedStatus: .authentication,
      timeout: 60,
      payload: payload
    )
  }

  func models(_ request: CopilotModelsRequest) async throws -> CopilotModelsResponse {
    try await exchange(request, expectedStatus: .models, timeout: nil)
  }

  func analyze(_ request: CopilotAnalyzeRequest) async throws -> CopilotAnalysisResponse {
    let timeout = request.deadline.timeIntervalSinceNow
    guard timeout > 0 else { throw CopilotXPCError.operationTimedOut }
    try request.input.validate()
    let response: CopilotAnalysisResponse = try await exchange(
      request,
      expectedStatus: .analysis,
      timeout: timeout
    )
    try response.validate(against: request.input)
    // A selected model is an authorization and cache boundary. Auto may
    // accept the runtime-selected model, but an explicit selection must not
    // silently accept a response from another model.
    guard request.modelID == nil || response.modelID == request.modelID else {
      throw CopilotXPCError.invalidAnalysis
    }
    return response
  }

  func cancel(_ request: CopilotCancelRequest) async throws -> CopilotCancelResponse {
    guard let activeOperation,
      activeOperation.requestID == request.targetRequestID,
      activeOperation.accountID == request.header.accountID,
      activeOperation.organizationID == request.header.organizationID,
      activeOperation.operation == .analyze
    else {
      throw CopilotXPCError.noActiveAnalysis
    }
    // A pipe has one response reader. Termination safely interrupts it; the
    // XPC service will own protocol-level cancellation dispatch.
    await terminateActiveOperation(
      matching: activeOperation.exchangeID,
      reason: .callerCancelled
    )
    return CopilotCancelResponse(
      header: CopilotResponseHeader(
        requestID: request.header.requestID,
        accountID: request.header.accountID,
        organizationID: request.header.organizationID,
        status: .cancelled
      ),
      cancelledRequestID: request.targetRequestID
    )
  }

  func shutdown(_ request: CopilotShutdownRequest) async throws -> CopilotShutdownResponse {
    let response: CopilotShutdownResponse = try await exchange(
      request,
      expectedStatus: .shutdown,
      timeout: nil
    )
    isShutDown = true
    await transport.terminate()
    return response
  }

  private func exchange<
    Request: Encodable & CopilotRequestContaining,
    Response: Decodable & CopilotResponseContaining & Sendable
  >(
    _ request: Request,
    expectedStatus: CopilotResponseStatus,
    timeout: TimeInterval?
  ) async throws -> Response {
    var encoded = try CopilotJSONCodec.encode(request)
    let payload = CopilotOwnedPayload(copying: encoded)
    encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex)
    return try await exchangePayload(
      header: request.header,
      expectedStatus: expectedStatus,
      timeout: timeout,
      payload: payload
    )
  }

  private func exchangePayload<Response: Decodable & CopilotResponseContaining & Sendable>(
    header: CopilotRequestHeader,
    expectedStatus: CopilotResponseStatus,
    timeout: TimeInterval?,
    payload: CopilotOwnedPayload
  ) async throws -> Response {
    guard !isShutDown else { throw CopilotXPCError.shutDown }
    guard activeOperation == nil else { throw CopilotXPCError.operationInProgress }
    try validate(header)

    let operation = ActiveOperation(
      exchangeID: exchangeIDGenerator(),
      requestID: header.requestID,
      accountID: header.accountID,
      organizationID: header.organizationID,
      operation: header.operation
    )
    activeOperation = operation
    defer {
      // A queued cancellation callback is allowed to run after this exchange
      // completes. It must not clear state for a later exchange.
      if activeOperation?.exchangeID == operation.exchangeID {
        activeOperation = nil
      }
    }

    guard payload.count <= CopilotIPC.maximumRequestBytes else {
      throw CopilotFrameError.payloadTooLarge
    }
    // The cancellation handler is a sending closure. Capture only the
    // concrete Sendable exchange identity and actor reference, never the
    // generic request or the current actor-isolated region.
    let exchangeID = operation.exchangeID
    let client = self

    do {
      let response: Response = try await withTaskCancellationHandler {
        try await readResponse(
          payload: payload,
          request: header,
          expectedStatus: expectedStatus,
          timeout: timeout,
          exchangeID: exchangeID
        )
      } onCancel: {
        Task { [client, exchangeID] in
          await client.cancelRunningProcess(
            matching: exchangeID,
            reason: .callerCancelled
          )
        }
      }
      // Cancellation handlers are allowed to run asynchronously. Do not
      // return a successful response after caller cancellation; the catch
      // below synchronously reaps this exact helper before returning.
      try Task.checkCancellation()
      return response
    } catch {
      if activeOperation?.exchangeID == exchangeID,
        let reason = activeOperation?.terminationReason {
        throw reason.error
      }
      guard error is CancellationError || error as? CopilotXPCError == .operationCancelled else {
        // Invalidating the NSXPC connection is the transport-level fence for
        // an explicit cancel. That invalidation is reported by the concrete
        // XPC client as helper-unavailable, even though this exact exchange
        // was deliberately terminated. Do not widen this normalization to
        // unrelated helper failures.
        throw error
      }
      // Both task cancellation and XPC's normalized cancellation error must
      // synchronously fence the active helper. Keeping a per-exchange token
      // prevents an old queued onCancel from terminating a newer retry.
      await cancelRunningProcess(matching: exchangeID, reason: .callerCancelled)
      throw CopilotXPCError.operationCancelled
    }
  }

  private func readResponse<Response: Decodable & CopilotResponseContaining & Sendable>(
    payload: CopilotOwnedPayload,
    request: CopilotRequestHeader,
    expectedStatus: CopilotResponseStatus,
    timeout: TimeInterval?,
    exchangeID: UUID
  ) async throws -> Response {
    if let timeout {
      return try await withThrowingTaskGroup(of: Response.self) { group in
        group.addTask {
          try await self.performExchange(
            payload: payload,
            request: request,
            expectedStatus: expectedStatus
          )
        }
        group.addTask {
          try await self.waitForTimeout(timeout)
          throw CopilotXPCError.operationTimedOut
        }
        do {
          guard let result = try await group.next() else {
            throw CopilotXPCError.helperUnavailable
          }
          group.cancelAll()
          return result
        } catch {
          group.cancelAll()
          if error as? CopilotXPCError == .operationTimedOut {
            await self.cancelRunningProcess(matching: exchangeID, reason: .timedOut)
          }
          throw error
        }
      }
    }
    return try await performExchange(
      payload: payload,
      request: request,
      expectedStatus: expectedStatus
    )
  }

  private func performExchange<Response: Decodable & CopilotResponseContaining & Sendable>(
    payload: CopilotOwnedPayload,
    request: CopilotRequestHeader,
    expectedStatus: CopilotResponseStatus
  ) async throws -> Response {
    guard var requestBytes = payload.take() else {
      throw CopilotXPCError.malformedFrame
    }
    defer {
      requestBytes.resetBytes(in: requestBytes.startIndex..<requestBytes.endIndex)
      requestBytes.removeAll(keepingCapacity: false)
    }
    try await transport.writeFrame(requestBytes)
    let responseData = try await transport.readFrame(
      maximumBytes: CopilotIPC.maximumResponseBytes
    )
    try CopilotWireSchema.validate(responseData, expectedStatus: expectedStatus)
    let wireResponse = try CopilotJSONCodec.decode(CopilotWireResponse.self, from: responseData)
    if let failure = wireResponse.failure {
      try validate(failureResponse: wireResponse, for: request)
      throw CopilotXPCError.helperFailure(failure)
    }
    let response = try CopilotJSONCodec.decode(Response.self, from: responseData)
    try validate(response: response, for: request, expectedStatus: expectedStatus)
    return response
  }

  private func validate(_ header: CopilotRequestHeader) throws {
    guard header.protocolVersion == CopilotIPC.version else {
      throw CopilotXPCError.invalidProtocolVersion
    }
    guard Self.isCanonicalOpaqueAccountID(header.accountID) else {
      throw CopilotXPCError.invalidAccountID
    }
  }

  /// Terminates only the local exchange whose cancellation or deadline
  /// triggered this request. The XPC transport cannot be reopened after
  /// termination, so a current-operation cancellation is terminal; a delayed
  /// stale handler is a no-op and cannot shut down a newer retry.
  private func terminateActiveOperation(
    matching exchangeID: UUID,
    reason: TerminationReason
  ) async {
    guard var activeOperation,
      activeOperation.exchangeID == exchangeID,
      !activeOperation.isTerminating
    else { return }
    activeOperation.isTerminating = true
    activeOperation.terminationReason = reason
    self.activeOperation = activeOperation
    isShutDown = true
    await transport.terminate()
  }

  /// The test-visible cancellation entry point intentionally accepts the
  /// local exchange token, rather than a reusable protocol request ID.
  private func cancelRunningProcess(
    matching exchangeID: UUID,
    reason: TerminationReason
  ) async {
    await terminateActiveOperation(matching: exchangeID, reason: reason)
  }

  /// The test-visible cancellation entry point intentionally accepts the
  /// local exchange token, rather than a reusable protocol request ID.
  func cancelRunningProcess(matching exchangeID: UUID) async {
    await cancelRunningProcess(matching: exchangeID, reason: .callerCancelled)
  }

  private func validate<Response: CopilotResponseContaining>(
    response: Response,
    for request: CopilotRequestHeader,
    expectedStatus: CopilotResponseStatus
  ) throws {
    let header = response.header
    guard header.protocolVersion == CopilotIPC.version else {
      throw CopilotXPCError.invalidProtocolVersion
    }
    guard header.status == expectedStatus,
      header.requestID == request.requestID,
      header.accountID == request.accountID,
      header.organizationID == request.organizationID,
      header.failure == nil
    else {
      throw CopilotXPCError.responseMismatch
    }
  }

  /// Helper failures are still untrusted frames. They must echo the exact
  /// exchange before callers can observe their code or message; otherwise a
  /// stale or cross-account failure could be attributed to current work.
  private func validate(failureResponse: CopilotWireResponse, for request: CopilotRequestHeader) throws {
    guard failureResponse.protocolVersion == CopilotIPC.version else {
      throw CopilotXPCError.invalidProtocolVersion
    }
    guard failureResponse.status == .failure,
      failureResponse.requestID == request.requestID,
      failureResponse.accountID == request.accountID,
      failureResponse.organizationID == request.organizationID
    else {
      throw CopilotXPCError.responseMismatch
    }
  }

  private static func isCanonicalOpaqueAccountID(_ accountID: AccountID) -> Bool {
    guard let value = UUID(uuidString: accountID.rawValue) else { return false }
    return value.uuidString.lowercased() == accountID.rawValue
  }
}

private protocol CopilotRequestContaining {
  var header: CopilotRequestHeader { get }
}

extension CopilotHealthRequest: CopilotRequestContaining {}
extension CopilotModelsRequest: CopilotRequestContaining {}
extension CopilotAnalyzeRequest: CopilotRequestContaining {}
extension CopilotCancelRequest: CopilotRequestContaining {}
extension CopilotShutdownRequest: CopilotRequestContaining {}

private protocol CopilotResponseContaining {
  var header: CopilotResponseHeader { get }
}

extension CopilotHealthResponse: CopilotResponseContaining {}
extension CopilotAuthenticationResponse: CopilotResponseContaining {}
extension CopilotModelsResponse: CopilotResponseContaining {}
extension CopilotAnalysisResponse: CopilotResponseContaining {}
extension CopilotCancelResponse: CopilotResponseContaining {}
extension CopilotShutdownResponse: CopilotResponseContaining {}

private enum CopilotJSONCodec {
  static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(Value.self, from: data)
    } catch {
      throw CopilotXPCError.invalidResponse
    }
  }
}

/// A single-use frame payload. `take()` transfers its only mutable buffer to
/// the transport call, so timeout and cancellation cannot leave another
/// app-owned alias containing an authentication credential.
private final class CopilotOwnedPayload: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data

  init(copying source: Data) {
    storage = source.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return Data() }
      return Data(bytes: baseAddress, count: bytes.count)
    }
  }

  deinit { wipe() }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage.count
  }

  func take() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard !storage.isEmpty else { return nil }
    let value = storage
    storage.removeAll(keepingCapacity: false)
    return value
  }

  private func wipe() {
    lock.lock()
    defer { lock.unlock() }
    guard !storage.isEmpty else { return }
    storage.resetBytes(in: storage.startIndex..<storage.endIndex)
    storage.removeAll(keepingCapacity: false)
  }
}

private enum CopilotAuthenticationRequestEncoder {
  static func encode(_ request: CopilotAuthenticateRequest) throws -> CopilotOwnedPayload {
    // `wireRequest` is the top-level v2 header object. Keeping the wrapper
    // itself non-Codable prevents authentication from accidentally entering
    // a generic serializer that could retain the credential as a String.
    var payload = try CopilotJSONCodec.encode(request.header.wireRequest)
    defer {
      payload.resetBytes(in: payload.startIndex..<payload.endIndex)
      payload.removeAll(keepingCapacity: false)
    }
    guard payload.popLast() == 0x7d else { throw CopilotXPCError.malformedFrame }
    // `,"credential":` in bytes. Keeping this non-secret structural text
    // out of a Swift String prevents accidental interpolation with the value.
    payload.append(contentsOf: [
      0x2c, 0x22, 0x63, 0x72, 0x65, 0x64, 0x65,
      0x6e, 0x74, 0x69, 0x61, 0x6c, 0x22, 0x3a,
    ])
    try request.credential.appendJSONString(to: &payload)
    payload.append(0x7d)
    return CopilotOwnedPayload(copying: payload)
  }
}

private enum CopilotWireSchema {
  static func validate(_ data: Data, expectedStatus: CopilotResponseStatus) throws {
    guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
      let object = jsonObject as? [String: Any]
    else {
      throw CopilotXPCError.invalidResponse
    }
    let commonFields: Set<String> = [
      "protocol_version",
      "request_id",
      "account_id",
      "organization_id",
      "status",
      "failure",
    ]
    guard let statusValue = object["status"] as? String,
      let actualStatus = CopilotResponseStatus(rawValue: statusValue)
    else {
      throw CopilotXPCError.invalidResponse
    }
    let operationFields: Set<String>
    switch actualStatus {
    case .failure:
      // A failure envelope carries only its bound header and failure detail.
      // Do not permit a stale success payload to piggyback on an error frame.
      operationFields = []
    default:
      switch expectedStatus {
    case .health:
      operationFields = ["health"]
    case .authentication:
      operationFields = ["authentication"]
    case .models:
      operationFields = ["models"]
    case .analysis:
      operationFields = [
        "summary",
        "state",
        "confidence",
        "evidence_ids",
        "action_items",
        "next_action",
        "model_id",
        "prompt_provenance",
      ]
    case .cancelled:
      operationFields = ["cancelled_request_id"]
    case .shutdown:
      operationFields = []
    case .failure:
      operationFields = []
      }
    }
    guard Set(object.keys).isSubset(of: commonFields.union(operationFields)) else {
      throw CopilotXPCError.invalidResponse
    }
    if actualStatus == .analysis, expectedStatus == .analysis {
      try validateAnalysis(object)
    }
  }

  private static func validateAnalysis(_ object: [String: Any]) throws {
    guard let actions = object["action_items"] as? [[String: Any]],
      actions.count <= 128
    else { throw CopilotXPCError.invalidResponse }
    let permittedActionFields: Set<String> = [
      "id", "text", "confidence", "evidence_ids", "deadline", "claims",
    ]
    let permittedClaimFields: Set<String> = [
      "evidence_id", "actor_role", "timestamp", "quoted_span", "deterministic_reason_id",
    ]
    for action in actions {
      guard Set(action.keys).isSubset(of: permittedActionFields),
        action["id"] is String,
        action["text"] is String,
        action["confidence"] is NSNumber,
        action["evidence_ids"] is [String],
        let claims = action["claims"] as? [[String: Any]],
        claims.count <= 128
      else { throw CopilotXPCError.invalidResponse }
      for claim in claims {
        guard Set(claim.keys).isSubset(of: permittedClaimFields),
          claim["evidence_id"] is String,
          claim["actor_role"] is String,
          claim["timestamp"] is String,
          claim["quoted_span"] is String,
          claim["deterministic_reason_id"] is String
        else { throw CopilotXPCError.invalidResponse }
      }
    }
  }
}
