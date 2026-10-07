import Foundation

enum CopilotXPCFrame {
  static let maximumRequestPayloadBytes = 1_048_576
  static let maximumResponsePayloadBytes = 262_144

  static func validate(_ frame: Data, maximumPayloadBytes: Int) throws {
    guard frame.count >= 4 else { throw CopilotXPCServiceError.malformedFrame }
    let length = frame.withUnsafeBytes { bytes in
      Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian)
    }
    guard length <= maximumPayloadBytes else {
      throw CopilotXPCServiceError.frameTooLarge
    }
    guard frame.count == length + 4 else {
      throw CopilotXPCServiceError.malformedFrame
    }
  }

  /// Parses only routing metadata. In particular, it intentionally does not
  /// decode, store, or describe the `credential` field of authenticate
  /// requests; the Rust helper receives that opaque frame and zeroizes it.
  static func validatedRequestHeader(_ frame: Data) throws -> RequestHeader {
    try validate(frame, maximumPayloadBytes: maximumRequestPayloadBytes)
    var payload = Data(frame.dropFirst(MemoryLayout<UInt32>.size))
    defer { wipe(&payload) }
    let header: RequestHeader
    do {
      header = try JSONDecoder().decode(RequestHeader.self, from: payload)
    } catch {
      throw CopilotXPCServiceError.malformedFrame
    }
    guard header.protocolVersion == 2,
      UUID(uuidString: header.requestID)?.uuidString.lowercased() == header.requestID,
      !header.organizationID.isEmpty,
      header.organizationID.utf8.count <= 256,
      Operation(rawValue: header.operation) != nil
    else { throw CopilotXPCServiceError.malformedFrame }
    guard UUID(uuidString: header.accountID)?.uuidString.lowercased() == header.accountID else {
      throw CopilotXPCServiceError.invalidAccountID
    }
    return header
  }

  /// Validates a helper response before it crosses the XPC boundary. An
  /// authenticate failure is deliberately replaced after its envelope is
  /// account-bound: a helper that saw the credential must not be able to
  /// reflect it through a failure message.
  static func responseForForwarding(
    _ frame: Data,
    matches request: RequestHeader
  ) throws -> ResponseForwarding {
    try validate(frame, maximumPayloadBytes: maximumResponsePayloadBytes)
    var payload = Data(frame.dropFirst(MemoryLayout<UInt32>.size))
    defer { wipe(&payload) }
    let header: ResponseHeader
    do {
      header = try JSONDecoder().decode(ResponseHeader.self, from: payload)
    } catch {
      throw CopilotXPCServiceError.malformedFrame
    }
    guard header.protocolVersion == request.protocolVersion,
      header.requestID == request.requestID,
      header.accountID == request.accountID,
      header.organizationID == request.organizationID,
      !header.status.isEmpty
    else { throw CopilotXPCServiceError.responseIdentityMismatch }

    if request.operation == Operation.authenticate.rawValue,
       header.status == "failure" {
      return .fixedAuthenticationFailure(
        try framedFixedAuthenticationFailure(for: request, payload: payload)
      )
    }

    guard let object = try? JSONSerialization.jsonObject(with: payload),
      !containsCredentialKey(object)
    else { throw CopilotXPCServiceError.malformedFrame }
    return .original
  }

  static func wipe(_ data: inout Data) {
    guard !data.isEmpty else { return }
    data.resetBytes(in: data.startIndex..<data.endIndex)
    data.removeAll(keepingCapacity: false)
  }

  private static func containsCredentialKey(_ value: Any) -> Bool {
    if let object = value as? [String: Any] {
      return object.contains { key, value in
        key == "credential" || containsCredentialKey(value)
      }
    }
    if let values = value as? [Any] {
      return values.contains(where: containsCredentialKey)
    }
    return false
  }

  private static func framedFixedAuthenticationFailure(
    for request: RequestHeader,
    payload originalPayload: Data
  ) throws -> Data {
    let safeMessages: Set<String> = [
      "Copilot browser login could not start.",
      "Copilot browser login exited before authorization completed.",
      "Copilot browser sign-in timed out. Connect again and finish authorization within five minutes.",
      "Copilot runtime startup timed out after browser sign-in.",
      "Copilot runtime could not start after browser sign-in.",
      "Copilot runtime could not read the signed-in account.",
      "Copilot runtime could not activate its saved account.",
      "Copilot runtime did not find the browser login in its isolated profile.",
      "Copilot browser login could not read its bounded response.",
      "Copilot could not establish a trusted TLS connection after browser authorization.",
      "Copilot could not contact GitHub to exchange the browser authorization.",
      "Copilot could not save its login in the system credential store.",
      "Copilot could not write its isolated login profile because access was denied.",
      "Copilot requested terminal input after browser authorization.",
      "GitHub rejected an expired or invalid browser authorization. Start a fresh Copilot sign-in.",
      "GitHub denied Copilot access for the authorized account. Check its subscription and organization policy.",
      "Copilot could not locate a required system tool or login-profile directory.",
      "Copilot requires confirmation before storing credentials in its local profile.",
    ]
    let object = try? JSONSerialization.jsonObject(with: originalPayload) as? [String: Any]
    let suppliedMessage = (object?["failure"] as? [String: Any])?["message"] as? String
    let message = suppliedMessage.flatMap { safeMessages.contains($0) ? $0 : nil }
      ?? "Copilot authentication could not be completed. Authenticate again after checking your GitHub connection."
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "protocol_version": request.protocolVersion,
        "request_id": request.requestID,
        "account_id": request.accountID,
        "organization_id": request.organizationID,
        "status": "failure",
        "failure": [
          "code": "authentication_failed",
          "message": message,
        ],
      ],
      options: [.sortedKeys]
    )
    guard payload.count <= maximumResponsePayloadBytes else {
      throw CopilotXPCServiceError.frameTooLarge
    }
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(payload)
    return frame
  }

  enum ResponseForwarding {
    case original
    case fixedAuthenticationFailure(Data)
  }

  struct RequestHeader: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let accountID: String
    let organizationID: String
    let operation: String

    enum CodingKeys: String, CodingKey {
      case protocolVersion = "protocol_version"
      case requestID = "request_id"
      case accountID = "account_id"
      case organizationID = "organization_id"
      case operation
    }
  }

  private struct ResponseHeader: Decodable {
    let protocolVersion: Int
    let requestID: String
    let accountID: String
    let organizationID: String
    let status: String

    enum CodingKeys: String, CodingKey {
      case protocolVersion = "protocol_version"
      case requestID = "request_id"
      case accountID = "account_id"
      case organizationID = "organization_id"
      case status
    }
  }

  private enum Operation: String {
    case health
    case authenticate
    case models
    case triage
    case cancel
    case shutdown
  }
}
