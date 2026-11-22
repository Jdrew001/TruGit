import AppKit
import SwiftUI

@MainActor
private final class GraphReferenceHover: ObservableObject {
    @Published var referenceID: String?
}

struct GraphReferenceRowBackground: View {
    let badge: GraphReferenceBadge
    let tint: Color
    @EnvironmentObject private var hover: GraphReferenceHover

    var body: some View {
        tint.overlay(Color.black.opacity(badge.references.contains { $0.id == hover.referenceID } ? 0.20 : 0))
    }
}

/// Hosted above the table so expanded badges can overlap the graph without changing row heights.
@MainActor
final class GraphReferencePreview {
    static let rowHeight: CGFloat = 24
    private let hoverState = GraphReferenceHover()
    private var overlay: NSView?
    private(set) var scrolls = false
    private var commit: String?

    func contains(_ point: NSPoint, in window: NSWindow?) -> Bool {
        guard let overlay, let window, overlay.window === window else { return false }
        return overlay.bounds.contains(overlay.convert(point, from: nil))
    }

    func updateHighlight(at point: NSPoint, in window: NSWindow?) {
        let id = contains(point, in: window) ? BranchMouseView.reference(at: point, window: window)?.id : nil
        if hoverState.referenceID != id { hoverState.referenceID = id }
    }

    func dismiss() {
        guard commit != nil else { return }
        commit = nil
        overlay?.removeFromSuperview()
        overlay = nil
        if hoverState.referenceID != nil { hoverState.referenceID = nil }
        scrolls = false
    }

    static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width)
    }

    func hover(_ badges: [GraphReferenceBadge], at id: String, anchor: NSRect, in table: NSTableView, content: @escaping (CGFloat) -> AnyView) {
        guard id != commit else { return }
        dismiss()
        guard table.window?.isKeyWindow == true, let clip = table.enclosingScrollView?.contentView,
              table.visibleRect.intersects(anchor) else { return }
        commit = id
        let longest = badges.map { badge in
            // Reserve space for the location icon and the local branch’s switch button.
            Self.nameWidth(badge.name) + (badge.reference.kind == .local ? 92 : 40) + (badge.reference.kind == .local && !badge.remotes.isEmpty ? 19 : 0)
        }.max() ?? 0
        // Measure the overlay and its text in the same coordinates as the table.
        let available = table.convert(table.visibleRect, to: clip)
        let rect = table.convert(anchor, to: clip)
        let width = min(available.width, min(560, longest))
        let maxHeight = min(312, available.height)
        let rows = content(width).environmentObject(hoverState).frame(width: width)
        let minimumHeight = CGFloat(badges.count) * Self.rowHeight
        let needsMeasurement = minimumHeight <= maxHeight && longest > width
        let naturalHeight = needsMeasurement
            ? NSHostingView(rootView: rows.fixedSize(horizontal: false, vertical: true)).fittingSize.height
            : minimumHeight
        let height = min(maxHeight, naturalHeight)
        scrolls = naturalHeight > height
        let view = NSHostingView(rootView: Group {
            if scrolls { ScrollView { rows } } else { rows }
        }.frame(width: width, height: height, alignment: .topLeading)
         .background(WorkspaceColors.history).preferredColorScheme(.dark))
        view.sizingOptions = []
        view.identifier = .init("expandedGraphReferences")
        let x = min(rect.minX, available.maxX - width)
        let y = clip.isFlipped ? min(rect.minY, available.maxY - height) : max(available.minY, rect.maxY - height)
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        clip.addSubview(view, positioned: .above, relativeTo: table)
        overlay = view
        view.layoutSubtreeIfNeeded()
    }
}
