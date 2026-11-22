import SwiftUI

struct GraphBranchInspector: View {
    let reference: RepositoryReference
    let atCommit: [RepositoryReference]
    let snapshot: RepositorySnapshot
    let canAct: Bool
    let select: (RepositoryReference) -> Void
    let checkout: (RepositoryReference) -> Void
    let track: (RepositoryReference) -> Void
    let push: (RepositoryReference) -> Void
    let merge: (RepositoryReference) -> Void

    @State private var comparison: (range: String, status: String)?

    var body: some View {
        let local = snapshot.checkoutBranch(for: reference)
        let remote = reference.kind == .remote ? reference : snapshot.remoteBranch(for: reference)
        let range = local.flatMap { branch in remote.map { branch.commitID + "..." + $0.commitID } }
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(reference.kind == .tag ? "Tag" : reference.kind.label + " branch")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if atCommit.count > 1 {
                    Menu("At this commit (\(atCommit.count))") {
                        ForEach(atCommit) { ref in
                            Button(ref.kind.label + " · " + ref.name) { select(ref) }
                        }
                    }.fixedSize().font(.caption)
                }
            }
            Label { Text(verbatim: reference.name) } icon: { ReferenceLocationIcon(reference: reference, size: 15) }
                .font(.headline)
                .foregroundStyle(snapshot.colors.color(for: reference))
                .lineLimit(2).truncationMode(.middle).help(reference.name)
            if let local, snapshot.isCheckedOut(local) {
                Label(reference.kind == .remote ? "Checked out locally as " + local.name : "Checked out in this worktree",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
            }
            if let local, let remote {
                Text(tipSummary(local, remote))
                    .font(.callout).foregroundStyle(.secondary)
            } else if reference.kind == .remote {
                Text("Create a local branch at this commit to work on " + reference.name + ".")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let local, let owner = snapshot.otherWorktree(for: local.name) {
                Label("Checked out in " + owner.id.lastPathComponent, systemImage: "folder")
                    .font(.callout).lineLimit(2).truncationMode(.middle).help(owner.id.path)
            }
            if reference.kind != .tag {
                ViewThatFits(in: .horizontal) {
                    HStack { actions(local) }
                    VStack(alignment: .leading) { actions(local) }
                }
                .controlSize(.small)
                if reference.kind == .remote, let local, local.commitID != reference.commitID {
                    Button("Create a local branch at the remote tip…") { track(reference) }
                        .buttonStyle(.link).font(.callout).disabled(!canAct)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceColors.panel, in: RoundedRectangle(cornerRadius: 5))
        .task(id: range) {
            guard let local, let remote, let range, local.commitID != remote.commitID else { return }
            guard let data = try? await GitRepository.git(["rev-list", "--left-right", "--count", range, "--"], in: snapshot.repository.root),
                  !Task.isCancelled else { return }
            let counts = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard counts.count == 2 else { return }
            let ahead = counts[0], behind = counts[1]
            let status: String
            if ahead == 0 { status = "\(behind) \(behind == 1 ? "commit" : "commits") behind" }
            else if behind == 0 { status = "\(ahead) \(ahead == 1 ? "commit" : "commits") ahead of" }
            else { status = "\(ahead) ahead of and \(behind) behind" }
            comparison = (range, status)
        }
    }

    private func tipSummary(_ local: RepositoryReference, _ remote: RepositoryReference) -> String {
        if local.commitID == remote.commitID { return local.name + " and " + remote.name + " point to the same commit." }
        if let comparison, comparison.range == local.commitID + "..." + remote.commitID {
            return "\(local.name) is \(comparison.status) \(remote.name)."
        }
        return local.name + " is at " + local.commitID.prefix(7) + " · " + remote.name + " is at " + remote.commitID.prefix(7)
    }

    @ViewBuilder
    private func actions(_ local: RepositoryReference?) -> some View {
        if let local {
            if !snapshot.isCheckedOut(local) {
                Button(snapshot.checkoutTitle(for: local)) { checkout(reference) }
                    .buttonStyle(.borderedProminent).disabled(!canAct)
            }
        } else if reference.kind == .remote {
            Button("Create Tracking Branch…") { checkout(reference) }
                .buttonStyle(.borderedProminent).disabled(!canAct)
        }
        if reference.kind == .local && reference.pushUpstream == nil {
            Button("Publish Branch") { push(reference) }.disabled(!canAct)
        }
        if snapshot.canMergeBranches(from: reference) {
            Button("Merge into…") { merge(reference) }.disabled(!canAct)
        }
    }
}
