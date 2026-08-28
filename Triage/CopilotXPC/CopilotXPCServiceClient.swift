import Foundation

/// XPC caller for the fixed, app-embedded service. It accepts only complete
/// frames and has no path, command, or environment configuration surface.
actor CopilotXPCServiceClient: CopilotXPCFrameService {
  static let machServiceName = "com.triage.mac.TriageCopilotXPC"

  private let connection: NSXPCConnection

  init(connection: NSXPCConnection? = nil) {
    let connection =
      connection
      ?? NSXPCConnection(machServiceName: Self.machServiceName, options: [])
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

    return try await withCheckedThrowingContinuation { continuation in
      let reply = CopilotXPCReplyOnce(continuation: continuation)
      guard
        let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
          reply.resume(throwing: CopilotXPCError.helperUnavailable)
        }) as? TriageCopilotHelper
      else {
        reply.resume(throwing: CopilotXPCError.helperUnavailable)
        return
      }
      helper.exchange(frame: frame) { responseFrame, error in
        if error != nil {
          reply.resume(throwing: CopilotXPCError.helperUnavailable)
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
  }

  func invalidate() async {
    connection.invalidate()
  }
}

actor CopilotXPCFrameTransport: CopilotFrameTransport {
  private let service: any CopilotXPCFrameService
  private var pendingRequestFrame: Data?

  init(service: any CopilotXPCFrameService) {
    self.service = service
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
    guard let requestFrame = pendingRequestFrame else {
      throw CopilotXPCError.invalidResponse
    }
    pendingRequestFrame = nil
    let responseFrame = try await service.exchange(frame: requestFrame)
    do {
      return try CopilotFrameCodec.decode(responseFrame, maximumBytes: maximumBytes)
    } catch {
      throw CopilotXPCError.malformedFrame
    }
  }

  func terminate() async {
    pendingRequestFrame = nil
    await service.invalidate()
  }
}

private final class CopilotXPCReplyOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?

  init(continuation: CheckedContinuation<Data, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Data) {
    resume { $0.resume(returning: value) }
  }

  func resume(throwing error: Error) {
    resume { $0.resume(throwing: error) }
  }

  private func resume(_ operation: (CheckedContinuation<Data, Error>) -> Void) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    if let continuation {
      operation(continuation)
    }
  }
}
