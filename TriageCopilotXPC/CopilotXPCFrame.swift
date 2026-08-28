import Foundation

enum CopilotXPCFrame {
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
}
