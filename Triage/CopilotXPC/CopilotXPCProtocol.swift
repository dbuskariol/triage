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
  case invalidAccountID
  case runtimeUnavailable
  case runtimeCorrupt
}

struct CopilotRequestHeader: Equatable, Sendable {
  let protocolVersion: Int
  let requestID: UUID
  let accountID: AccountID
  let organizationID: OrganizationID
  let operation: CopilotOperation

  init(
    accountID: AccountID,
    organizationID: OrganizationID,
    operation: CopilotOperation,
    requestID: UUID = UUID()
  ) {
    protocolVersion = CopilotIPC.version
    self.requestID = requestID
    self.accountID = accountID
    self.organizationID = organizationID
    self.operation = operation
  }

  init(wireRequest: CopilotWireRequest) {
    protocolVersion = wireRequest.protocolVersion
    requestID = wireRequest.requestID
    accountID = wireRequest.accountID
    organizationID = wireRequest.organizationID
    operation = wireRequest.operation
  }

  var wireRequest: CopilotWireRequest {
    CopilotWireRequest(
      protocolVersion: protocolVersion,
      requestID: requestID,
      accountID: accountID,
      organizationID: organizationID,
      operation: operation
    )
  }
}

struct CopilotHealthRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader

  init(accountID: AccountID, organizationID: OrganizationID, requestID: UUID = UUID()) {
    header = CopilotRequestHeader(
      accountID: accountID,
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

  init(accountID: AccountID, organizationID: OrganizationID, requestID: UUID = UUID()) {
    header = CopilotRequestHeader(
      accountID: accountID,
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

/// Exclusive owner for a UTF-8 credential during one Copilot authentication
/// exchange. It deliberately never exposes a `String`, is redacted in every
/// diagnostic representation, and clears its mutable bytes when consumed or
/// discarded. Foundation/XPC may make boundary copies while marshalling the
/// final frame; the caller-owned buffer is still wiped before that handoff
/// begins.
final class CopilotEphemeralCredential: @unchecked Sendable, CustomStringConvertible {
  private let lock = NSLock()
  private var storage: Data

  init(copying bytes: Data) {
    storage = bytes.withUnsafeBytes { rawBytes in
      guard let baseAddress = rawBytes.baseAddress else { return Data() }
      return Data(bytes: baseAddress, count: rawBytes.count)
    }
  }

  deinit { wipe() }

  var description: String { "<redacted>" }

  /// Appends a JSON string without materializing the credential as a Swift
  /// `String`. This consumes and wipes the credential even when framing fails.
  func appendJSONString(to destination: inout Data) throws {
    lock.lock()
    defer {
      wipeLocked()
      lock.unlock()
    }
    guard !storage.isEmpty else { throw CopilotXPCError.malformedFrame }

    destination.append(0x22)
    for byte in storage {
      switch byte {
      case 0x22:
        destination.append(contentsOf: [0x5c, 0x22])
      case 0x5c:
        destination.append(contentsOf: [0x5c, 0x5c])
      case 0x08:
        destination.append(contentsOf: [0x5c, 0x62])
      case 0x0c:
        destination.append(contentsOf: [0x5c, 0x66])
      case 0x0a:
        destination.append(contentsOf: [0x5c, 0x6e])
      case 0x0d:
        destination.append(contentsOf: [0x5c, 0x72])
      case 0x09:
        destination.append(contentsOf: [0x5c, 0x74])
      case 0x00...0x1f:
        destination.append(contentsOf: [0x5c, 0x75, 0x30, 0x30])
        let digits = Array("0123456789abcdef".utf8)
        destination.append(digits[Int(byte >> 4)])
        destination.append(digits[Int(byte & 0x0f)])
      default:
        destination.append(byte)
      }
    }
    destination.append(0x22)
  }

  func wipe() {
    lock.lock()
    wipeLocked()
    lock.unlock()
  }

  var isWipedForTesting: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage.isEmpty
  }

  private func wipeLocked() {
    guard !storage.isEmpty else { return }
    storage.resetBytes(in: storage.startIndex..<storage.endIndex)
    storage.removeAll(keepingCapacity: false)
  }
}

/// This request exists only in an in-memory, length-framed XPC exchange.
/// Callers must never serialize it to disk, diagnostics, command arguments,
/// or a process environment. The Rust helper zeroizes its frame credential.
struct CopilotAuthenticateRequest: Sendable, CustomStringConvertible {
  let header: CopilotRequestHeader
  let credential: CopilotEphemeralCredential

  init(
    accountID: AccountID,
    organizationID: OrganizationID,
    credential: CopilotEphemeralCredential,
    requestID: UUID = UUID()
  ) {
    header = CopilotRequestHeader(accountID: accountID, organizationID: organizationID, operation: .authenticate, requestID: requestID)
    self.credential = credential
  }

  var description: String {
    "CopilotAuthenticateRequest(header: \(header), credential: <redacted>)"
  }
}

struct CopilotAnalysisInput: Codable, Equatable, Sendable {
  let candidateID: AIRequestID
  /// Every byte originating outside the vault's local workflow is untrusted.
  /// The helper must not treat titles, conversation, labels, or evidence as
  /// instructions to alter its fixed schema or tool policy.
  let contentIsUntrusted: Bool
  let workItemTitle: String
  let workItemState: String
  let deterministicReasons: [String]
  let body: String
  let labels: [String]
  let projectFields: [String: String]
  let conversation: [CopilotConversationExcerpt]
  let evidence: [CopilotEvidenceExcerpt]
  let evidenceIDs: [EvidenceID]

  enum CodingKeys: String, CodingKey {
    case candidateID = "candidate_id"
    case contentIsUntrusted = "content_is_untrusted"
    case workItemTitle = "work_item_title"
    case workItemState = "work_item_state"
    case deterministicReasons = "deterministic_reasons"
    case body, labels, conversation, evidence
    case projectFields = "project_fields"
    case evidenceIDs = "evidence_ids"
  }

  init(
    candidateID: AIRequestID,
    contentIsUntrusted: Bool = true,
    workItemTitle: String,
    workItemState: String,
    deterministicReasons: [String],
    body: String,
    labels: [String] = [],
    projectFields: [String: String] = [:],
    conversation: [CopilotConversationExcerpt],
    evidence: [CopilotEvidenceExcerpt]? = nil,
    evidenceIDs: [EvidenceID]
  ) {
    self.candidateID = candidateID
    self.contentIsUntrusted = contentIsUntrusted
    self.workItemTitle = workItemTitle
    self.workItemState = workItemState
    self.deterministicReasons = deterministicReasons
    self.body = body
    self.labels = labels
    self.projectFields = projectFields
    self.conversation = conversation
    // Compatibility for in-memory fixture callers. Production uses the
    // explicit source-backed table assembled by `CopilotCandidateInputBuilder`;
    // an empty compatibility excerpt can never authorize auto-entry.
    self.evidence = evidence ?? evidenceIDs.map {
      CopilotEvidenceExcerpt(
        id: $0,
        actorRole: "source:unknown",
        text: "",
        timestamp: .distantPast,
        explicitDeadline: nil
      )
    }
    self.evidenceIDs = evidenceIDs
  }

  func validate() throws {
    guard contentIsUntrusted,
      !workItemTitle.isEmpty,
      !workItemState.isEmpty,
      !deterministicReasons.isEmpty,
      Set(deterministicReasons).count == deterministicReasons.count,
      Set(evidenceIDs).count == evidenceIDs.count,
      evidence.count <= 128,
      labels.count <= 64,
      projectFields.count <= 64,
      workItemTitle.utf8.count <= 4_096,
      workItemState.utf8.count <= 256,
      body.utf8.count <= 65_536,
      labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
      Set(labels).count == labels.count,
      projectFields.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 512 && $0.value.utf8.count <= 2_048 }),
      deterministicReasons.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
      conversation.allSatisfy({
        !$0.authorRole.isEmpty
          && $0.authorRole.utf8.count <= 256
          && $0.text.utf8.count <= 32_768
          && evidenceIDs.contains($0.evidenceID)
          && $0.timestamp.timeIntervalSinceReferenceDate.isFinite
      }),
      Set(evidence.map(\.id)).count == evidence.count,
      Set(evidence.map(\.id)) == Set(evidenceIDs),
      evidence.allSatisfy({
        !$0.actorRole.isEmpty
          && $0.actorRole.utf8.count <= 256
          && $0.text.utf8.count <= 8_192
          && $0.timestamp.timeIntervalSinceReferenceDate.isFinite
          && ($0.explicitDeadline?.timeIntervalSinceReferenceDate.isFinite ?? true)
      })
    else {
      throw CopilotXPCError.invalidAnalysis
    }
  }
}

/// The fixed evidence table is the only source context a response may cite.
/// `explicitDeadline` is intentionally absent unless normalization identified
/// it as a source fact; the helper cannot invent one from prose.
struct CopilotEvidenceExcerpt: Codable, Equatable, Sendable {
  let id: EvidenceID
  let actorRole: String
  let text: String
  let timestamp: Date
  let explicitDeadline: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case actorRole = "actor_role"
    case text, timestamp
    case explicitDeadline = "explicit_deadline"
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
    accountID: AccountID,
    organizationID: OrganizationID,
    input: CopilotAnalysisInput,
    modelID: String? = nil,
    deadline: Date,
    requestID: UUID = UUID()
  ) {
    header = CopilotRequestHeader(
      accountID: accountID,
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
    accountID: AccountID,
    organizationID: OrganizationID,
    targetRequestID: UUID,
    requestID: UUID = UUID()
  ) {
    header = CopilotRequestHeader(
      accountID: accountID,
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

  init(accountID: AccountID, organizationID: OrganizationID, requestID: UUID = UUID()) {
    header = CopilotRequestHeader(
      accountID: accountID,
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
  let accountID: AccountID?
  let organizationID: OrganizationID?
  let status: CopilotResponseStatus
  let failure: CopilotFailure?

  init(wireResponse: CopilotWireResponse) {
    protocolVersion = wireResponse.protocolVersion
    requestID = wireResponse.requestID
    accountID = wireResponse.accountID
    organizationID = wireResponse.organizationID
    status = wireResponse.status
    failure = wireResponse.failure
  }

  init(
    requestID: UUID?,
    accountID: AccountID?,
    organizationID: OrganizationID?,
    status: CopilotResponseStatus,
    failure: CopilotFailure? = nil
  ) {
    protocolVersion = CopilotIPC.version
    self.requestID = requestID
    self.accountID = accountID
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

struct CopilotAuthenticationResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader
  let authentication: CopilotAuthentication

  init(header: CopilotResponseHeader, authentication: CopilotAuthentication) {
    self.header = header
    self.authentication = authentication
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try CopilotResponseHeader(container: container)
    authentication = try container.decode(CopilotAuthentication.self, forKey: .authentication)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &container)
    try container.encode(authentication, forKey: .authentication)
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

/// A source-grounded assertion made by an action suggestion.  Claims are
/// optional for review-only output, but are deliberately structured so the
/// app can independently reject an automatic action that does not exactly
/// match its current, bounded evidence table.
struct CopilotActionClaim: Codable, Equatable, Sendable {
  let evidenceID: EvidenceID
  let actorRole: String
  let timestamp: Date
  let quotedSpan: String
  let deterministicReasonID: String

  enum CodingKeys: String, CodingKey {
    case evidenceID = "evidence_id"
    case actorRole = "actor_role"
    case timestamp
    case quotedSpan = "quoted_span"
    case deterministicReasonID = "deterministic_reason_id"
  }

  init(
    evidenceID: EvidenceID,
    actorRole: String,
    timestamp: Date,
    quotedSpan: String,
    deterministicReasonID: String
  ) {
    self.evidenceID = evidenceID
    self.actorRole = actorRole
    self.timestamp = timestamp
    self.quotedSpan = quotedSpan
    self.deterministicReasonID = deterministicReasonID
  }
}

struct CopilotSuggestedActionItem: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let confidence: Double
  let evidenceIDs: [EvidenceID]
  let deadline: Date?
  /// Empty claims keep an otherwise valid semantic result review-only.
  let claims: [CopilotActionClaim]

  enum CodingKeys: String, CodingKey {
    case id, text, confidence, deadline, claims
    case evidenceIDs = "evidence_ids"
  }

  init(
    id: String,
    text: String,
    confidence: Double = 0,
    evidenceIDs: [EvidenceID],
    deadline: Date? = nil,
    claims: [CopilotActionClaim] = []
  ) {
    self.id = id
    self.text = text
    self.confidence = confidence
    self.evidenceIDs = evidenceIDs
    self.deadline = deadline
    self.claims = claims
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
    let evidenceByID = Dictionary(uniqueKeysWithValues: input.evidence.map { ($0.id, $0) })
    let permittedReasons = Set(input.deterministicReasons)
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
      actionItems.allSatisfy({ action in
        !action.id.isEmpty
          && !action.text.isEmpty
          && action.text.utf8.count <= 8_192
          && !action.text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
          && (0...1).contains(action.confidence)
          && (action.deadline?.timeIntervalSinceReferenceDate.isFinite ?? true)
          && Set(action.evidenceIDs).count == action.evidenceIDs.count
          && Set(action.evidenceIDs).isSubset(of: permittedEvidenceIDs)
          && (action.deadline == nil || action.evidenceIDs.contains { evidenceID in
            input.evidence.first(where: { $0.id == evidenceID })?.explicitDeadline == action.deadline
          })
          // A semantic-only response may carry no claims and remains
          // review-only. Any claim it does provide must be exact evidence,
          // not a model-supplied paraphrase or attribution.
          && Set(action.claims.map(\.evidenceID)).count == action.claims.count
          && action.claims.allSatisfy({ claim in
            guard let evidence = evidenceByID[claim.evidenceID] else { return false }
            return action.evidenceIDs.contains(claim.evidenceID)
              && !claim.actorRole.isEmpty
              && claim.actorRole.utf8.count <= 256
              && claim.actorRole == evidence.actorRole
              && claim.timestamp.timeIntervalSinceReferenceDate.isFinite
              && claim.timestamp == evidence.timestamp
              && !claim.quotedSpan.isEmpty
              && claim.quotedSpan.utf8.count <= 8_192
              && !claim.quotedSpan.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
              && evidence.text.contains(claim.quotedSpan)
              && !claim.deterministicReasonID.isEmpty
              && claim.deterministicReasonID.utf8.count <= 1_024
              && permittedReasons.contains(claim.deterministicReasonID)
          })
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
  func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse
  func models(_ request: CopilotModelsRequest) async throws -> CopilotModelsResponse
  func analyze(_ request: CopilotAnalyzeRequest) async throws -> CopilotAnalysisResponse
  func cancel(_ request: CopilotCancelRequest) async throws -> CopilotCancelResponse
  func shutdown(_ request: CopilotShutdownRequest) async throws -> CopilotShutdownResponse
}

private enum CopilotWireCodingKey: String, CodingKey {
  case protocolVersion = "protocol_version"
  case requestID = "request_id"
  case accountID = "account_id"
  case organizationID = "organization_id"
  case operation, status, failure, health, authentication, models, credential
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
    accountID = try container.decode(AccountID.self, forKey: .accountID)
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
    try container.encode(accountID, forKey: .accountID)
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
    accountID = try container.decodeIfPresent(AccountID.self, forKey: .accountID)
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
    try container.encodeIfPresent(accountID, forKey: .accountID)
    try container.encodeIfPresent(organizationID, forKey: .organizationID)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(failure, forKey: .failure)
  }
}
