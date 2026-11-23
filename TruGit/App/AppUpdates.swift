import Combine
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
    private let releaseFeed: ReleaseFeed?
    private var automaticChecks: AnyCancellable?
    private var releaseWatch: Task<Void, Never>?
    private var checkingRelease: ReleaseFeed.Release?
    private var checkedRelease: String?
    @Published private(set) var status = Status.idle
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var installsAutomatically = false
    var configured: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        releaseFeed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
            .flatMap { URL(string: $0) }
            .flatMap { ReleaseFeed(latestURL: $0, installedVersion: version) }
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
        automaticChecks = updater.publisher(for: \.automaticallyChecksForUpdates).removeDuplicates().sink { [weak self] enabled in
            self?.watchReleases(enabled: enabled)
        }
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$installsAutomatically)
    }

    private var availableBackgroundUpdater: SPUUpdater? {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates,
              updater.canCheckForUpdates, !updater.sessionInProgress else { return nil }
        return updater
    }

    private func watchReleases(enabled: Bool) {
        checksAutomatically = enabled
        releaseWatch?.cancel()
        releaseWatch = nil
        guard enabled, let releaseFeed else { return }

        releaseWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(ReleaseFeed.checkInterval)) }
                catch { return }
                guard let self else { return }
                guard self.availableBackgroundUpdater != nil else { continue }
                let release = await releaseFeed.latestUpdate()
                if !Task.isCancelled, let release { self.checkRelease(release) }
            }
        }
    }

    private func checkRelease(_ release: ReleaseFeed.Release) {
        guard let updater = availableBackgroundUpdater, release.version != checkedRelease else { return }
        checkingRelease = release
        updater.checkForUpdatesInBackground()
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
        checkedRelease = item.displayVersionString
        status = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if let checkingRelease { checkedRelease = checkingRelease.version }
        status = .noUpdate
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        checkingRelease = nil
        if status == .checking || (error != nil && status == .idle) {
            status = error == nil ? .idle : .failed
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        (checkingRelease?.appcastURL ?? releaseFeed?.freshURL)?.absoluteString
    }

    func setChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setInstalls(_ value: Bool) { controller?.updater.automaticallyDownloadsUpdates = value }
}

private struct ReleaseFeed: Sendable {
    static let checkInterval = 15

    struct Release: Sendable {
        let version: String
        let appcastURL: URL
    }

    let latestURL: URL
    let installedVersion: String
    private let releasePrefix: String
    private let assetName: String

    init?(latestURL: URL, installedVersion: String?) {
        let path = latestURL.path
        guard let installedVersion, let latest = path.range(of: "/releases/latest/download/") else { return nil }
        self.latestURL = latestURL
        self.installedVersion = installedVersion
        releasePrefix = String(path[..<latest.lowerBound]) + "/releases/download/"
        assetName = String(path[latest.upperBound...])
    }

    var freshURL: URL {
        // GitHub can cache the unqualified latest-release redirect after a new release is published.
        let window = Int(Date().timeIntervalSince1970) / Self.checkInterval
        return latestURL.appending(queryItems: [URLQueryItem(name: "trugit-check", value: String(window))])
    }

    func latestUpdate() async -> Release? {
        var request = URLRequest(url: freshURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (_, response) = try? await URLSession.shared.data(for: request, delegate: ReleaseRedirect.shared),
              let redirect = response as? HTTPURLResponse, (300..<400).contains(redirect.statusCode),
              let location = redirect.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: latestURL)?.absoluteURL,
              target.scheme == latestURL.scheme, target.host == latestURL.host, target.port == latestURL.port else { return nil }

        let path = target.path
        guard path.hasPrefix(releasePrefix + "v"), path.hasSuffix("/" + assetName) else { return nil }
        let version = String(path.dropFirst(releasePrefix.count + 1).dropLast(assetName.count + 1))
        let numbers = version.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ Int($0).map { $0 >= 0 } == true }),
              version.compare(installedVersion, options: .numeric) == .orderedDescending else { return nil }
        return Release(version: version, appcastURL: target)
    }
}

private final class ReleaseRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = ReleaseRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UpdateSettings: View {
    @EnvironmentObject private var updates: AppUpdates

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updates").font(.title2.bold())
            Text(AppVersion.display).foregroundStyle(.secondary)
            if updates.configured {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Check for updates while TruGit is open", isOn: Binding(get: { updates.checksAutomatically }, set: updates.setChecks))
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
    let fetchStatus: RepositoryFetchStatus?
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

            if let fetchStatus {
                RepositoryFetchIndicator(status: fetchStatus)
            }
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

private struct RepositoryFetchIndicator: View {
    let status: RepositoryFetchStatus

    var body: some View {
        indicator
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("repository-fetch-status")
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .fetching:
            Label("Fetching remotes…", systemImage: "arrow.down.circle")
        case .fetched(let date):
            Label("Remotes fetched", systemImage: "checkmark.circle")
                .help("Last fetched \(date.formatted(date: .abbreviated, time: .shortened))")
        case .unavailable:
            Label("Auto-fetch unavailable", systemImage: "exclamationmark.circle")
                .help("Use Fetch All Remotes in the Actions menu to try manually.")
        }
    }
}
