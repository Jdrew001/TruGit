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

struct PullBrowser: View {
    let api: GitHubAPI
    let login: String
    let repo: GitHubRepository
    let remotes: [GitHubRepository]
    let branch: String
    let showsInbox: Bool
    @State private var filter = "open"
    @State private var order = PullRequestOrder.updated
    @State private var search = ""
    @State private var expanded = false
    @State private var rows: [PullRequestSummary] = []
    @State private var selected: Int?
    @State private var loading = true
    @State private var error: String?
    @State private var revision = 0
    @State private var detailRevision = 0
    @State private var creating = false
    @State private var preferred: Int?
    @State private var inboxWidth: CGFloat = 328
    @State private var nextPage: Request?
    @State private var requestedPage: Request?
    @State private var loadedScope: Scope?

    private struct Scope: Equatable {
        let state: String
        let order: PullRequestOrder
        let search: String
    }

    private struct Request: Equatable {
        let scope: Scope
        let revision: Int
        let page: Int

        func next() -> Self { Self(scope: scope, revision: revision, page: page + 1) }
    }

    private var scope: Scope {
        Scope(state: filter, order: order, search: String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
    }

    private var request: Request {
        if let requestedPage, requestedPage.scope == scope, requestedPage.revision == revision { return requestedPage }
        return Request(scope: scope, revision: revision, page: 1)
    }

    private var visibleRows: [PullRequestSummary] { loadedScope == scope ? rows : [] }
    private var showList: Bool { expanded || showsInbox || selected == nil }

    var body: some View {
        let current = request
        GeometryReader { geometry in
            let maximum = max(274, min(500, geometry.size.width - 460))
            let width = min(inboxWidth, maximum)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if showsInbox || selected == nil {
                        Spacer().frame(width: width + 8)
                    }
                    detail
                }
                .opacity(expanded ? 0 : 1)
                .accessibilityHidden(expanded)
                .allowsHitTesting(!expanded)

                if showList {
                    HStack(spacing: 0) {
                        inbox(columns: expanded)
                            .frame(width: expanded ? geometry.size.width : width)
                        if !expanded {
                            WidthDivider(label: "Pull request inbox width", width: width, limits: 274...maximum) { proposed, _ in
                                inboxWidth = proposed
                            }
                            .frame(width: 8)
                        }
                    }
                }
            }
        }
        .onChange(of: scope) { requestedPage = nil }
        .task(id: current) { await load(current) }
        .sheet(isPresented: $creating) {
            NewPullRequestView(api: api, repo: repo, repos: remotes, localBranch: branch) { created in
                preferred = created.number
                filter = "open"
                search = ""
                expanded = false
                revision += 1
            }
            .zoomAppDialog()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            PullDetailView(api: api, repo: repo, number: selected, login: login, refresh: detailRevision) { number in
                if filter == "open" { rows.removeAll { $0.number == number } }
                revision += 1
            }
            .id(selected)
        } else {
            ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull",
                                   description: Text("Open a pull request to review its code and conversation."))
                .frame(maxWidth: .infinity)
        }
    }

    private func inbox(columns: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            inboxControls
            Divider()
            if columns { columnHeadings }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows) { pull in
                        PullInboxRow(pull: pull, order: order, columns: columns, selected: selected == pull.number) {
                            selected = pull.number
                            expanded = false
                        }
                    }
                    listMessage
                }
                .padding(.horizontal, columns ? 18 : 8)
                .padding(.vertical, 5)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PullStyle.rail)
    }

    @ViewBuilder
    private var inboxControls: some View {
        if expanded {
            HStack(spacing: 12) {
                statePicker
                searchField.frame(maxWidth: 360)
                sortPicker.fixedSize()
                Spacer(minLength: 4)
                listCount
                listModeButton
                listActions
            }
            .padding(.horizontal, 19).padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statePicker
                    Spacer(minLength: 0)
                    listActions
                }
                searchField
                HStack {
                    listModeButton
                    Spacer(minLength: 4)
                    sortPicker
                }
            }
            .padding(12)
        }
    }

    private var statePicker: some View {
        Picker("Status", selection: $filter) {
            Text("Open").tag("open")
            Text("Closed").tag("closed")
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 132)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search title, @author, or #number", text: $search)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search pull requests")
            if !search.isEmpty {
                inboxButton("Clear search", icon: "xmark.circle.fill") { search = "" }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(PullStyle.inset, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PullStyle.stroke).allowsHitTesting(false) }
    }

    private var sortPicker: some View {
        Picker("Sort pull requests", selection: $order) {
            ForEach(PullRequestOrder.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().controlSize(.small)
    }

    private var listActions: some View {
        HStack(spacing: 8) {
            inboxButton("Refresh pull requests", icon: "arrow.clockwise") {
                revision += 1
                detailRevision += 1
            }
            Button { creating = true } label: { Label("New PR", systemImage: "plus") }
                .buttonStyle(PullPrimaryButton())
        }
        .fixedSize()
    }

    private var listModeButton: some View {
        Button { expanded.toggle() } label: {
            Label(expanded ? "Split view" : "Full list",
                  systemImage: expanded ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless).fixedSize()
        .accessibilityLabel(expanded ? "Return to split view" : "Expand pull request list")
    }

    @ViewBuilder
    private var listCount: some View {
        if !visibleRows.isEmpty {
            let count = visibleRows.count
            Text(nextPage == nil ? (count == 1 ? "1 pull request" : "\(count) pull requests") : "\(count) loaded")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func inboxButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly).buttonStyle(.plain)
            .foregroundStyle(.secondary).padding(2)
            .help(title).accessibilityLabel(title)
    }

    private var columnHeadings: some View {
        HStack(spacing: 16) {
            Text("Pull request").frame(maxWidth: .infinity, alignment: .leading)
            Text("Author").frame(width: PullInboxRow.authorWidth, alignment: .leading)
            Text(order.dateHeading).frame(width: PullInboxRow.dateWidth, alignment: .leading)
            Text("Status").frame(width: PullInboxRow.statusWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 30).padding(.vertical, 9)
        .background(PullStyle.inset)
    }

    @ViewBuilder
    private var listMessage: some View {
        if let error {
            Text(error).font(.caption).foregroundStyle(PullStyle.amber)
                .textSelection(.enabled).padding(12)
        } else if loading {
            ProgressView().controlSize(.small).padding(12)
        } else if visibleRows.isEmpty {
            Label(scope.search.isEmpty ? "No \(filter) pull requests" : "No matching \(filter) pull requests",
                  systemImage: scope.search.isEmpty ? "tray" : "magnifyingglass")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
        } else if let nextPage, nextPage.scope == scope, nextPage.revision == revision {
            Button("Load more") { requestedPage = nextPage }
                .padding(12)
        }
    }

    private func load(_ request: Request) async {
        let incoming = request.scope
        let replaced = loadedScope != incoming
        loading = true
        error = nil
        if replaced {
            if loadedScope?.state != incoming.state { selected = nil }
            rows = []
            nextPage = nil
        }
        do {
            if replaced && !incoming.search.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            let result = try await api.pulls(repo, state: incoming.state, order: incoming.order,
                                             search: incoming.search, page: request.page)
            try Task.checkCancellation()
            var existing = request.page == 1 ? [] : Set(rows.map(\.number))
            let newRows = result.items.filter { existing.insert($0.number).inserted }
            rows = request.page == 1 ? newRows : rows + newRows
            loadedScope = incoming
            nextPage = result.more ? request.next() : nil
            if let preferred {
                selected = preferred
                self.preferred = nil
            } else if selected == nil || (replaced && !rows.contains(where: { $0.number == selected })) {
                selected = rows.first?.number
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if !Task.isCancelled { loading = false }
    }
}

private struct PullInboxRow: View {
    static let authorWidth: CGFloat = 180
    static let dateWidth: CGFloat = 118
    static let statusWidth: CGFloat = 74

    let pull: PullRequestSummary
    let order: PullRequestOrder
    let columns: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            if columns { tableRow } else { compactRow }
        }
        .buttonStyle(.plain)
        .background(selected ? PullStyle.blue.opacity(0.13) : hovering ? PullStyle.surface : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(PullStyle.blue).frame(width: 3).padding(.vertical, 7) }
        }
        .overlay(alignment: .bottom) {
            if !selected { Divider().padding(.horizontal, 11) }
        }
        .onHover { hovering = $0 }
        .accessibilityLabel("\(pull.title), #\(pull.number), \(pull.author), \(order.dateHeading) \(dateText), \(pull.status.rawValue)")
        .accessibilityIdentifier("pull-request-\(pull.number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(pull.title)
    }

    private var tableRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                title
                number
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            author.frame(width: Self.authorWidth, alignment: .leading)
            date.frame(width: Self.dateWidth, alignment: .leading)
            PullStatus(status: pull.status).frame(width: Self.statusWidth, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            title
            HStack(spacing: 6) {
                author
                Spacer(minLength: 0)
                date.fixedSize()
            }
            HStack(spacing: 7) {
                number
                PullStatus(status: pull.status)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(pull.title)
            .font(.system(size: columns ? 15 : 14, weight: .semibold))
            .foregroundStyle(.primary).lineLimit(columns ? 2 : 3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var number: some View {
        Text("#\(pull.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private var author: some View {
        HStack(spacing: 6) {
            PullAvatar(name: pull.author, size: 18)
            Text(pull.author).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 12, weight: .medium))
        .help(pull.author)
    }

    private var dateText: String {
        pull.date(for: order)?.formatted(date: .abbreviated, time: .omitted) ?? "—"
    }

    private var date: some View {
        Text(dateText)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .help(pull.date(for: order).map { order.dateHeading + " " + $0.formatted(date: .complete, time: .shortened) }
                  ?? order.dateHeading + " date unavailable")
    }
}
