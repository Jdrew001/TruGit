import AppKit
import SwiftUI

/// Only the painted thumb is narrow. AppKit keeps its normal hit area and
/// handles track clicks, drags, momentum, and overlay fading.
class WorkspaceScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    var thumbThickness: CGFloat = 4

    override func drawKnob() {
        let native = rect(for: .knob)
        guard !native.isEmpty else { return }
        let vertical = bounds.height > bounds.width
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let width = contrast ? max(3, thumbThickness) : thumbThickness
        var thumb = native
        if vertical {
            thumb.origin.x = (native.midX - width / 2).rounded()
            thumb.size.width = width
        } else {
            thumb.origin.y = (native.midY - width / 2).rounded()
            thumb.size.height = width
        }
        NSColor(calibratedWhite: contrast ? 0.84 : 0.58, alpha: 1).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

extension NSScrollView {
    func useWorkspaceScrollers() {
        if hasVerticalScroller, !(verticalScroller is WorkspaceScroller) {
            verticalScroller = WorkspaceScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
        }
        if hasHorizontalScroller, !(horizontalScroller is WorkspaceScroller) {
            horizontalScroller = WorkspaceScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
        }
    }
}

struct WorkspaceScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content().background(ScrollerInstaller().allowsHitTesting(false).accessibilityHidden(true))
        }
    }
}

private struct ScrollerInstaller: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            enclosingScrollView?.useWorkspaceScrollers()
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.enclosingScrollView?.useWorkspaceScrollers()
    }
}
