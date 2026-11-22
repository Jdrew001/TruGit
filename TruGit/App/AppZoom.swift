import SwiftUI

enum AppZoom: Int {
    case percent75 = 75
    case percent100 = 100
    case percent125 = 125
    case percent150 = 150
    case percent175 = 175

    static var initialValue: Self {
        Self(rawValue: UserDefaults.standard.integer(forKey: "historyGraphZoom")) ?? .percent100
    }

    var scale: CGFloat { CGFloat(rawValue) / 100 }
    var smaller: Self? { Self(rawValue: rawValue - 25) }
    var larger: Self? { Self(rawValue: rawValue + 25) }
}

private struct AppZoomKey: EnvironmentKey {
    static let defaultValue: Binding<AppZoom> = .constant(.percent100)
}

extension EnvironmentValues {
    var appZoom: Binding<AppZoom> {
        get { self[AppZoomKey.self] }
        set { self[AppZoomKey.self] = newValue }
    }
}

struct AppZoomViewport<Content: View>: View {
    @Environment(\.appZoom) private var zoom
    @ViewBuilder let content: () -> Content

    private let minimumSize = CGSize(width: 860, height: 480)

    var body: some View {
        GeometryReader { geometry in
            let scale = zoom.wrappedValue.scale
            // Keep the scroll view inside the safe area when overflow enables scrolling.
            let topGap: CGFloat = 1
            let available = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - topGap))
            let width = max(minimumSize.width, available.width / scale)
            let height = max(minimumSize.height, available.height / scale)
            let axes = overflow(in: available, scale: scale)
            ScrollView(axes) {
                content()
                    .frame(width: width, height: height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: height * scale, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, topGap)
        }
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .background(WorkspaceColors.history.ignoresSafeArea())
    }

    private func overflow(in available: CGSize, scale: CGFloat) -> Axis.Set {
        var axes: Axis.Set = []
        if minimumSize.width * scale > available.width { axes.insert(.horizontal) }
        if minimumSize.height * scale > available.height { axes.insert(.vertical) }
        return axes
    }
}

struct AppZoomControls: View {
    @Environment(\.appZoom) private var binding

    var body: some View {
        let zoom = binding.wrappedValue
        HStack(spacing: 6) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                if let smaller = zoom.smaller { binding.wrappedValue = smaller }
            }
            .labelStyle(.iconOnly)
            .help("Zoom out (⌘−)")
            .disabled(zoom.smaller == nil)
            Button("\(zoom.rawValue)%") { binding.wrappedValue = .percent100 }
                .monospacedDigit()
                .accessibilityLabel("Reset app zoom")
                .accessibilityValue("\(zoom.rawValue) percent")
                .help("Reset app zoom (⌘0)")
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                if let larger = zoom.larger { binding.wrappedValue = larger }
            }
            .labelStyle(.iconOnly)
            .help("Zoom in (⌘=)")
            .disabled(zoom.larger == nil)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .fixedSize()
    }
}

struct AppZoomCommands: Commands {
    @Binding var zoom: AppZoom

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { if let larger = zoom.larger { zoom = larger } }
                .keyboardShortcut("=")
                .disabled(zoom.larger == nil)
            Button("Zoom Out") { if let smaller = zoom.smaller { zoom = smaller } }
                .keyboardShortcut("-")
                .disabled(zoom.smaller == nil)
            Button("Reset App Zoom") { zoom = .percent100 }
                .keyboardShortcut("0")
        }
    }
}

extension View {
    func zoomAppDialog() -> some View { modifier(AppZoomDialog()) }
}

private struct AppZoomDialog: ViewModifier {
    @Environment(\.appZoom) private var zoom

    func body(content: Content) -> some View {
        let scale = zoom.wrappedValue.scale
        AppZoomDialogLayout(scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }
}

private struct AppZoomDialogLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(unscaled(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: unscaled(ProposedViewSize(bounds.size)))
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}
