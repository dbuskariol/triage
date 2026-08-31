import CryptoKit
import Darwin
import Foundation
import Security
import zlib

/// The only Copilot CLI release that this client will acquire.  This is an
/// acquisition boundary, not a runtime enablement switch: callers must still
/// satisfy the independent consent, credential, and XPC gates.
struct CopilotRuntimeRelease: Equatable, Sendable {
    static let pinned = Self(version: "1.0.81-10")

    let version: String
    static let githubAuthority = "github.com"
    static let signingTeam = "VEKTX9H2N7"
    static let signingIdentifier = "copilot"

    func archive(for architecture: CopilotRuntimeArchitecture) -> CopilotRuntimeArchive {
        let name = architecture == .arm64 ? "copilot-darwin-arm64.tar.gz" : "copilot-darwin-x64.tar.gz"
        let archiveSHA256 = architecture == .arm64
            ? "7d693bfdc82f1a1223d4fe034903faeb16063cbc0075d0f45e04af1ea7914871"
            : "1fb04e8e040525ae39cf53cce7f9e44b7d3fbb200bc9bfe38e2e7436d7dd3b74"
        // These are deliberately distinct from the compressed archive pins.
        // They were derived only after authenticating each official archive
        // against the archive pins above and hashing its sole `copilot` file.
        let executableSHA256 = architecture == .arm64
            ? "2f4238eebaa42e1196e4f9473a06d03fca612fd6fed09bb9033d9c506d4a5e9a"
            : "8da653f6c4944d6be001af17aaf6d685066c91b1f62af543bbc3ebb35b85435c"
        return CopilotRuntimeArchive(
            url: URL(string: "https://github.com/github/copilot-cli/releases/download/v\(version)/\(name)")!,
            expectedArchiveSHA256: archiveSHA256,
            expectedExecutableSHA256: executableSHA256
        )
    }
}

enum CopilotRuntimeArchitecture: String, CaseIterable, Equatable, Sendable {
    case arm64
    case x86_64

    static func host() throws -> Self {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        throw CopilotRuntimeAcquisitionError.unsupportedArchitecture
        #endif
    }

    var cpuType: UInt32 {
        switch self {
        case .arm64: return 0x0100_000c
        case .x86_64: return 0x0100_0007
        }
    }
}

struct CopilotRuntimeArchive: Equatable, Sendable {
    let url: URL
    /// Pin for the downloaded compressed release asset.
    let expectedArchiveSHA256: String
    /// Pin for the regular `copilot` file extracted from that authenticated asset.
    /// The XPC launch boundary independently enforces this before execution.
    let expectedExecutableSHA256: String
}

enum CopilotRuntimeAcquisitionState: Equatable, Sendable {
    case absent
    case downloading(receivedBytes: Int64, expectedBytes: Int64?)
    case verifying
    case ready(URL)
    case corrupt(String)
}

enum CopilotRuntimeAcquisitionError: Error, Equatable, Sendable {
    case unsupportedArchitecture
    case invalidSource
    case redirectRejected
    case invalidResponse
    case archiveTooLarge
    case checksumMismatch
    case executableChecksumMismatch
    case invalidArchive
    case executableMissing
    case invalidExecutableArchitecture
    case invalidCodeSignature
    case cancellation
    case fileSystem
}

/// A downloading implementation must write only to `destination`, calculate
/// the SHA-256 while bytes arrive, reject redirects, and never retain a copy.
protocol CopilotRuntimeDownloading: Sendable {
    func download(
        _ archive: CopilotRuntimeArchive,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> String
}

protocol CopilotRuntimeExtracting: Sendable {
    /// Extracts exactly one regular `copilot` file.  Implementations must reject
    /// traversal, links, special files, duplicate entries, and extra payloads.
    func extractVerifiedExecutable(from archive: URL, to directory: URL) throws -> URL
}

protocol CopilotRuntimeValidating: Sendable {
    func validate(_ executable: URL, architecture: CopilotRuntimeArchitecture) throws
}

/// The extracted executable has a separate, architecture-specific pin from
/// the compressed release asset. Keeping this operation injectable lets the
/// acquisition lifecycle be tested without manufacturing a SHA-256 preimage.
protocol CopilotRuntimeHashing: Sendable {
    func sha256(of file: URL) throws -> String
}

/// Isolating file operations makes adversarial acquisition tests deterministic.
protocol CopilotRuntimeFileManaging: Sendable {
    func makeTemporaryDirectory() throws -> URL
    func removeIfPresent(_ url: URL)
    func installedExecutable(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) -> URL
    func install(_ executable: URL, root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws -> URL
    func removeInstalled(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws
    func scavengeStaleStages(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws
    func exists(_ url: URL) -> Bool
}

/// Cross-process exclusion shared by acquisition and the XPC launch boundary.
/// Install/repair/remove take an exclusive lock.  XPC must take a shared lock
/// from final descriptor/signature verification through `Process.run()`; it
/// must not retain a pathname after dropping that lock.
enum CopilotRuntimeInstallLock {
    static let filename = ".runtime.lock"

    static func withExclusiveLock<T>(root: URL, _ body: () throws -> T) throws -> T {
        try withLock(root: root, operation: LOCK_EX, body)
    }

    static func withSharedLock<T>(root: URL, _ body: () throws -> T) throws -> T {
        try withLock(root: root, operation: LOCK_SH, body)
    }

    private static func withLock<T>(root: URL, operation: Int32, _ body: () throws -> T) throws -> T {
        let rootDescriptor = try CopilotRuntimePOSIX.openDirectoryTree(root, create: true)
        defer { close(rootDescriptor) }
        let descriptor = openat(rootDescriptor, filename, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        defer { close(descriptor) }
        let type: Int16 = operation == LOCK_EX ? Int16(F_WRLCK) : Int16(F_RDLCK)
        var advisoryLock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: type, l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_SETLKW, &advisoryLock) != -1 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        defer {
            var unlock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_UNLCK), l_whence: Int16(SEEK_SET))
            _ = fcntl(descriptor, F_SETLK, &unlock)
        }
        return try body()
    }
}

/// Actor ownership makes downloads explicitly user-triggered and single-flight.
actor CopilotRuntimeAcquisitionService {
    static let maximumArchiveBytes: Int64 = 150 * 1_024 * 1_024

    private let release: CopilotRuntimeRelease
    private let architecture: CopilotRuntimeArchitecture
    private let root: URL
    private let downloader: any CopilotRuntimeDownloading
    private let extractor: any CopilotRuntimeExtracting
    private let validator: any CopilotRuntimeValidating
    private let hasher: any CopilotRuntimeHashing
    private let files: any CopilotRuntimeFileManaging
    private var currentState: CopilotRuntimeAcquisitionState = .absent
    private var stateObservers: [UUID: AsyncStream<CopilotRuntimeAcquisitionState>.Continuation] = [:]
    /// Progress arrives on an unstructured task after the downloader callback.
    /// This generation makes terminal states win when that task is delayed.
    private var acquisitionGeneration: UInt64 = 0
    private var activeProgressGeneration: UInt64?

    init(
        applicationSupportDirectory: URL,
        release: CopilotRuntimeRelease = .pinned,
        architecture: CopilotRuntimeArchitecture? = nil,
        downloader: any CopilotRuntimeDownloading = URLSessionCopilotRuntimeDownloader(),
        extractor: any CopilotRuntimeExtracting = CopilotRuntimeTarExtractor(),
        validator: any CopilotRuntimeValidating = CopilotRuntimeCodeValidator(),
        hasher: any CopilotRuntimeHashing = CopilotRuntimeSHA256Hasher(),
        files: any CopilotRuntimeFileManaging = CopilotRuntimeFileManager()
    ) throws {
        if !FileManager.default.fileExists(atPath: applicationSupportDirectory.path) {
            try FileManager.default.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        self.release = release
        self.architecture = try architecture ?? .host()
        root = Self.runtimeRoot(applicationSupportDirectory: applicationSupportDirectory)
        self.downloader = downloader
        self.extractor = extractor
        self.validator = validator
        self.hasher = hasher
        self.files = files
    }

    /// Canonicalizes only the existing, trusted support-directory boundary.
    /// `URL.resolvingSymlinksInPath()` does not expand macOS's `/var` firmlink;
    /// POSIX `realpath` does. App-owned descendants are appended afterward and
    /// remain protected by the descriptor walk's O_NOFOLLOW checks.
    nonisolated static func runtimeRoot(applicationSupportDirectory: URL) -> URL {
        guard let resolved = Darwin.realpath(applicationSupportDirectory.path, nil) else {
            return applicationSupportDirectory
                .appending(path: "Triage/CopilotRuntime", directoryHint: .isDirectory)
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appending(path: "Triage/CopilotRuntime", directoryHint: .isDirectory)
    }

    func state() -> CopilotRuntimeAcquisitionState { currentState }

    /// Emits the exact acquisition state owned by this actor. Consumers see an
    /// immediate current value, then only state transitions from an explicit
    /// user-requested operation; this stream never starts an acquisition.
    func stateUpdates() -> AsyncStream<CopilotRuntimeAcquisitionState> {
        let observerID = UUID()
        var continuation: AsyncStream<CopilotRuntimeAcquisitionState>.Continuation!
        let stream = AsyncStream<CopilotRuntimeAcquisitionState> { continuation = $0 }
        stateObservers[observerID] = continuation
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(observerID) }
        }
        return stream
    }

    /// The only method that may contact GitHub.  Nothing calls it implicitly.
    func acquireAtUserRequest() async throws -> URL {
        let archive = release.archive(for: architecture)
        guard archive.url.scheme == "https", archive.url.host == CopilotRuntimeRelease.githubAuthority else {
            throw CopilotRuntimeAcquisitionError.invalidSource
        }
        let generation = beginAcquisition()
        var installed: URL?
        do {
            let temporary = try files.makeTemporaryDirectory()
            defer { files.removeIfPresent(temporary) }
            let downloaded = temporary.appending(path: "runtime.tar.gz")
            try requireActiveAcquisition(generation)
            try files.scavengeStaleStages(root: root, release: release, architecture: architecture)
            try requireActiveAcquisition(generation)
            let digest = try await downloader.download(archive, to: downloaded, maximumBytes: Self.maximumArchiveBytes) { [weak self] received, expected in
                Task { await self?.publishDownloadProgress(received, expected: expected, generation: generation) }
            }
            try requireActiveAcquisition(generation)
            guard digest.lowercased() == archive.expectedArchiveSHA256 else {
                throw CopilotRuntimeAcquisitionError.checksumMismatch
            }
            publishActiveState(.verifying, generation: generation)
            let extraction = temporary.appending(path: "extracted", directoryHint: .isDirectory)
            try requireActiveAcquisition(generation)
            let executable = try extractor.extractVerifiedExecutable(from: downloaded, to: extraction)
            try requireActiveAcquisition(generation)
            guard try hasher.sha256(of: executable).lowercased() == archive.expectedExecutableSHA256 else {
                throw CopilotRuntimeAcquisitionError.executableChecksumMismatch
            }
            try validator.validate(executable, architecture: architecture)
            try requireActiveAcquisition(generation)
            installed = try files.install(executable, root: root, release: release, architecture: architecture)
            try requireActiveAcquisition(generation)
            // Validation after the atomic publish catches replacement between
            // extraction and use; clients must call `runtimeForUse` again at exec.
            try validator.validate(installed!, architecture: architecture)
            try requireActiveAcquisition(generation)
            finishAcquisition(.ready(installed!), generation: generation)
            return installed!
        } catch is CancellationError {
            rollbackInstalledRuntime(installed, generation: generation)
            finishAcquisition(.absent, generation: generation)
            throw CopilotRuntimeAcquisitionError.cancellation
        } catch CopilotRuntimeAcquisitionError.cancellation {
            rollbackInstalledRuntime(installed, generation: generation)
            finishAcquisition(.absent, generation: generation)
            throw CopilotRuntimeAcquisitionError.cancellation
        } catch let error as CopilotRuntimeAcquisitionError {
            rollbackInstalledRuntime(installed, generation: generation)
            finishAcquisition(.corrupt(String(describing: error)), generation: generation)
            throw error
        } catch {
            rollbackInstalledRuntime(installed, generation: generation)
            finishAcquisition(.corrupt("acquisition failed"), generation: generation)
            throw CopilotRuntimeAcquisitionError.fileSystem
        }
    }

    /// Revalidation is mandatory immediately before a future helper executes it.
    func runtimeForUse() throws -> URL {
        let executable = files.installedExecutable(root: root, release: release, architecture: architecture)
        guard files.exists(executable) else {
            invalidateAcquisitionAndPublish(.absent)
            throw CopilotRuntimeAcquisitionError.executableMissing
        }
        do {
            try validator.validate(executable, architecture: architecture)
            invalidateAcquisitionAndPublish(.ready(executable))
            return executable
        } catch let error as CopilotRuntimeAcquisitionError {
            invalidateAcquisitionAndPublish(.corrupt(String(describing: error)))
            throw error
        } catch {
            invalidateAcquisitionAndPublish(.corrupt("runtime validation failed"))
            throw CopilotRuntimeAcquisitionError.invalidCodeSignature
        }
    }

    func removeAtUserRequest() throws {
        do {
            try files.removeInstalled(root: root, release: release, architecture: architecture)
            invalidateAcquisitionAndPublish(.absent)
        } catch {
            invalidateAcquisitionAndPublish(.corrupt("runtime removal failed"))
            throw CopilotRuntimeAcquisitionError.fileSystem
        }
    }

    func repairAtUserRequest() async throws -> URL {
        try removeAtUserRequest()
        return try await acquireAtUserRequest()
    }

    private func beginAcquisition() -> UInt64 {
        acquisitionGeneration &+= 1
        activeProgressGeneration = acquisitionGeneration
        publishState(.downloading(receivedBytes: 0, expectedBytes: nil))
        return acquisitionGeneration
    }

    /// A newer user action (including Remove) invalidates the old operation
    /// before it can extract or publish anything. This check also closes the
    /// cancellation window around synchronous extraction and installation.
    private func requireActiveAcquisition(_ generation: UInt64) throws {
        guard activeProgressGeneration == generation, acquisitionGeneration == generation else {
            throw CopilotRuntimeAcquisitionError.cancellation
        }
        try Task.checkCancellation()
    }

    /// An install is atomic but synchronous, so cancellation can arrive while
    /// it is in progress. Once it returns, remove the just-published file
    /// before reporting cancellation or verification failure.
    private func rollbackInstalledRuntime(_ installed: URL?, generation: UInt64) {
        guard installed != nil,
              activeProgressGeneration == generation,
              acquisitionGeneration == generation
        else { return }
        try? files.removeInstalled(root: root, release: release, architecture: architecture)
    }

    private func publishDownloadProgress(_ received: Int64, expected: Int64?, generation: UInt64) {
        guard activeProgressGeneration == generation, acquisitionGeneration == generation else { return }
        publishState(.downloading(receivedBytes: received, expectedBytes: expected))
    }

    private func publishActiveState(_ state: CopilotRuntimeAcquisitionState, generation: UInt64) {
        guard activeProgressGeneration == generation, acquisitionGeneration == generation else { return }
        publishState(state)
    }

    private func finishAcquisition(_ state: CopilotRuntimeAcquisitionState, generation: UInt64) {
        guard acquisitionGeneration == generation else { return }
        activeProgressGeneration = nil
        publishState(state)
    }

    private func invalidateAcquisitionAndPublish(_ state: CopilotRuntimeAcquisitionState) {
        acquisitionGeneration &+= 1
        activeProgressGeneration = nil
        publishState(state)
    }

    private func publishState(_ state: CopilotRuntimeAcquisitionState) {
        currentState = state
        for continuation in stateObservers.values {
            continuation.yield(state)
        }
    }

    private func removeStateObserver(_ observerID: UUID) {
        stateObservers[observerID] = nil
    }
}

/// URLSession implementation intentionally has no cookie/cache persistence.
/// Redirects are allowed only between GitHub's two fixed HTTPS authorities.
final class URLSessionCopilotRuntimeDownloader: NSObject, CopilotRuntimeDownloading, @unchecked Sendable {
    func download(_ archive: CopilotRuntimeArchive, to destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        guard CopilotRuntimeURLTransfer.isApprovedInitialURL(archive.url) else { throw CopilotRuntimeAcquisitionError.invalidSource }
        let transfer = CopilotRuntimeURLTransfer(destination: destination, maximumBytes: maximumBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await transfer.run(session: session, url: archive.url)
    }
}

final class CopilotRuntimeURLTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var expected: Int64?
    private var task: URLSessionDataTask?
    private var acceptedRedirect = false
    /// Stored before resuming so cancellation and URLSession callbacks can
    /// race without ever resuming the continuation more than once.
    private var terminalOutcome: Result<String, Error>?

    init(destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination; self.maximumBytes = maximumBytes; self.progress = progress
    }

    func run(session: URLSession, url: URL) async throws -> String {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let fileHandle = try FileHandle(forWritingTo: destination)
        guard install(fileHandle) else {
            try? fileHandle.close()
            throw CopilotRuntimeAcquisitionError.cancellation
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDataTask?
                let terminalOutcome: Result<String, Error>?
                stateLock.lock()
                terminalOutcome = self.terminalOutcome
                if terminalOutcome == nil {
                    self.continuation = continuation
                    let createdTask = session.dataTask(with: request)
                    self.task = createdTask
                    task = createdTask
                } else {
                    task = nil
                }
                stateLock.unlock()
                if let terminalOutcome {
                    continuation.resume(with: terminalOutcome)
                    return
                }
                task?.resume()
            }
        }, onCancel: { [weak self] in
            self?.finish(.failure(CopilotRuntimeAcquisitionError.cancellation), cancelTask: true)
        })
    }

    private static func isCleanHTTPSURL(_ url: URL, host: String) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let observedHost = url.host?.lowercased()
        else { return false }
        return observedHost == host
    }

    static func isApprovedInitialURL(_ url: URL) -> Bool {
        isCleanHTTPSURL(url, host: CopilotRuntimeRelease.githubAuthority)
    }

    static func isApprovedRedirect(from source: URL, to destination: URL) -> Bool {
        isApprovedInitialURL(source)
            && isCleanHTTPSURL(destination, host: "release-assets.githubusercontent.com")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        stateLock.lock()
        let acceptsRedirect = terminalOutcome == nil
            && !acceptedRedirect
            && task.originalRequest?.url.map({ original in
                newRequest.url.map { Self.isApprovedRedirect(from: original, to: $0) } ?? false
            }) == true
        if acceptsRedirect { acceptedRedirect = true }
        stateLock.unlock()
        guard acceptsRedirect else {
            finish(.failure(CopilotRuntimeAcquisitionError.redirectRejected), cancelTask: true)
            completionHandler(nil)
            return
        }
        completionHandler(newRequest)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        stateLock.lock()
        let acceptsResponse = terminalOutcome == nil
            && (response as? HTTPURLResponse)?.statusCode == 200
        if acceptsResponse, let response = response as? HTTPURLResponse {
            expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        }
        let responseTooLarge = expected.map { $0 > maximumBytes } ?? false
        stateLock.unlock()
        guard acceptsResponse else {
            finish(.failure(CopilotRuntimeAcquisitionError.invalidResponse), cancelTask: true)
            completionHandler(.cancel)
            return
        }
        if responseTooLarge {
            finish(.failure(CopilotRuntimeAcquisitionError.archiveTooLarge), cancelTask: true)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let progressUpdate: (Int64, Int64?)?
        let failure: Error?
        stateLock.lock()
        if terminalOutcome != nil {
            progressUpdate = nil
            failure = nil
        } else if Int64(data.count) > maximumBytes - received {
            progressUpdate = nil
            failure = CopilotRuntimeAcquisitionError.archiveTooLarge
        } else if let handle {
            do {
                try handle.write(contentsOf: data)
                received += Int64(data.count)
                hasher.update(data: data)
                progressUpdate = (received, expected)
                failure = nil
            } catch {
                progressUpdate = nil
                failure = error
            }
        } else {
            progressUpdate = nil
            failure = CopilotRuntimeAcquisitionError.invalidResponse
        }
        stateLock.unlock()
        if let failure {
            finish(.failure(failure), cancelTask: true)
        } else if let progressUpdate {
            progress(progressUpdate.0, progressUpdate.1)
        } else {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let isTerminal = terminalOutcome != nil
        let outcome: Result<String, Error>?
        if isTerminal {
            outcome = nil
        } else if let error {
            outcome = .failure(error)
        } else {
            outcome = .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        stateLock.unlock()
        if let outcome { finish(outcome, cancelTask: false) }
    }

    /// Atomically records the first terminal result, detaches all mutable
    /// resources, then closes/resumes outside the lock to avoid delegate
    /// reentrancy. Later cancellation/response/completion callbacks are no-ops.
    private func finish(_ outcome: Result<String, Error>, cancelTask: Bool) {
        let continuation: CheckedContinuation<String, Error>?
        let handle: FileHandle?
        let task: URLSessionDataTask?
        stateLock.lock()
        guard terminalOutcome == nil else {
            stateLock.unlock()
            return
        }
        terminalOutcome = outcome
        continuation = self.continuation
        self.continuation = nil
        handle = self.handle
        self.handle = nil
        task = self.task
        self.task = nil
        stateLock.unlock()
        try? handle?.close()
        if cancelTask { task?.cancel() }
        continuation?.resume(with: outcome)
    }

    private func install(_ fileHandle: FileHandle) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminalOutcome == nil else { return false }
        handle = fileHandle
        return true
    }
}

/// Parses the gzip payload and a deliberately tiny tar profile.  The official
/// release must contain exactly one regular file named `copilot`; accepting a
/// general-purpose tar archive would broaden the writable surface needlessly.
struct CopilotRuntimeTarExtractor: CopilotRuntimeExtracting {
    func extractVerifiedExecutable(from archive: URL, to directory: URL) throws -> URL {
        let tar = try CopilotRuntimeGzip.decode(Data(contentsOf: archive), maximumOutputBytes: 300 * 1_024 * 1_024)
        var offset = 0; var executable: Data?; var sawTerminator = false
        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                try Self.requireCanonicalTerminator(in: tar, at: offset)
                sawTerminator = true
                break
            }
            let name = try string(header, 0, 100)
            let prefix = try string(header, 345, 155)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let type = header[156]
            guard type == 0 || type == 48, path == "copilot", executable == nil else { throw CopilotRuntimeAcquisitionError.invalidArchive }
            let length = try octal(header, 124, 12)
            let dataStart = offset + 512; let dataEnd = dataStart + length
            guard dataEnd <= tar.count else { throw CopilotRuntimeAcquisitionError.invalidArchive }
            executable = tar.subdata(in: dataStart..<dataEnd)
            offset = dataStart + ((length + 511) / 512) * 512
        }
        guard sawTerminator else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        guard let executable, !executable.isEmpty else { throw CopilotRuntimeAcquisitionError.executableMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = directory.appending(path: "copilot")
        try executable.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.path)
        return output
    }

    /// POSIX tar ends in exactly two zero records. We permit additional zero
    /// padding only; accepting payload after the terminator would permit a
    /// concatenated or ambiguously parsed archive.
    static func requireCanonicalTerminator(in tar: Data, at offset: Int) throws {
        let recordSize = 512
        guard offset >= 0, offset + (recordSize * 2) <= tar.count else {
            throw CopilotRuntimeAcquisitionError.invalidArchive
        }
        let first = tar[offset..<(offset + recordSize)]
        let second = tar[(offset + recordSize)..<(offset + recordSize * 2)]
        guard first.allSatisfy({ $0 == 0 }), second.allSatisfy({ $0 == 0 }),
              tar.dropFirst(offset + recordSize * 2).allSatisfy({ $0 == 0 }) else {
            throw CopilotRuntimeAcquisitionError.invalidArchive
        }
    }

    private func string(_ header: Data, _ offset: Int, _ length: Int) throws -> String {
        let bytes = header[offset..<(offset + length)].prefix { $0 != 0 }
        guard let value = String(data: bytes, encoding: .utf8), !value.contains(".."), !value.hasPrefix("/") else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        return value
    }
    private func octal(_ header: Data, _ offset: Int, _ length: Int) throws -> Int {
        let text = String(data: header[offset..<(offset + length)].prefix { $0 != 0 && $0 != 32 }, encoding: .ascii) ?? ""
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines), radix: 8), value >= 0 else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        return value
    }
}

private enum CopilotRuntimeGzip {
    static func decode(_ source: Data, maximumOutputBytes: Int) throws -> Data {
        let (deflateRange, expectedCRC32, expectedSize) = try gzipMember(in: source)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CopilotRuntimeAcquisitionError.invalidArchive
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        try source.withUnsafeBytes { input in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else { throw CopilotRuntimeAcquisitionError.invalidArchive }
            stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: deflateRange.lowerBound))
            stream.avail_in = uInt(deflateRange.count)
            repeat {
                var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
                let inputBytesBefore = stream.avail_in
                let status = try buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(destination.count)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    let outputBytes = destination.count - Int(stream.avail_out)
                    output.append(destination.bindMemory(to: UInt8.self).baseAddress!, count: outputBytes)
                    guard output.count <= maximumOutputBytes else { throw CopilotRuntimeAcquisitionError.archiveTooLarge }
                    guard result == Z_OK || result == Z_STREAM_END else {
                        throw CopilotRuntimeAcquisitionError.invalidArchive
                    }
                    // This decoder receives the complete member at once. A
                    // `Z_OK` result with neither consumed input nor output is
                    // malformed/truncated input, not an invitation to spin.
                    guard result != Z_OK
                        || stream.avail_in < inputBytesBefore
                        || outputBytes > 0
                    else { throw CopilotRuntimeAcquisitionError.invalidArchive }
                    return result
                }
                guard status == Z_STREAM_END, stream.avail_in == 0 else {
                    if status == Z_OK { continue }
                    throw CopilotRuntimeAcquisitionError.invalidArchive
                }
                break
            } while true
        }
        let actualCRC32 = output.withUnsafeBytes { bytes in
            UInt32(truncatingIfNeeded: crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
        guard actualCRC32 == expectedCRC32,
              UInt32(truncatingIfNeeded: output.count) == expectedSize
        else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        return output
    }

    /// Parses one RFC 1952 member and makes its raw DEFLATE region explicit.
    /// zlib's `inflateInit2` raw mode lets us reject any second member or
    /// trailing payload by requiring the region to be consumed exactly.
    private static func gzipMember(in source: Data) throws -> (Range<Int>, UInt32, UInt32) {
        guard source.count >= 18,
              source[0] == 0x1f, source[1] == 0x8b, source[2] == 8,
              source[3] & 0xe0 == 0
        else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        let trailerStart = source.count - 8
        var offset = 10
        let flags = source[3]
        if flags & 0x04 != 0 {
            guard offset + 2 <= trailerStart else { throw CopilotRuntimeAcquisitionError.invalidArchive }
            let length = Int(source[offset]) | (Int(source[offset + 1]) << 8)
            offset += 2
            guard offset + length <= trailerStart else { throw CopilotRuntimeAcquisitionError.invalidArchive }
            offset += length
        }
        if flags & 0x08 != 0 { offset = try skipCString(in: source, from: offset, before: trailerStart) }
        if flags & 0x10 != 0 { offset = try skipCString(in: source, from: offset, before: trailerStart) }
        if flags & 0x02 != 0 {
            guard offset + 2 <= trailerStart else { throw CopilotRuntimeAcquisitionError.invalidArchive }
            offset += 2
        }
        guard offset < trailerStart else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        let expectedCRC32 = littleEndian32(source, at: trailerStart)
        let expectedSize = littleEndian32(source, at: trailerStart + 4)
        return (offset..<trailerStart, expectedCRC32, expectedSize)
    }

    private static func skipCString(in source: Data, from offset: Int, before limit: Int) throws -> Int {
        guard offset < limit else { throw CopilotRuntimeAcquisitionError.invalidArchive }
        guard let terminator = source[offset..<limit].firstIndex(of: 0) else {
            throw CopilotRuntimeAcquisitionError.invalidArchive
        }
        return terminator + 1
    }

    private static func littleEndian32(_ source: Data, at offset: Int) -> UInt32 {
        UInt32(source[offset])
            | (UInt32(source[offset + 1]) << 8)
            | (UInt32(source[offset + 2]) << 16)
            | (UInt32(source[offset + 3]) << 24)
    }
}

struct CopilotRuntimeCodeValidator: CopilotRuntimeValidating {
    private let requirementPreflight: @Sendable (String) -> Bool

    init(requirementPreflight: @escaping @Sendable (String) -> Bool = { text in
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess && requirement != nil
    }) {
        self.requirementPreflight = requirementPreflight
    }

    static var requirementText: String {
        "identifier \"\(CopilotRuntimeRelease.signingIdentifier)\" and certificate leaf[subject.OU] = \"\(CopilotRuntimeRelease.signingTeam)\" and anchor apple generic"
    }

    func hasParsableRequirement() -> Bool { requirementPreflight(Self.requirementText) }

    func validate(_ executable: URL, architecture: CopilotRuntimeArchitecture) throws {
        let requirementText = Self.requirementText
        guard requirementPreflight(requirementText) else { throw CopilotRuntimeAcquisitionError.invalidCodeSignature }
        let header = try Data(contentsOf: executable, options: .mappedIfSafe).prefix(8)
        guard header.count == 8, header.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }) == UInt32(0xfeedfacf).littleEndian,
              header.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }) == architecture.cpuType.littleEndian else { throw CopilotRuntimeAcquisitionError.invalidExecutableArchitecture }
        var code: SecStaticCode?; guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { throw CopilotRuntimeAcquisitionError.invalidCodeSignature }
        var requirement: SecRequirement?; guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw CopilotRuntimeAcquisitionError.invalidCodeSignature }
        var information: CFDictionary?; guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let flags = (information as? [CFString: Any])?[kSecCodeInfoFlags] as? UInt32,
              flags & 0x10000 != 0 else { throw CopilotRuntimeAcquisitionError.invalidCodeSignature }
    }
}

struct CopilotRuntimeSHA256Hasher: CopilotRuntimeHashing {
    func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty {
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct CopilotRuntimeFileManager: CopilotRuntimeFileManaging {
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return directory
    }
    func removeIfPresent(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    func installedExecutable(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) -> URL { root.appending(path: release.version).appending(path: architecture.rawValue).appending(path: "copilot") }
    func install(_ executable: URL, root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws -> URL {
        try CopilotRuntimeInstallLock.withExclusiveLock(root: root) {
            let rootDescriptor = try CopilotRuntimePOSIX.openDirectoryTree(root, create: true)
            defer { close(rootDescriptor) }
            let versionDescriptor = try CopilotRuntimePOSIX.openOrCreateDirectory(release.version, beneath: rootDescriptor)
            defer { close(versionDescriptor) }
            let architectureDescriptor = try CopilotRuntimePOSIX.openOrCreateDirectory(architecture.rawValue, beneath: versionDescriptor)
            defer { close(architectureDescriptor) }

            let source = try CopilotRuntimePOSIX.openVerifiedRegularFile(executable)
            defer { close(source) }
            let stageName = ".copilot-stage-\(UUID().uuidString.lowercased())"
            let stage = openat(architectureDescriptor, stageName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IXUSR)
            guard stage >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
            defer { _ = unlinkat(architectureDescriptor, stageName, 0); close(stage) }
            try CopilotRuntimePOSIX.copy(source: source, destination: stage)
            guard fchmod(stage, S_IRUSR | S_IXUSR) == 0, fsync(stage) == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
            try CopilotRuntimePOSIX.requirePrivateRegularFile(stage)
            // `renameat` is an atomic publication in the already-open target
            // directory. No path lookup can follow a swapped ancestor.
            guard renameat(architectureDescriptor, stageName, architectureDescriptor, "copilot") == 0,
                  fsync(architectureDescriptor) == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
            let installedDescriptor = try CopilotRuntimePOSIX.openRegularFile("copilot", beneath: architectureDescriptor)
            defer { close(installedDescriptor) }
            try CopilotRuntimePOSIX.requirePrivateRegularFile(installedDescriptor)
            return installedExecutable(root: root, release: release, architecture: architecture)
        }
    }
    func removeInstalled(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws {
        try CopilotRuntimeInstallLock.withExclusiveLock(root: root) {
            let architectureDescriptor = try runtimeDirectory(root: root, release: release, architecture: architecture)
            defer { close(architectureDescriptor) }
            let executable = openat(architectureDescriptor, "copilot", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if executable >= 0 {
                defer { close(executable) }
                try CopilotRuntimePOSIX.requirePrivateRegularFile(executable)
                guard unlinkat(architectureDescriptor, "copilot", 0) == 0 else {
                    throw CopilotRuntimeAcquisitionError.fileSystem
                }
            } else if errno != ENOENT {
                throw CopilotRuntimeAcquisitionError.fileSystem
            }
            try CopilotRuntimePOSIX.removeStaleStageFiles(beneath: architectureDescriptor)
            guard fsync(architectureDescriptor) == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        }
    }

    func scavengeStaleStages(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws {
        try CopilotRuntimeInstallLock.withExclusiveLock(root: root) {
            let architectureDescriptor = try runtimeDirectory(root: root, release: release, architecture: architecture)
            defer { close(architectureDescriptor) }
            try CopilotRuntimePOSIX.removeStaleStageFiles(beneath: architectureDescriptor)
            guard fsync(architectureDescriptor) == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        }
    }

    private func runtimeDirectory(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws -> Int32 {
        let rootDescriptor = try CopilotRuntimePOSIX.openDirectoryTree(root, create: true)
        defer { close(rootDescriptor) }
        let versionDescriptor = try CopilotRuntimePOSIX.openOrCreateDirectory(release.version, beneath: rootDescriptor)
        defer { close(versionDescriptor) }
        return try CopilotRuntimePOSIX.openOrCreateDirectory(architecture.rawValue, beneath: versionDescriptor)
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

private enum CopilotRuntimePOSIX {
    private static let privateDirectoryMode: mode_t = S_IRWXU
    private static let privateExecutableMode: mode_t = S_IRUSR | S_IXUSR
    private static let stagePrefix = ".copilot-stage-"

    static func openDirectoryTree(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL else { throw CopilotRuntimeAcquisitionError.fileSystem }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        let components = url.pathComponents.filter { $0 != "/" }
        for (index, component) in components.enumerated() {
            do {
                // Every component is opened with O_NOFOLLOW. Only the
                // app-owned root itself needs the private-mode invariant;
                // system ancestors such as /Users are not Triage-owned.
                let child = try openOrCreateDirectory(
                    component,
                    beneath: descriptor,
                    create: create,
                    requirePrivate: index == components.count - 1
                )
                close(descriptor); descriptor = child
            } catch {
                close(descriptor); throw error
            }
        }
        return descriptor
    }

    static func openOrCreateDirectory(_ name: String, beneath parent: Int32, create: Bool = true, requirePrivate: Bool = true) throws -> Int32 {
        guard isSafeComponent(name) else { throw CopilotRuntimeAcquisitionError.fileSystem }
        var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, create {
            guard mkdirat(parent, name, privateDirectoryMode) == 0 || errno == EEXIST else { throw CopilotRuntimeAcquisitionError.fileSystem }
            descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        if requirePrivate {
            do { try requirePrivateDirectory(descriptor) } catch { close(descriptor); throw error }
        }
        return descriptor
    }

    static func openVerifiedRegularFile(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        do { try requirePrivateRegularFile(descriptor) } catch { close(descriptor); throw error }
        return descriptor
    }

    static func openRegularFile(_ name: String, beneath parent: Int32) throws -> Int32 {
        guard isSafeComponent(name) else { throw CopilotRuntimeAcquisitionError.fileSystem }
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        do { try requirePrivateRegularFile(descriptor) } catch { close(descriptor); throw error }
        return descriptor
    }

    static func copy(source: Int32, destination: Int32) throws {
        guard lseek(source, 0, SEEK_SET) >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count == 0 { return }
            guard count > 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { write(destination, $0.baseAddress!.advanced(by: written), count - written) }
                guard result > 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
                written += result
            }
        }
    }

    static func requirePrivateDirectory(_ descriptor: Int32) throws {
        var information = stat(); guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid(),
              (information.st_mode & S_IFMT) == S_IFDIR,
              (information.st_mode & 0o077) == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
    }

    static func requirePrivateRegularFile(_ descriptor: Int32) throws {
        var information = stat(); guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid(),
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_nlink == 1,
              (information.st_mode & 0o077) == 0,
              (information.st_mode & privateExecutableMode) == privateExecutableMode else { throw CopilotRuntimeAcquisitionError.fileSystem }
    }

    /// Scavenge only files that can have been created by our descriptor-safe
    /// publisher. Other names are never enumerated for deletion.
    static func removeStaleStageFiles(beneath directory: Int32) throws {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw CopilotRuntimeAcquisitionError.fileSystem
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(decodingCString: $0, as: UTF8.self)
                }
            }
            guard isStagingName(name) else { continue }
            let stage = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard stage >= 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
            do {
                try requirePrivateRegularFile(stage)
            } catch {
                close(stage)
                throw error
            }
            close(stage)
            guard unlinkat(directory, name, 0) == 0 else { throw CopilotRuntimeAcquisitionError.fileSystem }
        }
    }

    private static func isStagingName(_ name: String) -> Bool {
        guard name.hasPrefix(stagePrefix) else { return false }
        let suffix = String(name.dropFirst(stagePrefix.count))
        return UUID(uuidString: suffix)?.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }
}
