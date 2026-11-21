import AppKit
import SwiftUI

struct BranchDrag {
    let repository: URL
    let source: RevisionPoint
    var commits: [GitCommit] = []
    static let commitType = NSPasteboard.PasteboardType("com.drewatkison.TruGit.commit")

    @MainActor static func commit(from info: NSDraggingInfo, in root: URL) -> Self? {
        guard let table = info.draggingSource as? HistoryTableView,
              let drag = table.draggedCommits, drag.repository == root else { return nil }
        return drag
    }
}

struct BranchDragControl: ViewModifier {
    let reference: RepositoryReference
    let repository: URL
    let onSelect: (RepositoryReference) -> Void
    let onCheckout: (RepositoryReference) -> Void
    let onDrop: (BranchDrag, RevisionPoint) -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        content.overlay {
            BranchMouseSurface(control: self)
                .accessibilityHidden(true)
        }
    }
}

private struct BranchMouseSurface: NSViewRepresentable {
    let control: BranchDragControl

    func makeNSView(context: Context) -> BranchMouseView {
        BranchMouseView(control: control)
    }

    func updateNSView(_ view: BranchMouseView, context: Context) {
        view.control = control
    }
}

final class BranchMouseView: NSView {
    private static let surfaces = NSHashTable<BranchMouseView>.weakObjects()
    static func reference(at event: NSEvent) -> RepositoryReference? {
        reference(at: event.locationInWindow, window: event.window)
    }

    static func reference(at location: NSPoint, window: NSWindow?) -> RepositoryReference? {
        surfaces.allObjects.first { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor &&
                view.bounds.intersection(view.visibleRect).contains(view.convert(location, from: nil))
        }?.control.reference
    }

    var control: BranchDragControl
    private var start: NSPoint?
    private weak var highlightedTarget: BranchMouseView?
    private var preview: NSTextField?

    init(control: BranchDragControl) {
        self.control = control
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        registerForDraggedTypes([BranchDrag.commitType])
        Self.surfaces.add(self)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let SwiftUI present the branch's contextual menu for secondary clicks.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        clearDrag()
        start = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, moved(from: start, to: event.locationInWindow) || preview != nil else { return }
        let target = destination(at: event.locationInWindow)
        if highlightedTarget !== target {
            highlightedTarget?.layer?.borderWidth = 0
            highlightedTarget = target
            target?.layer?.borderColor = NSColor.controlAccentColor.cgColor
            target?.layer?.borderWidth = 2
        }
        if let contentView = window?.contentView {
            let label = preview ?? makePreview(in: contentView)
            let position = contentView.convert(event.locationInWindow, from: nil)
            label.setFrameOrigin(NSPoint(x: position.x + 12, y: position.y + 8))
        }
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        defer { clearDrag() }
        if preview != nil || moved(from: start, to: event.locationInWindow) {
            if Self.reference(at: event)?.id == control.reference.id { return }
            let badge = destination(at: event.locationInWindow)
            let target = badge.map { RevisionPoint($0.control.reference) } ?? HistoryTableView.revision(at: event, in: control.repository)
            guard let target, target.id != control.reference.id else { return }
            _ = control.onDrop(BranchDrag(repository: control.repository, source: RevisionPoint(control.reference)), target)
        } else if event.clickCount == 2 {
            control.onCheckout(control.reference)
        } else {
            control.onSelect(control.reference)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard control.reference.kind == .local, BranchDrag.commit(from: sender, in: control.repository) != nil else { return [] }
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard control.reference.kind == .local, let drag = BranchDrag.commit(from: sender, in: control.repository) else { return false }
        return control.onDrop(drag, RevisionPoint(control.reference))
    }

    private func destination(at point: NSPoint) -> BranchMouseView? {
        Self.surfaces.allObjects.first { view in
            view.window === window && view.control.repository == control.repository
                && view.control.reference.id != control.reference.id && !view.isHiddenOrHasHiddenAncestor
                && view.visibleRect.contains(view.convert(point, from: nil))
        }
    }

    private func moved(from start: NSPoint, to end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= 4
    }

    private func makePreview(in parent: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: "  " + control.reference.name + "  ")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.backgroundColor = .selectedContentBackgroundColor
        label.textColor = .white
        label.drawsBackground = true
        label.sizeToFit()
        parent.addSubview(label)
        preview = label
        return label
    }

    private func clearDrag() {
        if preview != nil { NSCursor.arrow.set() }
        preview?.removeFromSuperview()
        preview = nil
        highlightedTarget?.layer?.borderWidth = 0
        highlightedTarget = nil
        start = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
}
