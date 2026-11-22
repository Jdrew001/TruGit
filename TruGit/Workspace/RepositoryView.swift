import SwiftUI

struct RepositoryView: View {
    @Bindable var model: RepositoryModel
    @AppStorage(PreferenceKey.launchAnimation) private var launchAnimation = true
    @AppStorage("repositorySidebarExpanded") private var sidebarExpanded = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isLaunching && launchAnimation {
                LaunchSplash().transition(.opacity)
            } else {
                workspace.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceColors.history.ignoresSafeArea())
        .animation(launchAnimation ? .easeInOut(duration: reduceMotion ? 0.15 : 0.35) : nil, value: model.isLaunching)
        .overlay(alignment: .topTrailing) {
            if let success = model.success {
                Label {
                    Text(success.message).lineLimit(2)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                .padding(12)
                .allowsHitTesting(false)
                .task(id: success.id) {
                    AccessibilityNotification.Announcement(success.message).post()
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    if model.success?.id == success.id { model.success = nil }
                }
            }
        }
        .onAppear {
            let duration = reduceMotion ? Duration.milliseconds(800) : LaunchSplash.displayTime
            model.restoreSession(minimumDisplayTime: launchAnimation ? duration : .zero)
        }
        .task(id: model.activeID) { await model.observeActiveRepository() }
        .sheet(isPresented: $model.showingClone) { CloneRepositorySheet(model: model).zoomAppDialog() }
        .sheet(item: $model.initialization) { review in
            InitializationSheet(review: review, cancel: { model.initialization = nil }) { selected in
                model.initializeRepositories(review, selected: selected)
            }
            .zoomAppDialog()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = model.failure, !model.isLaunching {
                VStack(spacing: 0) {
                    Divider()
                    let retry = failure.retry
                    let canRetry = retry.map { context in model.tabs.contains { $0.id == context.root } } ?? false
                    GitErrorDetails(title: failure.title + (retry.map { " · " + $0.root.lastPathComponent + " / " + $0.branch.name } ?? ""),
                                    message: failure.message,
                                    retry: canRetry ? { model.retryFailure(failure.id) } : nil,
                                    retryDisabled: model.isLoading, retrying: model.retryingFailureID == failure.id,
                                    dismiss: { model.failure = nil })
                        .frame(maxWidth: 850)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(WorkspaceColors.sidebar)
            }
        }
    }

    @ViewBuilder
    private var workspace: some View {
        if let tab = model.activeTab {
            VStack(spacing: 0) {
                RepositoryTabs(model: model, sidebarExpanded: sidebarExpanded, toggleSidebar: toggleSidebar)
                RepositoryWorkspace(tab: tab, sidebarExpanded: sidebarExpanded,
                                    canChangeBranch: !model.isLoading, openWorktree: { model.openFolder($0, inspectWorktree: true) }, selectTab: model.selectTab,
                                    refresh: model.refresh, repoTabs: model.tabs, openRepository: model.openRepository) { action in
                    model.performBranchAction(action, in: tab)
                }
                .id(tab.id)
            }
        } else if model.isLoading || model.isLaunching {
            ProgressView("Reading repository…")
        } else {
            ContentUnavailableView {
                Label("Add a Git Repository", systemImage: "folder")
            } description: {
                Text("Choose an existing repository or initialize a folder with Git.")
            } actions: {
                Button("Add Repository…", action: model.openRepository)
                    .buttonStyle(.borderedProminent)
                Button("Clone Repository…", action: model.showCloneSheet)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                AppZoomControls()
            }
        }
    }

    private func toggleSidebar() {
        sidebarExpanded.toggle()
    }
}

private struct InitializationSheet: View {
    let review: RepositoryModel.InitializationReview
    let cancel: () -> Void
    let initialize: (Set<URL>) -> Void
    @State private var selected: Set<URL>

    init(review: RepositoryModel.InitializationReview, cancel: @escaping () -> Void, initialize: @escaping (Set<URL>) -> Void) {
        self.review = review
        self.cancel = cancel
        self.initialize = initialize
        _selected = State(initialValue: Set(review.folders.map(\.folder)))
    }

    var body: some View {
        let multiple = review.folders.count > 1
        VStack(alignment: .leading, spacing: 14) {
            Text(multiple ? "Initialize Git Repositories?" : "Initialize Git Repository?").font(.headline)
            Text(multiple ? "Choose which folders to initialize and open in tabs." : "TruGit will initialize this folder and open it in a tab.")
            WorkspaceScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.folders) { request in
                        if multiple {
                            Toggle(isOn: Binding(
                                get: { selected.contains(request.folder) },
                                set: { include in
                                    if include { selected.insert(request.folder) }
                                    else { selected.remove(request.folder) }
                                }
                            )) { folderLabel(request) }
                            .toggleStyle(.checkbox)
                        } else {
                            folderLabel(request)
                        }
                    }
                    if !review.openErrors.isEmpty {
                        Divider()
                        GitErrorDetails(title: "Couldn’t open these folders", message: review.openErrors.joined(separator: "\n\n"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(300, CGFloat(review.folders.count) * 46 + (review.openErrors.isEmpty ? 0 : 90)))
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(selected.count > 1 ? "Initialize \(selected.count) Repositories" : "Initialize Repository") {
                    initialize(selected)
                }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }

    private func folderLabel(_ request: GitRepository.Initialization) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.folder.path).font(.callout.monospaced())
            if let parent = request.enclosingRepository {
                Text("Creates a separate repository inside " + parent.path + ".").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
