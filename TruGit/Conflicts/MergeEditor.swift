import AppKit
import SwiftUI

struct MergeDraft {
    private(set) var string = ""
    private(set) var ranges: [NSRange] = []
    private(set) var choices: [Int: ConflictChoice] = [:]
    private(set) var hasManualEdits = false
    private(set) var revision = UUID()
    private(set) var focusedHunk: Int?
    let usesCRLF: Bool

    init(_ text: ConflictText) {
        usesCRLF = Self.usesCRLF(text.data)
        var length = 0
        for part in text.resultParts(using: [:]) {
            let piece: String
            switch part {
            case .context(let data): piece = String(decoding: data, as: UTF8.self)
            case .conflict(let id, _):
                piece = "Conflict \(id + 1) · Choose a side" + (usesCRLF ? "\r\n" : "\n")
                ranges.append(NSRange(location: length, length: piece.utf16.count))
            }
            string += piece
            length += piece.utf16.count
        }
    }

    init(file: Data) {
        string = String(decoding: file, as: UTF8.self)
        usesCRLF = Self.usesCRLF(file)
    }

    private static func usesCRLF(_ data: Data) -> Bool {
        guard let newline = data.firstIndex(of: 10), newline > data.startIndex else { return false }
        return data[newline - 1] == 13
    }

    var remaining: Int { ranges.count - choices.count }

    mutating func choose(_ choice: ConflictChoice, for hunk: ConflictHunk) {
        if choices[hunk.id] != choice {
            let range = ranges[hunk.id]
            let replacement = String(decoding: hunk.content(for: choice), as: UTF8.self)
            string = (string as NSString).replacingCharacters(in: range, with: replacement)
            let length = replacement.utf16.count
            ranges[hunk.id].length = length
            for i in (hunk.id + 1)..<ranges.count {
                ranges[i].location += length - range.length
            }
            choices[hunk.id] = choice
        }
        focusedHunk = hunk.id
        revision = UUID()
    }

    func canEdit(_ range: NSRange) -> Bool {
        !ranges.enumerated().contains { index, region in
            guard choices[index] == nil else { return false }
            return NSIntersectionRange(region, range).length > 0 ||
                (range.length == 0 && range.location > region.location && range.location < NSMaxRange(region))
        }
    }

    // AppKit reports edits in UTF-16. Track each hunk in those same coordinates
    // so a later side choice replaces just that hunk in the edited document.
    mutating func recordEdit(range: NSRange, replacementLength: Int, result: String) {
        let end = NSMaxRange(range)
        let delta = replacementLength - range.length
        for index in ranges.indices {
            let region = ranges[index]
            let start = region.location
            let stop = NSMaxRange(region)
            if end <= start {
                ranges[index].location += delta
            } else if range.location < stop {
                let mappedStart = range.location < start ? range.location + replacementLength : start
                let mappedEnd = stop <= end ? range.location + replacementLength : stop + delta
                ranges[index] = NSRange(location: mappedStart, length: max(0, mappedEnd - mappedStart))
            }
        }
        string = result
        hasManualEdits = true
    }
}

struct MergeEditor: NSViewRepresentable {
    let draft: MergeDraft
    let path: String
    let enabled: Bool
    let edited: (MergeDraft) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let initial = NSRect(x: 0, y: 0, width: 600, height: 200)
        let scroll = NSScrollView(frame: initial)
        scroll.hasVerticalScroller = true
        scroll.useWorkspaceScrollers()
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: initial.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NumberedCodeView(frame: initial, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        scroll.documentView = view
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.usesFindBar = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.backgroundColor = NSColor(WorkspaceColors.history)
        view.textContainerInset = NSSize(width: 42, height: 6)
        view.setAccessibilityLabel("Merged result code editor")
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        context.coordinator.view = view
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 200))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.view else { return }
        view.isEditable = enabled
        guard draft.revision != coordinator.revision else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.revision = draft.revision
        if !(view.string as NSString).isEqual(to: draft.string) {
            view.string = draft.string
            coordinator.undo.removeAllActions()
        }
        (view as? NumberedCodeView)?.invalidateLines()
        coordinator.color(NSRange(location: 0, length: view.string.utf16.count))
        if let id = draft.focusedHunk {
            let region = draft.ranges[id]
            view.setSelectedRange(NSRange(location: region.location, length: 0))
            view.scrollRangeToVisible(NSRange(location: region.location, length: min(1, region.length)))
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: MergeEditor
        let syntax: CodeHighlighting
        let undo = UndoManager()
        weak var view: NSTextView?
        var updating = false
        var revision: UUID?
        private var pendingHighlight: NSRange?

        init(_ parent: MergeEditor) {
            self.parent = parent
            syntax = CodeHighlighting(path: parent.path)
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard parent.draft.canEdit(range) else { NSSound.beep(); return false }
            if parent.draft.usesCRLF, let replacementString, replacementString.contains("\n") {
                let converted = replacementString.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n")
                if converted != replacementString {
                    view.insertText(converted, replacementRange: range)
                    return false
                }
            }
            return true
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard !updating, mask.contains(.editedCharacters) else { return }
            let old = NSRange(location: range.location, length: range.length - delta)
            // Keep the delegate's copy current even during a batch of native edits.
            var draft = parent.draft
            draft.recordEdit(range: old, replacementLength: range.length, result: storage.string)
            parent = MergeEditor(draft: draft, path: parent.path, enabled: parent.enabled, edited: parent.edited)
            parent.edited(draft)
            (view as? NumberedCodeView)?.invalidateLines()
            // TextKit updates its temporary-attribute ranges after this callback.
            // Wait until the text view finishes the edit before changing them.
            let text = storage.string as NSString
            pendingHighlight = pendingHighlight == nil ? text.lineRange(for: range) : NSRange(location: 0, length: text.length)
        }

        func textDidChange(_ notification: Notification) {
            guard let range = pendingHighlight else { return }
            pendingHighlight = nil
            color(range)
        }

        func color(_ range: NSRange) {
            guard range.length > 0, let view, let layout = view.layoutManager else { return }
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            let text = (view.string as NSString).substring(with: range)
            var location = range.location
            let highlighted = syntax.highlight(text)
            for run in highlighted.runs {
                let count = String(highlighted[run.range].characters).utf16.count
                if let color = run.foregroundColor {
                    layout.addTemporaryAttribute(.foregroundColor, value: NSColor(color),
                                                 forCharacterRange: NSRange(location: location, length: count))
                }
                location += count
            }
            for (i, region) in parent.draft.ranges.enumerated() {
                let overlap = NSIntersectionRange(range, region)
                if overlap.length > 0 {
                    let color: NSColor = parent.draft.choices[i] == nil ? .systemOrange : .systemMint
                    layout.addTemporaryAttribute(.backgroundColor, value: color.withAlphaComponent(0.12),
                                                 forCharacterRange: overlap)
                }
            }
        }
    }

}

private final class NumberedCodeView: NSTextView {
    private var starts: [Int]?

    func invalidateLines() {
        starts = nil
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer else { return }
        let text = string as NSString
        if starts == nil {
            var offsets = [0]
            var position = 0
            while position < text.length {
                position = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
                offsets.append(position)
            }
            starts = offsets
        }
        guard let starts else { return }
        let origin = textContainerOrigin
        let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        let first = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < first { low = middle + 1 } else { high = middle }
        }
        var line = low
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            guard line < starts.count, layout.characterIndexForGlyph(at: range.location) == starts[line] else { return }
            let label = String(line + 1) as NSString
            let y = origin.y + rect.minY
            label.draw(at: NSPoint(x: origin.x - label.size(withAttributes: attributes).width - 5, y: y),
                       withAttributes: attributes)
            line += 1
        }
    }

}
