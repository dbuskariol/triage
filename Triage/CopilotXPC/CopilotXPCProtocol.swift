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
  case noActiveOperation
  case operationCancelled
  case operationTimedOut
  case shutDown
  case malformedFrame
  case responseTooLarge
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
  /// `nil` selects the CLI's standard OAuth device flow. A credential is
  /// retained only for backwards-compatible fixture coverage; production
  /// device sign-in never supplies a GitHub credential.
  let credential: CopilotEphemeralCredential?
  let allowsBrowser: Bool

  init(
    accountID: AccountID,
    organizationID: OrganizationID,
    credential: CopilotEphemeralCredential,
    requestID: UUID = UUID()
  ) {
    header = CopilotRequestHeader(accountID: accountID, organizationID: organizationID, operation: .authenticate, requestID: requestID)
    self.credential = credential
    allowsBrowser = false
  }

  init(
    accountID: AccountID,
    organizationID: OrganizationID,
    requestID: UUID = UUID(),
    allowsBrowser: Bool = true
  ) {
    header = CopilotRequestHeader(accountID: accountID, organizationID: organizationID, operation: .authenticate, requestID: requestID)
    credential = nil
    self.allowsBrowser = allowsBrowser
  }

  var description: String {
    "CopilotAuthenticateRequest(header: \(header), credential: <redacted>)"
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
  /// Reasoning effort levels this model accepts (e.g. low, medium, high).
  var supportedReasoningEfforts: [String]? = nil
  var defaultReasoningEffort: String? = nil
  /// Whether the model offers the long-context tier.
  var supportsLongContext: Bool? = nil

  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case isDefault = "is_default"
    case supportedReasoningEfforts = "supported_reasoning_efforts"
    case defaultReasoningEffort = "default_reasoning_effort"
    case supportsLongContext = "supports_long_context"
  }
}

/// The user's Copilot model choice for an organization.
/// What a model choice is used for.
enum CopilotPurpose: Sendable {
  case triage, reply
}

struct CopilotModelChoice: Equatable, Sendable {
  /// `nil` is Auto.
  var modelID: String?
  /// `nil` uses the model's default.
  var reasoningEffort: String?
  /// `"long_context"` or `nil` (default tier).
  var contextTier: String?

  static let auto = CopilotModelChoice(modelID: nil, reasoningEffort: nil, contextTier: nil)

  static func isValidReasoningEffort(_ value: String?) -> Bool {
    guard let value else { return true }
    return (1...16).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "_") }
  }

  static func isValidContextTier(_ value: String?) -> Bool {
    value == nil || value == "long_context" || value == "default"
  }

  var isValid: Bool {
    AIConsentRepository.isValidModelID(modelID)
      && Self.isValidReasoningEffort(reasoningEffort) && Self.isValidContextTier(contextTier)
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
  func triage(_ request: CopilotTriageRequest) async throws -> CopilotTriageResponse
  func draft(_ request: CopilotDraftRequest) async throws -> CopilotDraftResponse
  func cancel(_ request: CopilotCancelRequest) async throws -> CopilotCancelResponse
  func shutdown(_ request: CopilotShutdownRequest) async throws -> CopilotShutdownResponse
}

extension TriageCopilotHelping {
  func triage(_ request: CopilotTriageRequest) async throws -> CopilotTriageResponse {
    throw CopilotXPCError.invalidResponse
  }

  func draft(_ request: CopilotDraftRequest) async throws -> CopilotDraftResponse {
    throw CopilotXPCError.invalidResponse
  }
}

private enum CopilotWireCodingKey: String, CodingKey {
  case protocolVersion = "protocol_version"
  case requestID = "request_id"
  case accountID = "account_id"
  case organizationID = "organization_id"
  case operation, status, failure, health, authentication, models, credential
  case modelID = "model_id"
  case deadline
  case triage
  case viewerLogin = "viewer_login"
  case items, decisions, id, disposition, priority, reason, instructions, item, goal, draft
  case writingStyle = "writing_style"
  case reasoningEffort = "reasoning_effort"
  case contextTier = "context_tier"
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
    try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
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

struct CopilotTriageReview: Codable, Equatable, Sendable {
  let author: String
  let state: String
  let submittedAt: Date?
  enum CodingKeys: String, CodingKey { case author, state; case submittedAt = "submitted_at" }
}

struct CopilotTriagePullRequest: Codable, Equatable, Sendable {
  let isDraft: Bool
  let reviewDecision: String?
  let requestedReviewers: [String]
  let latestReviews: [CopilotTriageReview]
  let checks: String?
  let mergeable: String?
  let unresolvedReviewThreads: Int
  let additions: Int
  let deletions: Int
  enum CodingKeys: String, CodingKey { case isDraft = "is_draft"; case reviewDecision = "review_decision"; case requestedReviewers = "requested_reviewers"; case latestReviews = "latest_reviews"; case checks, mergeable; case unresolvedReviewThreads = "unresolved_review_threads"; case additions, deletions }
}

struct CopilotTriageActivity: Codable, Equatable, Sendable {
  let author: String
  let createdAt: Date
  let excerpt: String
  enum CodingKeys: String, CodingKey { case author; case createdAt = "created_at"; case excerpt }
  /// Copilot sees the start of each comment, keeping prompts and batches small.
  static let maximumExcerptBytes = 600
}

struct CopilotTriageItem: Codable, Equatable, Sendable {
  let id: String
  let kind: String
  let repository: String
  let number: Int
  let title: String
  let state: String
  let author: String?
  let updatedAt: Date
  let relationships: [String]
  let labels: [String]
  let assignees: [String]
  let body: String
  let pullRequest: CopilotTriagePullRequest?
  let recentActivity: [CopilotTriageActivity]
  /// Outcomes the user's hard rules will enforce, so Copilot's explanation agrees.
  var ruleHints: [String]? = nil
  /// The previous decision's next step, when the viewer has acted since.
  var previousNextAction: String? = nil
  /// What the viewer did since that decision.
  var viewerActivity: [String]? = nil
  enum CodingKeys: String, CodingKey { case id, kind, repository, number, title, state, author, relationships, labels, assignees, body; case updatedAt = "updated_at"; case pullRequest = "pull_request"; case recentActivity = "recent_activity"; case ruleHints = "rule_hints"; case previousNextAction = "previous_next_action"; case viewerActivity = "viewer_activity" }
  func validate() throws {
    guard !id.isEmpty, !kind.isEmpty, !repository.isEmpty, number > 0, !title.isEmpty, !state.isEmpty, body.utf8.count <= 4_000,
      Set(relationships).count == relationships.count, relationships.allSatisfy({ !$0.isEmpty }), labels.allSatisfy({ !$0.isEmpty }), assignees.allSatisfy({ !$0.isEmpty }), recentActivity.allSatisfy({ !$0.author.isEmpty && $0.excerpt.utf8.count <= CopilotTriageActivity.maximumExcerptBytes }), (ruleHints ?? []).count <= 10, (ruleHints ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }), (previousNextAction?.utf8.count ?? 0) <= 200, (viewerActivity ?? []).count <= 10, (viewerActivity ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else { throw CopilotXPCError.invalidResponse }
  }
}

struct CopilotTriageItemDecision: Codable, Equatable, Sendable {
  let id: String
  let disposition: TriageDisposition
  let priority: Int
  let confidence: Double
  let summary: String
  let reason: String
  let nextAction: String?
  var instructionNote: String? = nil
  var handled: HandledState? = nil
  var handledEvidence: String? = nil
  var effort: TriageEffort? = nil
  enum CodingKeys: String, CodingKey { case id, disposition, priority, confidence, summary, reason, handled, effort; case nextAction = "next_action"; case instructionNote = "instruction_note"; case handledEvidence = "handled_evidence" }
  func validate() throws { guard !id.isEmpty, (0...100).contains(priority), confidence.isFinite && (0...1).contains(confidence), !summary.isEmpty && summary.utf8.count <= 280, !reason.isEmpty && reason.utf8.count <= 400, nextAction?.utf8.count ?? 0 <= 200, instructionNote?.utf8.count ?? 0 <= 200, handledEvidence?.utf8.count ?? 0 <= 200 else { throw CopilotXPCError.invalidResponse } }
}

struct CopilotTriageRequest: Codable, Equatable, Sendable {
  let header: CopilotRequestHeader
  let modelID: String?
  let viewerLogin: String
  let items: [CopilotTriageItem]
  let deadline: Date
  /// The user's free-text triage preferences; sent in a delimited system block.
  let instructions: String?
  let reasoningEffort: String?
  let contextTier: String?
  enum CodingKeys: String, CodingKey { case modelID = "model_id"; case viewerLogin = "viewer_login"; case items, deadline, instructions; case reasoningEffort = "reasoning_effort"; case contextTier = "context_tier" }
  init(accountID: AccountID, organizationID: OrganizationID, viewerLogin: String, items: [CopilotTriageItem], modelID: String? = nil, deadline: Date, instructions: String? = nil, reasoningEffort: String? = nil, contextTier: String? = nil, requestID: UUID = UUID()) { header = .init(accountID: accountID, organizationID: organizationID, operation: .triage, requestID: requestID); self.modelID = modelID; self.viewerLogin = viewerLogin; self.items = items; self.deadline = deadline; self.instructions = instructions; self.reasoningEffort = reasoningEffort; self.contextTier = contextTier }
  init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CopilotWireCodingKey.self); header = try .init(container: c); modelID = try c.decodeIfPresent(String.self, forKey: .modelID); viewerLogin = try c.decode(String.self, forKey: .viewerLogin); items = try c.decode([CopilotTriageItem].self, forKey: .items); deadline = try c.decode(Date.self, forKey: .deadline); instructions = try c.decodeIfPresent(String.self, forKey: .instructions); reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort); contextTier = try c.decodeIfPresent(String.self, forKey: .contextTier) }
  func encode(to encoder: any Encoder) throws { var c = encoder.container(keyedBy: CopilotWireCodingKey.self); try header.encode(to: &c); try c.encodeIfPresent(modelID, forKey: .modelID); try c.encode(viewerLogin, forKey: .viewerLogin); try c.encode(items, forKey: .items); try c.encode(deadline, forKey: .deadline); try c.encodeIfPresent(instructions, forKey: .instructions); try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort); try c.encodeIfPresent(contextTier, forKey: .contextTier) }
  func validate() throws { guard header.operation == .triage, !viewerLogin.isEmpty, (1...20).contains(items.count), Set(items.map(\.id)).count == items.count, (instructions?.utf8.count ?? 0) <= TriageRules.maximumInstructionBytes, CopilotModelChoice.isValidReasoningEffort(reasoningEffort), CopilotModelChoice.isValidContextTier(contextTier) else { throw CopilotXPCError.invalidResponse }; try items.forEach { try $0.validate() }; guard try JSONEncoder().encode(self).count <= 120 * 1024 else { throw CopilotXPCError.invalidResponse } }
}

struct CopilotTriageResponse: Codable, Equatable, Sendable {
  let header: CopilotResponseHeader
  let modelID: String
  let decisions: [CopilotTriageItemDecision]
  enum CodingKeys: String, CodingKey { case modelID = "model_id"; case decisions }
  init(header: CopilotResponseHeader, modelID: String, decisions: [CopilotTriageItemDecision]) { self.header = header; self.modelID = modelID; self.decisions = decisions }
  init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CopilotWireCodingKey.self); header = try .init(container: c); modelID = try c.decode(String.self, forKey: .modelID); decisions = try c.decode([CopilotTriageItemDecision].self, forKey: .decisions) }
  func encode(to encoder: any Encoder) throws { var c = encoder.container(keyedBy: CopilotWireCodingKey.self); try header.encode(to: &c); try c.encode(modelID, forKey: .modelID); try c.encode(decisions, forKey: .decisions) }
  /// Partial responses are allowed: every decision must be for a distinct requested item.
  func validate(against request: CopilotTriageRequest) throws { let ids = decisions.map(\.id); guard !modelID.isEmpty, !decisions.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(request.items.map(\.id))) else { throw CopilotXPCError.invalidResponse }; try decisions.forEach { try $0.validate() } }
}

/// Asks Copilot to draft a reply the user will review, edit, and post themselves.
struct CopilotDraftRequest: Codable, Equatable, Sendable {
  static let maximumGoalBytes = 400
  let header: CopilotRequestHeader
  let modelID: String?
  let viewerLogin: String
  let item: CopilotTriageItem
  let deadline: Date
  /// What the reply should accomplish, usually Copilot's next action.
  let goal: String?
  /// The user's writing style from Settings; sent in a delimited system block.
  let writingStyle: String?
  let reasoningEffort: String?
  let contextTier: String?

  init(accountID: AccountID, organizationID: OrganizationID, viewerLogin: String, item: CopilotTriageItem, modelID: String? = nil, deadline: Date, goal: String? = nil, writingStyle: String? = nil, reasoningEffort: String? = nil, contextTier: String? = nil, requestID: UUID = UUID()) {
    header = .init(accountID: accountID, organizationID: organizationID, operation: .draft, requestID: requestID)
    self.modelID = modelID; self.viewerLogin = viewerLogin; self.item = item; self.deadline = deadline
    self.goal = goal; self.writingStyle = writingStyle; self.reasoningEffort = reasoningEffort; self.contextTier = contextTier
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try .init(container: c)
    modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
    viewerLogin = try c.decode(String.self, forKey: .viewerLogin)
    item = try c.decode(CopilotTriageItem.self, forKey: .item)
    deadline = try c.decode(Date.self, forKey: .deadline)
    goal = try c.decodeIfPresent(String.self, forKey: .goal)
    writingStyle = try c.decodeIfPresent(String.self, forKey: .writingStyle)
    reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    contextTier = try c.decodeIfPresent(String.self, forKey: .contextTier)
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &c)
    try c.encodeIfPresent(modelID, forKey: .modelID)
    try c.encode(viewerLogin, forKey: .viewerLogin)
    try c.encode(item, forKey: .item)
    try c.encode(deadline, forKey: .deadline)
    try c.encodeIfPresent(goal, forKey: .goal)
    try c.encodeIfPresent(writingStyle, forKey: .writingStyle)
    try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    try c.encodeIfPresent(contextTier, forKey: .contextTier)
  }

  func validate() throws {
    guard header.operation == .draft, !viewerLogin.isEmpty,
      (goal?.utf8.count ?? 0) <= Self.maximumGoalBytes,
      (writingStyle?.utf8.count ?? 0) <= TriageRules.maximumInstructionBytes,
      CopilotModelChoice.isValidReasoningEffort(reasoningEffort), CopilotModelChoice.isValidContextTier(contextTier)
    else { throw CopilotXPCError.invalidResponse }
    try item.validate()
    guard try JSONEncoder().encode(self).count <= 32 * 1024 else { throw CopilotXPCError.invalidResponse }
  }
}

struct CopilotDraftResponse: Codable, Equatable, Sendable {
  static let maximumDraftBytes = 8_000
  let header: CopilotResponseHeader
  let modelID: String
  let draft: String

  init(header: CopilotResponseHeader, modelID: String, draft: String) {
    self.header = header; self.modelID = modelID; self.draft = draft
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CopilotWireCodingKey.self)
    header = try .init(container: c)
    modelID = try c.decode(String.self, forKey: .modelID)
    draft = try c.decode(String.self, forKey: .draft)
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CopilotWireCodingKey.self)
    try header.encode(to: &c)
    try c.encode(modelID, forKey: .modelID)
    try c.encode(draft, forKey: .draft)
  }

  func validate() throws {
    guard !modelID.isEmpty, !draft.isEmpty, draft.utf8.count <= Self.maximumDraftBytes else {
      throw CopilotXPCError.invalidResponse
    }
  }
}
