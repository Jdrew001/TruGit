import SwiftUI
import AppKit

struct CloneRepositorySheet: View {
    let model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var customName = ""
    private var suggestedName: String { RepositoryClone.suggestedName(for: source) }
    private var name: String { customName.isEmpty ? suggestedName : customName }
    @State private var parent: URL
    @State private var error: String?
    @State private var cloning = false

    init(model: RepositoryModel) {
        self.model = model
        _parent = State(initialValue: model.activeID?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Repository URL")
                    TextField("HTTPS or SSH URL", text: $source)
                }
                GridRow {
                    Text("Save in")
                    HStack {
                        Text(parent.path).lineLimit(1).truncationMode(.middle).help(parent.path)
                        Spacer()
                        Button("Choose…", action: chooseParent)
                    }
                }
                GridRow {
                    Text("Folder name")
                    TextField(suggestedName.isEmpty ? "Repository folder" : suggestedName, text: $customName)
                        .accessibilityLabel("Folder name")
                }
            }.disabled(cloning)
            if let error { GitErrorDetails(title: "Couldn’t Clone Repository", message: error) }
            HStack {
                if cloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning repository…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(cloning)
                Button("Clone", action: clone).keyboardShortcut(.defaultAction)
                    .disabled(cloning || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 490).interactiveDismissDisabled(cloning)
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "Choose Clone Location"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    private func clone() {
        guard !cloning else { return }
        cloning = true
        error = nil
        let request = RepositoryClone(source: source, parent: parent, folderName: name)
        Task {
            defer { cloning = false }
            do {
                try await model.cloneRepository(request)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
