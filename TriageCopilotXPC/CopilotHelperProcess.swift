import CryptoKit
import Darwin
import Foundation
import Security

protocol CopilotHelperProcessing: AnyObject {
  func cancel()
  func exchange(frame: Data) throws -> Data
  func exchangeAndWipe(frame: inout Data) throws -> Data
}

extension CopilotHelperProcessing {
  func exchangeAndWipe(frame: inout Data) throws -> Data {
    defer { CopilotXPCFrame.wipe(&frame) }
    return try exchange(frame: frame)
  }
}

final class CopilotHelperProcess: CopilotHelperProcessing {
  private static let helperRelativePath =
    "Contents/Resources/TriageCopilotHelper"
  private static let helperIdentifier = "com.triage.mac.TriageCopilotHelper"
  private static let maximumRuntime: DispatchTimeInterval = .seconds(60)
  private static let maximumIdleInterval: TimeInterval = 5 * 60
  private static let bootstrapVersion = 1
  private static let maximumBootstrapPayloadBytes = 16 * 1_024
  private let bundle: Bundle
  private let applicationSupportDirectory: URL?
  private let signatureValidator: (URL, String) throws -> Void
  private let runtimeVerifier: any CopilotRuntimeTrustVerifying
  private let processLauncher: (Process) throws -> Void
  // Test-only seam for a deterministic framed helper. Production always uses
  // the signed Process/Pipe path below; this keeps session lifecycle tests
  // independent of an installed runtime or an ambient executable.
  private let syntheticSessionExchange: (@Sendable (Data) throws -> Data)?
  private let syntheticSessionIsRunning: @Sendable () -> Bool
  private let now: @Sendable () -> Date
  private let maximumIdleInterval: TimeInterval
  private let supervisor = CopilotProcessSupervisor()
  // Exchanges arrive on the XPC serial queue, while connection invalidation
  // may call `cancel` from another thread. This is the one ownership gate for
  // the Process, pipes, and private scratch tree.
  private let lifecycleLock = NSLock()
  private var session: HelperSession?

  init(
    bundle: Bundle = .main,
    applicationSupportDirectory: URL? = nil,
    signatureValidator: @escaping (URL, String) throws -> Void = {
      try CopilotCodeSignatureValidator.validate(executableURL: $0, identifier: $1)
    },
    runtimeVerifier: (any CopilotRuntimeTrustVerifying)? = nil,
    processLauncher: @escaping (Process) throws -> Void = { try $0.run() },
    syntheticSessionExchange: (@Sendable (Data) throws -> Data)? = nil,
    syntheticSessionIsRunning: @escaping @Sendable () -> Bool = { true },
    now: @escaping @Sendable () -> Date = { Date() },
    maximumIdleInterval: TimeInterval = CopilotHelperProcess.maximumIdleInterval
  ) {
    self.bundle = bundle
    self.applicationSupportDirectory = applicationSupportDirectory
    self.signatureValidator = signatureValidator
    self.runtimeVerifier = runtimeVerifier ?? CopilotRuntimeTrustVerifier(
      applicationSupportDirectory: applicationSupportDirectory
    )
    self.processLauncher = processLauncher
    self.syntheticSessionExchange = syntheticSessionExchange
    self.syntheticSessionIsRunning = syntheticSessionIsRunning
    self.now = now
    self.maximumIdleInterval = maximumIdleInterval
  }

  deinit {
    // A session owns an authenticated engine and its private scratch tree.
    // Never leave either alive merely because the listener is being torn down.
    lifecycleLock.lock()
    endSession(gracefully: false)
    lifecycleLock.unlock()
  }

  func cancel() {
    // Stop the active read first. The supervisor schedules a SIGKILL fallback
    // if TERM is ignored, so acquiring the ownership gate below is bounded.
    supervisor.cancel()
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    endSession(gracefully: false)
  }

  func exchange(frame: Data) throws -> Data {
    var mutableFrame = frame
    return try exchangeAndWipe(frame: &mutableFrame)
  }

  func exchangeAndWipe(frame: inout Data) throws -> Data {
    defer { CopilotXPCFrame.wipe(&frame) }
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    // A completed prior cancellation leaves the supervisor stopped. Clear it
    // only while we own the lifecycle gate, before this new exchange starts;
    // a concurrent cancel thereafter cannot be erased before Process.run.
    supervisor.reset()
    let request = try CopilotXPCFrame.validatedRequestHeader(frame)
    let helperURL = try helperURL()
    try signatureValidator(helperURL, Self.helperIdentifier)
    return try runtimeVerifier.withVerifiedRuntime { trustedRuntime in
      let key = HelperSessionKey(
        accountID: request.accountID,
        organizationID: request.organizationID,
        runtimeExecutablePath: trustedRuntime.executableURL.standardizedFileURL.path,
        runtimeLockPath: trustedRuntime.lockURL.standardizedFileURL.path
      )
      expireIdleSessionIfNeeded()
      if request.operation == "authenticate" {
        endSession(gracefully: true)
        return try startAuthenticatedSession(
          key: key,
          request: request,
          frame: &frame,
          helperURL: helperURL,
          trustedRuntime: trustedRuntime
        )
      }
      guard let session, session.key == key, session.isRunning else {
        endSession(gracefully: false)
        throw CopilotXPCServiceError.runtimeUnavailable
      }
      do {
        let response = try exchange(using: session, frame: &frame)
        if request.operation == "shutdown" { endSession(gracefully: false) }
        return response
      } catch {
        endSession(gracefully: false)
        throw error
      }
    }
  }

  private func startAuthenticatedSession(
    key: HelperSessionKey,
    request: CopilotXPCFrame.RequestHeader,
    frame: inout Data,
    helperURL: URL,
    trustedRuntime: CopilotTrustedRuntime
  ) throws -> Data {
    let accountID = request.accountID
    let privateDirectory = try makePrivateDirectory(for: accountID)
    do {
      if syntheticSessionExchange == nil {
        try makePrivateChildDirectories(privateDirectory, accountID: accountID)
      }
      let session = try launchSession(
        key: key,
        privateDirectory: privateDirectory,
        helperURL: helperURL,
        trustedRuntime: trustedRuntime
      )
      let response = try exchange(using: session, frame: &frame)
      // Authentication failures are an expected, credential-adjacent helper
      // response. Return that envelope to TriageCopilotXPCService so its
      // fixed failure replacement runs; only successful authentication may
      // become a reusable session.
      if authenticationSucceeded(response, for: request) {
        self.session = session
      } else {
        close(session: session, gracefully: false)
      }
      return response
    } catch {
      try? removePrivateDirectory(privateDirectory, accountID: accountID)
      throw error
    }
  }

  private func launchSession(
    key: HelperSessionKey,
    privateDirectory: URL,
    helperURL: URL,
    trustedRuntime: CopilotTrustedRuntime
  ) throws -> HelperSession {
    if let syntheticSessionExchange {
      return HelperSession(
        key: key,
        process: nil,
        input: nil,
        output: nil,
        privateDirectory: privateDirectory,
        lastUsedAt: now(),
        syntheticExchange: syntheticSessionExchange,
        syntheticIsRunning: syntheticSessionIsRunning
      )
    }
    let process = Process()
    process.executableURL = helperURL
    // The helper has no path-bearing command-line interface. Its verified
    // runtime handoff is the first, bounded frame on its anonymous stdin pipe.
    process.arguments = []
    process.environment = [
      "LANG": "C",
      "LC_ALL": "C",
      "COPILOT_SKIP_CLI_DOWNLOAD": "1",
    ]

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try supervisor.run(process, launchingWith: processLauncher)
      var bootstrap = try runtimeBootstrap(
        trustedRuntime: trustedRuntime,
        privateDirectory: privateDirectory
      )
      defer { CopilotXPCFrame.wipe(&bootstrap) }
      try input.fileHandleForWriting.write(contentsOf: bootstrap)
      return HelperSession(
        key: key,
        process: process,
        input: input,
        output: output,
        privateDirectory: privateDirectory,
        lastUsedAt: now(),
        syntheticExchange: nil,
        syntheticIsRunning: nil
      )
    } catch {
      input.fileHandleForWriting.closeFile()
      output.fileHandleForReading.closeFile()
      supervisor.terminateAndReap(process)
      throw error
    }
  }

  private func exchange(using session: HelperSession, frame: inout Data) throws -> Data {
    let timeout = DispatchSource.makeTimerSource()
    let request = try CopilotXPCFrame.validatedRequestHeader(frame)
    let maximumRuntime: DispatchTimeInterval =
      switch request.operation {
      case "authenticate": .seconds(320)
      // One triage request analyzes up to 15 items in a single model call.
      case "triage": .seconds(150)
      default: Self.maximumRuntime
      }
    timeout.schedule(deadline: .now() + maximumRuntime)
    let supervisor = self.supervisor
    timeout.setEventHandler { supervisor.timeout() }
    timeout.resume()
    defer { timeout.cancel() }
    do {
      try supervisor.throwIfStopped()
      if let syntheticExchange = session.syntheticExchange {
        let response = try syntheticExchange(frame)
        CopilotXPCFrame.wipe(&frame)
        try supervisor.throwIfStopped()
        session.lastUsedAt = now()
        return response
      }
      guard let input = session.input, let output = session.output else {
        throw CopilotXPCServiceError.processExited
      }
      try input.fileHandleForWriting.write(contentsOf: frame)
      CopilotXPCFrame.wipe(&frame)
      let response = try readFrame(from: output.fileHandleForReading)
      try supervisor.throwIfStopped()
      session.lastUsedAt = now()
      return response
    } catch {
      CopilotXPCFrame.wipe(&frame)
      throw error
    }
  }

  private func expireIdleSessionIfNeeded() {
    guard let session,
      now().timeIntervalSince(session.lastUsedAt) >= maximumIdleInterval
    else { return }
    endSession(gracefully: true)
  }

  private func endSession(gracefully: Bool) {
    guard let session else { return }
    self.session = nil
    close(session: session, gracefully: gracefully)
  }

  private func close(session: HelperSession, gracefully: Bool) {
    if gracefully, session.isRunning {
      var shutdown = framedShutdown(for: session.key)
      defer { CopilotXPCFrame.wipe(&shutdown) }
      _ = try? exchange(using: session, frame: &shutdown)
    }
    session.input?.fileHandleForWriting.closeFile()
    if let process = session.process {
      supervisor.terminateAndReap(process)
    }
    session.output?.fileHandleForReading.closeFile()
    supervisor.reset()
    try? removePrivateDirectory(session.privateDirectory, accountID: session.key.accountID)
  }

  private func framedShutdown(for key: HelperSessionKey) -> Data {
    let payload = (try? JSONSerialization.data(withJSONObject: [
      "protocol_version": 2,
      "request_id": UUID().uuidString.lowercased(),
      "account_id": key.accountID,
      "organization_id": key.organizationID,
      "operation": "shutdown",
    ], options: [.sortedKeys])) ?? Data()
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(payload)
    return frame
  }

  private func authenticationSucceeded(
    _ response: Data,
    for request: CopilotXPCFrame.RequestHeader
  ) -> Bool {
    guard (try? CopilotXPCFrame.responseForForwarding(response, matches: request)) != nil else {
      return false
    }
    var payload = Data(response.dropFirst(MemoryLayout<UInt32>.size))
    defer { CopilotXPCFrame.wipe(&payload) }
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      object["status"] as? String == "authentication",
      object["failure"] == nil,
      let authentication = object["authentication"] as? [String: Any],
      authentication["is_authenticated"] as? Bool == true
    else { return false }
    return true
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

  private func makePrivateDirectory(for accountID: String) throws -> URL {
    let root: URL
    if let applicationSupportDirectory {
      root = applicationSupportDirectory
    } else {
      root = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    }
    let scratchID = UUID().uuidString.lowercased()
    let components = ["Triage", "CopilotXPC", accountID, scratchID]
    let directory = root.appending(path: components.joined(separator: "/"))
    guard !isDeletionFenced(accountID: accountID, applicationSupportDirectory: root) else {
      throw CopilotXPCServiceError.accountDeletionInProgress
    }
    if syntheticSessionExchange != nil {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
      } catch {
        throw CopilotXPCServiceError.processLaunchFailed
      }
    }
    scavengeStaleScratchDirectories(for: accountID, beneath: root)
    do {
      try CopilotScratchFilesystem.ensureDirectory(at: root, components: components)
    } catch {
      throw CopilotXPCServiceError.processLaunchFailed
    }
    // The deletion journal remains until the scratch root is the last account
    // artifact removed. Recheck after directory creation so a concurrent
    // account removal cannot leave a newly named scratch directory reachable.
    guard !isDeletionFenced(accountID: accountID, applicationSupportDirectory: root) else {
      try? CopilotScratchFilesystem.removeTreeIfPresent(
        beneath: root,
        components: components
      )
      throw CopilotXPCServiceError.accountDeletionInProgress
    }
    return directory
  }

  private func makePrivateChildDirectories(_ directory: URL, accountID: String) throws {
    let root = try scratchRootDirectory()
    let accountComponents = ["Triage", "CopilotXPC", accountID]
    let scratchID = directory.lastPathComponent
    for components in [accountComponents + [scratchID, "work"], accountComponents + ["copilot-home"]] {
      do {
        try CopilotScratchFilesystem.ensureDirectory(
          at: root,
          components: components
        )
      } catch {
        throw CopilotXPCServiceError.processLaunchFailed
      }
    }
  }

  private func runtimeBootstrap(
    trustedRuntime: CopilotTrustedRuntime,
    privateDirectory: URL
  ) throws -> Data {
    let handoff = CopilotRuntimeBootstrap(
      version: Self.bootstrapVersion,
      executablePath: trustedRuntime.executableURL.path,
      runtimeLockPath: trustedRuntime.lockURL.path,
      baseDirectoryPath: privateDirectory.deletingLastPathComponent().appending(path: "copilot-home").path,
      workingDirectoryPath: privateDirectory.appending(path: "work").path
    )
    let payload = try JSONEncoder().encode(handoff)
    guard payload.count <= Self.maximumBootstrapPayloadBytes else {
      throw CopilotXPCServiceError.processLaunchFailed
    }
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(payload)
    return frame
  }

  private func removePrivateDirectory(_ directory: URL, accountID: String) throws {
    let root = try scratchRootDirectory()
    try CopilotScratchFilesystem.removeTreeIfPresent(
      beneath: root,
      components: ["Triage", "CopilotXPC", accountID, directory.lastPathComponent]
    )
  }

  /// A helper is hard-limited to 60 seconds. A much older UUID child can only
  /// be a crash remnant, so clear it before new work. Enumeration is advisory;
  /// deletion itself is descriptor-relative and refuses symlink traversal.
  private func scavengeStaleScratchDirectories(for accountID: String, beneath root: URL) {
    let accountRoot = root
      .appending(path: "Triage")
      .appending(path: "CopilotXPC")
      .appending(path: accountID)
    let cutoff = Date().addingTimeInterval(-5 * 60)
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: accountRoot,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for child in children {
      guard let identifier = UUID(uuidString: child.lastPathComponent),
        identifier.uuidString.lowercased() == child.lastPathComponent,
        let values = try? child.resourceValues(forKeys: [.contentModificationDateKey]),
        (values.contentModificationDate ?? .distantFuture) < cutoff
      else { continue }
      try? CopilotScratchFilesystem.removeTreeIfPresent(
        beneath: root,
        components: ["Triage", "CopilotXPC", accountID, child.lastPathComponent]
      )
    }
  }

  private func scratchRootDirectory() throws -> URL {
    if let applicationSupportDirectory { return applicationSupportDirectory }
    return try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
  }

  private func isDeletionFenced(accountID: String, applicationSupportDirectory: URL) -> Bool {
    let journal = applicationSupportDirectory
      .appending(path: "Triage")
      .appending(path: "Recovery")
      .appending(path: accountID)
      .appending(path: "account-deletion.json")
    return FileManager.default.fileExists(atPath: journal.path)
  }

  private static func isCanonicalOpaqueAccountID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
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

private struct HelperSessionKey: Equatable {
  let accountID: String
  let organizationID: String
  let runtimeExecutablePath: String
  let runtimeLockPath: String
}

private final class HelperSession {
  let key: HelperSessionKey
  let process: Process?
  let input: Pipe?
  let output: Pipe?
  let privateDirectory: URL
  var lastUsedAt: Date
  let syntheticExchange: (@Sendable (Data) throws -> Data)?
  let syntheticIsRunning: (@Sendable () -> Bool)?

  var isRunning: Bool {
    (syntheticIsRunning?() ?? process?.isRunning) == true
  }

  init(
    key: HelperSessionKey,
    process: Process?,
    input: Pipe?,
    output: Pipe?,
    privateDirectory: URL,
    lastUsedAt: Date,
    syntheticExchange: (@Sendable (Data) throws -> Data)?,
    syntheticIsRunning: (@Sendable () -> Bool)?
  ) {
    self.key = key
    self.process = process
    self.input = input
    self.output = output
    self.privateDirectory = privateDirectory
    self.lastUsedAt = lastUsedAt
    self.syntheticExchange = syntheticExchange
    self.syntheticIsRunning = syntheticIsRunning
  }
}

private struct CopilotRuntimeBootstrap: Encodable {
  let version: Int
  let executablePath: String
  let runtimeLockPath: String
  let baseDirectoryPath: String
  let workingDirectoryPath: String

  enum CodingKeys: String, CodingKey {
    case version
    case executablePath = "executable_path"
    case runtimeLockPath = "runtime_lock_path"
    case baseDirectoryPath = "base_directory_path"
    case workingDirectoryPath = "working_directory_path"
  }
}

/// XPC receives a pathname only for `Process` setup, but all directory
/// creation and cleanup is first performed through no-follow descriptors so a
/// crafted Application Support ancestor cannot redirect private prompts.
private enum CopilotScratchFilesystem {
  private static let directoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  private static let trustedRootDirectoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_CLOEXEC

  static func ensureDirectory(at root: URL, components: [String]) throws {
    var descriptor = try openRoot(root)
    defer { _ = Darwin.close(descriptor) }
    for component in components {
      let next = try openDirectory(named: component, relativeTo: descriptor, create: true)
      guard Darwin.fchmod(next, 0o700) == 0 else {
        _ = Darwin.close(next)
        throw posixError()
      }
      _ = Darwin.close(descriptor)
      descriptor = next
    }
  }

  static func removeTreeIfPresent(beneath root: URL, components: [String]) throws {
    guard let name = components.last else { return }
    guard let parent = try openDirectoryChain(root, components: Array(components.dropLast())) else { return }
    defer { _ = Darwin.close(parent) }
    try removeEntry(named: name, relativeTo: parent)
  }

  private static func openDirectoryChain(_ root: URL, components: [String]) throws -> Int32? {
    var descriptor: Int32
    do {
      descriptor = try openRoot(root)
    } catch let error as NSError where error.code == Int(ENOENT) {
      return nil
    }
    for component in components {
      do {
        let next = try openDirectory(named: component, relativeTo: descriptor, create: false)
        _ = Darwin.close(descriptor)
        descriptor = next
      } catch let error as NSError where error.code == Int(ENOENT) {
        _ = Darwin.close(descriptor)
        return nil
      }
    }
    return descriptor
  }

  private static func openRoot(_ root: URL) throws -> Int32 {
    let path = root.standardizedFileURL.path
    guard path.hasPrefix("/") else { throw posixError(code: EINVAL) }
    // The system-selected Application Support/temp root may be reached through
    // macOS aliases or firmlinks. Create only that trusted boundary with
    // ordinary directory traversal, then reopen its final component with
    // O_NOFOLLOW before entering the private Copilot namespace.
    var descriptor = Darwin.open("/", trustedRootDirectoryFlags)
    guard descriptor != -1 else { throw posixError() }
    for component in path.split(separator: "/").map(String.init) {
      do {
        guard isSafeComponent(component) else { throw posixError(code: EINVAL) }
        var next = Darwin.openat(descriptor, component, trustedRootDirectoryFlags)
        if next == -1, errno == ENOENT {
          guard Darwin.mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
            throw posixError()
          }
          next = Darwin.openat(descriptor, component, trustedRootDirectoryFlags)
        }
        guard next != -1 else { throw posixError() }
        _ = Darwin.close(descriptor)
        descriptor = next
      } catch {
        _ = Darwin.close(descriptor)
        throw error
      }
    }
    _ = Darwin.close(descriptor)
    descriptor = Darwin.open(path, directoryFlags)
    guard descriptor != -1 else { throw posixError() }
    return descriptor
  }

  private static func openDirectory(named name: String, relativeTo parent: Int32, create: Bool) throws -> Int32 {
    guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
    var descriptor = Darwin.openat(parent, name, directoryFlags)
    if descriptor == -1, create, errno == ENOENT {
      guard Darwin.mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw posixError() }
      descriptor = Darwin.openat(parent, name, directoryFlags)
    }
    guard descriptor != -1 else { throw posixError() }
    return descriptor
  }

  private static func removeEntry(named name: String, relativeTo parent: Int32) throws {
    guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
    var status = stat()
    guard Darwin.fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      guard errno == ENOENT else { throw posixError() }
      return
    }
    if (status.st_mode & S_IFMT) != S_IFDIR {
      guard Darwin.unlinkat(parent, name, 0) == 0 else { throw posixError() }
      return
    }
    let child = Darwin.openat(parent, name, directoryFlags)
    guard child != -1 else { throw posixError() }
    guard let stream = Darwin.fdopendir(child) else {
      _ = Darwin.close(child)
      throw posixError()
    }
    defer { _ = Darwin.closedir(stream) }
    while let entry = Darwin.readdir(stream) {
      let childName = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
      }
      guard childName != ".", childName != ".." else { continue }
      try removeEntry(named: childName, relativeTo: child)
    }
    guard Darwin.unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posixError() }
  }

  private static func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/")
  }

  private static func posixError(code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }
}

final class CopilotProcessSupervisor: @unchecked Sendable {
  private static let terminationGrace: DispatchTimeInterval = .milliseconds(500)
  private static let forceKillGrace: DispatchTimeInterval = .milliseconds(500)

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

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    guard process == nil else { return }
    stopReason = .none
  }

  func finish(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    guard self.process === process else { return }
    self.process = nil
  }

  /// Reap a known child without letting a hostile or wedged helper hold the
  /// XPC queue indefinitely. TERM gives normal shutdown a short chance; a
  /// surviving child receives SIGKILL, and both waits are bounded.
  func terminateAndReap(_ process: Process) {
    guard process.isRunning else {
      finish(process)
      return
    }
    let exited = DispatchSemaphore(value: 0)
    let previousHandler = process.terminationHandler
    process.terminationHandler = { terminated in
      previousHandler?(terminated)
      exited.signal()
    }
    process.terminate()
    if exited.wait(timeout: .now() + Self.terminationGrace) == .timedOut,
      process.isRunning {
      let pid = process.processIdentifier
      guard pid > 0 else {
        finish(process)
        return
      }
      _ = Darwin.kill(pid, SIGKILL)
      _ = exited.wait(timeout: .now() + Self.forceKillGrace)
    }
    finish(process)
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
      scheduleForceKill(for: process!)
    }
  }

  private func scheduleForceKill(for process: Process) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + Self.terminationGrace
    ) { [weak process] in
      guard let process,
        process.isRunning,
        process.processIdentifier == pid
      else { return }
      _ = Darwin.kill(pid, SIGKILL)
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

/// A successfully inspected runtime is deliberately just a fixed pathname.
/// The Rust helper independently rechecks this pathname before constructing
/// its CLI client. No request field or ambient environment value can select it.
struct CopilotTrustedRuntime: Sendable {
  let executableURL: URL
  let lockURL: URL
}

protocol CopilotRuntimeTrustVerifying {
  /// Holds the shared acquisition lock from final validation through helper
  /// spawn. The body must not retain the pathname after it returns.
  func withVerifiedRuntime<Result>(
    _ body: (CopilotTrustedRuntime) throws -> Result
  ) throws -> Result
}

/// Verifies the locally installed official Copilot CLI immediately before every
/// helper launch. Runtime acquisition publishes only this fixed namespace:
/// `Application Support/Triage/CopilotRuntime/1.0.92/<host-arch>/copilot`.
/// The XPC process never accepts a runtime path from its caller.
final class CopilotRuntimeTrustVerifier: CopilotRuntimeTrustVerifying {
  private static let releaseVersion = "1.0.92"
  private static let directoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

  private let applicationSupportDirectory: URL?
  private let signatureValidator: (URL) throws -> Void
  private let architectureValidator: (Int32, CopilotRuntimeHostArchitecture) throws -> Void

  init(
    applicationSupportDirectory: URL? = nil,
    signatureValidator: @escaping (URL) throws -> Void = {
      try CopilotRuntimeCodeSignatureValidator.validate(executableURL: $0)
    },
    architectureValidator: @escaping (Int32, CopilotRuntimeHostArchitecture) throws -> Void = {
      try CopilotRuntimeMachOValidator.validate(fileDescriptor: $0, expectedArchitecture: $1)
    }
  ) {
    self.applicationSupportDirectory = applicationSupportDirectory
    self.signatureValidator = signatureValidator
    self.architectureValidator = architectureValidator
  }

  func withVerifiedRuntime<Result>(
    _ body: (CopilotTrustedRuntime) throws -> Result
  ) throws -> Result {
    let root: URL
    do {
      root = try applicationSupportDirectory ?? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      )
    } catch {
      throw CopilotXPCServiceError.runtimeUnavailable
    }
    let architecture: CopilotRuntimeHostArchitecture
    do {
      architecture = try .host()
    } catch {
      throw CopilotXPCServiceError.runtimeUnavailable
    }
    let runtimeRootComponents = ["Triage", "CopilotRuntime"]
    let components = runtimeRootComponents + [Self.releaseVersion, architecture.rawValue]
    let runtimeRootURL = root.standardizedFileURL
      .appending(path: runtimeRootComponents.joined(separator: "/"))
    let executableURL = root.standardizedFileURL
      .appending(path: components.joined(separator: "/"))
      .appending(path: "copilot")

    do {
      let runtimeRoot = try openDirectoryChain(beneath: root, components: runtimeRootComponents)
      defer { _ = Darwin.close(runtimeRoot) }
      return try withSharedInstallLock(in: runtimeRoot) {
        let runtimeDirectory = try openDirectoryChain(beneath: root, components: components)
        defer { _ = Darwin.close(runtimeDirectory) }
        let executable = Darwin.openat(runtimeDirectory, "copilot", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard executable != -1 else { throw RuntimeFailure.fromErrno() }
        defer { _ = Darwin.close(executable) }

        let identity = try checkedExecutableIdentity(executable)
        try hash(executable, matches: architecture.expectedExecutableSHA256)
        try architectureValidator(executable, architecture)
        // Security validates a path, so retain the ancestor descriptor and prove
        // that the same leaf remains installed after that validation returns.
        try signatureValidator(executableURL)
        try assertCurrentLeaf(named: "copilot", in: runtimeDirectory, matches: identity)
        return try body(CopilotTrustedRuntime(
          executableURL: executableURL,
          lockURL: runtimeRootURL.appending(path: ".runtime.lock")
        ))
      }
    } catch let failure as RuntimeFailure {
      throw failure.xpcError
    } catch let error as CopilotXPCServiceError {
      throw error
    } catch {
      throw CopilotXPCServiceError.runtimeCorrupt
    }
  }

  private func openDirectoryChain(beneath root: URL, components: [String]) throws -> Int32 {
    var descriptor = try openAbsoluteDirectory(root)
    do {
      for component in components {
        let next = Darwin.openat(descriptor, component, Self.directoryFlags)
        guard next != -1 else { throw RuntimeFailure.fromErrno() }
        _ = Darwin.close(descriptor)
        descriptor = next
        try assertPrivateDirectory(descriptor)
      }
      return descriptor
    } catch {
      _ = Darwin.close(descriptor)
      throw error
    }
  }

  private func withSharedInstallLock<Result>(
    in runtimeRoot: Int32,
    _ body: () throws -> Result
  ) throws -> Result {
    let lock = Darwin.openat(runtimeRoot, ".runtime.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard lock != -1 else { throw RuntimeFailure.fromErrno() }
    defer { _ = Darwin.close(lock) }
    var status = stat()
    guard Darwin.fstat(lock, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == Darwin.geteuid(),
      status.st_nlink == 1,
      (status.st_mode & 0o022) == 0
    else { throw RuntimeFailure.corrupt }
    var advisoryLock = flock()
    advisoryLock.l_type = Int16(F_RDLCK)
    advisoryLock.l_whence = Int16(SEEK_SET)
    advisoryLock.l_start = 0
    advisoryLock.l_len = 0
    guard Darwin.fcntl(lock, F_SETLKW, &advisoryLock) != -1 else { throw RuntimeFailure.corrupt }
    defer {
      advisoryLock.l_type = Int16(F_UNLCK)
      _ = Darwin.fcntl(lock, F_SETLK, &advisoryLock)
    }
    return try body()
  }

  private func openAbsoluteDirectory(_ root: URL) throws -> Int32 {
    let path = root.standardizedFileURL.path
    guard path.hasPrefix("/") else { throw RuntimeFailure.corrupt }
    // The trusted system Application Support root may contain a firmlink in
    // its ancestors. O_NOFOLLOW on the final root still rejects caller-level
    // redirection; all runtime-owned descendants are opened component-wise.
    let descriptor = Darwin.open(path, Self.directoryFlags)
    guard descriptor != -1 else { throw RuntimeFailure.fromErrno() }
    return descriptor
  }

  private func assertPrivateDirectory(_ descriptor: Int32) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { throw RuntimeFailure.corrupt }
    guard (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == Darwin.geteuid(),
      (status.st_mode & 0o077) == 0
    else { throw RuntimeFailure.corrupt }
  }

  private func checkedExecutableIdentity(_ descriptor: Int32) throws -> RuntimeFileIdentity {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { throw RuntimeFailure.corrupt }
    guard (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == Darwin.geteuid(),
      status.st_nlink == 1,
      (status.st_mode & 0o022) == 0,
      (status.st_mode & 0o500) == 0o500
    else { throw RuntimeFailure.corrupt }
    return RuntimeFileIdentity(device: status.st_dev, inode: status.st_ino)
  }

  private func hash(_ descriptor: Int32, matches expected: String) throws {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) != -1 else { throw RuntimeFailure.corrupt }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      guard count >= 0 else { throw RuntimeFailure.corrupt }
      guard count > 0 else { break }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expected else { throw RuntimeFailure.corrupt }
  }

  private func assertCurrentLeaf(
    named name: String,
    in directory: Int32,
    matches expected: RuntimeFileIdentity
  ) throws {
    var status = stat()
    guard Darwin.fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_nlink == 1,
      status.st_dev == expected.device,
      status.st_ino == expected.inode
    else { throw RuntimeFailure.corrupt }
  }

  private struct RuntimeFileIdentity {
    let device: dev_t
    let inode: ino_t
  }

  private enum RuntimeFailure: Error {
    case unavailable
    case corrupt

    static func fromErrno() -> Self {
      errno == ENOENT ? .unavailable : .corrupt
    }

    var xpcError: CopilotXPCServiceError {
      switch self {
      case .unavailable: .runtimeUnavailable
      case .corrupt: .runtimeCorrupt
      }
    }
  }
}

enum CopilotRuntimeHostArchitecture: String {
  case arm64
  case x86_64

  static func host() throws -> Self {
    #if arch(arm64)
    .arm64
    #elseif arch(x86_64)
    .x86_64
    #else
    throw CopilotXPCServiceError.runtimeUnavailable
    #endif
  }

  /// SHA-256 of the regular `copilot` executable, not of its `.tar.gz` asset.
  /// These values were derived after the matching official assets satisfied
  /// the acquisition-side archive pins.
  var expectedExecutableSHA256: String {
    switch self {
    case .arm64: "d054ca3c31802d48e88e96627af502a0d5c579ee2f940c8cadf2d4bda07e0b54"
    case .x86_64: "33980346a4094f8cc17f19dd66d5e71e01a39457911af312bd407bb5d8eb7b97"
    }
  }

  var cpuType: UInt32 {
    switch self {
    case .arm64: 0x0100_000c
    case .x86_64: 0x0100_0007
    }
  }
}

private enum CopilotRuntimeMachOValidator {
  static func validate(fileDescriptor: Int32, expectedArchitecture: CopilotRuntimeHostArchitecture) throws {
    var header = [UInt8](repeating: 0, count: 8)
    let count = header.withUnsafeMutableBytes { bytes in
      Darwin.pread(fileDescriptor, bytes.baseAddress, bytes.count, 0)
    }
    guard count == header.count else { throw CopilotXPCServiceError.runtimeCorrupt }
    let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let cpuType = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    guard magic == UInt32(0xfeedfacf).littleEndian,
      cpuType == expectedArchitecture.cpuType.littleEndian
    else { throw CopilotXPCServiceError.runtimeCorrupt }
  }
}

private enum CopilotRuntimeCodeSignatureValidator {
  static func validate(executableURL: URL) throws {
    let requirementString =
      "anchor apple generic and identifier \"copilot\" and certificate leaf[subject.OU] = \"VEKTX9H2N7\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw CopilotXPCServiceError.runtimeCorrupt }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    else { throw CopilotXPCServiceError.runtimeCorrupt }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      code,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    ) == errSecSuccess,
      let flags = (information as? [CFString: Any])?[kSecCodeInfoFlags] as? UInt32,
      flags & 0x10000 != 0
    else { throw CopilotXPCServiceError.runtimeCorrupt }
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
