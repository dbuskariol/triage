import Foundation
import Security

protocol CopilotHelperProcessing: AnyObject {
  func cancel()
  func exchange(frame: Data) throws -> Data
}

final class CopilotHelperProcess: CopilotHelperProcessing {
  private static let helperRelativePath =
    "Contents/Resources/TriageCopilotHelper"
  private static let helperIdentifier = "com.triage.mac.copilot-helper"
  private static let maximumRuntime: DispatchTimeInterval = .seconds(60)
  private let bundle: Bundle
  private let signatureValidator: (URL, String) throws -> Void
  private let processLauncher: (Process) throws -> Void
  private let supervisor = CopilotProcessSupervisor()

  init(
    bundle: Bundle = .main,
    signatureValidator: @escaping (URL, String) throws -> Void = {
      try CopilotCodeSignatureValidator.validate(executableURL: $0, identifier: $1)
    },
    processLauncher: @escaping (Process) throws -> Void = { try $0.run() }
  ) {
    self.bundle = bundle
    self.signatureValidator = signatureValidator
    self.processLauncher = processLauncher
  }

  func cancel() {
    supervisor.cancel()
  }

  func exchange(frame: Data) throws -> Data {
    let helperURL = try helperURL()
    try signatureValidator(helperURL, Self.helperIdentifier)
    let privateDirectory = try makePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: privateDirectory) }

    let process = Process()
    process.executableURL = helperURL
    process.arguments = []
    process.environment = [
      "HOME": privateDirectory.appending(path: "home").path,
      "PATH": "/usr/bin:/bin",
      "LANG": "C",
      "LC_ALL": "C",
      "COPILOT_HOME": privateDirectory.appending(path: "copilot-home").path,
    ]
    process.currentDirectoryURL = privateDirectory.appending(path: "work")

    try FileManager.default.createDirectory(
      at: process.currentDirectoryURL!,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: privateDirectory.appending(path: "home"),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: privateDirectory.appending(path: "copilot-home"),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var launched = false
    defer {
      input.fileHandleForWriting.closeFile()
      output.fileHandleForReading.closeFile()
      if launched, process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    do {
      try supervisor.run(process, launchingWith: processLauncher)
      launched = true
      defer { supervisor.finish(process) }
      let timeout = DispatchSource.makeTimerSource()
      timeout.schedule(deadline: .now() + Self.maximumRuntime)
      let supervisor = self.supervisor
      timeout.setEventHandler {
        supervisor.timeout()
      }
      timeout.resume()
      defer { timeout.cancel() }

      try supervisor.throwIfStopped()
      try input.fileHandleForWriting.write(contentsOf: frame)
      input.fileHandleForWriting.closeFile()
      let response = try readFrame(from: output.fileHandleForReading)
      process.waitUntilExit()
      try supervisor.throwIfStopped()
      return response
    } catch let error as CopilotXPCServiceError {
      throw error
    } catch {
      throw CopilotXPCServiceError.processLaunchFailed
    }
  }

  private func helperURL() throws -> URL {
    let bundleURL = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    let executableURL = bundleURL
      .appending(path: Self.helperRelativePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let requiredPrefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"
    guard executableURL.path.hasPrefix(requiredPrefix) else {
      throw CopilotXPCServiceError.helperLocationInvalid
    }
    guard FileManager.default.fileExists(atPath: executableURL.path) else {
      throw CopilotXPCServiceError.helperUnavailable
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw CopilotXPCServiceError.helperNotExecutable
    }
    return executableURL
  }

  private func makePrivateDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root
      .appending(path: "com.triage.mac")
      .appending(path: "CopilotXPC")
      .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func readFrame(from handle: FileHandle) throws -> Data {
    guard let lengthData = try handle.read(upToCount: 4), lengthData.count == 4 else {
      throw CopilotXPCServiceError.processExited
    }
    let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    guard length <= 262_144 else { throw CopilotXPCServiceError.frameTooLarge }
    guard let payload = try handle.read(upToCount: Int(length)), payload.count == Int(length) else {
      throw CopilotXPCServiceError.processExited
    }
    return lengthData + payload
  }
}

private final class CopilotProcessSupervisor: @unchecked Sendable {
  private enum StopReason: Equatable {
    case none
    case cancelled
    case timedOut
  }

  private let lock = NSLock()
  private var process: Process?
  private var stopReason: StopReason = .none

  func run(
    _ process: Process,
    launchingWith launch: (Process) throws -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    try throwIfStoppedLocked()
    try launch(process)
    self.process = process
  }

  func finish(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    guard self.process === process else { return }
    self.process = nil
  }

  func cancel() {
    stop(.cancelled)
  }

  func timeout() {
    stop(.timedOut)
  }

  func throwIfStopped() throws {
    lock.lock()
    defer { lock.unlock() }
    try throwIfStoppedLocked()
  }

  private func stop(_ reason: StopReason) {
    lock.lock()
    if stopReason == .none {
      stopReason = reason
    }
    let process = process
    lock.unlock()
    if process?.isRunning == true {
      process?.terminate()
    }
  }

  private func throwIfStoppedLocked() throws {
    switch stopReason {
    case .none:
      return
    case .cancelled:
      throw CopilotXPCServiceError.operationCancelled
    case .timedOut:
      throw CopilotXPCServiceError.operationTimedOut
    }
  }
}

enum CopilotCodeSignatureValidator {
  static func validate(executableURL: URL, identifier: String) throws {
    let teamIdentifier = try validatedTeamIdentifier(
      Bundle.main.object(forInfoDictionaryKey: "TriageExpectedTeamIdentifier") as? String
    )
    let requirementString =
      "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw CopilotXPCServiceError.codeSignatureNotValidated
    }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    else {
      throw CopilotXPCServiceError.codeSignatureNotValidated
    }
  }

  static func validatedTeamIdentifier(_ value: String?) throws -> String {
    guard let value,
      value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    else {
      throw CopilotXPCServiceError.codeSignatureNotValidated
    }
    return value
  }
}
