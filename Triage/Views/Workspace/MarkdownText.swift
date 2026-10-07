import SwiftUI

/// Renders GitHub-flavored Markdown as native SwiftUI blocks: headings,
/// paragraphs, bullet/numbered/task lists, quotes, code, tables, and rules,
/// with inline bold, italic, code, and links. Images and raw HTML are shown
/// as their alt text or dropped; nothing is fetched.
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(item.marker)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .strikethrough(item.marker == .task(true), color: .secondary)
                            .foregroundStyle(item.marker == .task(true) ? .secondary : .primary)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                Text(Self.inline(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.callout.monospaced())
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .table(let rows):
            MarkdownTable(rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func marker(_ marker: MarkdownBlock.ListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•").foregroundStyle(.secondary)
        case .number(let value):
            Text("\(value).").foregroundStyle(.secondary).monospacedDigit()
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? Color.accentColor : .secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
        }
    }

    /// Inline Markdown (emphasis, code, links); images become their alt text.
    static func inline(_ text: String) -> AttributedString {
        let withoutImages = text.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )
        let withoutTags = withoutImages.replacingOccurrences(
            of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression
        )
        return (try? AttributedString(
            markdown: withoutTags,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(withoutTags)
    }
}

private struct MarkdownTable: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownText.inline(cell))
                                .font(index == 0 ? .callout.weight(.semibold) : .callout)
                                .lineLimit(3)
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(10)
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(String)
    case table([[String]])
    case rule

    struct ListItem: Equatable {
        enum Marker: Equatable { case bullet, number(Int), task(Bool) }
        let marker: Marker
        let text: String
        let depth: Int
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !listItems.isEmpty { blocks.append(.list(listItems)); listItems = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }

            if let heading = line.firstMatch(of: /^(#{1,6})\s+(.+?)\s*#*$/) {
                flush()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
            } else if line.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                // Skip the |---|:---:| separator row.
                guard line.wholeMatch(of: /\|?(\s*:?-{2,}:?\s*\|)+\s*:?-*:?\s*/) == nil else { continue }
                table.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
            } else if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.drop(while: { $0 == ">" || $0 == " " })))
            } else if let item = listItem(rawLine) {
                if listItems.isEmpty { flush() }
                listItems.append(item)
            } else if !listItems.isEmpty, rawLine.hasPrefix("  ") {
                // Continuation of the previous list item.
                let last = listItems.removeLast()
                listItems.append(ListItem(marker: last.marker, text: last.text + " " + line, depth: last.depth))
            } else {
                if !listItems.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func listItem(_ rawLine: String) -> ListItem? {
        let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let depth = min(indent / 2, 4)
        if let task = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) {
            return ListItem(marker: .task(task.1 != " "), text: String(task.2), depth: depth)
        }
        if let bullet = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
            return ListItem(marker: .bullet, text: String(bullet.1), depth: depth)
        }
        if let numbered = line.firstMatch(of: /^(\d{1,4})[.)]\s+(.*)$/), let value = Int(numbered.1) {
            return ListItem(marker: .number(value), text: String(numbered.2), depth: depth)
        }
        return nil
    }
}
