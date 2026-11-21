import SwiftUI

struct NewPullRequestView: View {
    let api: GitHubAPI
    let repo: GitHubRepository
    let repos: [GitHubRepository]
    let localBranch: String
    let created: (GitHubPull) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: GitHubRepository
    @State private var bases: [String] = []
    @State private var heads: [String] = []
    @State private var base = ""
    @State private var head = ""
    @State private var title = ""
    @State private var message = ""
    @State private var error: String?
    @State private var busy = false
    @State private var loading = true
    @State private var attempt = 0

    init(api: GitHubAPI, repo: GitHubRepository, repos: [GitHubRepository], localBranch: String, created: @escaping (GitHubPull) -> Void) {
        self.api = api; self.repo = repo; self.repos = repos; self.localBranch = localBranch; self.created = created
        _source = State(initialValue: repo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(repo.id).font(.caption.monospaced()).foregroundStyle(PullStyle.mint)
                Text("Open a pull request").font(.system(size: 24, weight: .semibold))
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 15) {
                if repos.count > 1 {
                    Picker("Source repository", selection: $source) { ForEach(repos) { Text($0.id).tag($0) } }
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Merge from", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(PullStyle.blue)
                        Picker("Compare branch", selection: $head) {
                            Text("Choose branch").tag("")
                            ForEach(heads, id: \.self) { Text($0) }
                        }.labelsHidden()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Into branch", systemImage: "arrow.triangle.merge").font(.caption).foregroundStyle(PullStyle.mint)
                        Picker("Base branch", selection: $base) { ForEach(bases, id: \.self) { Text($0) } }.labelsHidden()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12).pullCard().disabled(loading)
                if loading { ProgressView("Loading published branches…").controlSize(.small) }
                else if !heads.contains(localBranch) {
                    Text("Push your local branch to use it as the compare branch.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title").font(.callout.weight(.semibold))
                    TextField("PR title", text: $title).textFieldStyle(.plain).padding(10).pullCard()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.callout.weight(.semibold))
                    TextField("Describe your changes…", text: $message, axis: .vertical)
                        .lineLimit(4...8).textFieldStyle(.plain).padding(10).pullCard()
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(PullStyle.amber).textSelection(.enabled)
                    if heads.isEmpty || bases.isEmpty { Button("Reload branches") { attempt += 1 } }
                }
            }.padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create pull request") { Task { await submit() } }
                    .buttonStyle(PullPrimaryButton())
                    .disabled(loading || !heads.contains(head) || !bases.contains(base) ||
                              (repo == source && head == base) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(14).background(PullStyle.rail)
        }
        .frame(width: 480).background(PullStyle.canvas).preferredColorScheme(.dark)
        .disabled(busy).interactiveDismissDisabled(busy)
        .task(id: BranchQuery(repo: source, attempt: attempt)) {
            loading = true; error = nil; heads = []; bases = []
            do {
                async let defaultName = api.defaultBranch(repo)
                let availableBases = try await api.branches(repo)
                let availableHeads = source == repo ? availableBases : try await api.branches(source)
                let defaultBase = try await defaultName
                try Task.checkCancellation()
                bases = availableBases; heads = availableHeads
                base = bases.contains(defaultBase) ? defaultBase : bases.first ?? ""
                head = heads.contains(localBranch) && (source != repo || localBranch != base) ? localBranch : ""
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }

    private func submit() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let pr = try await api.create(in: repo, base: base, from: source, head: head, title: title, body: message)
            created(pr); dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private struct BranchQuery: Equatable { let repo: GitHubRepository; let attempt: Int }
}
