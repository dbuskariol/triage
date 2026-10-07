import Foundation

/// XPC caller for the fixed, app-embedded service. It accepts only complete
/// frames and has no path, command, or environment configuration surface.
actor CopilotXPCServiceClient: CopilotXPCFrameService {
  static let serviceName = "com.triage.mac.TriageCopilotXPC"

  private let connection: NSXPCConnection

  init(connection: NSXPCConnection? = nil) {
    let connection =
      connection
      ?? NSXPCConnection(serviceName: Self.serviceName)
    connection.remoteObjectInterface = NSXPCInterface(with: TriageCopilotHelper.self)
    connection.resume()
    self.connection = connection
  }

  func exchange(frame: Data) async throws -> Data {
    do {
      _ = try CopilotFrameCodec.decode(
        frame,
        maximumBytes: CopilotIPC.maximumRequestBytes
      )
    } catch {
      throw CopilotXPCError.malformedFrame
    }

    let reply = CopilotXPCReplyOnce()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        reply.install(continuation)
        guard !Task.isCancelled else {
          reply.resume(throwing: CopilotXPCError.operationCancelled)
          return
        }
        guard
          let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
            reply.resume(throwing: CopilotXPCError.helperUnavailable)
          }) as? TriageCopilotHelper
        else {
          reply.resume(throwing: CopilotXPCError.helperUnavailable)
          return
        }
        helper.exchange(frame: frame) { responseFrame, error in
          if let error {
            reply.resume(throwing: Self.mapServiceError(error))
            return
          }
          guard let responseFrame else {
            reply.resume(throwing: CopilotXPCError.invalidResponse)
            return
          }
          do {
            _ = try CopilotFrameCodec.decode(
              responseFrame,
              maximumBytes: CopilotIPC.maximumResponseBytes
            )
            reply.resume(returning: responseFrame)
          } catch {
            reply.resume(throwing: CopilotXPCError.malformedFrame)
          }
        }
      }
    } onCancel: {
      reply.resume(throwing: CopilotXPCError.operationCancelled)
    }
  }

  func invalidate() async {
    connection.invalidate()
  }

  /// XPC failures cross the process boundary as NSError values. Keep this
  /// mapping deliberately closed: only stable, path-free service codes that
  /// callers need to present or fence have a public identity; everything else
  /// is helper-unavailable. Never forward an NSError description from the
  /// privileged service.
  nonisolated static func mapServiceError(_ error: Error) -> CopilotXPCError {
    let error = error as NSError
    guard error.domain == "com.triage.mac.copilot-xpc" else {
      return .helperUnavailable
    }
    switch error.code {
    case 2: return .malformedFrame
    case 10: return .operationCancelled
    case 11: return .operationTimedOut
    case 12: return .invalidAccountID
    case 14: return .runtimeUnavailable
    case 15: return .runtimeCorrupt
    default: return .helperUnavailable
    }
  }
}

actor CopilotXPCFrameTransport: CopilotFrameTransport {
  private let service: any CopilotXPCFrameService
  private let pendingFrameWiper: @Sendable (inout Data) -> Void
  private var pendingRequestFrame: Data?

  init(service: any CopilotXPCFrameService) {
    self.service = service
    pendingFrameWiper = { frame in
      guard !frame.isEmpty else { return }
      frame.resetBytes(in: frame.startIndex..<frame.endIndex)
      frame.removeAll(keepingCapacity: false)
    }
  }

  init(
    service: any CopilotXPCFrameService,
    pendingFrameWiper: @escaping @Sendable (inout Data) -> Void
  ) {
    self.service = service
    self.pendingFrameWiper = pendingFrameWiper
  }

  func writeFrame(_ payload: Data) async throws {
    guard pendingRequestFrame == nil else { throw CopilotXPCError.operationInProgress }
    do {
      pendingRequestFrame = try CopilotFrameCodec.encode(
        payload,
        maximumBytes: CopilotIPC.maximumRequestBytes
      )
    } catch {
      throw CopilotXPCError.malformedFrame
    }
  }

  func readFrame(maximumBytes: Int) async throws -> Data {
    guard var requestFrame = pendingRequestFrame else {
      throw CopilotXPCError.invalidResponse
    }
    pendingRequestFrame = nil
    defer { requestFrame.resetBytes(in: 0..<requestFrame.count) }
    let responseFrame = try await service.exchange(frame: requestFrame)
    do {
      return try CopilotFrameCodec.decode(responseFrame, maximumBytes: maximumBytes)
    } catch {
      throw CopilotXPCError.malformedFrame
    }
  }

  func terminate() async {
    // A cancellation can happen after framing but before the frame was sent
    // over XPC. Clear that credential-bearing buffer before releasing it.
    if var pendingRequestFrame {
      self.pendingRequestFrame = nil
      pendingFrameWiper(&pendingRequestFrame)
    }
    await service.invalidate()
  }

}

private final class CopilotXPCReplyOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?
  private var pendingResult: Result<Data, Error>?

  func install(_ continuation: CheckedContinuation<Data, Error>) {
    lock.lock()
    if let pendingResult {
      lock.unlock()
      continuation.resume(with: pendingResult)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func resume(returning value: Data) {
    complete(.success(value))
  }

  func resume(throwing error: Error) {
    complete(.failure(error))
  }

  private func complete(_ result: Result<Data, Error>) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    if continuation == nil {
      if pendingResult == nil {
        pendingResult = result
      }
      lock.unlock()
      return
    }
    lock.unlock()
    if let continuation {
      continuation.resume(with: result)
    }
  }
}
