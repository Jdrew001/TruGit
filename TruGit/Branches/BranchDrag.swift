import AppKit
import SwiftUI

struct BranchDrag {
    let repository: URL
    let source: RevisionPoint
    var commits: [GitCommit] = []
    static let commitType = NSPasteboard.PasteboardType("com.drewatkison.TruGit.commit")

    static let referenceType = NSPasteboard.PasteboardType("com.drewatkison.TruGit.reference")

    @MainActor static func local(from info: NSDraggingInfo, in root: URL) -> Self? {
        let drag = (info.draggingSource as? BranchDragSession)?.drag
            ?? (info.draggingSource as? HistoryTableView)?.draggedCommits
        guard let drag, drag.repository == root else { return nil }
        return drag
    }

    func canDrop(on target: RevisionPoint) -> Bool {
        source.id != target.id && (source.isLocal || target.isLocal)
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
        surface(at: location, window: window)?.control.reference
    }

    private static func surface(at location: NSPoint, window: NSWindow?) -> BranchMouseView? {
        guard let root = window?.contentView else { return nil }
        let point = root.superview?.convert(location, from: nil) ?? location
        var hit = root.hitTest(point)
        if let surface = hit as? BranchMouseView { return surface }
        // A secondary click passes through our mouse surface to its SwiftUI menu.
        // Resolve overlapping graph badges in the frontmost hit view's subtree first.
        let candidates = surfaces.allObjects.filter { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor &&
                view.visibleRect.contains(view.convert(location, from: nil))
        }
        while let view = hit {
            if let match = candidates.first(where: { $0.isDescendant(of: view) }) { return match }
            hit = view.superview
        }
        return nil
    }

    var control: BranchDragControl
    private var start: NSPoint?
    init(control: BranchDragControl) {
        self.control = control
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        registerForDraggedTypes([BranchDrag.commitType, BranchDrag.referenceType])
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
        start = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        self.start = nil
        let drag = BranchDrag(repository: control.repository, source: RevisionPoint(control.reference))
        let writer = NSPasteboardItem()
        writer.setString(drag.source.id, forType: BranchDrag.referenceType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let label = NSAttributedString(string: drag.source.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white
        ])
        let size = NSSize(width: ceil(label.size().width) + 16, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: 8, y: (rect.height - label.size().height) / 2))
            return true
        }
        let cursor = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: cursor.x - 8, y: cursor.y - 12, width: size.width, height: size.height), contents: image)
        let source = BranchDragSession(drag: drag, window: window)
        beginDraggingSession(with: [item], event: event, source: source)
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        if event.clickCount == 2 { control.onCheckout(control.reference) }
        else { control.onSelect(control.reference) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = RevisionPoint(control.reference)
        guard let drag = BranchDrag.local(from: sender, in: control.repository), drag.canDrop(on: target) else { return [] }
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let target = RevisionPoint(control.reference)
        guard let drag = BranchDrag.local(from: sender, in: control.repository), drag.canDrop(on: target) else { return false }
        return control.onDrop(drag, target)
    }
}

/// Owns the picked reference after its transient badge disappears.
@MainActor private final class BranchDragSession: NSObject, NSDraggingSource {
    private static var active: BranchDragSession?
    let drag: BranchDrag
    weak var window: NSWindow?

    init(drag: BranchDrag, window: NSWindow) {
        self.drag = drag
        self.window = window
        super.init()
        Self.active = self
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        HistoryTableView.updateDragPreview(in: window, repository: drag.repository, at: nil, leaving: drag.source.oid)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        HistoryTableView.updateDragPreview(in: window, repository: drag.repository, at: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        HistoryTableView.updateDragPreview(in: window, repository: drag.repository, at: nil)
        Self.active = nil
    }
}
