import SwiftUI

struct ConflictDiffView: View {
    let request: DiffRequest
    let integration: GitIntegration
    let branch: String
    let snapshotID: UUID
    let busy: Bool
    let save: (GitConflict, ConflictResolution) -> Void
    let close: () -> Void

    @State private var document: GitConflict?
    @State private var draft: MergeDraft?
    @State private var stale = false
    @State private var fileChoice: ConflictChoice?
    @State private var failure: String?
    @State private var hunkPaneFraction: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back to changed files")
                Label(request.path, systemImage: "doc")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let document {
                    Button("Save and Stage") {
                        if let draft, draft.remaining == 0 {
                            if draft.hasManualEdits {
                                save(document, .edited(Data(draft.string.utf8), side: fileChoice))
                            } else if let fileChoice {
                                save(document, .side(fileChoice))
                            } else {
                                save(document, .hunks(draft.choices))
                            }
                        } else if let fileChoice {
                            save(document, .side(fileChoice))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || stale || !(draft.map { $0.remaining == 0 } ?? (fileChoice != nil)))
                }
            }
            .padding(12)
            .background(WorkspaceColors.sidebar)
            if stale {
                Text("The file changed on disk. Copy your edits before reopening it.")
                    .foregroundStyle(.orange).padding(6)
            }
            if let failure, document != nil {
                GitErrorDetails(title: "Couldn’t Refresh Conflict", message: failure).padding(8)
            }
            if let document {
                if let text = document.text, !text.hunks.isEmpty {
                    conflictPanes(text)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose the version to stage").font(.headline)
                        HStack {
                            fileOption(.left, label: document.left == nil ? "Left · Delete file" : "Left · \(leftTitle)")
                            fileOption(.right, label: document.right == nil ? "Right · Delete file" : "Right · \(rightTitle)")
                        }
                        Button("Stage Current Working Copy") { save(document, .workingCopy) }
                            .disabled(busy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    if draft != nil { editor }
                    WholeFileResult(document: document, choice: fileChoice, root: request.root,
                                    loadText: { draft = MergeDraft(file: $0) })
                        .id(fileChoice)
                }
            } else if let failure {
                GitErrorDetails(title: "Couldn’t read conflict", message: failure)
                    .frame(maxWidth: 560).padding()
            } else {
                ProgressView("Reading conflict…").padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WorkspaceColors.history)
        .onExitCommand(perform: close)
        .task(id: snapshotID) {
            do {
                let loaded = try await GitConflict.read(path: request.path, in: request.root)
                guard !Task.isCancelled else { return }
                failure = nil
                if let document, loaded.hasSameInputs(as: document) { stale = false; return }
                if draft?.hasManualEdits == true { stale = true; return }
                fileChoice = nil
                stale = false
                draft = loaded.text.flatMap { $0.hunks.isEmpty ? nil : MergeDraft($0) }
                document = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                if draft?.hasManualEdits == true { stale = true; return }
                document = nil
            }
        }
    }

    private func conflictPanes(_ text: ConflictText) -> some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 6
            let height = max(0, geometry.size.height - dividerHeight)
            let minimum = min(100, height / 2)
            let topHeight = min(height - minimum, max(minimum, height * hunkPaneFraction))
            VStack(spacing: 0) {
                WorkspaceScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(text.hunks) { hunk in
                            block(hunk) { choice in draft?.choose(choice, for: hunk) }
                        }
                    }
                    .padding(12)
                }
                .frame(height: topHeight)
                Divider()
                    .frame(height: dividerHeight)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("conflictPanes"))
                        .onChanged { drag in
                            guard height > 0 else { return }
                            let y = drag.location.y - dividerHeight / 2
                            hunkPaneFraction = min(height - minimum, max(minimum, y)) / height
                        })
                    .accessibilityLabel("Resize conflict panes")
                    .accessibilityAdjustableAction { direction in
                        hunkPaneFraction = min(1, max(0, hunkPaneFraction + (direction == .increment ? 0.1 : -0.1)))
                    }
                editor
            }
            .coordinateSpace(name: "conflictPanes")
        }
    }

    private var leftTitle: String { integration.gitCommand == "rebase" ? "Rebased base" : branch }
    private var rightTitle: String { integration.gitCommand == "rebase" ? "Commit being replayed" : integration == .revert ? "Reverted changes" : "Incoming changes" }

    @ViewBuilder private var editor: some View {
        if let current = draft {
            VStack(spacing: 0) {
                HStack {
                    Label("Merged Result", systemImage: "pencil.line").font(.headline)
                    Spacer()
                    Text(current.remaining == 0 ? "Ready to stage" : "\(current.remaining) unresolved")
                        .foregroundStyle(current.remaining == 0 ? Color.mint : Color.orange)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(WorkspaceColors.panel)
                MergeEditor(draft: current, path: request.path, enabled: !busy) { draft = $0 }
            }
        }
    }

    private func fileOption(_ choice: ConflictChoice, label: String) -> some View {
        Button { if fileChoice != choice { draft = nil; fileChoice = choice } } label: {
            Label(label, systemImage: fileChoice == choice ? "checkmark.circle.fill" : "circle")
        }
    }

    private func block(_ hunk: ConflictHunk, select: @escaping (ConflictChoice) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: draft?.choices[hunk.id] == nil ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundStyle(draft?.choices[hunk.id] == nil ? Color.orange : Color.mint)
                Text("Conflict \(hunk.id + 1)").font(.callout.weight(.semibold))
                Text("Line \(hunk.line)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach(ConflictChoice.allCases, id: \.self) { choice in
                    Button {
                        select(choice)
                    } label: {
                        HStack(spacing: 3) {
                            if draft?.choices[hunk.id] == choice { Image(systemName: "checkmark") }
                            Text(choice.rawValue)
                        }
                    }
                    .accessibilityLabel("Conflict \(hunk.id + 1), \(choice.rawValue)")
                    .help(choice == .both ? "Keep left followed by right" : "Keep the \(choice.rawValue.lowercased()) change")
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(WorkspaceColors.panel)
            HStack(alignment: .top, spacing: 1) {
                side("Left · \(leftTitle)", content: hunk.left, tint: WorkspaceColors.accent)
                side("Right · \(rightTitle)", content: hunk.right, tint: .mint)
            }
        }
        .background(WorkspaceColors.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceColors.divider))
    }

    private func side(_ title: String, content: Data, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            if content.isEmpty {
                Text("No lines").font(.caption.italic()).foregroundStyle(.secondary)
            } else {
                let lines = String(decoding: content, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
                let code = lines.hasSuffix("\n") ? String(lines.dropLast()) : lines
                Text(CodeHighlighting(path: request.path).highlight(code))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(9)
    }
}

private struct WholeFileResult: View {
    let document: GitConflict
    let choice: ConflictChoice?
    let root: URL

    let loadText: (Data) -> Void
    @State private var loaded = false
    @State private var message: String?

    private var side: GitConflict.Side? { choice == .left ? document.left : document.right }

    var body: some View {
        Group {
            if choice == nil {
                Text("Choose a side to preview the result.").foregroundStyle(.secondary)
            } else if side == nil {
                Label("The file will be deleted.", systemImage: "trash")
            } else if let message {
                Text(message).foregroundStyle(.secondary)
            } else if loaded {
                EmptyView()
            } else {
                ProgressView("Reading file…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: side?.oid) {
            loaded = false
            message = nil
            guard choice != nil, let side else { return }
            do {
                let bytes = try await GitRepository.git(["cat-file", "blob", side.oid], in: root)
                guard !Task.isCancelled else { return }
                if bytes.contains(0) || String(data: bytes, encoding: .utf8) == nil {
                    message = "Binary file · \(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file))"
                } else {
                    if side.mode == "120000" {
                        message = "Symbolic link → " + String(decoding: bytes, as: UTF8.self)
                    } else {
                        loadText(bytes)
                        loaded = true
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
        }
    }
}
