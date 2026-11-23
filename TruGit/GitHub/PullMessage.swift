import SwiftUI

struct PullMessage: View {
    private let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        MarkdownMessage(source: source).id(source)
    }
}

private struct MarkdownMessage: View {
    let source: String
    @State private var pages: [[MarkdownBlock]]?
    @State private var visiblePages = 1

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if let pages {
                ForEach(pages.prefix(visiblePages).indices, id: \.self) { page in
                    ForEach(pages[page].indices, id: \.self) { index in
                        row(pages[page][index])
                    }
                }
                if visiblePages < pages.count {
                    Button("Show more of message") { visiblePages += 1 }
                        .buttonStyle(.link).font(.caption)
                }
            } else if !source.isEmpty {
                Color.clear.frame(height: 17).accessibilityHidden(true)
            }
        }
        .task {
            guard pages == nil else { return }
            let rendered = await MarkdownBlock.render(source)
            if !Task.isCancelled { pages = rendered }
        }
    }

    private func row(_ block: MarkdownBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let marker = block.marker {
                listMarker(marker)
                    .frame(minWidth: 16, alignment: .trailing)
            }
            content(block.content)
        }
        .padding(.leading, block.quote ? 12 : 0)
        .overlay(alignment: .leading) {
            if block.quote {
                RoundedRectangle(cornerRadius: 1)
                    .fill(PullStyle.blue.opacity(0.5)).frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(block.indent) * 17)
    }

    @ViewBuilder
    private func listMarker(_ marker: MarkdownBlock.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
        case .number(let ordinal):
            Text("\(ordinal).").monospacedDigit().foregroundStyle(.secondary)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? PullStyle.mint : Color.secondary)
                .accessibilityLabel(checked ? "Completed" : "Incomplete")
        }
    }

    @ViewBuilder
    private func content(_ content: MarkdownBlock.Content) -> some View {
        switch content {
        case .prose(let text, let heading):
            if let heading {
                messageText(text).font(heading <= 2 ? .title3.weight(.semibold) : .headline)
                    .accessibilityAddTraits(.isHeader).padding(.top, 3)
            } else {
                messageText(text)
            }
        case .code(let text, let language):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                messageText(text).font(.callout.monospaced())
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(PullStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PullStyle.stroke).allowsHitTesting(false) }
        case .rule:
            Divider().padding(.vertical, 3)
        case .table(let table):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 1) {
                    ForEach(table.rows) { row in
                        GridRow {
                            ForEach(0..<table.columns, id: \.self) { column in
                                messageText(row.cells[column] ?? AttributedString())
                                    .font(row.header ? .callout.weight(.semibold) : .callout)
                                    .padding(8)
                                    .frame(width: 150, alignment: .leading)
                                    .frame(maxHeight: .infinity, alignment: .topLeading)
                                    .background(row.header ? PullStyle.rail : PullStyle.inset)
                            }
                        }
                    }
                }
                .background(PullStyle.stroke)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func messageText(_ text: AttributedString) -> some View {
        Text(text).textSelection(.enabled).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .tint(PullStyle.blue)
    }
}

private struct MarkdownBlock: Sendable {
    enum Marker: Sendable { case bullet, number(Int), task(Bool) }

    enum Content: Sendable {
        case prose(AttributedString, heading: Int?)
        case code(AttributedString, language: String?)
        case rule
        case table(Table)
    }

    struct Table: Sendable {
        struct Row: Identifiable, Sendable {
            let id: Int
            let header: Bool
            var cells: [Int: AttributedString] = [:]
        }

        let columns: Int
        let rows: [Row]
    }

    var content: Content
    var marker: Marker?
    var indent = 0
    var quote = false

    var weight: Int {
        switch content {
        case .prose(let text, _), .code(let text, _): text.characters.count
        case .rule: 1
        case .table(let table): table.rows.reduce(0) { size, row in
            size + row.cells.values.reduce(0) { $0 + $1.characters.count + 30 }
        }
        }
    }

    nonisolated static func render(_ source: String) async -> [[Self]] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        let text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        var parser = MarkdownBlocks(text: text)
        return pages(parser.parse())
    }

    private static func pages(_ blocks: [Self]) -> [[Self]] {
        var pages: [[Self]] = []
        var page: [Self] = []
        var weight = 0
        for block in blocks {
            let blockWeight = block.weight
            if !page.isEmpty && (page.count >= 24 || weight + blockWeight > 6_000) {
                pages.append(page)
                page = []
                weight = 0
            }
            page.append(block)
            weight += blockWeight
        }
        if !page.isEmpty { pages.append(page) }
        return pages
    }
}

private struct MarkdownBlocks {
    let text: AttributedString
    private var seenItems: Set<Int> = []

    init(text: AttributedString) { self.text = text }

    mutating func parse() -> [MarkdownBlock] {
        let runs = Array(text.runs[\.presentationIntent])
        var output: [MarkdownBlock] = []
        var index = 0
        while index < runs.count && !Task.isCancelled {
            let (intent, range) = runs[index]
            let components = intent?.components ?? []
            if let table = components.last(where: {
                if case .table = $0.kind { return true }
                return false
            }),
               case .table(let columns) = table.kind {
                let end = runs[index...].firstIndex { run in
                    run.0?.components.contains(table) != true
                } ?? runs.endIndex
                output += tableBlocks(runs[index..<end], columns: columns.count)
                index = end
                continue
            }
            output += blocks(for: range, components: components)
            index += 1
        }
        return output
    }

    private mutating func blocks(for range: Range<AttributedString.Index>,
                                 components: [PresentationIntent.IntentType]) -> [MarkdownBlock] {
        let kind = components.first?.kind
        var block = MarkdownBlock(content: .rule)
        block.quote = components.contains { $0.kind == .blockQuote }
        if kind == .thematicBreak { return [block] }
        if case .codeBlock(let hint) = kind {
            let language = hint?.split(whereSeparator: \.isWhitespace).first.map(String.init)
            let syntax = CodeHighlighting(path: "snippet." + Self.extensionForLanguage(language))
            return Self.chunks(AttributedString(text[range])).map { part in
                let code = String(part.characters)
                let display = code.last?.isNewline == true ? String(code.dropLast()) : code
                return MarkdownBlock(content: .code(syntax.highlight(display), language: language), quote: block.quote)
            }
        }

        var content = inlineText(range)
        let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
        if let item = components.first(where: {
            if case .listItem = $0.kind { return true }
            return false
        }), case .listItem(let ordinal) = item.kind {
            block.indent = min(max(0, lists.count - 1), 4)
            if seenItems.insert(item.identity).inserted {
                block.marker = listMarker(for: &content, ordinal: ordinal, ordered: lists.first?.kind == .orderedList)
            } else {
                block.indent = min(lists.count, 4)
            }
        }
        let heading: Int?
        if case .header(let level) = kind {
            heading = level
        } else {
            heading = nil
        }
        return Self.chunks(content).enumerated().map { index, part in
            if index == 1 {
                if block.marker != nil { block.indent += 1 }
                block.marker = nil
            }
            block.content = .prose(part, heading: index == 0 ? heading : nil)
            return block
        }
    }

    private func listMarker(for content: inout AttributedString, ordinal: Int, ordered: Bool) -> MarkdownBlock.Marker {
        let prefix = String(content.characters.prefix(4)).lowercased()
        if prefix == "[x] " || prefix == "[ ] " {
            let end = content.characters.index(content.startIndex, offsetBy: 4)
            content.removeSubrange(content.startIndex..<end)
            return .task(prefix == "[x] ")
        }
        return ordered ? .number(ordinal) : .bullet
    }

    private func inlineText(_ range: Range<AttributedString.Index>) -> AttributedString {
        var content = AttributedString()
        let part = text[range]
        for run in part.runs {
            let intent = run.inlinePresentationIntent ?? []
            var span = AttributedString(text[run.range])
            if intent.contains(.blockHTML) || intent.contains(.inlineHTML) {
                let html = String(span.characters)
                let plain = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?s)<!--.*?-->|</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
                content.append(AttributedString(intent.contains(.blockHTML) ? plain.trimmingCharacters(in: .newlines) : plain))
                continue
            }
            if intent.contains(.softBreak) {
                content.append(AttributedString("\n"))
                continue
            }
            span.presentationIntent = nil
            span.imageURL = nil
            if let url = run.link ?? run.imageURL, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                span.link = url
            } else {
                span.link = nil
            }
            if intent.contains(.code) {
                span.foregroundColor = PullStyle.violet
                span.backgroundColor = PullStyle.inset
            }
            content.append(span)
        }
        return content
    }

    private func tableBlocks(_ runs: ArraySlice<(PresentationIntent?, Range<AttributedString.Index>)>,
                             columns: Int) -> [MarkdownBlock] {
        var rows: [MarkdownBlock.Table.Row] = []
        for (intent, range) in runs {
            guard let parts = intent?.components, parts.count >= 2,
                  case .tableCell(let column) = parts[0].kind else { continue }
            let row = parts[1]
            if rows.last?.id != row.identity {
                rows.append(.init(id: row.identity, header: row.kind == .tableHeaderRow))
            }
            rows[rows.count - 1].cells[column] = inlineText(range)
        }
        // Use selectable text for unusually wide tables or very large cells to bound grid layout.
        if columns > 12 || rows.contains(where: { row in row.cells.values.contains { $0.characters.count > 2_000 } }) {
            return rows.flatMap { row in
                row.cells.keys.sorted().flatMap { column in
                    Self.chunks(row.cells[column] ?? AttributedString()).map { MarkdownBlock(content: .prose($0, heading: nil)) }
                }
            }
        }
        return stride(from: 0, to: rows.count, by: 8).map { start in
            let rows = Array(rows[start..<min(start + 8, rows.count)])
            return MarkdownBlock(content: .table(.init(columns: columns, rows: rows)))
        }
    }

    private static func chunks(_ text: AttributedString) -> [AttributedString] {
        let characters = text.characters
        var start = text.startIndex
        var pieces: [AttributedString] = []
        while start < text.endIndex {
            var end = characters.index(start, offsetBy: 4_000, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex {
                let nearby = characters.index(end, offsetBy: -450)
                if let newline = characters[nearby..<end].lastIndex(where: \.isNewline) {
                    end = characters.index(after: newline)
                }
            }
            pieces.append(AttributedString(text[start..<end]))
            start = end
        }
        return pieces
    }

    private static func extensionForLanguage(_ language: String?) -> String {
        switch language?.lowercased() {
        case "python": "py"
        case "javascript": "js"
        case "typescript": "ts"
        case "shell", "shellscript", "console": "sh"
        case "ruby": "rb"
        case "rust": "rs"
        case "kotlin": "kt"
        default: language ?? ""
        }
    }
}
