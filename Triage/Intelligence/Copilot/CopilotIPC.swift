import Foundation

enum CopilotIPC {
    static let version = 1
    static let maximumRequestBytes = 1_024 * 1_024
    static let maximumResponseBytes = 256 * 1_024
}

enum CopilotOperation: String, Codable, Sendable {
    case health, models, analyze, cancel, shutdown
}

struct CopilotWireRequest: Codable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let organizationID: OrganizationID
    let operation: CopilotOperation

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case organizationID = "organization_id"
        case operation
    }
}

enum CopilotResponseStatus: String, Codable, Sendable {
    case health, models, analysis, cancelled, shutdown, failure
}

struct CopilotHealth: Codable, Equatable, Sendable {
    let helperVersion: String
    let copilotAvailable: Bool
    let toolPolicy: String

    enum CodingKeys: String, CodingKey {
        case helperVersion = "helper_version"
        case copilotAvailable = "copilot_available"
        case toolPolicy = "tool_policy"
    }
}

struct CopilotFailure: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct CopilotWireResponse: Codable, Sendable {
    let protocolVersion: Int
    let requestID: UUID?
    let organizationID: OrganizationID?
    let status: CopilotResponseStatus
    let health: CopilotHealth?
    let failure: CopilotFailure?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case organizationID = "organization_id"
        case status, health, failure
    }
}

enum CopilotFrameError: Error, Equatable, Sendable {
    case invalidLength
    case payloadTooLarge
}

enum CopilotFrameCodec {
    static func encode(_ data: Data, maximumBytes: Int) throws -> Data {
        guard data.count <= maximumBytes, data.count <= Int(UInt32.max) else {
            throw CopilotFrameError.payloadTooLarge
        }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(data)
        return frame
    }

    static func decode(_ frame: Data, maximumBytes: Int) throws -> Data {
        guard frame.count >= MemoryLayout<UInt32>.size else { throw CopilotFrameError.invalidLength }
        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard Int(length) <= maximumBytes else { throw CopilotFrameError.payloadTooLarge }
        guard frame.count == Int(length) + 4 else { throw CopilotFrameError.invalidLength }
        return frame.dropFirst(4)
    }
}
