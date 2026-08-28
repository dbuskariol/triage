import Foundation

/// Resolves only the helper location owned by the signed host app bundle.
enum CopilotHelperLocation {
  private static let relativePath =
    "Contents/XPCServices/TriageCopilotXPC.xpc/Contents/Resources/TriageCopilotHelper"

  static func bundledHelperURL(bundle: Bundle = .main) throws -> URL {
    let bundleURL = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    let executableURL =
      bundleURL
      .appending(path: relativePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let requiredPrefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"

    guard executableURL.path.hasPrefix(requiredPrefix) else {
      throw CopilotXPCError.helperLocationInvalid
    }
    guard FileManager.default.fileExists(atPath: executableURL.path) else {
      throw CopilotXPCError.helperUnavailable
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw CopilotXPCError.helperNotExecutable
    }
    return executableURL
  }
}

struct CopilotCodeSigningRequirement: Equatable, Sendable {
  let teamIdentifier: String
  let bundleIdentifier: String
}

protocol CopilotCodeSignatureValidating: Sendable {
  func validate(
    executableURL: URL,
    requirement: CopilotCodeSigningRequirement
  ) throws
}

/// Fails closed until the XPC target supplies a Security.framework validator and
/// its release-time team and bundle identifiers.
struct UnconfiguredCopilotCodeSignatureValidator: CopilotCodeSignatureValidating {
  func validate(
    executableURL: URL,
    requirement: CopilotCodeSigningRequirement
  ) throws {
    throw CopilotXPCError.codeSignatureNotValidated
  }
}
