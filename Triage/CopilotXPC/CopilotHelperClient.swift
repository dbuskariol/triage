import Foundation

actor CopilotHelperClient: TriageCopilotHelping {
  private struct ActiveOperation: Sendable {
    let requestID: UUID
    let organizationID: OrganizationID
    let operation: CopilotOperation
  }

  private let transport: any CopilotFrameTransport
  private var activeOperation: ActiveOperation?
  private var isShutDown = false

  init(transport: any CopilotFrameTransport) {
    self.transport = transport
  }

  func health(_ request: CopilotHealthRequest) async throws -> CopilotHealthResponse {
    let response: CopilotHealthResponse = try await exchange(
      request,
      expectedStatus: .health,
      timeout: nil
    )
    return response
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
    return response
  }

  func cancel(_ request: CopilotCancelRequest) async throws -> CopilotCancelResponse {
    guard let activeOperation,
      activeOperation.requestID == request.targetRequestID,
      activeOperation.organizationID == request.header.organizationID,
      activeOperation.operation == .analyze
    else {
      throw CopilotXPCError.noActiveAnalysis
    }
    // A pipe has one response reader. Termination safely interrupts it; the
    // XPC service will own protocol-level cancellation dispatch.
    isShutDown = true
    await transport.terminate()
    return CopilotCancelResponse(
      header: CopilotResponseHeader(
        requestID: request.header.requestID,
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
    guard !isShutDown else { throw CopilotXPCError.shutDown }
    guard activeOperation == nil else { throw CopilotXPCError.operationInProgress }
    try validate(request.header)

    activeOperation = ActiveOperation(
      requestID: request.header.requestID,
      organizationID: request.header.organizationID,
      operation: request.header.operation
    )
    defer {
      activeOperation = nil
    }

    let payload = try CopilotJSONCodec.encode(request)
    guard payload.count <= CopilotIPC.maximumRequestBytes else {
      throw CopilotFrameError.payloadTooLarge
    }

    return try await withTaskCancellationHandler {
      try await readResponse(
        payload: payload,
        request: request.header,
        expectedStatus: expectedStatus,
        timeout: timeout
      )
    } onCancel: {
      Task {
        await self.cancelRunningProcess()
      }
    }
  }

  private func readResponse<Response: Decodable & CopilotResponseContaining & Sendable>(
    payload: Data,
    request: CopilotRequestHeader,
    expectedStatus: CopilotResponseStatus,
    timeout: TimeInterval?
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
          try await Task.sleep(for: .seconds(timeout))
          await self.cancelRunningProcess()
          throw CopilotXPCError.operationTimedOut
        }
        guard let result = try await group.next() else {
          throw CopilotXPCError.helperUnavailable
        }
        group.cancelAll()
        return result
      }
    }
    return try await performExchange(
      payload: payload,
      request: request,
      expectedStatus: expectedStatus
    )
  }

  private func performExchange<Response: Decodable & CopilotResponseContaining & Sendable>(
    payload: Data,
    request: CopilotRequestHeader,
    expectedStatus: CopilotResponseStatus
  ) async throws -> Response {
    try await transport.writeFrame(payload)
    let responseData = try await transport.readFrame(
      maximumBytes: CopilotIPC.maximumResponseBytes
    )
    try CopilotWireSchema.validate(responseData, expectedStatus: expectedStatus)
    let wireResponse = try CopilotJSONCodec.decode(CopilotWireResponse.self, from: responseData)
    if let failure = wireResponse.failure {
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
  }

  private func cancelRunningProcess() async {
    isShutDown = true
    await transport.terminate()
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
      header.organizationID == request.organizationID,
      header.failure == nil
    else {
      throw CopilotXPCError.responseMismatch
    }
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
      "organization_id",
      "status",
      "failure",
    ]
    let operationFields: Set<String>
    switch expectedStatus {
    case .health:
      operationFields = ["health"]
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
    guard Set(object.keys).isSubset(of: commonFields.union(operationFields)) else {
      throw CopilotXPCError.invalidResponse
    }
  }
}
