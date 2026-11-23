import SwiftUI

enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug, feature

    var id: Self { self }

    var title: String {
        switch self {
        case .bug: "Report a Bug"
        case .feature: "Request a Feature"
        }
    }

    var label: String { self == .bug ? "bug" : "enhancement" }
    var heading: String { self == .bug ? "Bug report" : "Feature request" }
    var prompt: String {
        switch self {
        case .bug: "Include steps to reproduce, what you expected, and what happened."
        case .feature: "Describe what you’d like to do and how the change would help."
        }
    }

    static let repositoryURL = URL(string: "https://github.com/Jdrew001/TruGit")!
    static let repository = GitHubRepository(remoteURL: repositoryURL.absoluteString)!

    func issueBody(_ description: String) -> String {
        """
        ## \(heading)

        \(description)

        ## App version

        \(AppVersion.display)
        """
    }

    var browserURL: URL {
        let newIssue = Self.repositoryURL.appending(path: "issues/new")
        return newIssue.appending(queryItems: [
            URLQueryItem(name: "body", value: issueBody("<!-- \(prompt) -->")),
            URLQueryItem(name: "labels", value: label)
        ])
    }
}

struct FeedbackView: View {
    @Environment(GitHubAccount.self) private var account
    @Environment(\.dismiss) private var dismiss
    let kind: FeedbackKind

    @State private var title = ""
    @State private var details = ""
    @State private var submitting = false
    @State private var issueNumber: Int?
    @State private var submissionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.title).font(.title2.bold())
            if let issueNumber {
                confirmation(issueNumber)
            } else {
                Text("Your feedback will be posted as a public issue in Jdrew001/TruGit.")
                    .foregroundStyle(.secondary)
                if account.client != nil {
                    form
                } else if account.restoration != .resolved {
                    GitHubConnectionStatus()
                } else if account.busy {
                    ProgressView("Connecting to GitHub…").controlSize(.small)
                } else {
                    Text("Connect your account in GitHub settings to submit from TruGit, or use the GitHub form.")
                        .foregroundStyle(.secondary)
                }
                footer
            }
        }
        .padding(22)
        .frame(width: 490)
        .tint(PullStyle.mint)
        .background(PullStyle.canvas)
        .interactiveDismissDisabled(submitting)
        .task { account.restore() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
            Text("Details").font(.callout.weight(.medium))
            Text(kind.prompt).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $details)
                .frame(height: 110)
                .padding(4)
                .pullCard()
                .accessibilityLabel("Details")
            Text(AppVersion.display).font(.caption).foregroundStyle(.secondary)
            if let submissionError {
                Text(submissionError).foregroundStyle(PullStyle.amber).textSelection(.enabled)
            }
        }
        .disabled(submitting)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Link("Open GitHub Form", destination: kind.browserURL)
            Spacer()
            if submitting { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            if let client = account.client {
                Button("Submit Issue") {
                    let issueTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = kind.issueBody(details.trimmingCharacters(in: .whitespacesAndNewlines))
                    submitting = true
                    Task { await submit(using: client, title: issueTitle, body: body) }
                }
                .buttonStyle(PullPrimaryButton())
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(submitting)
    }

    private func confirmation(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Created TruGit issue #\(number).")
            HStack {
                Link("View Issue", destination: FeedbackKind.repositoryURL.appending(path: "issues/\(number)"))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submit(using client: GitHubAPI, title: String, body: String) async {
        submissionError = nil
        defer { submitting = false }
        do {
            issueNumber = try await client.createIssue(in: FeedbackKind.repository, title: title, body: body, label: kind.label)
        } catch {
            submissionError = error.localizedDescription
        }
    }
}
