import Darwin
import Foundation
import XCTest

@testable import Triage

final class CopilotRuntimeAcquisitionTests: XCTestCase {
    func testRuntimeIsAbsentAndNoNetworkStartsUntilExplicitUserRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()

        let state = await service.state()
        XCTAssertEqual(state, .absent)
        XCTAssertEqual(fixture.downloader.calls, 0)
        XCTAssertEqual(fixture.extractor.calls, 0)
    }

    func testVerifiedExplicitAcquisitionInstallsPinnedArchitectureAndRevalidatesBeforeUse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()

        let installed = try await service.acquireAtUserRequest()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(installed.lastPathComponent, "copilot")
        XCTAssertTrue(installed.path.contains("Triage/CopilotRuntime/1.0.81-10/arm64"))
        XCTAssertEqual(fixture.downloader.calls, 1)
        XCTAssertEqual(fixture.extractor.calls, 1)
        XCTAssertEqual(fixture.validator.calls, 2, "validate before and after atomic publish")

        let runtimeForUse = try await service.runtimeForUse()
        XCTAssertEqual(runtimeForUse, installed)
        XCTAssertEqual(fixture.validator.calls, 3, "future execution must revalidate")
    }

    func testVerifiedInstalledRuntimeIsDetectedAndRevalidatedAfterRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.service()
        let installed = try await first.acquireAtUserRequest()
        let validationCallsAfterInstall = fixture.validator.calls

        let relaunched = try fixture.service()
        let state = await relaunched.state()

        XCTAssertEqual(state, .ready(installed))
        XCTAssertEqual(fixture.downloader.calls, 1, "local detection must never start a download")
        XCTAssertEqual(
            fixture.validator.calls,
            validationCallsAfterInstall + 1,
            "the persisted executable must be revalidated before it is shown as ready"
        )
    }

    func testAbsentStateReconcilesAnAtomicInstallCompletedByAnotherService() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observer = try fixture.service()
        let initial = await observer.state()
        XCTAssertEqual(initial, .absent)

        let installer = try fixture.service()
        let installed = try await installer.acquireAtUserRequest()
        let observed = await observer.state()

        XCTAssertEqual(observed, .ready(installed))
        XCTAssertEqual(fixture.downloader.calls, 1, "state reconciliation must remain local-only")
    }

    func testPinnedArchiveAndExecutableDigestsAreDistinctForEachArchitecture() {
        let arm64 = CopilotRuntimeRelease.pinned.archive(for: .arm64)
        XCTAssertEqual(arm64.expectedArchiveSHA256, "7d693bfdc82f1a1223d4fe034903faeb16063cbc0075d0f45e04af1ea7914871")
        XCTAssertEqual(arm64.expectedExecutableSHA256, "2f4238eebaa42e1196e4f9473a06d03fca612fd6fed09bb9033d9c506d4a5e9a")
        XCTAssertNotEqual(arm64.expectedArchiveSHA256, arm64.expectedExecutableSHA256)

        let x86_64 = CopilotRuntimeRelease.pinned.archive(for: .x86_64)
        XCTAssertEqual(x86_64.expectedArchiveSHA256, "1fb04e8e040525ae39cf53cce7f9e44b7d3fbb200bc9bfe38e2e7436d7dd3b74")
        XCTAssertEqual(x86_64.expectedExecutableSHA256, "8da653f6c4944d6be001af17aaf6d685066c91b1f62af543bbc3ebb35b85435c")
        XCTAssertNotEqual(x86_64.expectedArchiveSHA256, x86_64.expectedExecutableSHA256)
    }

    func testTarTerminatorRequiresTwoZeroBlocksAndOnlyZeroPadding() {
        XCTAssertNoThrow(try CopilotRuntimeTarExtractor.requireCanonicalTerminator(in: Data(repeating: 0, count: 1_024), at: 0))
        XCTAssertNoThrow(try CopilotRuntimeTarExtractor.requireCanonicalTerminator(in: Data(repeating: 0, count: 1_536), at: 0))

        XCTAssertThrowsError(try CopilotRuntimeTarExtractor.requireCanonicalTerminator(in: Data(repeating: 0, count: 512), at: 0))

        var trailingPayload = Data(repeating: 0, count: 1_024)
        trailingPayload.append(1)
        XCTAssertThrowsError(try CopilotRuntimeTarExtractor.requireCanonicalTerminator(in: trailingPayload, at: 0))

        var missingSecondZeroRecord = Data(repeating: 0, count: 1_024)
        missingSecondZeroRecord[700] = 1
        XCTAssertThrowsError(try CopilotRuntimeTarExtractor.requireCanonicalTerminator(in: missingSecondZeroRecord, at: 0))
    }

    func testRealTarExtractorAcceptsOnlyTheExpectedRegularExecutable() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let payload = Data("verified executable bytes".utf8)
        let archive = RuntimeArchiveFixture.gzip(
            RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", payload: payload)])
        )

        let executable = try fixture.extract(archive)
        XCTAssertEqual(executable.lastPathComponent, "copilot")
        XCTAssertEqual(try Data(contentsOf: executable), payload)
    }

    func testRealTarExtractorRejectsTraversalLinksSpecialFilesDuplicatesAndInvalidTermination() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let payload = Data("untrusted".utf8)
        let malformedTars: [Data] = [
            RuntimeArchiveFixture.tar(entries: [.init(name: "../copilot", payload: payload)]),
            RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", type: 49, payload: Data())]), // hard link
            RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", type: 50, payload: Data())]), // symlink
            RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", type: 51, payload: Data())]), // character device
            RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", type: 54, payload: Data())]), // FIFO
            RuntimeArchiveFixture.tar(entries: [
                .init(name: "copilot", payload: payload),
                .init(name: "copilot", payload: payload),
            ]),
            RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", payload: payload)], terminatorRecords: 1),
            RuntimeArchiveFixture.tar(
                entries: [.init(name: "copilot", payload: payload)],
                trailingBytes: Data([0x01])
            ),
        ]

        for tar in malformedTars {
            XCTAssertThrowsError(try fixture.extract(RuntimeArchiveFixture.gzip(tar)))
        }
    }

    func testRealTarExtractorRejectsMalformedAndConcatenatedGzipMembers() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.extract(Data([0x1f, 0x8b, 0x08, 0x00, 0xff])))

        let tar = RuntimeArchiveFixture.tar(entries: [.init(name: "copilot", payload: Data("runtime".utf8))])
        var concatenated = RuntimeArchiveFixture.gzip(tar)
        concatenated.append(RuntimeArchiveFixture.gzip(tar))
        XCTAssertThrowsError(try fixture.extract(concatenated))
    }

    func testHashMismatchDoesNotExtractOrInstall() async throws {
        let fixture = try Fixture(digest: "not-the-pinned-hash")
        defer { fixture.remove() }
        let service = try fixture.service()

        await assertRuntimeThrows { _ = try await service.acquireAtUserRequest() }
        XCTAssertEqual(fixture.extractor.calls, 0)
        let state = await service.state()
        XCTAssertEqual(state, .absent)
    }

    func testExecutablePinMismatchDoesNotInstall() async throws {
        let fixture = try Fixture(executableDigest: "not-the-pinned-executable-hash")
        defer { fixture.remove() }
        let service = try fixture.service()

        await assertRuntimeThrows { _ = try await service.acquireAtUserRequest() }
        XCTAssertEqual(fixture.extractor.calls, 1)
        XCTAssertEqual(fixture.validator.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeExecutable.path))
        let state = await service.state()
        XCTAssertEqual(state, .absent)
    }

    func testRedirectAndOversizedArchiveFailuresAreFailClosed() async throws {
        for error in [CopilotRuntimeAcquisitionError.redirectRejected, .archiveTooLarge] {
            let fixture = try Fixture(downloadError: error)
            defer { fixture.remove() }
            let service = try fixture.service()
            await assertRuntimeThrows { _ = try await service.acquireAtUserRequest() }
            XCTAssertEqual(fixture.extractor.calls, 0)
            let state = await service.state()
            XCTAssertEqual(state, .absent)
        }
    }

    func testMaliciousArchiveSignatureAndArchitectureFailuresNeverPublishRuntime() async throws {
        let cases: [(CopilotRuntimeAcquisitionError?, CopilotRuntimeAcquisitionError?)] = [
            (.invalidArchive, nil),
            (nil, .invalidExecutableArchitecture),
            (nil, .invalidCodeSignature),
        ]
        for (extractError, validationError) in cases {
            let fixture = try Fixture(extractError: extractError, validationError: validationError)
            defer { fixture.remove() }
            let service = try fixture.service()
            await assertRuntimeThrows { _ = try await service.acquireAtUserRequest() }
            await assertRuntimeThrows { _ = try await service.runtimeForUse() }
        }
    }

    func testCancellationLeavesNoInstalledRuntime() async throws {
        let fixture = try Fixture(downloadError: .cancellation)
        defer { fixture.remove() }
        let service = try fixture.service()

        await assertRuntimeThrows { _ = try await service.acquireAtUserRequest() }
        let state = await service.state()
        XCTAssertEqual(state, .absent)
        await assertRuntimeThrows { _ = try await service.runtimeForUse() }
    }

    func testRemoveSupersedesSuspendedAcquisitionBeforeExtractionOrInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloader = SuspendedDownloader(digest: fixture.archiveDigest)
        let service = try fixture.service(downloader: downloader)
        let acquisition = Task { await acquisitionError(from: service) }

        await downloader.waitUntilStarts(1)
        try await service.removeAtUserRequest()
        await downloader.resumeNext()

        let acquisitionResult = await acquisition.value
        XCTAssertEqual(acquisitionResult, .cancellation)
        XCTAssertEqual(fixture.extractor.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeExecutable.path))
        let state = await service.state()
        XCTAssertEqual(state, .absent)
    }

    func testNewerAcquisitionSupersedesOlderSuspendedAcquisitionBeforeExtraction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloader = SuspendedDownloader(digest: fixture.archiveDigest)
        let service = try fixture.service(downloader: downloader)
        let first = Task { await acquisitionError(from: service) }
        await downloader.waitUntilStarts(1)
        let second = Task { await acquisitionError(from: service) }
        await downloader.waitUntilStarts(2)

        await downloader.resumeNext()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .cancellation)
        await downloader.resumeNext()

        let secondResult = await second.value
        XCTAssertNil(secondResult)
        XCTAssertEqual(fixture.extractor.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.runtimeExecutable.path))
    }

    func testCancellationDuringSynchronousInstallRollsBackPublishedRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = BlockingInstallFiles()
        let service = try fixture.service(files: files)
        let acquisition = Task { await acquisitionError(from: service) }

        XCTAssertEqual(files.waitForInstallStart(), .success)
        acquisition.cancel()
        files.allowInstallToFinish()

        let acquisitionResult = await acquisition.value
        XCTAssertEqual(acquisitionResult, .cancellation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeExecutable.path))
        let state = await service.state()
        XCTAssertEqual(state, .absent)
    }

    func testAcquireAndRemoveScavengeOnlyUUIDStagingArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stage = try fixture.makeStaleStage(named: ".copilot-stage-\(UUID().uuidString.lowercased())")
        let nonStage = try fixture.makeStaleStage(named: ".copilot-stage-not-a-uuid")
        let service = try fixture.service()

        _ = try await service.acquireAtUserRequest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonStage.path))

        let removeStage = try fixture.makeStaleStage(named: ".copilot-stage-\(UUID().uuidString.lowercased())")
        try await service.removeAtUserRequest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeExecutable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removeStage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonStage.path))
    }

    func testDelayedProgressAfterCancellationCannotOverwriteAbsentState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-progress-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = DelayedProgressDownloader()
        let service = try CopilotRuntimeAcquisitionService(
            applicationSupportDirectory: root,
            architecture: .arm64,
            downloader: downloader,
            extractor: Extractor(error: nil),
            validator: Validator(error: nil)
        )

        await assertRuntimeThrows { _ = try await service.acquireAtUserRequest() }
        downloader.emitDelayedProgress()
        for _ in 0..<16 { await Task.yield() }
        let state = await service.state()
        XCTAssertEqual(state, .absent)
    }

    func testCancellationResponseAndCompletionRaceResumesDownloadOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-transfer-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "URLProtocol started")
        SuspendedRuntimeDownloadURLProtocol.setStartHandler { started.fulfill() }
        defer { SuspendedRuntimeDownloadURLProtocol.setStartHandler(nil) }

        let source = URL(string: "https://github.com/github/copilot-cli/releases/download/v1.0.81-10/copilot-darwin-arm64.tar.gz")!
        let transfer = CopilotRuntimeURLTransfer(
            destination: root.appending(path: "runtime.tar.gz"),
            maximumBytes: 1_024,
            progress: { _, _ in }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedRuntimeDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let operation = Task { () -> Bool in
            do {
                _ = try await transfer.run(session: session, url: source)
                return false
            } catch let error as CopilotRuntimeAcquisitionError {
                return error == .cancellation
            } catch {
                return false
            }
        }
        await fulfillment(of: [started], timeout: 1)
        operation.cancel()

        let callbackTask = session.dataTask(with: source)
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: nil))
        transfer.urlSession(session, dataTask: callbackTask, didReceive: response) { _ in }
        transfer.urlSession(session, task: callbackTask, didCompleteWithError: nil)
        let didCancel = await operation.value
        XCTAssertTrue(didCancel)
    }

    func testRedirectPolicyAllowsOnlyGitHubsSignedPinnedAssetRedirect() {
        let source = URL(string: "https://github.com/github/copilot-cli/releases/download/v1.0.81-10/copilot-darwin-arm64.tar.gz")!
        var components = URLComponents(string: "https://release-assets.githubusercontent.com/github-production-release-asset/585860664/72ea65b1-51c9-4b30-87ed-e9ca2904af61")!
        components.queryItems = [
            URLQueryItem(name: "sig", value: "signed-value"),
            URLQueryItem(name: "jwt", value: "bounded-token"),
            URLQueryItem(name: "rscd", value: "attachment; filename=copilot-darwin-arm64.tar.gz"),
        ]
        let releaseAsset = components.url!
        XCTAssertTrue(CopilotRuntimeURLTransfer.isApprovedInitialURL(source))
        XCTAssertTrue(CopilotRuntimeURLTransfer.isApprovedRedirect(from: source, to: releaseAsset))
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedInitialURL(releaseAsset))
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedRedirect(
            from: source,
            to: URL(string: "https://release-assets.githubusercontent.com/copilot-darwin-arm64.tar.gz")!
        ))
        components.queryItems = [
            URLQueryItem(name: "sig", value: "signed-value"),
            URLQueryItem(name: "jwt", value: "bounded-token"),
            URLQueryItem(name: "rscd", value: "attachment; filename=other-file.tar.gz"),
        ]
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedRedirect(from: source, to: components.url!))
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedInitialURL(URL(string: "http://github.com/file")!))
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedInitialURL(URL(string: "https://evil.example/file")!))
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedInitialURL(URL(string: "https://github.com/file?token=secret")!))
        XCTAssertFalse(CopilotRuntimeURLTransfer.isApprovedInitialURL(URL(string: "https://user:secret@github.com/file")!))
    }

    func testDescriptorPublisherRejectsSymlinkAncestorAndHardlinkedSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = CopilotRuntimeFileManager()
        let source = fixture.root.appending(path: "source")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: source.path)

        let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let swappedRuntimeRoot = fixture.root.appending(path: "swapped", directoryHint: .isDirectory)
        XCTAssertEqual(symlink(outside.path, swappedRuntimeRoot.path), 0)
        XCTAssertThrowsError(try files.install(source, root: swappedRuntimeRoot, release: .pinned, architecture: .arm64))

        let hardlink = fixture.root.appending(path: "source-link")
        XCTAssertEqual(link(source.path, hardlink.path), 0)
        let runtimeRoot = fixture.root.appending(path: "runtime", directoryHint: .isDirectory)
        XCTAssertThrowsError(try files.install(source, root: runtimeRoot, release: .pinned, architecture: .arm64))
    }

    func testDescriptorPublisherInstallsPrivateSingleLinkExecutable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appending(path: "valid-source")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: source.path)
        let installed = try CopilotRuntimeFileManager().install(
            source,
            root: fixture.runtimeRoot,
            release: .pinned,
            architecture: .arm64
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }

    func testStagingScavengerRejectsFIFOWithoutBlocking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fifo = fixture.runtimeDirectory.appending(path: ".copilot-stage-\(UUID().uuidString.lowercased())")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertThrowsError(
            try CopilotRuntimeFileManager().scavengeStaleStages(
                root: fixture.runtimeRoot,
                release: .pinned,
                architecture: .arm64
            )
        )
    }

    func testCodeRequirementTextUsesNormalQuotedRequirementAndInjectableParserSeam() {
        XCTAssertEqual(
            CopilotRuntimeCodeValidator.requirementText,
            "identifier \"copilot\" and certificate leaf[subject.OU] = \"VEKTX9H2N7\" and anchor apple generic"
        )
        let accepted = CopilotRuntimeCodeValidator { _ in true }
        XCTAssertTrue(accepted.hasParsableRequirement())
        let rejected = CopilotRuntimeCodeValidator { _ in false }
        XCTAssertFalse(rejected.hasParsableRequirement())
    }
}

private final class Fixture {
    let root: URL
    let downloader: Downloader
    let extractor: Extractor
    let validator: Validator
    let executableDigest: String

    var archiveDigest: String { CopilotRuntimeRelease.pinned.archive(for: .arm64).expectedArchiveSHA256 }
    var runtimeRoot: URL {
        CopilotRuntimeAcquisitionService.runtimeRoot(applicationSupportDirectory: root)
    }
    var runtimeDirectory: URL { runtimeRoot.appending(path: "1.0.81-10/arm64", directoryHint: .isDirectory) }
    var runtimeExecutable: URL { runtimeDirectory.appending(path: "copilot") }

    init(
        digest: String = CopilotRuntimeRelease.pinned.archive(for: .arm64).expectedArchiveSHA256,
        executableDigest: String = CopilotRuntimeRelease.pinned.archive(for: .arm64).expectedExecutableSHA256,
        downloadError: CopilotRuntimeAcquisitionError? = nil,
        extractError: CopilotRuntimeAcquisitionError? = nil,
        validationError: CopilotRuntimeAcquisitionError? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "triage-copilot-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        downloader = Downloader(digest: digest, error: downloadError)
        extractor = Extractor(error: extractError)
        validator = Validator(error: validationError)
        self.executableDigest = executableDigest
    }

    func service(
        downloader: (any CopilotRuntimeDownloading)? = nil,
        files: (any CopilotRuntimeFileManaging)? = nil
    ) throws -> CopilotRuntimeAcquisitionService {
        try CopilotRuntimeAcquisitionService(
            applicationSupportDirectory: root,
            architecture: .arm64,
            downloader: downloader ?? self.downloader,
            extractor: extractor,
            validator: validator,
            hasher: FileHasher(digest: executableDigest),
            files: files ?? CopilotRuntimeFileManager()
        )
    }

    func makeStaleStage(named name: String) throws -> URL {
        for directory in [
            root.appending(path: "Triage", directoryHint: .isDirectory),
            runtimeRoot,
            runtimeRoot.appending(path: "1.0.81-10", directoryHint: .isDirectory),
            runtimeDirectory,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let stage = runtimeDirectory.appending(path: name)
        try Data("partial runtime".utf8).write(to: stage)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stage.path)
        return stage
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class ArchiveFixture {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "triage-copilot-extractor-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func extract(_ archive: Data) throws -> URL {
        let token = UUID().uuidString
        let archiveURL = root.appending(path: "\(token).tar.gz")
        try archive.write(to: archiveURL, options: .atomic)
        return try CopilotRuntimeTarExtractor().extractVerifiedExecutable(
            from: archiveURL,
            to: root.appending(path: "\(token)-output", directoryHint: .isDirectory)
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum RuntimeArchiveFixture {
    struct Entry {
        let name: String
        let type: UInt8
        let payload: Data

        init(name: String, type: UInt8 = 48, payload: Data) {
            self.name = name
            self.type = type
            self.payload = payload
        }
    }

    static func tar(
        entries: [Entry],
        terminatorRecords: Int = 2,
        trailingBytes: Data = Data()
    ) -> Data {
        var archive = Data()
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            putASCII(entry.name, into: &header, at: 0, limit: 100)
            putASCII(String(format: "%011o", entry.payload.count), into: &header, at: 124, limit: 11)
            header[156] = entry.type
            archive.append(header)
            archive.append(entry.payload)
            let padding = (512 - (entry.payload.count % 512)) % 512
            archive.append(Data(repeating: 0, count: padding))
        }
        archive.append(Data(repeating: 0, count: terminatorRecords * 512))
        archive.append(trailingBytes)
        return archive
    }

    /// Emits a standards-compliant gzip stream using DEFLATE stored blocks.
    /// Keeping the fixture encoder local makes malformed-archive cases
    /// deterministic without invoking an external archiver in tests.
    static func gzip(_ input: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        var offset = 0
        repeat {
            let length = min(65_535, input.count - offset)
            let isFinal = offset + length == input.count
            output.append(isFinal ? 0x01 : 0x00) // BFINAL plus stored BTYPE.
            appendLittleEndian(UInt16(length), to: &output)
            appendLittleEndian(~UInt16(length), to: &output)
            if length > 0 {
                output.append(input.subdata(in: offset..<(offset + length)))
                offset += length
            }
        } while offset < input.count
        appendLittleEndian(crc32(input), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: input.count), to: &output)
        return output
    }

    private static func putASCII(_ value: String, into data: inout Data, at offset: Int, limit: Int) {
        let bytes = Array(value.utf8)
        precondition(bytes.count <= limit)
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(_ input: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in input {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb8_8320
            }
        }
        return ~value
    }
}

private final class Downloader: CopilotRuntimeDownloading, @unchecked Sendable {
    private let digest: String; private let error: CopilotRuntimeAcquisitionError?
    private(set) var calls = 0
    init(digest: String, error: CopilotRuntimeAcquisitionError?) { self.digest = digest; self.error = error }
    func download(_ archive: CopilotRuntimeArchive, to destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        calls += 1
        if let error { throw error }
        try Data("synthetic archive".utf8).write(to: destination)
        progress(17, 17)
        return digest
    }
}

private final class DelayedProgressDownloader: CopilotRuntimeDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var progress: (@Sendable (Int64, Int64?) -> Void)?

    func download(_ archive: CopilotRuntimeArchive, to destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        lock.withLock { self.progress = progress }
        throw CopilotRuntimeAcquisitionError.cancellation
    }

    func emitDelayedProgress() {
        let callback = lock.withLock { progress }
        callback?(42, 42)
    }
}

private actor SuspendedDownloader: CopilotRuntimeDownloading {
    private let digest: String
    private var starts = 0
    private var continuations: [CheckedContinuation<String, Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(digest: String) { self.digest = digest }

    func download(_ archive: CopilotRuntimeArchive, to destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        try Data("suspended archive".utf8).write(to: destination)
        starts += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitUntilStarts(_ expected: Int) async {
        while starts < expected {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: digest)
    }
}

private final class BlockingInstallFiles: CopilotRuntimeFileManaging, @unchecked Sendable {
    private let base = CopilotRuntimeFileManager()
    private let installStarted = DispatchSemaphore(value: 0)
    private let allowInstall = DispatchSemaphore(value: 0)

    func makeTemporaryDirectory() throws -> URL { try base.makeTemporaryDirectory() }
    func removeIfPresent(_ url: URL) { base.removeIfPresent(url) }
    func installedExecutable(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) -> URL {
        base.installedExecutable(root: root, release: release, architecture: architecture)
    }
    func install(_ executable: URL, root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws -> URL {
        installStarted.signal()
        _ = allowInstall.wait(timeout: .now() + 2)
        return try base.install(executable, root: root, release: release, architecture: architecture)
    }
    func removeInstalled(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws {
        try base.removeInstalled(root: root, release: release, architecture: architecture)
    }
    func scavengeStaleStages(root: URL, release: CopilotRuntimeRelease, architecture: CopilotRuntimeArchitecture) throws {
        try base.scavengeStaleStages(root: root, release: release, architecture: architecture)
    }
    func exists(_ url: URL) -> Bool { base.exists(url) }

    func waitForInstallStart() -> DispatchTimeoutResult { installStarted.wait(timeout: .now() + 2) }
    func allowInstallToFinish() { allowInstall.signal() }
}

private final class SuspendedRuntimeDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startHandler: (() -> Void)?

    static func setStartHandler(_ handler: (() -> Void)?) {
        lock.lock()
        startHandler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.startHandler
        Self.lock.unlock()
        handler?()
    }
    override func stopLoading() {}
}

private final class Extractor: CopilotRuntimeExtracting, @unchecked Sendable {
    private let error: CopilotRuntimeAcquisitionError?
    private(set) var calls = 0
    init(error: CopilotRuntimeAcquisitionError?) { self.error = error }
    func extractVerifiedExecutable(from archive: URL, to directory: URL) throws -> URL {
        calls += 1
        if let error { throw error }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "copilot")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: executable.path)
        return executable
    }
}

private final class Validator: CopilotRuntimeValidating, @unchecked Sendable {
    private let error: CopilotRuntimeAcquisitionError?
    private(set) var calls = 0
    init(error: CopilotRuntimeAcquisitionError?) { self.error = error }
    func validate(_ executable: URL, architecture: CopilotRuntimeArchitecture) throws {
        calls += 1
        if let error { throw error }
    }
}

private struct FileHasher: CopilotRuntimeHashing {
    let digest: String
    func sha256(of file: URL) throws -> String { digest }
}

private func acquisitionError(from service: CopilotRuntimeAcquisitionService) async -> CopilotRuntimeAcquisitionError? {
    do {
        _ = try await service.acquireAtUserRequest()
        return nil
    } catch let error as CopilotRuntimeAcquisitionError {
        return error
    } catch {
        return .fileSystem
    }
}

private func assertRuntimeThrows<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
