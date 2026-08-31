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
      UUID(uuidString: header.accountID)?.uuidString.lowercased() == header.accountID,
      !header.organizationID.isEmpty,
      header.organizationID.utf8.count <= 256,
      Operation(rawValue: header.operation) != nil
    else { throw CopilotXPCServiceError.malformedFrame }
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
        try framedFixedAuthenticationFailure(for: request)
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
    for request: RequestHeader
  ) throws -> Data {
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "protocol_version": request.protocolVersion,
        "request_id": request.requestID,
        "account_id": request.accountID,
        "organization_id": request.organizationID,
        "status": "failure",
        "failure": [
          "code": "authentication_failed",
          "message": "Copilot authentication could not be completed. Authenticate again after checking your GitHub connection.",
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
    case analyze
    case cancel
    case shutdown
  }
}
