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
      // A device-code login waits for the person to complete browser consent.
      // Cancelling its task invalidates the XPC connection and reaps its
      // isolated helper process.
      timeout: request.credential == nil ? 330 : 60,
      payload: payload
    )
  }

  func models(_ request: CopilotModelsRequest) async throws -> CopilotModelsResponse {
    try await exchange(request, expectedStatus: .models, timeout: nil)
  }

  func triage(_ request: CopilotTriageRequest) async throws -> CopilotTriageResponse {
    let timeout = request.deadline.timeIntervalSinceNow
    guard timeout > 0 else { throw CopilotXPCError.operationTimedOut }
    try request.validate()
    let response: CopilotTriageResponse = try await exchange(request, expectedStatus: .triage, timeout: timeout)
    try response.validate(against: request)
    guard request.modelID == nil || response.modelID == request.modelID else { throw CopilotXPCError.invalidResponse }
    return response
  }

  func cancel(_ request: CopilotCancelRequest) async throws -> CopilotCancelResponse {
    guard let activeOperation,
      activeOperation.requestID == request.targetRequestID,
      activeOperation.accountID == request.header.accountID,
      activeOperation.organizationID == request.header.organizationID
    else {
      throw CopilotXPCError.noActiveOperation
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
extension CopilotTriageRequest: CopilotRequestContaining {}
extension CopilotCancelRequest: CopilotRequestContaining {}
extension CopilotShutdownRequest: CopilotRequestContaining {}

private protocol CopilotResponseContaining {
  var header: CopilotResponseHeader { get }
}

extension CopilotHealthResponse: CopilotResponseContaining {}
extension CopilotAuthenticationResponse: CopilotResponseContaining {}
extension CopilotModelsResponse: CopilotResponseContaining {}
extension CopilotTriageResponse: CopilotResponseContaining {}
extension CopilotCancelResponse: CopilotResponseContaining {}
extension CopilotShutdownResponse: CopilotResponseContaining {}

private enum CopilotJSONCodec {
  private static func fractionalSecondsFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  private static func legacyFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(fractionalSecondsFormatter().string(from: date))
    }
    return try encoder.encode(value)
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = fractionalSecondsFormatter().date(from: value)
        ?? legacyFormatter().date(from: value)
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected an ISO 8601 timestamp."
        )
      }
      return date
    }
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
    if let credential = request.credential {
      try credential.appendJSONString(to: &payload)
    } else {
      payload.append(contentsOf: "null".utf8)
    }
    payload.append(contentsOf: ",\"allow_browser\":".utf8)
    payload.append(contentsOf: (request.allowsBrowser ? "true" : "false").utf8)
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
    case .triage:
      operationFields = ["model_id", "decisions"]
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
    if actualStatus == .triage, expectedStatus == .triage { try validateTriage(object) }
  }



  private static func validateTriage(_ object: [String: Any]) throws {
    guard let model = object["model_id"] as? String, !model.isEmpty,
      let decisions = object["decisions"] as? [[String: Any]], (1...20).contains(decisions.count) else { throw CopilotXPCError.invalidResponse }
    let fields: Set<String> = ["id", "disposition", "priority", "confidence", "summary", "reason", "next_action"]
    var ids = Set<String>()
    for decision in decisions {
      guard Set(decision.keys).isSubset(of: fields), let id = decision["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
        let disposition = decision["disposition"] as? String, ["act", "review", "wait", "none"].contains(disposition),
        let priority = decision["priority"] as? NSNumber, CFGetTypeID(priority) != CFBooleanGetTypeID(), priority.doubleValue.rounded() == priority.doubleValue, (0...100).contains(priority.doubleValue),
        let confidence = decision["confidence"] as? NSNumber, CFGetTypeID(confidence) != CFBooleanGetTypeID(), confidence.doubleValue.isFinite, (0...1).contains(confidence.doubleValue),
        let summary = decision["summary"] as? String, !summary.isEmpty, summary.utf8.count <= 280,
        let reason = decision["reason"] as? String, !reason.isEmpty, reason.utf8.count <= 400,
        decision["next_action"] == nil || decision["next_action"] is String || decision["next_action"] is NSNull,
        (decision["next_action"] as? String)?.utf8.count ?? 0 <= 200 else { throw CopilotXPCError.invalidResponse }
    }
  }


}
