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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let highlighted = badge.references.contains { $0.id == hover.referenceID }
        tint.overlay(Color.white.opacity(highlighted ? 0.08 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: highlighted)
    }
}

/// Hosted above the table so expanded badges can overlap the graph without changing row heights.
@MainActor
final class GraphReferencePreview {
    static let rowHeight: CGFloat = 23
    static let fontSize: CGFloat = 11
    private static let maximumWidth: CGFloat = 320
    private static let maximumHeight = rowHeight * 5
    private let hoverState = GraphReferenceHover()
    private var overlay: NSView?
    private(set) var scrolls = false
    private var commit: String?
    private var pendingCommit: String?
    private var pending: Task<Void, Never>?

    func contains(_ point: NSPoint, in window: NSWindow?) -> Bool {
        guard let overlay, let window, overlay.window === window else { return false }
        return overlay.bounds.contains(overlay.convert(point, from: nil))
    }

    func updateHighlight(at point: NSPoint, in window: NSWindow?) {
        let id = contains(point, in: window) ? BranchMouseView.reference(at: point, window: window)?.id : nil
        if hoverState.referenceID != id { hoverState.referenceID = id }
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        pendingCommit = nil
        guard commit != nil else { return }
        commit = nil
        overlay?.removeFromSuperview()
        overlay = nil
        if hoverState.referenceID != nil { hoverState.referenceID = nil }
        scrolls = false
    }

    private static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width)
    }

    func hover(_ badges: [GraphReferenceBadge], at id: String, anchor: NSRect, in table: NSTableView,
               immediately: Bool, content: @escaping () -> AnyView) {
        guard id != commit, immediately || id != pendingCommit else { return }
        dismiss()
        if immediately {
            present(badges, at: id, anchor: anchor, in: table, animate: false, content: content)
            return
        }

        pendingCommit = id
        pending = Task { [weak self, weak table] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.pendingCommit = nil
            guard let table, NSEvent.pressedMouseButtons == 0 else { return }
            self.present(badges, at: id, anchor: anchor, in: table, animate: true, content: content)
            if let window = table.window {
                self.updateHighlight(at: window.mouseLocationOutsideOfEventStream, in: window)
            }
        }
    }

    private func present(_ badges: [GraphReferenceBadge], at id: String, anchor: NSRect, in table: NSTableView,
                         animate: Bool, content: () -> AnyView) {
        guard table.window?.isKeyWindow == true, let clip = table.enclosingScrollView?.contentView,
              table.visibleRect.intersects(anchor) else { return }
        let available = table.convert(table.visibleRect, to: clip)
        let rect = table.convert(anchor, to: clip)
        let naturalHeight = CGFloat(badges.count) * Self.rowHeight
        let height = min(available.height, Self.maximumHeight, naturalHeight)
        let width = min(available.width, Self.maximumWidth, preferredWidth(badges))
        guard width > 0, height > 0 else { return }

        commit = id
        scrolls = naturalHeight > height
        let rows = content().environmentObject(hoverState)
        let shape = RoundedRectangle(cornerRadius: 6)
        let view = NSHostingView(rootView: Group {
            if scrolls { ScrollView { rows } } else { rows }
        }.frame(width: width, height: height, alignment: .topLeading)
         .background(WorkspaceColors.sidebar)
         .clipShape(shape)
         .overlay { shape.strokeBorder(WorkspaceColors.divider).allowsHitTesting(false) }
         .preferredColorScheme(.dark))
        view.sizingOptions = []
        view.identifier = .init("expandedGraphReferences")
        let x = min(rect.minX, available.maxX - width)
        let y = clip.isFlipped ? min(rect.minY, available.maxY - height) : max(available.minY, rect.maxY - height)
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        let fadesIn = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fadesIn { view.alphaValue = 0 }
        clip.addSubview(view, positioned: .above, relativeTo: table)
        overlay = view
        view.layoutSubtreeIfNeeded()
        if fadesIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
        }
    }

    private func preferredWidth(_ badges: [GraphReferenceBadge]) -> CGFloat {
        let width = badges.map { badge in
            // Reserve room for the location icons and the local branch's Switch button.
            let controls: CGFloat = badge.reference.kind == .local ? 90 : 36
            let remote: CGFloat = badge.reference.kind == .local && !badge.remotes.isEmpty ? 19 : 0
            return Self.nameWidth(badge.name) + controls + remote
        }.max() ?? 0
        return max(132, width)
    }
}
