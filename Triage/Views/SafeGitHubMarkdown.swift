import SwiftUI

struct SafeGitHubMarkdown: View {
    let source: String

    var body: some View {
        Text(attributedText)
            .textSelection(.enabled)
    }

    private var attributedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}
