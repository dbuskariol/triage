import Foundation

protocol CopilotXPCFrameService: Sendable {
  func exchange(frame: Data) async throws -> Data
  func invalidate() async
}

enum CopilotXPCError: Error, Equatable, Sendable {
  case invalidProtocolVersion
  case invalidResponse
  case responseMismatch
  case helperFailure(CopilotFailure)
  case helperUnavailable
  case helperLocationInvalid
  case helperNotExecutable
  case codeSignatureNotValidated
  case processLaunchFailed
  case processExited
  case operationInProgress
  case noActiveAnalysis
  case operationCancelled
  case operationTimedOut
  case shutDown
  case malformedFrame
  case responseTooLarge
  case invalidAnalysis
}

struct CopilotRequestHeader: Equatable, Sendable {
  let protocolVersion: Int
  let requestID: UUID
  let organizationID: OrganizationID
  let operation: CopilotOperation

  init(
    organizationID: OrganizationID,
    operation: CopilotOperation,
    requestID: UUID = UUID()
  ) {
    protocolVersion = CopilotIPC.version
    self.requestID = requestID
    self.organizationID = organizationID
    self.operation = operation
  }

  init(wireRequest: CopilotWireRequest) {
    protocolVersion = wireRequest.protocolVersion
    requestID = wireRequest.requestID
    organizationID = wireRequest.organizationID
    operation = wireRequest.operation
  }

  var wireRequest: CopilotWireRequest {
    CopilotWireRequest(
      protocolVersion: protocolVersion,
      requestID: requestID,
      organizationID: organizationID,
      operation: operation
    )
  }
}

struct CopilotHealthRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader

  init(organizationID: OrganizationID, requestID: UUID = UUID()) {
    header = CopilotRequestHeader(
      organizationID: organizationID,
      operation: .health,
      requestID: requestID
    )
  }

  init(from decoder: any Decoder) throws {
    header = try CopilotRequestHeader(from: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    try header.encode(to: encoder)
  }
}

struct CopilotModelsRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader

  init(organizationID: OrganizationID, requestID: UUID = UUID()) {
    header = CopilotRequestHeader(
      organizationID: organizationID,
      operation: .models,
      requestID: requestID
    )
  }

  init(from decoder: any Decoder) throws {
    header = try CopilotRequestHeader(from: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    try header.encode(to: encoder)
  }
}

struct CopilotAnalysisInput: Codable, Equatable, Sendable {
  let candidateID: AIRequestID
  let workItemTitle: String
  let workItemState: String
  let deterministicReasons: [String]
  let body: String
  let conversation: [CopilotConversationExcerpt]
  let evidenceIDs: [EvidenceID]

  enum CodingKeys: String, CodingKey {
    case candidateID = "candidate_id"
    case workItemTitle = "work_item_title"
    case workItemState = "work_item_state"
    case deterministicReasons = "deterministic_reasons"
    case body, conversation
    case evidenceIDs = "evidence_ids"
  }

  func validate() throws {
    guard !workItemTitle.isEmpty,
      !workItemState.isEmpty,
      !deterministicReasons.isEmpty,
      Set(evidenceIDs).count == evidenceIDs.count,
      workItemTitle.utf8.count <= 4_096,
      workItemState.utf8.count <= 256,
      body.utf8.count <= 65_536,
      deterministicReasons.allSatisfy({ $0.utf8.count <= 1_024 }),
      conversation.allSatisfy({
        !$0.authorRole.isEmpty
          && $0.authorRole.utf8.count <= 256
          && $0.text.utf8.count <= 32_768
      })
    else {
      throw CopilotXPCError.invalidAnalysis
    }
  }
}

struct CopilotConversationExcerpt: Codable, Equatable, Sendable {
  let evidenceID: EvidenceID
  let authorRole: String
  let text: String
  let timestamp: Date

  enum CodingKeys: String, CodingKey {
    case evidenceID = "evidence_id"
    case authorRole = "author_role"
    case text, timestamp
  }
}

struct CopilotAnalyzeRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader
  let modelID: String?
  let input: CopilotAnalysisInput
  let deadline: Date

  init(
    organizationID: OrganizationID,
    input: CopilotAnalysisInput,
    modelID: String? = nil,
    deadline: Date,
    requestID: UUID = UUID()
  ) {
    header = CopilotRequestHeader(
      organizationID: organizationID,
      operation: .analyze,
      requestID: requestID
    )
    self.modelID = modelID
    self.input = input
    self.deadline = deadline
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotRequestHeader(container: container)
    modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    input = try container.decode(CopilotAnalysisInput.self, forKey: .input)
    deadline = try container.decode(Date.self, forKey: .deadline)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encodeIfPresent(modelID, forKey: .modelID)
    try container.encode(input, forKey: .input)
    try container.encode(deadline, forKey: .deadline)
  }
}

struct CopilotCancelRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader
  let targetRequestID: UUID

  init(
    organizationID: OrganizationID,
    targetRequestID: UUID,
    requestID: UUID = UUID()
  ) {
    header = CopilotRequestHeader(
      organizationID: organizationID,
      operation: .cancel,
      requestID: requestID
    )
    self.targetRequestID = targetRequestID
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotRequestHeader(container: container)
    targetRequestID = try container.decode(UUID.self, forKey: .targetRequestID)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encode(targetRequestID, forKey: .targetRequestID)
  }
}

struct CopilotShutdownRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader

  init(organizationID: OrganizationID, requestID: UUID = UUID()) {
    header = CopilotRequestHeader(
      organizationID: organizationID,
      operation: .shutdown,
      requestID: requestID
    )
  }

  init(from decoder: any Decoder) throws {
    header = try CopilotRequestHeader(from: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    try header.encode(to: encoder)
  }
}

struct CopilotResponseHeader: Equatable, Sendable {
  let protocolVersion: Int
  let requestID: UUID?
  let organizationID: OrganizationID?
  let status: CopilotResponseStatus
  let failure: CopilotFailure?

  init(wireResponse: CopilotWireResponse) {
    protocolVersion = wireResponse.protocolVersion
    requestID = wireResponse.requestID
    organizationID = wireResponse.organizationID
    status = wireResponse.status
    failure = wireResponse.failure
  }

  init(
    requestID: UUID?,
    organizationID: OrganizationID?,
    status: CopilotResponseStatus,
    failure: CopilotFailure? = nil
  ) {
    protocolVersion = CopilotIPC.version
    self.requestID = requestID
    self.organizationID = organizationID
    self.status = status
    self.failure = failure
  }
}

struct CopilotHealthResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader
  let health: CopilotHealth

  init(header: CopilotResponseHeader, health: CopilotHealth) {
    self.header = header
    self.health = health
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotResponseHeader(container: container)
    health = try container.decode(CopilotHealth.self, forKey: .health)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encode(health, forKey: .health)
  }
}

struct CopilotModel: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let displayName: String
  let isDefault: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case isDefault = "is_default"
  }
}

struct CopilotModelsResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader
  let models: [CopilotModel]

  init(header: CopilotResponseHeader, models: [CopilotModel]) {
    self.header = header
    self.models = models
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotResponseHeader(container: container)
    models = try container.decode([CopilotModel].self, forKey: .models)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encode(models, forKey: .models)
  }
}

struct CopilotSuggestedActionItem: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let evidenceIDs: [EvidenceID]

  enum CodingKeys: String, CodingKey {
    case id, text
    case evidenceIDs = "evidence_ids"
  }
}

struct CopilotAnalysisResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader
  let summary: String
  let state: String
  let confidence: Double
  let evidenceIDs: [EvidenceID]
  let actionItems: [CopilotSuggestedActionItem]
  let nextAction: String?
  let modelID: String
  let promptProvenance: String

  init(
    header: CopilotResponseHeader,
    summary: String,
    state: String,
    confidence: Double,
    evidenceIDs: [EvidenceID],
    actionItems: [CopilotSuggestedActionItem],
    nextAction: String?,
    modelID: String,
    promptProvenance: String
  ) {
    self.header = header
    self.summary = summary
    self.state = state
    self.confidence = confidence
    self.evidenceIDs = evidenceIDs
    self.actionItems = actionItems
    self.nextAction = nextAction
    self.modelID = modelID
    self.promptProvenance = promptProvenance
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotResponseHeader(container: container)
    summary = try container.decode(String.self, forKey: .summary)
    state = try container.decode(String.self, forKey: .state)
    confidence = try container.decode(Double.self, forKey: .confidence)
    evidenceIDs = try container.decode([EvidenceID].self, forKey: .evidenceIDs)
    actionItems = try container.decode([CopilotSuggestedActionItem].self, forKey: .actionItems)
    nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
    modelID = try container.decode(String.self, forKey: .modelID)
    promptProvenance = try container.decode(String.self, forKey: .promptProvenance)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encode(summary, forKey: .summary)
    try container.encode(state, forKey: .state)
    try container.encode(confidence, forKey: .confidence)
    try container.encode(evidenceIDs, forKey: .evidenceIDs)
    try container.encode(actionItems, forKey: .actionItems)
    try container.encodeIfPresent(nextAction, forKey: .nextAction)
    try container.encode(modelID, forKey: .modelID)
    try container.encode(promptProvenance, forKey: .promptProvenance)
  }

  func validate(against input: CopilotAnalysisInput) throws {
    let permittedEvidenceIDs = Set(input.evidenceIDs)
    guard (0...1).contains(confidence),
      !summary.isEmpty,
      !state.isEmpty,
      !modelID.isEmpty,
      !promptProvenance.isEmpty,
      summary.utf8.count <= 16_384,
      state.utf8.count <= 256,
      nextAction?.utf8.count ?? 0 <= 8_192,
      !summary.contains("```"),
      !state.contains("```"),
      !(nextAction?.contains("```") ?? false),
      Set(evidenceIDs).count == evidenceIDs.count,
      Set(evidenceIDs).isSubset(of: permittedEvidenceIDs),
      Set(actionItems.map(\.id)).count == actionItems.count,
      actionItems.allSatisfy({
        !$0.id.isEmpty
          && !$0.text.isEmpty
          && $0.text.utf8.count <= 8_192
          && Set($0.evidenceIDs).count == $0.evidenceIDs.count
          && Set($0.evidenceIDs).isSubset(of: permittedEvidenceIDs)
      })
    else {
      throw CopilotXPCError.invalidAnalysis
    }
  }
}

struct CopilotCancelResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader
  let cancelledRequestID: UUID

  init(header: CopilotResponseHeader, cancelledRequestID: UUID) {
    self.header = header
    self.cancelledRequestID = cancelledRequestID
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotResponseHeader(container: container)
    cancelledRequestID = try container.decode(UUID.self, forKey: .cancelledRequestID)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encode(cancelledRequestID, forKey: .cancelledRequestID)
  }
}

struct CopilotShutdownResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader

  init(header: CopilotResponseHeader) {
    self.header = header
  }

  init(from decoder: any Decoder) throws {
    header = try CopilotResponseHeader(from: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    try header.encode(to: encoder)
  }
}

protocol TriageCopilotHelping: Sendable {
  func health(_ request: CopilotHealthRequest) async throws -> CopilotHealthResponse
  func models(_ request: CopilotModelsRequest) async throws -> CopilotModelsResponse
  func analyze(_ request: CopilotAnalyzeRequest) async throws -> CopilotAnalysisResponse
  func cancel(_ request: CopilotCancelRequest) async throws -> CopilotCancelResponse
  func shutdown(_ request: CopilotShutdownRequest) async throws -> CopilotShutdownResponse
}

private enum CopilotWireCodingKey: String, CodingKey {
  case protocolVersion = "protocol_version"
  case requestID = "request_id"
  case organizationID = "organization_id"
  case operation, status, failure, health, models
  case modelID = "model_id"
  case input, deadline, summary, state, confidence
  case evidenceIDs = "evidence_ids"
  case actionItems = "action_items"
  case nextAction = "next_action"
  case promptProvenance = "prompt_provenance"
  case targetRequestID = "target_request_id"
  case cancelledRequestID = "cancelled_request_id"
}

extension CopilotRequestHeader {
  fileprivate init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    try self.init(container: container)
  }

  fileprivate init(container: KeyedDecodingContainer<CopilotWireCodingKey>) throws {
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    requestID = try container.decode(UUID.self, forKey: .requestID)
    organizationID = try container.decode(OrganizationID.self, forKey: .organizationID)
    operation = try container.decode(CopilotOperation.self, forKey: .operation)
  }

  fileprivate func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try encode(to: &container)
  }

  fileprivate func encode(to container: inout KeyedEncodingContainer<CopilotWireCodingKey>) throws {
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(organizationID, forKey: .organizationID)
    try container.encode(operation, forKey: .operation)
  }
}

extension CopilotResponseHeader {
  fileprivate init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    try self.init(container: container)
  }

  fileprivate init(container: KeyedDecodingContainer<CopilotWireCodingKey>) throws {
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID)
    organizationID = try container.decodeIfPresent(OrganizationID.self, forKey: .organizationID)
    status = try container.decode(CopilotResponseStatus.self, forKey: .status)
    failure = try container.decodeIfPresent(CopilotFailure.self, forKey: .failure)
  }

  fileprivate func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try encode(to: &container)
  }

  fileprivate func encode(to container: inout KeyedEncodingContainer<CopilotWireCodingKey>) throws {
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encodeIfPresent(requestID, forKey: .requestID)
    try container.encodeIfPresent(organizationID, forKey: .organizationID)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(failure, forKey: .failure)
  }
}
