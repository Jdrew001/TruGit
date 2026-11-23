import SwiftUI

@main
struct TruGitApp: App {
    @StateObject private var updates = AppUpdates()
    @State private var github = GitHubAccount()
    @State private var model = RepositoryModel()
    @State private var feedback: FeedbackKind?
    @AppStorage("appZoom") private var zoom = AppZoom.initialValue

    var body: some Scene {
        Window("TruGit", id: "main") {
            AppZoomViewport {
                RepositoryView(model: model)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        AppStatusBar(fetchStatus: model.activeFetchStatus) { feedback = $0 }
                    }
                    .sheet(item: $feedback) { kind in
                        FeedbackView(kind: kind).zoomAppDialog()
                    }
                    .environmentObject(updates)
                    .environment(github)
            }
            .environment(\.appZoom, $zoom)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                if updates.configured {
                    Button("Check for Updates…", action: updates.check).disabled(!updates.canCheck)
                }
            }
            CommandGroup(after: .help) {
                ForEach(FeedbackKind.allCases) { kind in
                    Button(kind.title + "…") { feedback = kind }
                }
            }
            CommitCommands()
            AppZoomCommands(zoom: $zoom)
            CommandGroup(replacing: .newItem) {
                Button("Add Repository…", action: model.openRepository)
                    .keyboardShortcut("o")
                    .disabled(model.isLoading)
                Button("Clone Repository…", action: model.showCloneSheet)
                    .disabled(model.isLoading)
                Button("Initialize Repository…") { model.chooseFolder(for: .initialize) }
                    .disabled(model.isLoading)
                Button("Close Repository Tab", action: model.closeActiveTab)
                    .keyboardShortcut("w")
                    .disabled(model.activeTab == nil)
                Button("Refresh", action: model.refresh)
                    .keyboardShortcut("r")
                    .disabled(model.activeTab == nil || model.isLoading)
            }
        }
        Settings {
            TruGitSettings()
                .zoomAppDialog()
                .environment(\.appZoom, $zoom)
                .environment(github)
                .environmentObject(updates)
        }
    }
}

private struct CommitShortcutKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var commitStagedChanges: (() -> Void)? {
        get { self[CommitShortcutKey.self] }
        set { self[CommitShortcutKey.self] = newValue }
    }
}

private struct CommitCommands: Commands {
    @FocusedValue(\.commitStagedChanges) private var commit

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Commit Staged Changes") { commit?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(commit == nil)
        }
    }
}
