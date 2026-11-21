import SwiftUI

struct PullRequestsView: View {
    let root: URL
    let remotes: [String]
    let branch: String
    let showsInbox: Bool
    let back: () -> Void
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PreferenceKey.settingsSection) private var settingsSection = SettingsSection.workspace
    @Environment(GitHubAccount.self) private var account
    @State private var repos: [GitHubRepository] = []
    @State private var selectedRepo: GitHubRepository?
    @State private var discovering = true
    @State private var discoveryError: String?
    @State private var discoveryAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: back) { Label("Back to graph", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Divider().frame(height: 20)
                Label("Pull requests", systemImage: "arrow.triangle.pull")
                    .font(.system(size: 16, weight: .semibold))
                if repos.count > 1 {
                    Picker("GitHub repository", selection: $selectedRepo) {
                        ForEach(repos) { Text($0.id).tag(Optional($0)) }
                    }.labelsHidden().fixedSize()
                } else if let selectedRepo {
                    Text(selectedRepo.id).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    settingsSection = .github
                    openSettings()
                } label: {
                    Label(account.login.isEmpty ? "Account" : account.login, systemImage: "person.crop.circle")
                }.buttonStyle(.plain).help("GitHub account settings")
            }.padding(.horizontal, 16).frame(height: 48).background(PullStyle.rail)
            Divider()
            Group {
                if let api = account.client {
                    if let discoveryError {
                        VStack { Text(discoveryError); Button("Retry") { discoveryAttempt += 1 } }
                    } else if let selectedRepo {
                        PullBrowser(api: api, login: account.login, repo: selectedRepo, remotes: repos, branch: branch, showsInbox: showsInbox)
                            .id(selectedRepo.id + account.generation.uuidString)
                    } else if discovering { ProgressView() }
                    else {
                        ContentUnavailableView("No GitHub Remote", systemImage: "network",
                                               description: Text("Add a github.com remote to this local repository to view its pull requests."))
                    }
                } else {
                    ScrollView {
                        GitHubAccountView().frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PullStyle.canvas)
        .task { await account.restore() }
        .task(id: Discovery(remotes: remotes, attempt: discoveryAttempt)) {
            discovering = true
            discoveryError = nil
            do {
                let list = try await GitHubRepository.destinations(in: root, remotes: remotes)
                try Task.checkCancellation()
                repos = list
                if !list.contains(where: { $0 == selectedRepo }) { selectedRepo = list.first }
            } catch { if !Task.isCancelled { discoveryError = error.localizedDescription } }
            if !Task.isCancelled { discovering = false }
        }
    }
    private struct Discovery: Equatable { let remotes: [String]; let attempt: Int }
}

private struct PullBrowser: View {
    let api: GitHubAPI
    let login: String
    let repo: GitHubRepository
    let remotes: [GitHubRepository]
    let branch: String
    let showsInbox: Bool
    @State private var filter = "open"
    @State private var page = 1
    @State private var more = false
    @State private var rows: [GitHubPull] = []
    @State private var selected: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var creating = false
    @State private var preferred: Int?

    var body: some View {
        HSplitView {
            if showsInbox || selected == nil {
                inbox.frame(minWidth: 220, idealWidth: 274, maxWidth: 350)
            }
            if let selected {
                PullDetailView(api: api, repo: repo, number: selected, login: login, refresh: revision)
                    .id(selected)
            } else {
                ContentUnavailableView("Select a pull request", systemImage: "text.bubble",
                                       description: Text("Its conversation and changed files will appear here."))
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: filter) { page = 1; rows = []; more = false; selected = nil }
        .onChange(of: revision) { page = 1 }
        .task(id: Query(state: filter, page: page, revision: revision)) {
            loading = true; error = nil
            do {
                let result = try await api.pulls(repo, state: filter, page: page)
                try Task.checkCancellation()
                let existing = Set(rows.map(\.number))
                rows = page == 1 ? result.items : rows + result.items.filter { !existing.contains($0.number) }
                more = result.more
                if let preferred { selected = preferred; self.preferred = nil }
                else if !rows.contains(where: { $0.number == selected }) { selected = rows.first?.number }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; more = false }
            }
            if !Task.isCancelled { loading = false }
        }
        .sheet(isPresented: $creating) {
            NewPullRequestView(api: api, repo: repo, repos: remotes, localBranch: branch) { created in
                preferred = created.number; filter = "open"; page = 1; revision += 1
            }
        }
    }
    private var inbox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Status", selection: $filter) {
                    Text("Open").tag("open")
                    Text("Closed").tag("closed")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 142)
                Spacer(minLength: 0)
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Refresh pull requests").accessibilityLabel("Refresh pull requests")
                Button { creating = true } label: { Label("New PR", systemImage: "plus") }
                    .buttonStyle(PullPrimaryButton())
            }.padding(.bottom, 12)
            Divider()
            if let error { Text(error).font(.caption).foregroundStyle(PullStyle.amber).textSelection(.enabled).padding(.vertical, 8) }
            if rows.isEmpty && !loading && error == nil {
                Label("No " + filter + " pull requests", systemImage: "tray")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows) { pr in
                        let active = selected == pr.number
                        Button { selected = pr.number } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("#\(pr.number)").font(.caption.monospacedDigit()).foregroundStyle(active ? PullStyle.mint : .secondary)
                                    Spacer()
                                    PullStatus(pull: pr)
                                }
                                Text(pr.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                HStack(spacing: 5) {
                                    PullAvatar(name: pr.user?.login ?? "GitHub", size: 17)
                                    Text(pr.user?.login ?? "GitHub").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(active ? PullStyle.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                if active { RoundedRectangle(cornerRadius: 7).strokeBorder(PullStyle.mint.opacity(0.4)) }
                            }
                            .overlay(alignment: .bottom) {
                                if !active { Divider().padding(.horizontal, 8) }
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
                    }
                    if loading { ProgressView().controlSize(.small).padding(8) }
                    if more && !loading { Button("Load more") { page += 1 }.padding(6) }
                }.padding(.vertical, 8)
            }
        }.padding(.horizontal, 12).padding(.top, 15).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(PullStyle.rail)
    }

    private struct Query: Equatable { let state: String; let page: Int; let revision: Int }
}
