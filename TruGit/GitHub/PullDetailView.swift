import SwiftUI

struct PullDetailView: View {
    let api: GitHubAPI
    let repo: GitHubRepository
    let number: Int
    let login: String
    let refresh: Int
    @State private var pull: GitHubPull?
    @State private var activity: [PullActivity] = []
    @State private var files: [PullFile] = []
    @State private var showFiles = false
    @State private var message = ""
    @State private var reviewTarget: GitHubPull?
    @State private var replyTo: PullActivity?
    @State private var sending = false
    @State private var loading = true
    @State private var revision = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pull {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        PullStatus(pull: pull)
                        Text("#\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Link(destination: URL(string: "https://github.com/" + repo.id + "/pull/\(number)")!) {
                            Label("GitHub", systemImage: "arrow.up.right.square")
                        }.font(.caption)
                    }
                    Text(pull.title).font(.system(size: 23, weight: .semibold)).textSelection(.enabled)
                    HStack(spacing: 7) {
                        PullAvatar(name: pull.user?.login ?? "GitHub", size: 20)
                        Text(pull.user?.login ?? "GitHub").font(.callout.weight(.medium))
                        Text("wants to merge").foregroundStyle(.secondary)
                        branchLabel(pull.head.label)
                        Text("into").foregroundStyle(.secondary)
                        branchLabel(pull.base.label)
                    }.font(.caption).lineLimit(1)
                    HStack(spacing: 14) {
                        detailTab("Conversation", icon: "bubble.left.and.bubble.right", fileTab: false)
                        detailTab("Files changed", icon: "doc.text", fileTab: true)
                        Spacer()
                        Button { reviewTarget = pull } label: { Label("Review changes", systemImage: "checkmark.bubble") }
                            .buttonStyle(PullPrimaryButton())
                            .disabled(pull.state != "open" || loading || sending || error != nil)
                    }.padding(.top, 5)
                }.padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
            }
            if let error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button("Reload") { revision += 1 }
                }.padding(8)
            }
            if loading { ProgressView().controlSize(.small).padding(8) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if showFiles {
                        if !files.isEmpty {
                            Text("\(files.count) changed " + (files.count == 1 ? "file" : "files")).font(.headline)
                        }
                        ForEach(files) { file in FilePatch(file: file, initiallyExpanded: file.id == files.first?.id) }
                        if files.isEmpty && !loading && error == nil { Text("No changed files").foregroundStyle(.secondary) }
                    } else if let pull {
                        if let body = pull.body, !body.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                PullMessage(body)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).pullCard()
                        }
                        let threads = Dictionary(grouping: activity.filter { $0.inReplyToId != nil }, by: \.inReplyToId)
                        let roots = Set(activity.filter { $0.path != nil && $0.inReplyToId == nil }.map(\.id))
                        ForEach(activity.filter { $0.inReplyToId.map { !roots.contains($0) } ?? true }, id: \.key) { entry in
                            PullActivityCard(entry: entry, replies: entry.path == nil ? [] : threads[entry.id] ?? [],
                                             canReply: !sending, reply: { replyTo = $0 })
                        }
                        if activity.isEmpty && !loading && error == nil { Text("No comments or reviews yet").foregroundStyle(.secondary) }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !showFiles && pull != nil {
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    PullAvatar(name: login)
                    VStack(alignment: .leading, spacing: 5) {
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
                }.padding(12).background(PullStyle.rail).disabled(sending)

            }
        }
        .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: DetailQuery(refresh: refresh, revision: revision, files: showFiles)) {
            loading = true; error = nil
            do {
                let latest = try await api.pull(repo, number)
                try Task.checkCancellation()
                pull = latest
                if showFiles {
                    let loaded = try await api.files(repo, number)
                    try Task.checkCancellation()
                    files = loaded
                } else {
                    let loaded = try await api.activity(repo, number)
                    try Task.checkCancellation()
                    activity = loaded
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
        .sheet(item: $reviewTarget) { reviewed in
            ReviewSheet(api: api, repo: repo, pull: reviewed, login: login) {
                showFiles = false
                revision += 1
            }
            .zoomAppDialog()
        }
    }

    private func branchLabel(_ name: String) -> some View {
        Text(name).font(.caption.monospaced()).truncationMode(.middle).foregroundStyle(PullStyle.blue)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(PullStyle.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4)).help(name)
    }

    private func detailTab(_ name: String, icon: String, fileTab: Bool) -> some View {
        let active = showFiles == fileTab
        return Button { showFiles = fileTab } label: {
            Label(name, systemImage: icon).font(.system(size: 12, weight: .semibold)).padding(.vertical, 7)
                .foregroundStyle(active ? PullStyle.mint : .secondary)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(PullStyle.mint).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    private func postComment() async {
        guard !sending else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            try await api.comment(message, repo: repo, number: number, replyingTo: replyTo?.inReplyToId ?? replyTo?.id)
            replyTo = nil
            message = ""
            revision += 1
        }
        catch { self.error = error.localizedDescription }
    }

    private struct DetailQuery: Equatable { let refresh: Int; let revision: Int; let files: Bool }
}

private struct PullActivityCard: View {
    let entry: PullActivity
    let replies: [PullActivity]
    let canReply: Bool
    let reply: (PullActivity) -> Void
    @State private var expanded = false

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
                    if let date = entry.submittedAt ?? entry.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let path = entry.path {
                    Label(path + (entry.line.map { ":\($0)" } ?? entry.originalLine.map { ":\($0) · outdated" } ?? ""),
                          systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption.monospaced()).foregroundStyle(PullStyle.blue).textSelection(.enabled)
                    if let hunk = entry.diffHunk, !hunk.isEmpty {
                        DisclosureGroup("Code context", isExpanded: $expanded) {
                            if expanded { PatchText(text: hunk) }
                        }
                            .font(.caption)
                    }
                }
                if let body = entry.body, !body.isEmpty { PullMessage(body) }
                ForEach(replies) { item in
                    Divider()
                    HStack(alignment: .top) {
                        PullAvatar(name: item.user?.login ?? "GitHub", size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.user?.login ?? "GitHub").font(.caption.bold())
                            PullMessage(item.body ?? "")
                        }
                    }
                }
                if entry.path != nil { Button("Reply") { reply(entry) }.buttonStyle(.link).font(.caption).disabled(!canReply) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).pullCard()
        }
    }
}

private struct FilePatch: View {
    let file: PullFile
    @State private var expanded: Bool

    init(file: PullFile, initiallyExpanded: Bool) {
        self.file = file
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                if let patch = file.patch { PatchText(text: patch) }
                else { Text("GitHub did not provide a text patch for this file.").font(.caption).foregroundStyle(.secondary) }
            }
        } label: {
            HStack {
                Text(file.filename).lineLimit(2).truncationMode(.middle)
                Spacer()
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }.font(.caption.monospaced())
        }.padding(12).pullCard()
    }
}

private struct ReviewSheet: View {
    let api: GitHubAPI
    let repo: GitHubRepository
    let pull: GitHubPull
    let login: String
    let posted: () -> Void
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
            try await api.review(decision, body: message, repo: repo, pull: pull)
            posted()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
