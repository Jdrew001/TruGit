import SwiftUI

struct BranchMergeReview: Identifiable {
    let id = UUID()
    let branches: [RepositoryReference]
    var source: RepositoryReference?
    var destination: RepositoryReference?

    init(branches: [RepositoryReference], source: RepositoryReference?, destination: RepositoryReference?) {
        self.branches = branches.filter { $0.kind != .tag }
        self.source = source
        self.destination = destination?.id == source?.id ? nil : destination
    }

    func action(in worktree: GitWorktree?) -> RevisionAction? {
        guard let source, source.kind != .tag, let destination, destination.kind == .local,
              source.id != destination.id, source.commitID != destination.commitID else { return nil }
        return RevisionAction(operation: .merge, source: RevisionPoint(source), target: RevisionPoint(destination),
                              mainline: nil, reviewedWorktree: worktree?.id)
    }
}

struct MergeBranchesSheet: View {
    @State var review: BranchMergeReview
    let root: URL
    let current: String
    let otherWorktree: (String) -> GitWorktree?
    let canMerge: Bool
    let run: (RevisionAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: (range: String, result: Result<Int, Error>)?

    var body: some View {
        let owner = review.destination.flatMap { otherWorktree($0.name) }
        let action = review.action(in: owner)
        let range = action.map { $0.target.oid + ".." + $0.source.oid }
        let incoming = preview?.range == range ? preview?.result : nil
        let canConfirm = canMerge && ((try? incoming?.get()) ?? 0) > 0
        let local = review.branches.filter { $0.kind == .local }
        let sources = local.count == 1 ? review.branches.filter { $0.kind == .remote } : review.branches
        VStack(alignment: .leading, spacing: 16) {
            Label("Merge Branches", systemImage: RevisionOperation.merge.icon).font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                branchPicker("Merge from", selection: $review.source, branches: sources)
                branchPicker("Into branch", selection: $review.destination,
                             branches: local.filter { $0.id != review.source?.id })
            }
            if let action {
                switch incoming {
                case .success(0):
                    Text("“" + action.target.name + "” already contains all commits from “" + action.source.name + "”.")
                case .success(let count):
                    Text("Merge \(count) incoming \(count == 1 ? "commit" : "commits") from “\(action.source.name)” into “\(action.target.name)”.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let owner {
                        WorktreeLocation(owner: owner)
                    } else if action.target.name != current {
                        Text("TruGit will switch this worktree to “" + action.target.name + "” before merging.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .failure(let error):
                    GitErrorDetails(title: "Couldn’t compare branches", message: error.localizedDescription)
                case nil:
                    Text("Comparing branches…").foregroundStyle(.secondary)
                }
            } else if let source = review.source, let destination = review.destination,
                      source.commitID == destination.commitID {
                Text("Both branches point to the same commit.").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard canConfirm, let action else { return }
                    dismiss()
                    run(action)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
            }
        }
        .padding(20).frame(width: 450)
        .onChange(of: review.source?.id) {
            if review.source?.id == review.destination?.id { review.destination = nil }
        }
        .task(id: range) {
            guard let range else { return }
            do {
                let data = try await GitRepository.git(["rev-list", "--count", range, "--"], in: root)
                guard let count = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw RepositoryReadError.invalidOutput }
                if !Task.isCancelled { preview = (range, .success(count)) }
            } catch {
                if !Task.isCancelled { preview = (range, .failure(error)) }
            }
        }
    }

    private func branchPicker(_ title: String, selection: Binding<RepositoryReference?>,
                              branches: [RepositoryReference]) -> some View {
        GridRow {
            Text(title).font(.callout.weight(.semibold))
            Picker(title, selection: selection) {
                Text("Choose a branch…").tag(nil as RepositoryReference?)
                ForEach(branches) { branch in
                    let isCurrent = branch.kind == .local && branch.name == current
                    Label(isCurrent ? branch.name + " (checked out)" : branch.name, systemImage: branch.kind.icon)
                        .tag(Optional(branch))
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
