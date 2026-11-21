import AppKit
import SwiftUI

// Keep dragging inside the tab strip so a short mouse movement reorders a tab
// immediately and never exports the repository path through the pasteboard.
struct RepositoryTabDrag: NSViewRepresentable {
    enum Target {
        case tab(RepositoryTab)
        case group(UUID)
        case end
    }
    let target: Target
    let model: RepositoryModel

    func makeNSView(context: Context) -> Surface { Surface(self) }
    func updateNSView(_ view: Surface, context: Context) { view.control = self }

    final class Surface: NSView {
        private static let targets = NSHashTable<Surface>.weakObjects()
        private static weak var source: Surface?
        private static var mouseMonitor: Any?
        var control: RepositoryTabDrag
        private var start: NSPoint?
        private var dragging = false
        private weak var hover: Surface?
        private enum Mark { case before, after, inside }
        private struct Drop {
            let view: Surface
            let mark: Mark
            let change: TabOrganizationChange
        }
        private var indicator: Mark? { didSet { needsDisplay = true } }

        init(_ control: RepositoryTabDrag) {
            self.control = control
            super.init(frame: .zero)
            Self.targets.add(self)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        // SwiftUI owns the buttons and context menus. Track only primary drags on
        // their labels, inside the content area below the native title bar.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, Self.mouseMonitor == nil else { return }
            Self.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                Self.route(event)
            }
        }

        private static func route(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseDown {
                source?.reset()
                source = nil
                guard !event.modifierFlags.contains(.control), let window = event.window, window.attachedSheet == nil else { return event }
                let point = event.locationInWindow
                guard let handle = targets.allObjects.first(where: { view in
                    guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
                    let local = view.convert(point, from: nil)
                    guard view.bounds.intersection(view.visibleRect).contains(local) else { return false }
                    switch view.control.target {
                    case .tab: return local.x < view.bounds.maxX - 22
                    case .group: return true
                    case .end: return false
                    }
                }) else { return event }
                source = handle
                handle.start = point
                window.makeKeyAndOrderFront(nil)
                return nil
            }
            guard let handle = source else { return event }
            if event.type == .leftMouseUp {
                source = nil
                handle.mouseUp(with: event)
            } else {
                handle.mouseDragged(with: event)
            }
            return nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            guard dragging || hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragging = true
            _ = autoscroll(with: event)
            let drop = drop(at: point)
            if drop?.view !== hover { hover?.indicator = nil; hover = drop?.view }
            hover?.indicator = drop?.mark
            NSCursor.closedHand.set()
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            let wasDragging = dragging || hypot(point.x - start.x, point.y - start.y) >= 4
            let change = wasDragging ? drop(at: point)?.change : nil
            reset()
            if wasDragging {
                if let change { control.model.organizeTabs(change) }
            } else {
                switch control.target {
                case .tab(let tab): control.model.selectTab(tab.id)
                case .group(let id): control.model.organizeTabs(.toggle(id))
                case .end: break
                }
            }
        }

        private func target(at point: NSPoint) -> Surface? {
            var end: Surface?
            for view in Self.targets.allObjects where view.window === window && view.control.model === control.model && !view.isHiddenOrHasHiddenAncestor {
                if view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil)) { return view }
                if case .end = view.control.target { end = view }
            }
            // The unoccupied strip to the right of + also accepts a move to the end.
            if let end, let scroll = enclosingScrollView, scroll.visibleRect.contains(scroll.convert(point, from: nil)) {
                let p = end.convert(point, from: nil)
                if p.x >= end.bounds.maxX && (end.bounds.minY...end.bounds.maxY).contains(p.y) { return end }
            }
            return nil
        }

        private func drop(at point: NSPoint) -> Drop? {
            guard let target = target(at: point) else { return nil }
            let after = target.convert(point, from: nil).x >= target.bounds.midX
            switch control.target {
            case .tab(let tab):
                let path = tab.id.path
                switch target.control.target {
                case .tab(let other):
                    guard path != other.id.path else { return nil }
                    return Drop(view: target, mark: after ? .after : .before, change: .move(path, .beside(other.id.path, after: after)))
                case .group(let id): return Drop(view: target, mark: .inside, change: .move(path, .group(id)))
                case .end: return Drop(view: target, mark: .before, change: .move(path, .end))
                }
            case .group(let id):
                return groupDrop(id, over: target, at: point)
            case .end: return nil
            }
        }

        private func groupDrop(_ id: UUID, over target: Surface, at point: NSPoint) -> Drop? {
            let neighbor: RepositoryTabGroup?
            switch target.control.target {
            case .end: return Drop(view: target, mark: .before, change: .moveGroup(id, .end))
            case .group(let other): neighbor = control.model.tabGroups.first { $0.id == other }
            case .tab(let tab): neighbor = control.model.tabGroups.first { $0.members.contains(tab.id.path) }
            }

            // Treat the destination group as one block, including a collapsed header.
            let first: Surface
            let last: Surface
            let anchor: String
            if let neighbor {
                guard neighbor.id != id, let member = neighbor.members.first else { return nil }
                let surfaces = Self.targets.allObjects.filter { view in
                    guard view.window === window, view.control.model === control.model, !view.isHiddenOrHasHiddenAncestor else { return false }
                    switch view.control.target {
                    case .group(let other): return other == neighbor.id
                    case .tab(let tab): return neighbor.members.contains(tab.id.path)
                    case .end: return false
                    }
                }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard let leading = surfaces.first, let trailing = surfaces.last else { return nil }
                first = leading
                last = trailing
                anchor = member
            } else {
                guard case .tab(let tab) = target.control.target else { return nil }
                first = target
                last = target
                anchor = tab.id.path
            }
            let midpoint = (first.convert(first.bounds, to: nil).minX + last.convert(last.bounds, to: nil).maxX) / 2
            let after = point.x >= midpoint
            return Drop(view: after ? last : first, mark: after ? .after : .before,
                        change: .moveGroup(id, .beside(anchor, after: after)))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let indicator else { return }
            switch indicator {
            case .inside:
                NSColor.controlAccentColor.setStroke()
                let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5)
                border.lineWidth = 2
                border.stroke()
            case .before, .after:
                NSColor.controlAccentColor.setFill()
                CGRect(x: indicator == .after ? bounds.maxX - 3 : 0, y: 3, width: 3, height: max(0, bounds.height - 6)).fill()
            }
        }
        private func reset() {
            hover?.indicator = nil
            hover = nil
            if dragging { NSCursor.arrow.set() }
            dragging = false
            start = nil
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { reset() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
