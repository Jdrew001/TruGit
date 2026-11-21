import SwiftUI

struct PatchText: View {
    let text: String

    var body: some View {
        PatchPages(text: text).id(text)
    }
}

private struct PatchPages: View {
    let text: String
    @State private var previous: [PatchPage.Cursor] = []
    @State private var cursor: PatchPage.Cursor?
    @State private var page: PatchPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let page {
                if !previous.isEmpty || page.next != nil {
                    HStack {
                        Text("Page \(previous.count + 1)").font(.caption.monospacedDigit())
                        Spacer()
                        Button("Previous") {
                            if let last = previous.popLast() { cursor = last }
                        }.disabled(previous.isEmpty)
                        Button("Next") {
                            if let next = page.next {
                                previous.append(page.start)
                                cursor = next
                            }
                        }.disabled(page.next == nil)
                    }
                    .controlSize(.small).disabled(page.start != (cursor ?? PatchPage.Cursor(startOf: text)))
                }
                ScrollView(.horizontal) {
                    Text(page.highlighted).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding(7)
                }
                .background(WorkspaceColors.panel, in: RoundedRectangle(cornerRadius: 4))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: cursor) {
            let result = await PatchPage.render(text, from: cursor ?? .init(startOf: text))
            if !Task.isCancelled { page = result }
        }
    }
}

struct PatchPage: Sendable {
    struct Cursor: Equatable, Sendable {
        let index: String.Index
        let linePrefix: Character?

        init(startOf text: String) {
            self.init(index: text.startIndex, linePrefix: text.first)
        }

        fileprivate init(index: String.Index, linePrefix: Character?) {
            self.index = index
            self.linePrefix = linePrefix
        }
    }

    let start: Cursor
    let next: Cursor?
    let highlighted: AttributedString

    // Bound both lines and bytes so a minified file cannot produce an enormous Text view.
    nonisolated static func render(_ text: String, from start: Cursor) async -> Self {
        var index = start.index
        var prefix = start.linePrefix
        var result = AttributedString()
        var lineCount = 0
        var bytes = 0
        while index < text.endIndex && lineCount < 100 && bytes < 8192 {
            let segment = index
            var endedLine = false
            repeat {
                let char = text[index]
                bytes += char.utf8.count
                text.formIndex(after: &index)
                endedLine = char.isNewline
            } while !endedLine && index < text.endIndex && bytes < 8192
            var run = AttributedString(String(text[segment..<index]))
            switch prefix {
            case "+": run.foregroundColor = .green
            case "-": run.foregroundColor = .red
            case "@": run.foregroundColor = WorkspaceColors.accent
            default: break
            }
            result.append(run)
            if endedLine {
                lineCount += 1
                prefix = index < text.endIndex ? text[index] : nil
            }
        }
        let next = index < text.endIndex ? Cursor(index: index, linePrefix: prefix) : nil
        return Self(start: start, next: next, highlighted: result)
    }
}
