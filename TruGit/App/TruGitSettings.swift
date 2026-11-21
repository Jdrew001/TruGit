import SwiftUI

enum PreferenceKey {
    static let settingsSection = "settingsSection"
    static let launchAnimation = "showLaunchAnimation"
    static let commitAction = "commitButtonAction"
    static let workingTree = "workingChangesTree"
    static let workingDescending = "workingChangesDescending"
    static let historyTree = "commitInspectorTree"
    static let historyDescending = "commitInspectorDescending"
}

enum SettingsSection: String, CaseIterable {
    case workspace = "Workspace"
    case github = "GitHub"
    case updates = "Updates"

    var icon: String {
        switch self {
        case .workspace: "rectangle.split.3x1"
        case .github: "key.horizontal"
        case .updates: "arrow.down.circle"
        }
    }
}

struct TruGitSettings: View {
    @AppStorage(PreferenceKey.settingsSection) private var section = SettingsSection.workspace

    var body: some View {
        let selection = section
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    let selected = selection == item
                    Button { section = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.rawValue)
                        }
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
                        .foregroundStyle(selected ? PullStyle.mint : .primary)
                        .background(selected ? PullStyle.mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12).frame(width: 145).background(PullStyle.rail)
            Divider()
            ScrollView {
                switch selection {
                case .workspace: WorkspaceSettings().padding(22)
                case .github: GitHubAccountView().padding(16)
                case .updates: UpdateSettings()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 648, height: 436)
        .background(PullStyle.canvas)
        .tint(PullStyle.mint)
        .preferredColorScheme(.dark)
    }
}

private struct WorkspaceSettings: View {
    @AppStorage(PreferenceKey.launchAnimation) private var launchAnimation = true
    @AppStorage(PreferenceKey.commitAction) private var action = CommitButtonAction.commitAndPush
    @AppStorage(PreferenceKey.workingTree) private var workingTree = true
    @AppStorage(PreferenceKey.workingDescending) private var workingDescending = false
    @AppStorage(PreferenceKey.historyTree) private var historyTree = true
    @AppStorage(PreferenceKey.historyDescending) private var historyDescending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workspace").font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Play the launch animation")
                    Spacer()
                    Toggle("Play the launch animation", isOn: $launchAnimation)
                        .labelsHidden().accessibilityLabel("Play the launch animation").toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                HStack {
                    Text("Commit button action")
                    Spacer()
                    Picker("Commit button action", selection: $action) {
                        ForEach(CommitButtonAction.allCases, id: \.self) { action in
                            Text(action.title(amending: false)).tag(action)
                        }
                    }.labelsHidden().accessibilityLabel("Commit button action").pickerStyle(.menu).fixedSize()
                }
            }.padding(14).pullCard()

            Text("File lists").font(.headline)
            VStack(spacing: 12) {
                listOptions("Uncommitted changes", tree: $workingTree, descending: $workingDescending)
                Divider()
                listOptions("Commit history", tree: $historyTree, descending: $historyDescending)
            }.padding(14).pullCard()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listOptions(_ name: String, tree: Binding<Bool>, descending: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.callout)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Picker("Layout for " + name, selection: tree) {
                    Text("Path").tag(false)
                    Text("Tree").tag(true)
                }
                Picker("Sort order for " + name, selection: descending) {
                    Text("A–Z").tag(false)
                    Text("Z–A").tag(true)
                }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}
