import SwiftUI

@Observable
final class CommitBatch: Identifiable {
    let id = UUID()
    let operation: CommitBatchOperation
    var commits: [GitCommit]
    var target: RevisionPoint
    let localBranches: [RevisionPoint]
    var mainline: Int
    var squash = false
    var customMessage: String?
    var removals: [(commit: GitCommit, index: Int)] = []

    init(operation: CommitBatchOperation = .cherryPick, commits: [GitCommit], target: RevisionPoint, localBranches: [RevisionPoint], mainline: Int = 1) {
        self.operation = operation
        self.commits = operation.ordered(commits)
        self.target = target
        self.localBranches = localBranches
        self.mainline = mainline
    }

    var hasMerge: Bool { commits.contains { $0.parents.count > 1 } }
    // Git uses a shared mainline for the entire sequence.
    var commonParentCount: Int { commits.map { max(1, $0.parents.count) }.min() ?? 1 }
    var message: String { customMessage ?? commits.first?.subject ?? "" }
    var countLabel: String { commits.count == 1 ? "1 commit" : "\(commits.count) commits" }

    func newCommits(in selection: [GitCommit]) -> [GitCommit] {
        var seen = Set(commits.map(\.id))
        return operation.ordered(selection.filter { seen.insert($0.id).inserted })
    }

    func append(_ selection: [GitCommit]) {
        let additions = newCommits(in: selection)
        let ids = Set(additions.map(\.id))
        commits.append(contentsOf: additions)
        removals.removeAll { ids.contains($0.commit.id) }
        mainline = min(mainline, commonParentCount)
    }

    func remove(_ commit: GitCommit) {
        guard let index = commits.firstIndex(where: { $0.id == commit.id }) else { return }
        removals.append((commits.remove(at: index), index))
    }

    func undoRemoval() {
        guard let last = removals.popLast() else { return }
        commits.insert(last.commit, at: min(last.index, commits.count))
        mainline = min(mainline, commonParentCount)
    }
}

struct CommitBatchSheet: View {
    @Bindable var batch: CommitBatch
    let otherWorktree: (String) -> GitWorktree?
    let addFromGraph: (CommitBatch) -> Void
    let run: (RevisionAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: batch.operation.revisionOperation.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WorkspaceColors.accent)
                    .frame(width: 34, height: 34)
                    .background(WorkspaceColors.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                Text(batch.operation.rawValue + " commits").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            Divider()
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Onto branch").font(.callout.weight(.medium))
                    Spacer()
                    Picker("Destination branch", selection: $batch.target) {
                        ForEach(batch.localBranches) { point in
                            Label(point.name, systemImage: "arrow.triangle.branch").tag(point)
                        }
                    }
                    .labelsHidden().fixedSize().frame(maxWidth: 330, alignment: .trailing).clipped()
                    .accessibilityLabel("Destination branch")
                }
                if let owner = otherWorktree(batch.target.name) { WorktreeLocation(owner: owner) }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(batch.operation == .revert ? "Revert order" : "Apply order").font(.callout.weight(.medium))
                        Spacer()
                        if let last = batch.removals.last {
                            Button("Undo remove", action: batch.undoRemoval)
                                .buttonStyle(.link).font(.caption)
                                .help("Restore “" + last.commit.subject + "”")
                        }
                        Text(batch.countLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    if batch.commits.isEmpty {
                        Text("No commits to apply").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        OrderedCommitList(commits: batch.commits, operation: batch.operation, onRemove: batch.remove) { offsets, destination in
                            batch.commits.move(fromOffsets: offsets, toOffset: destination)
                        }
                        .frame(height: min(batch.squash ? 148 : 180, CGFloat(batch.commits.count) * 29))
                    }
                }
                if batch.operation == .revert {
                    Text("Create one revert commit for each entry on “" + batch.target.name + "”, in the order shown.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        modeButton("Separate commits", detail: "Keep each commit message", icon: "square.stack.3d.up", combined: false)
                        modeButton("Squash into one", detail: "Use one commit message", icon: "square.stack.3d.down.right", combined: true)
                    }
                }
                if batch.squash {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Squashed commit message").font(.callout.weight(.medium))
                        TextField("Commit message", text: Binding(get: { batch.message }, set: { batch.customMessage = $0 }), axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(2...4)
                            .padding(8)
                            .background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 5))
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(WorkspaceColors.divider) }
                    }
                }
                if batch.hasMerge {
                    if batch.commonParentCount > 1 {
                        Picker("Mainline for merge commits", selection: $batch.mainline) {
                            ForEach(1...batch.commonParentCount, id: \.self) { Text("Parent \($0)").tag($0) }
                        }
                    } else {
                        Text("Merge commits use their first parent as the mainline.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            HStack {
                Button("Add from graph…", systemImage: "plus") { addFromGraph(batch) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(batch.squash ? "Squash and cherry-pick" : batch.operation.rawValue + " " + batch.countLabel, action: apply)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(batch.commits.isEmpty || (batch.squash && batch.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.padding(.horizontal, 18).padding(.vertical, 11).background(WorkspaceColors.panel)
        }
        .frame(width: 510).background(WorkspaceColors.sidebar)
    }

    private func modeButton(_ title: String, detail: String, icon: String, combined: Bool) -> some View {
        let selected = batch.squash == combined
        return Button { batch.squash = combined } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(selected ? WorkspaceColors.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? WorkspaceColors.accent : Color.secondary)
            }
            .padding(9)
            .background(selected ? WorkspaceColors.accent.opacity(0.10) : WorkspaceColors.panel,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? WorkspaceColors.accent.opacity(0.75) : WorkspaceColors.divider) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func apply() {
        guard let first = batch.commits.first else { return }
        let plan = CommitBatchPlan(commits: batch.commits, squashMessage: batch.squash ? batch.message : nil)
        let action = RevisionAction(operation: batch.operation.revisionOperation, source: RevisionPoint(commit: first.id), target: batch.target,
                                    mainline: batch.hasMerge ? batch.mainline : nil, reviewedWorktree: otherWorktree(batch.target.name)?.id, batchPlan: plan)
        dismiss()
        run(action)
    }
}

struct OrderedCommitList: View {
    let commits: [GitCommit]
    var operation: CommitBatchOperation = .cherryPick
    var onRemove: ((GitCommit) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    var body: some View {
        Group {
            if let onMove {
                List {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                        row(commit, at: index)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove(perform: onMove)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 29)
                .contentMargins(0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Commit apply order")
            } else {
                WorkspaceScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits.indices, id: \.self) { index in
                            row(commits[index], at: index)
                        }
                    }
                }
            }
        }
        .background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(WorkspaceColors.divider).allowsHitTesting(false) }
    }

    private func row(_ commit: GitCommit, at index: Int) -> some View {
        HStack(spacing: 8) {
            if onMove != nil {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Drag to change apply order").accessibilityHidden(true)
            }
            Text(String(index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(commit.shortID).font(.caption.monospaced()).foregroundStyle(WorkspaceColors.accent)
            Text(commit.subject).lineLimit(1).help(commit.subject)
            Spacer(minLength: 0)
            if let onRemove {
                Button { onRemove(commit) } label: {
                    Image(systemName: "xmark").font(.caption.weight(.medium))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from " + operation.gitCommand)
                .accessibilityLabel("Remove " + commit.shortID + " from " + operation.gitCommand)
            }
        }
        .font(.callout).padding(.horizontal, 8).frame(height: 29)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if index < commits.count - 1 { Divider().padding(.horizontal, 8) }
        }
    }
}
