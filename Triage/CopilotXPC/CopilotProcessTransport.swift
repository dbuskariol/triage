import Foundation

struct CopilotHelperLaunchConfiguration: Sendable {
  fileprivate let executableURL: URL
  fileprivate let workingDirectoryURL: URL
  fileprivate let environment: [String: String]

  static func make(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws -> Self {
    let helperURL = try CopilotHelperLocation.bundledHelperURL(bundle: bundle)
    let supportURL = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root =
      supportURL
      .appending(path: bundle.bundleIdentifier ?? "com.triage.mac")
      .appending(path: "CopilotXPC")
    let workingDirectory = root.appending(path: "empty-working-directory")
    let copilotHome = root.appending(path: "copilot-home")
    try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: copilotHome, withIntermediateDirectories: true)

    return Self(
      executableURL: helperURL,
      workingDirectoryURL: workingDirectory,
      environment: [
        "HOME": copilotHome.path,
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "COPILOT_HOME": copilotHome.path,
      ]
    )
  }
}

protocol CopilotFrameTransport: Sendable {
  func writeFrame(_ payload: Data) async throws
  func readFrame(maximumBytes: Int) async throws -> Data
  func terminate() async
}

protocol CopilotHelperLaunching: Sendable {
  func launch(
    configuration: CopilotHelperLaunchConfiguration
  ) throws -> any CopilotFrameTransport
}

struct FoundationCopilotHelperLauncher: CopilotHelperLaunching {
  private let codeSignatureValidator: any CopilotCodeSignatureValidating
  private let codeSigningRequirement: CopilotCodeSigningRequirement

  init(
    codeSignatureValidator: any CopilotCodeSignatureValidating,
    codeSigningRequirement: CopilotCodeSigningRequirement
  ) {
    self.codeSignatureValidator = codeSignatureValidator
    self.codeSigningRequirement = codeSigningRequirement
  }

  func launch(
    configuration: CopilotHelperLaunchConfiguration
  ) throws -> any CopilotFrameTransport {
    try codeSignatureValidator.validate(
      executableURL: configuration.executableURL,
      requirement: codeSigningRequirement
    )
    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = []
    process.environment = configuration.environment
    process.currentDirectoryURL = configuration.workingDirectoryURL

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = nil

    do {
      try process.run()
    } catch {
      throw CopilotXPCError.processLaunchFailed
    }

    return CopilotPipeFrameTransport(process: process, input: input, output: output)
  }
}

actor CopilotPipeFrameTransport: CopilotFrameTransport {
  private let process: Process
  private let input: Pipe
  private let output: Pipe

  init(process: Process, input: Pipe, output: Pipe) {
    self.process = process
    self.input = input
    self.output = output
  }

  func writeFrame(_ payload: Data) async throws {
    guard process.isRunning else { throw CopilotXPCError.processExited }
    let frame: Data
    do {
      frame = try CopilotFrameCodec.encode(
        payload,
        maximumBytes: CopilotIPC.maximumRequestBytes
      )
    } catch {
      throw CopilotXPCError.malformedFrame
    }
    do {
      try input.fileHandleForWriting.write(contentsOf: frame)
    } catch {
      throw CopilotXPCError.processExited
    }
  }

  func readFrame(maximumBytes: Int) async throws -> Data {
    do {
      guard let lengthData = try output.fileHandleForReading.read(upToCount: 4),
        lengthData.count == 4
      else {
        throw CopilotXPCError.processExited
      }
      let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
      guard Int(length) <= maximumBytes else {
        throw CopilotXPCError.responseTooLarge
      }
      guard let payload = try output.fileHandleForReading.read(upToCount: Int(length)),
        payload.count == Int(length)
      else {
        throw CopilotXPCError.processExited
      }
      return payload
    } catch let error as CopilotXPCError {
      throw error
    } catch {
      throw CopilotXPCError.processExited
    }
  }

  func terminate() async {
    input.fileHandleForWriting.closeFile()
    output.fileHandleForReading.closeFile()
    if process.isRunning {
      process.terminate()
    }
  }
}
