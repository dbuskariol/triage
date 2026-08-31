import SwiftUI

enum GitHubMarkdownPolicy {
    static let maximumSourceCharacters = 100_000

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
        let withoutMarkdownImages = withoutOpenUnsupportedElements.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^\)]*\)"#,
            with: "[remote image omitted]",
            options: .regularExpression
        )
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
}

struct SafeGitHubMarkdown: View {
    let source: String
    @Environment(\.openURL) private var systemOpenURL
    @State private var pendingURL: URL?

    var body: some View {
        Text(attributedText)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard GitHubMarkdownPolicy.permitsExternalNavigation(to: url) else {
                    return .discarded
                }
                pendingURL = url
                return .handled
            })
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
