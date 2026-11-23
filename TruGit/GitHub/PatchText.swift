import AppKit
import SwiftUI

struct PatchText: View {
    let text: String
    let path: String
    var compact = false

    var body: some View {
        PatchEditor(text: text, path: path, compact: compact)
            .id(PatchIdentity(text: text, path: path))
    }

    private struct PatchIdentity: Hashable { let text: String; let path: String }
}

private struct PatchEditor: View {
    let text: String
    let path: String
    let compact: Bool
    @AppStorage("wrapPullRequestDiffLines") private var wrap = false
    @State private var previous: [PatchPage.Cursor] = []
    @State private var cursor: PatchPage.Cursor?
    @State private var page: PatchPage?
    @State private var editorWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if let page {
                if compact {
                    canvas(page)
                } else {
                    ScrollView {
                        canvas(page)
                    }
                    .id(page.start.index)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity).padding(16)
            }
        }
        .background(PatchPalette.editor)
        .task(id: cursor) {
            let result = await PatchPage.render(text, path: path, from: cursor ?? .init(startOf: text))
            if !Task.isCancelled { page = result }
        }
    }

    @ViewBuilder
    private func canvas(_ page: PatchPage) -> some View {
        if wrap && !compact {
            rows(page)
        } else {
            ScrollView(.horizontal) {
                rows(page).frame(minWidth: editorWidth, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { editorWidth = $0 }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 0) {
                Text("Old").frame(width: PatchLineView.numberWidth)
                Text("New").frame(width: PatchLineView.numberWidth)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            Spacer(minLength: 0)
            if let page, !previous.isEmpty || page.next != nil {
                pagination(page)
            }
            if !compact {
                Button("Wrap lines", systemImage: "arrow.turn.down.left") { wrap.toggle() }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(wrap ? PullStyle.blue : Color.secondary)
                    .help(wrap ? "Turn off line wrapping" : "Wrap long lines")
                    .accessibilityAddTraits(wrap ? .isSelected : [])
            }
            Button("Copy patch", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .labelStyle(.iconOnly).foregroundStyle(.secondary).help("Copy patch")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(PatchPalette.gutter)
    }

    private func pagination(_ page: PatchPage) -> some View {
        HStack(spacing: 6) {
            Button("Previous patch page", systemImage: "chevron.left") {
                if let last = previous.popLast() { cursor = last }
            }
            .labelStyle(.iconOnly).disabled(previous.isEmpty)
            Text("Page \(previous.count + 1)").font(.caption.monospacedDigit())
            Button("Next patch page", systemImage: "chevron.right") {
                if let next = page.next {
                    previous.append(page.start)
                    cursor = next
                }
            }
            .labelStyle(.iconOnly).disabled(page.next == nil)
        }
        .foregroundStyle(.secondary)
        .disabled(page.start != (cursor ?? PatchPage.Cursor(startOf: text)))
    }

    private func rows(_ page: PatchPage) -> some View {
        VStack(spacing: 0) {
            ForEach(page.lines) { line in
                PatchLineView(line: line, wrap: wrap && !compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pull-request-diff")
    }
}

private enum PatchPalette {
    static let editor = Color(red: 0.046, green: 0.056, blue: 0.071)
    static let gutter = Color(red: 0.065, green: 0.078, blue: 0.096)
    static let hunk = Color(red: 0.087, green: 0.115, blue: 0.158)
    static let added = Color(red: 0.079, green: 0.148, blue: 0.142)
    static let removed = Color(red: 0.149, green: 0.084, blue: 0.112)
    static let addition = Color(red: 0.48, green: 0.83, blue: 0.69)
    static let deletion = Color(red: 1.0, green: 0.59, blue: 0.65)
    static let code = Color(red: 0.83, green: 0.88, blue: 0.94)
}

private struct PatchLineView: View {
    static let numberWidth: CGFloat = 43
    let line: PatchPage.Line
    let wrap: Bool

    var body: some View {
        switch line.kind {
        case .hunk, .note:
            Text(line.code)
                .foregroundStyle(line.kind == .hunk ? PullStyle.blue : Color.secondary)
                .fixedSize(horizontal: !wrap, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.kind == .hunk ? PatchPalette.hunk : PatchPalette.gutter)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        case .added, .removed, .context:
            codeLine
        }
    }

    private var codeLine: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                lineNumber(line.before)
                lineNumber(line.after)
            }
            .padding(.leading, 2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Text(marker)
                .frame(width: 22)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(line.code.characters.isEmpty ? AttributedString(" ") : line.code)
                .foregroundStyle(PatchPalette.code)
                .fixedSize(horizontal: !wrap, vertical: true)
                .textSelection(.enabled)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 3)
        .background(line.kind == .added ? PatchPalette.added : line.kind == .removed ? PatchPalette.removed : PatchPalette.editor)
        .overlay(alignment: .leading) {
            if line.kind != .context { Rectangle().fill(accent.opacity(0.65)).frame(width: 2) }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(PullStyle.stroke).frame(width: 1).offset(x: Self.numberWidth * 2 + 2)
                .allowsHitTesting(false)
        }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .frame(width: Self.numberWidth - 7, alignment: .trailing)
            .padding(.trailing, 7)
            .padding(.top, 1)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var accent: Color { line.kind == .added ? PatchPalette.addition : PatchPalette.deletion }
}

struct PatchPage: Sendable {
    enum Kind: Equatable, Sendable { case hunk, added, removed, context, note }

    struct Cursor: Equatable, Sendable {
        let index: String.Index
        var before: Int?
        var after: Int?
        var continuing: Kind?

        init(startOf text: String) { index = text.startIndex }

        fileprivate init(index: String.Index, before: Int?, after: Int?, continuing: Kind?) {
            self.index = index
            self.before = before
            self.after = after
            self.continuing = continuing
        }
    }

    struct Line: Identifiable, Sendable {
        let id: Int
        let kind: Kind
        let before: Int?
        let after: Int?
        let code: AttributedString
    }

    let start: Cursor
    let next: Cursor?
    let lines: [Line]

    // Preserve both line counters if a generated line spans more than one page.
    nonisolated static func render(_ text: String, path: String, from start: Cursor) async -> Self {
        let syntax = CodeHighlighting(path: path)
        var cursor = start
        var lines: [Line] = []
        var bytesRemaining = 32_768
        // Start the next page before a short remaining budget could split a hunk range.
        while cursor.index < text.endIndex && lines.count < 180 && bytesRemaining >= 128 {
            let segment = readSegment(text, at: cursor.index, budget: bytesRemaining)
            let kind = cursor.continuing ?? classify(segment.text)
            if kind == .hunk, cursor.continuing == nil {
                let starts = GitDiff.hunkStarts(in: segment.text)
                cursor.before = starts?.before
                cursor.after = starts?.after
            }
            lines.append(highlight(segment.text, kind: kind, cursor: cursor, syntax: syntax, id: lines.count))
            cursor = advance(cursor, to: segment.end, kind: kind, lineComplete: segment.complete)
            bytesRemaining -= segment.bytes
        }
        return Self(start: start, next: cursor.index < text.endIndex ? cursor : nil, lines: lines)
    }

    private static func classify(_ text: Substring) -> Kind {
        if text.hasPrefix("@@ ") { return .hunk }
        switch text.first {
        case "+": return .added
        case "-": return .removed
        case " ": return .context
        default: return .note
        }
    }

    private static func highlight(_ text: Substring, kind: Kind, cursor: Cursor, syntax: CodeHighlighting, id: Int) -> Line {
        guard kind != .hunk && kind != .note else {
            return Line(id: id, kind: kind, before: nil, after: nil, code: AttributedString(text))
        }
        let firstSegment = cursor.continuing == nil
        let code = firstSegment ? text.dropFirst() : text
        let before = firstSegment && kind != .added ? cursor.before : nil
        let after = firstSegment && kind != .removed ? cursor.after : nil
        return Line(id: id, kind: kind, before: before, after: after,
                    code: syntax.highlight(code.replacingOccurrences(of: "\t", with: "    ")))
    }

    private static func advance(_ cursor: Cursor, to end: String.Index, kind: Kind, lineComplete: Bool) -> Cursor {
        guard lineComplete else {
            return Cursor(index: end, before: cursor.before, after: cursor.after, continuing: kind)
        }
        let oldIncrement = kind == .context || kind == .removed ? 1 : 0
        let newIncrement = kind == .context || kind == .added ? 1 : 0
        return Cursor(index: end, before: cursor.before.map { $0 + oldIncrement },
                      after: cursor.after.map { $0 + newIncrement }, continuing: nil)
    }

    private static func readSegment(_ text: String, at start: String.Index, budget: Int)
        -> (text: Substring, end: String.Index, bytes: Int, complete: Bool) {
        var end = start
        var bytes = 0
        while end < text.endIndex && bytes < min(8_192, budget) {
            let character = text[end]
            bytes += character.utf8.count
            if character == "\n" || character == "\r\n" {
                return (text[start..<end], text.index(after: end), bytes, true)
            }
            text.formIndex(after: &end)
        }
        return (text[start..<end], end, bytes, end == text.endIndex)
    }
}
