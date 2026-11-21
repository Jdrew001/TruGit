import SwiftUI

struct DiffView: View {
    let selection: DiffSelection
    let snapshotID: UUID
    let chooseSource: (DiffRequest.Source) -> Void
    let close: () -> Void

    private var request: DiffRequest { selection.request }

    @State private var diff: GitDiff?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            if let diff, !diff.rows.isEmpty {
                DiffColumns(diff: diff, labels: request.source.labels,
                            syntax: CodeHighlighting(path: request.path))
            } else if let diff {
                ContentUnavailableView(diff.isBinary ? "Binary File Changed" : "No Text Changes",
                                       systemImage: "doc")
            } else if let error {
                GitErrorDetails(title: "Couldn’t read diff", message: error)
                    .frame(maxWidth: 560).padding()
            } else {
                ProgressView("Reading diff…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceColors.history)
        .onExitCommand(perform: close)
        .task(id: snapshotID) {
            diff = nil
            error = nil
            do {
                let loaded = try await GitDiff.read(request)
                guard !Task.isCancelled else { return }
                diff = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WorkspaceColors.accent)
                    .frame(width: 25, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to changed files")
            .accessibilityLabel("Back to changed files")

            let path = formatPath(request.path, original: request.originalPath)
            Label(path, systemImage: "doc")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            if selection.sources.count > 1 {
                Picker("Comparison", selection: Binding(get: { request.source }, set: { chooseSource($0) })) {
                    ForEach(selection.sources, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(WorkspaceColors.sidebar)
        .overlay(alignment: .bottom) {
            WorkspaceColors.divider.frame(height: 1)
        }
    }
}

private struct DiffColumns: View {
    let diff: GitDiff
    let labels: (before: String, after: String)
    let syntax: CodeHighlighting

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = (geometry.size.width - 1) / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        columnTitle(labels.before, width: width)
                        WorkspaceColors.divider.frame(width: 1)
                        columnTitle(labels.after, width: width)
                    }
                    .frame(height: 30)
                    WorkspaceColors.divider.frame(height: 1)
                    WorkspaceScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(diff.rows) { row in
                                diffRow(row, width: width)
                            }
                        }
                    }
                }
            }
        }
    }

    private func columnTitle(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(width: width, height: 30, alignment: .leading)
            .background(WorkspaceColors.panel)
    }

    @ViewBuilder
    private func diffRow(_ row: GitDiff.Row, width: CGFloat) -> some View {
        switch row.content {
        case .hunk(let title):
            Text(title)
                .font(.caption.monospaced())
                .foregroundStyle(WorkspaceColors.accent)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceColors.panel)

        case .lines(let before, let after):
            HStack(alignment: .top, spacing: 1) {
                DiffCodeLine(line: before, syntax: syntax)
                    .frame(width: width)
                DiffCodeLine(line: after, syntax: syntax)
                    .frame(width: width)
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .center) {
                WorkspaceColors.divider.frame(width: 1)
            }
        }
    }
}

private struct DiffCodeLine: View {
    let line: GitDiff.Line?
    let syntax: CodeHighlighting

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.map { String($0.number) } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .accessibilityHidden(true)
            Text(syntax.highlight(line?.text.replacingOccurrences(of: "\t", with: "    ") ?? ""))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .frame(minHeight: 18, alignment: .topLeading)
        .background(rowColor)
    }

    private var rowColor: Color {
        switch line?.change {
        case .removed: Color(red: 0.27, green: 0.14, blue: 0.19)
        case .added: Color(red: 0.11, green: 0.24, blue: 0.22)
        case .context: WorkspaceColors.history
        case nil: WorkspaceColors.sidebar
        }
    }
}
