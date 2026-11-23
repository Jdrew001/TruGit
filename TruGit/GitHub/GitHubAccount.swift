import SwiftUI
import Security

private actor GitHubKeychain {
    static let shared = GitHubKeychain()

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "TruGit") + ".github.com",
         kSecAttrAccount as String: "personal-access-token"]
    }

    func read() throws -> String? {
        var search = query
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GitHubFailure("Couldn’t read the GitHub token from Keychain.")
        }
        return token
    }

    func save(_ token: String) throws {
        let value = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw GitHubFailure((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status).")
        }
    }
}

@MainActor @Observable
final class GitHubAccount {
    enum Restoration { case checking, resolved, failed }

    private(set) var client: GitHubAPI?
    private(set) var login = ""
    private(set) var generation = UUID()
    private(set) var busy = false
    private(set) var error: String?
    private(set) var hasStoredToken = false
    private(set) var restoration = Restoration.checking

    func restore() {
        guard restoration == .checking, !busy else { return }
        busy = true
        error = nil
        // The shared account finishes restoring even if the initiating view goes away.
        Task { [weak self] in await self?.restoreSavedConnection() }
    }

    func retryRestore() {
        guard restoration == .failed, !busy else { return }
        restoration = .checking
        restore()
    }

    private func restoreSavedConnection() async {
        defer { busy = false }
        do {
            #if TRUGIT_E2E
            let environment = ProcessInfo.processInfo.environment
            let fixture = environment["TRUGIT_FIXTURE_ACCOUNT_RESTORE"]
            guard fixture != "missing" else {
                restoration = .resolved
                return
            }
            hasStoredToken = true
            let api = GitHubFixtureProtocol.api()
            if fixture == "validate" {
                let user = try await api.user()
                setConnected(api, login: user.login)
            } else {
                setConnected(api, login: environment["TRUGIT_FIXTURE_LOGIN"] ?? "reviewer")
            }
            #else
            guard let token = try await GitHubKeychain.shared.read() else {
                restoration = .resolved
                return
            }
            hasStoredToken = true
            try await authenticate(token, save: false)
            #endif
        } catch {
            self.error = error.localizedDescription
            restoration = .failed
        }
    }

    func connect(_ token: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await authenticate(token.trimmingCharacters(in: .whitespacesAndNewlines), save: true) }
        catch { self.error = error.localizedDescription }
    }

    private func authenticate(_ token: String, save: Bool) async throws {
        let api = GitHubAPI(token: token)
        let user = try await api.user()
        try Task.checkCancellation()
        if save { try await GitHubKeychain.shared.save(token) }
        setConnected(api, login: user.login)
    }

    private func setConnected(_ api: GitHubAPI, login: String) {
        hasStoredToken = true
        client = api
        self.login = login
        generation = UUID()
        error = nil
        restoration = .resolved
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await GitHubKeychain.shared.remove()
            hasStoredToken = false
            client = nil
            login = ""
            generation = UUID()
            error = nil
            restoration = .resolved
        } catch { self.error = error.localizedDescription }
    }
}

struct GitHubConnectionStatus: View {
    @Environment(GitHubAccount.self) private var account

    var body: some View {
        if account.restoration == .failed {
            VStack(alignment: .leading, spacing: 9) {
                Label("Couldn’t restore GitHub connection", systemImage: "exclamationmark.circle")
                    .font(.headline)
                if let error = account.error {
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Retry connection", action: account.retryRestore)
            }
            .padding(18)
        } else {
            ProgressView("Checking GitHub connection…")
                .accessibilityIdentifier("github-connection-checking")
        }
    }
}

struct GitHubAccountView: View {
    @Environment(GitHubAccount.self) private var account
    @State private var token = ""
    @State private var editingToken = false

    private var showsTokenEditor: Bool {
        editingToken || (account.restoration == .resolved && !account.hasStoredToken && account.client == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if account.restoration == .checking {
                GitHubConnectionStatus().frame(maxWidth: .infinity)
            } else {
                accountHeader
                Divider()
                accountControls
            }
        }
        .padding(22).frame(width: 440).background(PullStyle.rail, in: RoundedRectangle(cornerRadius: 10))
        .preferredColorScheme(.dark)
        .task { account.restore() }
    }

    private var accountHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: account.client == nil ? "key.fill" : "person.crop.circle.badge.checkmark")
                .font(.system(size: 21)).foregroundStyle(PullStyle.mint).frame(width: 42, height: 42)
                .background(PullStyle.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(showsTokenEditor && !account.hasStoredToken ? "Connect to GitHub" : "GitHub account")
                    .font(.title2.bold())
                Text(account.client == nil ? "Create and review pull requests from TruGit." : "Connected as @" + account.login)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var accountControls: some View {
        if showsTokenEditor {
            tokenEditor
        } else if account.restoration == .failed {
            GitHubConnectionStatus()
        } else {
            Label("Token saved in your macOS Keychain", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = account.error, showsTokenEditor || account.restoration == .resolved {
            Text(error).foregroundStyle(PullStyle.amber).textSelection(.enabled)
        }
        HStack {
            if account.hasStoredToken {
                Button("Disconnect") {
                    clearEditor()
                    Task { await account.disconnect() }
                }
            }
            Spacer()
            if account.busy { ProgressView().controlSize(.small) }
            if showsTokenEditor {
                if editingToken { Button("Cancel", action: clearEditor) }
                Button(account.hasStoredToken ? "Save token" : "Connect") {
                    Task {
                        await account.connect(token)
                        if account.error == nil { clearEditor() }
                    }
                }
                .buttonStyle(PullPrimaryButton())
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Replace token…") { editingToken = true }
            }
        }.disabled(account.busy)
    }

    private var tokenEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Personal access token").font(.callout.weight(.semibold))
                    Spacer()
                    Link("Create token ↗", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                        .font(.caption).foregroundStyle(PullStyle.mint)
                }
                SecureField("Paste your token", text: $token)
                    .textFieldStyle(.plain).padding(10).pullCard().accessibilityLabel("Personal access token")
                Label("Saved in your macOS Keychain", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Fine-grained token access").font(.callout.weight(.semibold))
                Text("Select the repositories you want to use.").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Pull requests"); Spacer(); Text("Read and write").foregroundStyle(.secondary) }
                HStack { Text("Contents"); Spacer(); Text("Read").foregroundStyle(.secondary) }
            }.font(.callout).padding(12).pullCard()
        }
    }

    private func clearEditor() {
        editingToken = false
        token = ""
    }
}
