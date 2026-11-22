import AppKit
import SwiftUI

struct RevisionReview: Identifiable {
    let id = UUID()
    let source: RevisionPoint
    let initialTarget: RevisionPoint
    let targets: [RevisionPoint]
    let preferred: RevisionOperation?

    // When a branch is dragged onto a commit, the dragged branch receives the reset or revert.
    func changesDraggedBranch(for operation: RevisionOperation) -> Bool {
        operation.isResetOrRevert && source.isLocal && initialTarget.reference == nil
    }

    func endpoints(for operation: RevisionOperation, target: RevisionPoint) -> (revision: RevisionPoint, branch: RevisionPoint) {
        changesDraggedBranch(for: operation) ? (target, source) : (source, target)
    }

    func choices(for target: RevisionPoint, current: String) -> [RevisionOperation] {
        RevisionOperation.allCases.filter { operation in
            let points = endpoints(for: operation, target: target)
            return operation.available(from: points.revision, to: points.branch, current: current)
        }
    }
}

struct WorktreeLocation: View {
    let owner: GitWorktree

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Worktree for “" + owner.branch + "”", systemImage: "folder").font(.callout.weight(.medium))
            Text(owner.id.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct PublishBranchSheet: View {
    let branch: RepositoryReference
    let remotes: [String]
    let publish: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosenRemote: String
    @State private var url = ""

    init(branch: RepositoryReference, remotes: [String], publish: @escaping (String, String?) -> Void) {
        self.branch = branch
        self.remotes = remotes
        self.publish = publish
        let trackingRemote = branch.upstreamTarget?.remote
        _chosenRemote = State(initialValue: trackingRemote.flatMap { remotes.contains($0) ? $0 : nil }
                              ?? (remotes.contains("origin") ? "origin" : remotes.first ?? "origin"))
    }

    var body: some View {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish “" + branch.name + "”").font(.title3.bold())
            if remotes.isEmpty {
                Text("Enter the remote repository address. TruGit will save it as origin.")
                TextField("Repository URL or absolute path", text: $url).textFieldStyle(.roundedBorder)
            } else {
                Picker("Remote", selection: $chosenRemote) {
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }.accessibilityLabel("Remote")
            }
            if let upstream = branch.upstreamTarget {
                Text("Currently tracks " + upstream.displayName + ".").font(.callout)
            }
            Text("Future pushes will use " + chosenRemote + "/" + branch.name + ".")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Publish Branch") {
                    publish(chosenRemote, remotes.isEmpty ? address : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remotes.isEmpty ? !CommitPushDestination.validRemoteURL(address) : !remotes.contains(chosenRemote))
            }
        }.padding(20).frame(width: 420)
    }
}

struct RevisionActionsSheet: View {
    let review: RevisionReview
    let root: URL
    let current: String
    let otherWorktree: (String) -> GitWorktree?
    let addFromGraph: (CommitBatch) -> Void
    let run: (RevisionAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: RevisionPoint
    @State private var operation: RevisionOperation
    @State private var choosingTarget = false
    @State private var filter = ""
    @State private var sourceCommit: GitCommit?
    private var points: (revision: RevisionPoint, branch: RevisionPoint) { review.endpoints(for: operation, target: target) }
    private var destinationWorktree: GitWorktree? {
        operation.checkoutBranch(source: points.revision, target: points.branch).flatMap { otherWorktree($0.name) }
    }
    private var parents: [String]? { sourceCommit?.id == points.revision.oid ? sourceCommit?.parents : nil }
    @State private var readError: String?
    @State private var parentIndex = 1
    @State private var remotes: [String] = []
    @State private var remoteName = ""
    @State private var refName = ""
    @State private var tagMessage = ""
    @State private var resetMode = BranchResetMode.soft
    @State private var discardConfirmed = false

    init(review: RevisionReview, root: URL, current: String, otherWorktree: @escaping (String) -> GitWorktree?, addFromGraph: @escaping (CommitBatch) -> Void, run: @escaping (RevisionAction) -> Void) {
        self.review = review
        self.root = root
        self.current = current
        self.otherWorktree = otherWorktree
        self.addFromGraph = addFromGraph
        self.run = run
        _target = State(initialValue: review.initialTarget)
        let options = review.choices(for: review.initialTarget, current: current)
        let defaultChoice: RevisionOperation = review.source.id == review.initialTarget.id ? .createBranch :
            (review.source.isLocal && review.initialTarget.isRemote ? .push : .merge)
        let requested = review.preferred ?? defaultChoice
        let initialOperation = options.contains(requested) ? requested : options.first ?? .createBranch
        _operation = State(initialValue: initialOperation)
        _refName = State(initialValue: initialOperation == .publish || initialOperation == .rename ? review.source.name : "")
    }

    private var choices: [RevisionOperation] {
        review.choices(for: target, current: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Branch Actions").font(.title3.bold())
                Spacer()
                Menu("More actions") {
                    ForEach(choices.filter(\.namesRef)) { choice in
                        Button(choice.rawValue + "…", systemImage: choice.icon) {
                            refName = choice == .rename || choice == .publish ? review.source.name : ""
                            operation = choice
                        }
                    }
                }.fixedSize()
            }
            HStack(spacing: 8) {
                endpoint(review.source, caption: operation == .merge ? "Merge from" : review.changesDraggedBranch(for: operation) ? "Branch" : "Source")
                if !operation.namesRef && operation != .checkout {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Button { filter = ""; choosingTarget = true } label: {
                        HStack {
                            endpoint(target, caption: operation == .merge ? "Into branch" : review.changesDraggedBranch(for: operation) ? "Commit" : "Target")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose target, " + target.name)
                    .popover(isPresented: $choosingTarget) { targetBrowser.zoomAppDialog() }
                }
            }
            .padding(10).background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 6))
            if let sourceCommit {
                Label(sourceCommit.subject, systemImage: "circle.circle").font(.callout).lineLimit(2).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(choices.filter { !$0.namesRef }) { choice in
                    Button { operation = choice } label: {
                        HStack {
                            Label(choice.rawValue, systemImage: choice.icon)
                            Spacer()
                            if operation == choice { Image(systemName: "checkmark") }
                        }
                        .padding(8).contentShape(Rectangle())
                        .background(operation == choice ? WorkspaceColors.selection : WorkspaceColors.panel, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityAddTraits(operation == choice ? .isSelected : [])
                }
            }
            if choices.contains(operation) {
                Text(operation == .checkout && destinationWorktree != nil ? "Open the worktree where this branch is checked out." : operation.explanation(points.revision, points.branch)).font(.callout)
                    .foregroundStyle(operation == .forcePush ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose a local target branch for this revision.").foregroundStyle(.secondary)
            }
            if let owner = destinationWorktree {
                WorktreeLocation(owner: owner)
            } else if operation != .checkout,
                      let checkout = operation.checkoutBranch(source: points.revision, target: points.branch), checkout.name != current {
                Text("TruGit will switch this worktree to “" + checkout.name + "” first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if operation.usesMainline, let parents, parents.count > 1 {
                Picker("Mainline parent", selection: $parentIndex) {
                    ForEach(parents.indices, id: \.self) { i in
                        Text("Parent \(i + 1) · \(parents[i].prefix(8))").tag(i + 1)
                    }
                }
            }
            if operation.namesRef {
                if operation == .publish {
                    if remotes.isEmpty {
                        Text("Configure a Git remote to publish this branch.").foregroundStyle(.secondary)
                    } else {
                        Picker("Remote", selection: $remoteName) {
                            ForEach(remotes, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                TextField(operation == .tag ? "Tag name" : "Branch name", text: $refName)
                if operation == .tag { TextField("Tag message (optional)", text: $tagMessage) }
            }
            if operation == .reset {
                Picker("Reset mode", selection: $resetMode) {
                    ForEach(BranchResetMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
                Text(resetMode.detail).font(.callout).foregroundStyle(resetMode == .hard ? Color.orange : .secondary)
                if resetMode == .hard {
                    Toggle("Discard changes on “" + points.branch.name + "”", isOn: $discardConfirmed).toggleStyle(.checkbox)
                }
            }
            if let readError { GitErrorDetails(title: "Couldn’t read source commit", message: readError) }
            Divider()
            HStack {
                if operation.usesMainline, let sourceCommit, sourceCommit.id == points.revision.oid, points.branch.isLocal {
                    Button("Add from graph…", systemImage: "plus") {
                        let kind: CommitBatchOperation = operation == .revert ? .revert : .cherryPick
                        addFromGraph(CommitBatch(operation: kind, commits: [sourceCommit], target: points.branch,
                                                localBranches: review.targets.filter(\.isLocal), mainline: parentIndex))
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(operation.rawValue) {
                    let request = RevisionAction(operation: operation, source: points.revision, target: points.branch,
                                                 mainline: operation.usesMainline && (parents?.count ?? 0) > 1 ? parentIndex : nil, reviewedWorktree: destinationWorktree?.id, resetMode: resetMode, name: refName, tagMessage: tagMessage, remoteName: remoteName)
                    dismiss()
                    run(request)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(operation == .forcePush || (operation == .reset && resetMode == .hard) ? .red : WorkspaceColors.accent)
                .disabled((operation == .publish && remoteName.isEmpty) || (operation.namesRef && refName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !choices.contains(operation) || (operation.usesMainline && parents == nil) || (operation == .reset && resetMode == .hard && !discardConfirmed))
            }
        }
        .padding(20).frame(width: 490)
        .onChange(of: destinationWorktree?.id) { discardConfirmed = false }
        .onChange(of: resetMode) { discardConfirmed = false }
        .onChange(of: operation) { discardConfirmed = false }
        .onChange(of: target) { discardConfirmed = false; if !choices.contains(operation), let first = choices.first { operation = first } }
        .task(id: points.revision.oid) {
            readError = nil
            sourceCommit = nil
            parentIndex = 1
            do {
                let commit = try await GitHistory.commit(in: root, id: points.revision.oid)
                if !Task.isCancelled { sourceCommit = commit }
            } catch { if !Task.isCancelled { readError = error.localizedDescription } }
        }
        .task {
            do {
                let remoteList = try await GitRepository.git(["remote"], in: root)
                remotes = String(decoding: remoteList, as: UTF8.self).split(separator: "\n").map(String.init)
                remoteName = remotes.contains("origin") ? "origin" : remotes.first ?? ""
            } catch { if !Task.isCancelled { readError = error.localizedDescription } }
        }
    }

    private func endpoint(_ point: RevisionPoint, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption + " · " + point.shortID).font(.caption.monospaced()).foregroundStyle(.secondary)
            Label(point.name, systemImage: point.icon).font(.callout.weight(.semibold))
                .lineLimit(2).truncationMode(.middle)
        }.frame(maxWidth: .infinity, alignment: .leading).help(point.name)
    }

    private var targetBrowser: some View {
        VStack(spacing: 8) {
            TextField("Filter branches and tags", text: $filter)
            WorkspaceScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(review.targets.filter { point in
                        let needsLocal = operation.isResetOrRevert && !review.changesDraggedBranch(for: operation)
                        return (!needsLocal || point.isLocal) && (filter.isEmpty || point.name.localizedCaseInsensitiveContains(filter))
                    }) { point in
                        Button { target = point; choosingTarget = false } label: {
                            Label(point.name, systemImage: point.icon)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(10).frame(width: 300, height: 250)
    }
}
