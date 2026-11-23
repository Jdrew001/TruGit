import SwiftUI

struct PullDetailView: View {
    private static let threadsPerPage = 25

    let api: GitHubAPI
    let repo: GitHubRepository
    let number: Int
    let login: String
    let refresh: Int
    let didClose: (Int) -> Void
    @State private var pull: GitHubPull?
    @State private var conversation = PullConversation(threads: [])
    @State private var conversationPage = 0
    @State private var submittedReviews: [String: PullActivity] = [:]
    @State private var revealedReview: String?
    @State private var files: [ReviewFile] = []
    @State private var selectedFile: String?
    @State private var showFiles = true
    @State private var message = ""
    @State private var reviewTarget: GitHubPull?
    @State private var replyTo: PullActivity?
    @State private var sending = false
    @State private var loading = true
    @State private var revision = 0
    @State private var error: String?
    @State private var commentError: String?
    @State private var confirmingClose = false
    @State private var closing = false
    @State private var closeError: String?
    @State private var statusRevision = 0

    var body: some View {
        let request = DetailQuery(refresh: refresh, revision: revision, files: showFiles)
        VStack(alignment: .leading, spacing: 0) {
            if let pull {
                header(pull)
                Divider()
            }
            if let error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button("Reload") { revision += 1 }
                }.padding(8)
            }
            if let closeError {
                HStack {
                    Text(closeError).font(.callout).foregroundStyle(PullStyle.amber).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { self.closeError = nil }
                }.padding(8)
            }
            if loading && pull == nil {
                ProgressView("Loading pull request…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showFiles {
                if !files.isEmpty {
                    PersonalFileReview(files: files, selection: $selectedFile, login: login, repository: repo.id, number: number)
                } else if loading && pull != nil {
                    ProgressView("Loading changed files…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !loading && error == nil {
                    ContentUnavailableView("No changed files", systemImage: "doc")
                }
            } else {
                conversationPanel
            }
            if !showFiles && pull != nil {
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    PullAvatar(name: login)
                    VStack(alignment: .leading, spacing: 5) {
                        if let commentError {
                            Text(commentError).font(.caption).foregroundStyle(PullStyle.amber).textSelection(.enabled)
                        }
                        if let replyTo {
                            HStack {
                                Text("Reply to " + (replyTo.user?.login ?? "thread") + " · " + (replyTo.path ?? "")).font(.caption)
                                Spacer()
                                Button("Cancel reply") { self.replyTo = nil }.buttonStyle(.link)
                            }
                        }
                        TextField(replyTo == nil ? "Write a comment…" : "Write a reply…", text: $message, axis: .vertical)
                            .lineLimit(1...5).textFieldStyle(.plain).padding(9)
                            .background(PullStyle.inset, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PullStyle.stroke).allowsHitTesting(false) }
                    }
                    Button(replyTo == nil ? "Comment" : "Send reply") { Task { await postComment() } }
                        .buttonStyle(PullPrimaryButton())
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if sending { ProgressView().controlSize(.small).accessibilityLabel("Posting comment") }
                }.padding(12).background(PullStyle.rail).disabled(sending)

            }
        }
        .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request) { await load(request) }
        .alert("Close pull request #\(number)?", isPresented: $confirmingClose) {
            Button("Cancel", role: .cancel) {}
            Button("Close Pull Request", role: .destructive) { Task { await closePull() } }
        } message: {
            Text("GitHub will close this pull request without merging it.")
        }
        .sheet(item: $reviewTarget) { reviewed in
            ReviewSheet(api: api, repo: repo, pull: reviewed, login: login, posted: showSubmittedReview)
            .zoomAppDialog()
        }
    }

    private var conversationPanel: some View {
        let count = conversation.threads.count
        let lastPage = lastConversationPage(threadCount: count)
        let page = min(conversationPage, lastPage)
        let start = page * Self.threadsPerPage
        let end = min(start + Self.threadsPerPage, count)

        return VStack(spacing: 0) {
            if lastPage > 0 {
                conversationNavigation(range: start..<end, total: count, page: page, lastPage: lastPage)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if page == 0, let body = pull?.body, !body.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                PullMessage(body)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).pullCard()
                        }
                        ForEach(conversation.threads[start..<end]) { thread in
                            PullActivityCard(entry: thread.entry, replies: thread.replies, canReply: !sending) { replyTo = $0 }
                                .id(thread.id)
                        }
                        if pull != nil && count == 0 {
                            if loading {
                                ProgressView("Loading conversation…").controlSize(.small)
                            } else if error == nil {
                                Text("No comments or reviews yet").foregroundStyle(.secondary)
                            }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("pull-request-conversation")
                .onChange(of: reviewLocation, initial: true) { _, location in
                    if let location, (start..<end).contains(location.index) {
                        proxy.scrollTo(location.id, anchor: .top)
                    }
                }
                .id(page)
            }
        }
    }

    private struct ReviewLocation: Equatable {
        let id: String
        let index: Int
    }

    private var reviewLocation: ReviewLocation? {
        guard let revealedReview, let index = conversation.threads.firstIndex(where: { $0.id == revealedReview }) else {
            return nil
        }
        return ReviewLocation(id: revealedReview, index: index)
    }

    private func showSubmittedReview(_ review: PullActivity?) {
        if let review {
            submittedReviews[review.key] = review
            revealedReview = review.key
            updateConversation(conversation.includingSubmittedReviews([review]))
        }
        showFiles = false
        revision += 1
    }

    private func updateConversation(_ conversation: PullConversation) {
        self.conversation = conversation
        if let location = reviewLocation {
            conversationPage = location.index / Self.threadsPerPage
        } else {
            conversationPage = min(conversationPage, lastConversationPage(threadCount: conversation.threads.count))
        }
    }

    private func goToConversationPage(_ page: Int) {
        revealedReview = nil
        conversationPage = page
    }

    private func lastConversationPage(threadCount: Int) -> Int {
        max(0, threadCount - 1) / Self.threadsPerPage
    }

    private func conversationNavigation(range: Range<Int>, total: Int, page: Int, lastPage: Int) -> some View {
        HStack(spacing: 10) {
            Text("Threads \(range.lowerBound + 1)–\(range.upperBound) of \(total)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("First threads", systemImage: "chevron.left.to.line") { goToConversationPage(0) }
                .help("First threads").disabled(page == 0)
            Button("Previous threads", systemImage: "chevron.left") { goToConversationPage(page - 1) }
                .help("Previous threads").disabled(page == 0)
            Button("Next threads", systemImage: "chevron.right") { goToConversationPage(page + 1) }
                .help("Next threads").disabled(page == lastPage)
            Button("Latest threads", systemImage: "chevron.right.to.line") { goToConversationPage(lastPage) }
                .help("Latest threads").disabled(page == lastPage)
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 7).background(PullStyle.rail)
    }

    private func load(_ request: DetailQuery) async {
        let originalStatusRevision = statusRevision
        loading = true
        error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            async let pending = loadPanel(files: request.files)
            let latest = try await api.pull(repo, number)
            try Task.checkCancellation()
            if statusRevision == originalStatusRevision { pull = latest }
            let panel = try await pending
            try Task.checkCancellation()
            switch panel {
            case .files(let files): self.files = files
            case .conversation(let conversation):
                if !submittedReviews.isEmpty {
                    let loadedIDs = Set(conversation.threads.map(\.id))
                    submittedReviews = submittedReviews.filter { !loadedIDs.contains($0.key) }
                }
                updateConversation(conversation.includingSubmittedReviews(Array(submittedReviews.values)))
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func closePull() async {
        guard pull?.state == "open", !closing, !sending else { return }
        closing = true
        closeError = nil
        defer { closing = false }
        do {
            let closed = try await api.closePull(repo, number)
            statusRevision += 1
            pull = closed
            didClose(number)
        } catch {
            closeError = error.localizedDescription
        }
    }

    private func loadPanel(files: Bool) async throws -> Panel {
        if files {
            let loaded = try await api.files(repo, number)
            return .files(await ReviewFile.build(from: loaded))
        }
        let loaded = try await api.activity(repo, number)
        return .conversation(await PullConversation.build(from: loaded))
    }

    private enum Panel: Sendable {
        case files([ReviewFile])
        case conversation(PullConversation)
    }

    private func header(_ pull: GitHubPull) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("#\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                PullStatus(status: pull.status)
                Spacer()
                if closing || loading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(closing ? "Closing pull request" : "Refreshing pull request")
                }
                if pull.state == "open" {
                    Button("Close pull request…", systemImage: "xmark.circle") { confirmingClose = true }
                        .font(.caption).buttonStyle(.borderless)
                        .disabled(closing || loading || sending)
                }
                Link(destination: URL(string: "https://github.com/" + repo.id + "/pull/\(number)")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .font(.caption)
                .help("Open this pull request on GitHub")
            }
            Text(pull.title)
                .font(.system(size: 24, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3).help(pull.title).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 13) { authorDetails(pull); branchRange(pull) }
                VStack(alignment: .leading, spacing: 6) { authorDetails(pull); branchRange(pull) }
            }
            HStack(spacing: 14) {
                detailTab("Conversation", icon: "bubble.left.and.bubble.right", fileTab: false)
                detailTab("Files changed", icon: "doc.text", fileTab: true)
                Spacer()
                Button { reviewTarget = pull } label: { Label("Submit review…", systemImage: "checkmark.bubble") }
                    .buttonStyle(PullPrimaryButton())
                    .disabled(pull.state != "open" || closing || loading || sending || error != nil)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 7)
    }

    private func authorDetails(_ pull: GitHubPull) -> some View {
        let author = pull.user?.login ?? "Unknown author"
        return HStack(spacing: 6) {
            PullAvatar(name: author, size: 20)
            Text(author).font(.callout.weight(.medium)).lineLimit(1)
            if let date = pull.createdAt {
                Text("Opened \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    private func branchRange(_ pull: GitHubPull) -> some View {
        HStack(spacing: 5) {
            branchLabel(pull.head.label)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel("Into")
            branchLabel(pull.base.label)
        }
        .lineLimit(1)
    }

    private func branchLabel(_ name: String) -> some View {
        Text(name).font(.caption.monospaced()).truncationMode(.middle).foregroundStyle(PullStyle.blue)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(PullStyle.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4)).help(name)
    }

    private func detailTab(_ name: String, icon: String, fileTab: Bool) -> some View {
        let active = showFiles == fileTab
        return Button {
            if fileTab { revealedReview = nil }
            showFiles = fileTab
        } label: {
            Label(name, systemImage: icon).font(.system(size: 12, weight: .semibold)).padding(.vertical, 7)
                .foregroundStyle(active ? PullStyle.mint : .secondary)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(PullStyle.mint).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    private func postComment() async {
        guard !sending else { return }
        sending = true; commentError = nil
        defer { sending = false }
        do {
            try await api.comment(message, repo: repo, number: number, replyingTo: replyTo?.inReplyToId ?? replyTo?.id)
            replyTo = nil
            message = ""
            revision += 1
        }
        catch { commentError = error.localizedDescription }
    }

    private struct DetailQuery: Equatable { let refresh: Int; let revision: Int; let files: Bool }
}

private struct PullActivityCard: View {
    let entry: PullActivity
    let replies: [PullActivity]
    let canReply: Bool
    let reply: (PullActivity) -> Void
    @State private var expanded = false
    @State private var visibleReplies = 4

    private var accent: Color {
        switch entry.state {
        case "APPROVED": PullStyle.mint
        case "CHANGES_REQUESTED": PullStyle.amber
        default: entry.path == nil ? .secondary : PullStyle.blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PullAvatar(name: entry.user?.login ?? "GitHub")
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(entry.user?.login ?? "GitHub").fontWeight(.semibold)
                    Text(entry.title).foregroundStyle(accent).font(.callout)
                    Spacer(minLength: 4)
                    if let date = entry.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let path = entry.path {
                    Label(path + (entry.line.map { ":\($0)" } ?? entry.originalLine.map { ":\($0) · outdated" } ?? ""),
                          systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption.monospaced()).foregroundStyle(PullStyle.blue).textSelection(.enabled)
                    if let hunk = entry.diffHunk, !hunk.isEmpty {
                        DisclosureGroup("Code context", isExpanded: $expanded) {
                            if expanded { PatchText(text: hunk, path: path, compact: true) }
                        }
                            .font(.caption)
                    }
                }
                if let body = entry.body, !body.isEmpty { PullMessage(body) }
                ForEach(replies.prefix(visibleReplies), id: \.key) { item in
                    Divider()
                    HStack(alignment: .top) {
                        PullAvatar(name: item.user?.login ?? "GitHub", size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.user?.login ?? "GitHub").font(.caption.bold())
                            PullMessage(item.body ?? "")
                        }
                    }
                }
                if replies.count > visibleReplies {
                    let remaining = replies.count - visibleReplies
                    Button("Show \(min(12, remaining)) more replies") { visibleReplies += 12 }
                        .buttonStyle(.link).font(.caption)
                }
                if entry.path != nil { Button("Reply") { reply(entry) }.buttonStyle(.link).font(.caption).disabled(!canReply) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).pullCard()
        }
    }
}

private struct ReviewSheet: View {
    let api: GitHubAPI
    let repo: GitHubRepository
    let pull: GitHubPull
    let login: String
    let posted: (PullActivity?) -> Void
    @State private var decision = ReviewDecision.comment
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var ownPR: Bool { login.lowercased() == pull.user?.login.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.id + "  /  #\(pull.number)").font(.caption.monospaced()).foregroundStyle(PullStyle.mint)
                Text("Review changes").font(.system(size: 24, weight: .semibold))
                Text(pull.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if ownPR {
                    Text("You can comment on your own pull request.").foregroundStyle(.secondary)
                } else {
                    ForEach(ReviewDecision.allCases, id: \.self) { option in decisionRow(option) }
                }
                Text(decision == .approve ? "Review summary (optional)" : "Review summary").font(.callout.weight(.semibold))
                TextField(decision == .changes ? "What needs to change?" : "Write your review…", text: $message, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(3...7).padding(10).pullCard()
                if let error { Text(error).foregroundStyle(PullStyle.amber).textSelection(.enabled) }
            }.padding(20)
            Divider()
            HStack {
                Label(String(pull.head.sha.prefix(8)), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if sending { ProgressView("Submitting review…").controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(decision == .approve ? "Approve PR" : decision == .changes ? "Request changes" : "Submit comment") {
                    Task { await submit() }
                }.buttonStyle(PullPrimaryButton(tint: decision == .changes ? PullStyle.amber : PullStyle.mint))
                 .disabled(decision != .approve && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(14).background(PullStyle.rail)
        }.frame(width: 470).background(PullStyle.canvas).preferredColorScheme(.dark)
            .disabled(sending).interactiveDismissDisabled(sending)
    }

    private func decisionRow(_ option: ReviewDecision) -> some View {
        let selected = decision == option
        let tint = option == .approve ? PullStyle.mint : option == .changes ? PullStyle.amber : PullStyle.blue
        let symbol = option == .approve ? "checkmark.circle" : option == .changes ? "arrow.uturn.backward.circle" : "bubble.left"
        let explanation = option == .approve ? "Mark these changes as ready to merge." :
            option == .changes ? "Ask the author to make revisions." : "Leave feedback without an approval decision."
        return Button { decision = option } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title).font(.callout.weight(.semibold))
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? tint : .secondary)
            }.padding(11).background(selected ? tint.opacity(0.10) : PullStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? tint.opacity(0.65) : PullStyle.stroke) }
        }.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityHint(explanation)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() async {
        guard !sending else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            let review = try await api.review(decision, body: message, repo: repo, pull: pull)
            posted(review)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
