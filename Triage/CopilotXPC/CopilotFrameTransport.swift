import Foundation

protocol CopilotFrameTransport: Sendable {
  func writeFrame(_ payload: Data) async throws
  func readFrame(maximumBytes: Int) async throws -> Data
  func terminate() async
}
