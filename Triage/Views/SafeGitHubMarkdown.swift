import AppKit
import Foundation
import SwiftUI

struct GitHubHostedImageReference: Identifiable, Hashable {
    let url: URL
    let altText: String

    var id: URL { url }
}

enum GitHubMarkdownPolicy {
    static let maximumSourceCharacters = 100_000
    static let maximumHostedImageCount = 3
    static let maximumHostedImageURLBytes = 8 * 1_024
    static let maximumHostedImageBytes = 8 * 1_024 * 1_024

    private static let approvedImageHosts: Set<String> = [
        "github.com",
        "raw.githubusercontent.com",
        "user-images.githubusercontent.com",
        "private-user-images.githubusercontent.com",
        "github.githubassets.com"
    ]
    private static let approvedImageContentTypes: Set<String> = [
        "image/avif", "image/gif", "image/heic", "image/jpeg", "image/png", "image/webp"
    ]
    private static let markdownImageExpression = try! NSRegularExpression(
        pattern: #"!\[([^\]\r\n]{0,512})\]\(\s*(<[^>\r\n]+>|[^\s)\r\n]+)(?:\s+[\"'][^\"'\r\n]*[\"'])?\s*\)"#
    )

    static func sanitizedSource(_ source: String) -> String {
        let bounded = String(source.prefix(maximumSourceCharacters))
        let withoutComments = bounded.replacingOccurrences(
            of: #"<!--[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )
        let withoutExecutableElements = withoutComments.replacingOccurrences(
            of: #"<(script|style|iframe|object|embed|img|video|audio|svg)\b[^>]*>[\s\S]*?</\1>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // A malformed or deliberately unclosed tag must not leave an external
        // URL or executable markup for the Markdown parser to interpret.
        let withoutOpenUnsupportedElements = withoutExecutableElements.replacingOccurrences(
            of: #"<(script|style|iframe|object|embed|img|video|audio|svg)\b[^>]*>"#,
            with: "[embedded content omitted]",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutMarkdownImages = replacingMarkdownImages(in: withoutOpenUnsupportedElements)
        // HTML links and other tags bypass Markdown's URL handling. Strip
        // them rather than preserving attributes that could carry tracking or
        // an unvalidated destination. Native Markdown links remain intact.
        let withoutHTMLTags = withoutMarkdownImages.replacingOccurrences(
            of: #"</?(?!https?://|mailto:)[A-Za-z][^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return taskListAccessibleSource(withoutHTMLTags)
    }

    /// `AttributedString` keeps GitHub task-list brackets as plain punctuation.
    /// Expand them into text so VoiceOver communicates the checked state while
    /// retaining native Markdown list layout.
    private static func taskListAccessibleSource(_ source: String) -> String {
        source
            .replacingOccurrences(
                of: #"(?m)^(\s*[-*+]\s*)\[\s\]\s+"#,
                with: "$1To do: ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?mi)^(\s*[-*+]\s*)\[x\]\s+"#,
                with: "$1Completed: ",
                options: .regularExpression
            )
    }

    static func permitsExternalNavigation(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    /// Image URLs are deliberately narrower than ordinary external links. They
    /// may be fetched only after the person using Triage explicitly asks to
    /// load a known GitHub-hosted image.
    static func permitsGitHubHostedImage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              url.fragment == nil,
              url.absoluteString.lengthOfBytes(using: .utf8) <= maximumHostedImageURLBytes,
              let host = url.host?.lowercased()
        else {
            return false
        }
        return approvedImageHosts.contains(host)
    }

    static func hostedImageReferences(in source: String) -> [GitHubHostedImageReference] {
        let bounded = String(source.prefix(maximumSourceCharacters))
        let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
        var references = [GitHubHostedImageReference]()
        var seen = Set<URL>()

        for match in markdownImageExpression.matches(in: bounded, range: range) {
            guard let urlRange = Range(match.range(at: 2), in: bounded) else { continue }
            let rawURL = String(bounded[urlRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let url = URL(string: rawURL), permitsGitHubHostedImage(url), seen.insert(url).inserted else {
                continue
            }
            let altText: String
            if let altRange = Range(match.range(at: 1), in: bounded) {
                altText = String(bounded[altRange]).prefix(512).description
            } else {
                altText = ""
            }
            references.append(.init(url: url, altText: altText))
            if references.count == maximumHostedImageCount { break }
        }
        return references
    }

    static func permitsImageContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let contentType = value.split(separator: ";", maxSplits: 1).first?.lowercased()
        return contentType.map(approvedImageContentTypes.contains) ?? false
    }

    private static func replacingMarkdownImages(in source: String) -> String {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = markdownImageExpression.matches(in: source, range: range)
        var result = source

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let urlRange = Range(match.range(at: 2), in: source)
            else {
                continue
            }
            let rawURL = String(source[urlRange]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let replacement: String
            if let url = URL(string: rawURL), permitsGitHubHostedImage(url) {
                let altText = Range(match.range(at: 1), in: source).map { String(source[$0]) } ?? ""
                replacement = altText.isEmpty
                    ? "[GitHub-hosted image available below]"
                    : "[GitHub-hosted image available below: \(altText)]"
            } else {
                replacement = "[remote image omitted]"
            }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }
}

struct SafeGitHubMarkdown: View {
    let source: String
    @Environment(\.openURL) private var systemOpenURL
    @State private var pendingURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(attributedText)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard GitHubMarkdownPolicy.permitsExternalNavigation(to: url) else {
                        return .discarded
                    }
                    pendingURL = url
                    return .handled
                })

            ForEach(hostedImages) { image in
                GitHubHostedMarkdownImage(reference: image)
            }
        }
        .confirmationDialog(
            "Open external link?",
            isPresented: Binding(
                get: { pendingURL != nil },
                set: { if !$0 { pendingURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingURL {
                Button("Open \(pendingURL.host ?? "external site")") {
                    systemOpenURL(pendingURL)
                    self.pendingURL = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingURL = nil
            }
        } message: {
            Text(linkConfirmationMessage)
        }
        .accessibilityHint("External links require confirmation before opening in your default browser.")
    }

    private var hostedImages: [GitHubHostedImageReference] {
        GitHubMarkdownPolicy.hostedImageReferences(in: source)
    }

    private var attributedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let sanitized = GitHubMarkdownPolicy.sanitizedSource(source)
        return (try? AttributedString(markdown: sanitized, options: options))
            ?? AttributedString(sanitized)
    }

    private var linkConfirmationMessage: String {
        guard let pendingURL else {
            return "Triage never loads hosted Markdown content automatically."
        }
        return "Triage has not loaded hosted content. Open \(pendingURL.host ?? "this external site") in your default browser?"
    }
}

@MainActor
private final class GitHubHostedImageModel: ObservableObject {
    enum State {
        case notLoaded
        case loading
        case loaded(NSImage)
        case failed
    }

    @Published private(set) var state: State = .notLoaded
    private var loadTask: Task<Void, Never>?

    deinit {
        loadTask?.cancel()
    }

    func load(_ reference: GitHubHostedImageReference) {
        guard GitHubMarkdownPolicy.permitsGitHubHostedImage(reference.url) else {
            state = .failed
            return
        }
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            do {
                let data = try await GitHubHostedImageDownloader().download(reference.url)
                guard !Task.isCancelled, let image = NSImage(data: data) else {
                    self?.state = .failed
                    return
                }
                self?.state = .loaded(image)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed
            }
        }
    }
}

private struct GitHubHostedMarkdownImage: View {
    let reference: GitHubHostedImageReference
    @StateObject private var model = GitHubHostedImageModel()

    var body: some View {
        Group {
            switch model.state {
            case .notLoaded:
                loadControl
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading GitHub-hosted image…")
                }
            case let .loaded(image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 640, maxHeight: 480, alignment: .leading)
                    .accessibilityLabel(accessibilityLabel)
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub-hosted image omitted")
                    Text("Triage could not load this approved image within its privacy and size limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { model.load(reference) }
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var loadControl: some View {
        HStack(spacing: 8) {
            Text("GitHub-hosted image not loaded")
            Button("Load Image") { model.load(reference) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Loads this GitHub-hosted image only after your confirmation.")
    }

    private var accessibilityLabel: String {
        reference.altText.isEmpty ? "GitHub-hosted image" : "GitHub-hosted image: \(reference.altText)"
    }
}

private enum GitHubHostedImageDownloadError: Error {
    case invalidResponse
    case disallowedRedirect
    case tooLarge
}

private struct GitHubHostedImageDownloader {
    func download(_ url: URL) async throws -> Data {
        guard GitHubMarkdownPolicy.permitsGitHubHostedImage(url) else {
            throw GitHubHostedImageDownloadError.invalidResponse
        }
        let transfer = GitHubHostedImageTransfer(maximumBytes: GitHubMarkdownPolicy.maximumHostedImageBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        return try await transfer.run(session: session, url: url)
    }
}

private final class GitHubHostedImageTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var terminalError: Error?
    private var redirectCount = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func run(session: URLSession, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("image/avif,image/webp,image/apng,image/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }, onCancel: { [weak self] in
            self?.task?.cancel()
        })
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard redirectCount == 0,
              let sourceURL = task.originalRequest?.url,
              let redirectURL = newRequest.url,
              GitHubMarkdownPolicy.permitsGitHubHostedImage(sourceURL),
              GitHubMarkdownPolicy.permitsGitHubHostedImage(redirectURL),
              task.currentRequest?.url.map(GitHubMarkdownPolicy.permitsGitHubHostedImage) == true
        else {
            terminalError = GitHubHostedImageDownloadError.disallowedRedirect
            completionHandler(nil)
            return
        }
        redirectCount += 1
        completionHandler(newRequest)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let responseURL = response.url,
              GitHubMarkdownPolicy.permitsGitHubHostedImage(responseURL),
              GitHubMarkdownPolicy.permitsImageContentType(response.value(forHTTPHeaderField: "Content-Type"))
        else {
            terminalError = GitHubHostedImageDownloadError.invalidResponse
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            terminalError = GitHubHostedImageDownloadError.tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard terminalError == nil else {
            dataTask.cancel()
            return
        }
        guard data.count <= maximumBytes - chunk.count else {
            terminalError = GitHubHostedImageDownloadError.tooLarge
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        if let terminalError {
            continuation?.resume(throwing: terminalError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if data.isEmpty {
            continuation?.resume(throwing: GitHubHostedImageDownloadError.invalidResponse)
        } else {
            continuation?.resume(returning: data)
        }
    }
}

struct ConfirmedExternalLink: View {
    let title: String
    let destination: URL
    @Environment(\.openURL) private var systemOpenURL
    @State private var isConfirmationPresented = false

    var body: some View {
        if GitHubMarkdownPolicy.permitsExternalNavigation(to: destination) {
            Button(title) {
                isConfirmationPresented = true
            }
            .confirmationDialog(
                "Open external link?",
                isPresented: $isConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Open \(destination.host ?? "external site")") {
                    systemOpenURL(destination)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Triage has not loaded hosted content. Open \(destination.host ?? "this external site") in your default browser?")
            }
            .accessibilityHint("Opens \(destination.host ?? "an external site") after confirmation.")
        } else {
            Text("Source link unavailable: Triage opens HTTPS links only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
