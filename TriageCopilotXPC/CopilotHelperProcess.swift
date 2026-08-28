import Foundation
import Security

struct CopilotHelperProcess {
  private static let helperRelativePath =
    "Contents/Resources/TriageCopilotHelper"
  private static let helperIdentifier = "com.triage.mac.copilot-helper"

  func exchange(frame: Data) throws -> Data {
    let helperURL = try helperURL()
    try CopilotCodeSignatureValidator.validate(
      executableURL: helperURL,
      identifier: Self.helperIdentifier
    )
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
    process.standardError = nil

    do {
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: frame)
      input.fileHandleForWriting.closeFile()
      let response = try readFrame(from: output.fileHandleForReading)
      output.fileHandleForReading.closeFile()
      process.waitUntilExit()
      return response
    } catch let error as CopilotXPCServiceError {
      if process.isRunning { process.terminate() }
      throw error
    } catch {
      if process.isRunning { process.terminate() }
      throw CopilotXPCServiceError.processLaunchFailed
    }
  }

  private func helperURL(bundle: Bundle = .main) throws -> URL {
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

enum CopilotCodeSignatureValidator {
  static func validate(executableURL: URL, identifier: String) throws {
    guard let teamIdentifier = Bundle.main.object(
      forInfoDictionaryKey: "TriageExpectedTeamIdentifier"
    ) as? String, !teamIdentifier.isEmpty else {
      throw CopilotXPCServiceError.codeSignatureNotValidated
    }
    let requirementString =
      "identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
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
}
