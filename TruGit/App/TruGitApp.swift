import SwiftUI

@main
struct TruGitApp: App {
    @State private var model = RepositoryModel()

    var body: some Scene {
        Window("TruGit", id: "main") {
            RepositoryView(model: model)
                .frame(minWidth: 860, minHeight: 480)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 800)
        .commands {
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
    }
}
