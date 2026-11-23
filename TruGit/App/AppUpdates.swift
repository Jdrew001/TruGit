import Sparkle
import SwiftUI

enum AppVersion {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    static let display = "TruGit \(version) · Build \(build)"
}

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Status: Equatable {
        case idle, checking, noUpdate, failed
        case available(String)

        var title: String {
            switch self {
            case .idle: "Check for Updates…"
            case .checking: "Checking for updates…"
            case .noUpdate: "No update available"
            case .failed: "Update check failed"
            case .available(let version): "Update available · \(version)"
            }
        }
    }

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var status = Status.idle
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var installsAutomatically = false
    var configured: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        super.init()
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
        let updater = controller.updater
        // Start the launch check before Sparkle schedules its regular update cycle.
        if updater.automaticallyChecksForUpdates && updater.canCheckForUpdates && !updater.sessionInProgress {
            status = .checking
            updater.checkForUpdatesInBackground()
        }
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$installsAutomatically)
    }

    func check() {
        guard canCheck, let controller else { return }
        if case .available = status {
            // Keep the known update visible while Sparkle opens its install dialog.
        } else {
            status = .checking
        }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .noUpdate
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if status == .checking || (error != nil && status == .idle) {
            status = error == nil ? .idle : .failed
        }
    }
    func setChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setInstalls(_ value: Bool) { controller?.updater.automaticallyDownloadsUpdates = value }
}

struct UpdateSettings: View {
    @EnvironmentObject private var updates: AppUpdates

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updates").font(.title2.bold())
            Text(AppVersion.display).foregroundStyle(.secondary)
            if updates.configured {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Check for updates at launch and periodically", isOn: Binding(get: { updates.checksAutomatically }, set: updates.setChecks))
                    Toggle("Download and install updates automatically", isOn: Binding(get: { updates.installsAutomatically }, set: updates.setInstalls))
                        .disabled(!updates.checksAutomatically)
                }.toggleStyle(.checkbox).padding(14).pullCard()
                HStack(spacing: 12) {
                    Button("Check for Updates…", action: updates.check).disabled(!updates.canCheck)
                    if updates.status != .idle {
                        Text(updates.status.title).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("This is a development build. Automatic updates are available in signed distribution builds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
    }
}


struct AppStatusBar: View {
    @EnvironmentObject private var updates: AppUpdates
    let openFeedback: (FeedbackKind) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(FeedbackKind.allCases) { kind in
                    Button(kind.title + "…") { openFeedback(kind) }
                }
            } label: {
                Label("Feedback", systemImage: "bubble.left")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            Text(AppVersion.display).foregroundStyle(.secondary)
            if updates.configured {
                updateStatus
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(WorkspaceColors.sidebar)
        .overlay(alignment: .top) { WorkspaceColors.divider.frame(height: 1) }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.status {
        case .available:
            Button(action: updates.check) {
                Label(updates.status.title, systemImage: "arrow.down.circle.fill")
                    .fontWeight(.semibold)
                    .foregroundStyle(PullStyle.mint)
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheck)
        case .checking:
            Text(updates.status.title).foregroundStyle(.secondary)
        default:
            Button(updates.status.title, action: updates.check)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!updates.canCheck)
                .help("Check for Updates")
        }
    }
}
