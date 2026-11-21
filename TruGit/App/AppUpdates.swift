import Sparkle
import SwiftUI

@MainActor
final class AppUpdates: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var installsAutomatically = false
    var configured: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        // Start the launch check before Sparkle schedules its regular update cycle.
        if updater.automaticallyChecksForUpdates && updater.canCheckForUpdates && !updater.sessionInProgress {
            updater.checkForUpdatesInBackground()
        }
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$installsAutomatically)
    }

    func check() { controller?.checkForUpdates(nil) }
    func setChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setInstalls(_ value: Bool) { controller?.updater.automaticallyDownloadsUpdates = value }
}

struct UpdateSettings: View {
    @EnvironmentObject private var updates: AppUpdates

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updates").font(.title2.bold())
            let info = Bundle.main.infoDictionary
            Text("TruGit " + (info?["CFBundleShortVersionString"] as? String ?? "") +
                 " · Build " + (info?["CFBundleVersion"] as? String ?? "")).foregroundStyle(.secondary)
            if updates.configured {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Check for updates at launch and periodically", isOn: Binding(get: { updates.checksAutomatically }, set: updates.setChecks))
                    Toggle("Download and install updates automatically", isOn: Binding(get: { updates.installsAutomatically }, set: updates.setInstalls))
                        .disabled(!updates.checksAutomatically)
                }.toggleStyle(.checkbox).padding(14).pullCard()
                Button("Check for Updates…", action: updates.check).disabled(!updates.canCheck)
            } else {
                Text("This is a development build. Automatic updates are available in signed distribution builds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
    }
}
