import AppKit
import SwiftUI

struct HistoryColumns: Equatable {
    let refLimits: ClosedRange<CGFloat>
    let refs: CGFloat
    let graph: CGFloat
    let message: CGFloat
    let author: CGFloat
    let date: CGFloat

    init(width: CGFloat, lanes: Int, preferredRefs: CGFloat) {
        let automatic = min(154, max(54, width * 0.19))
        graph = min(width * 0.25, max(min(254, width * 0.12), min(254, CGFloat(lanes) * 23 + 15)))
        refLimits = 54...max(54, width - graph - min(160, width * 0.35))
        refs = min(refLimits.upperBound, max(refLimits.lowerBound, preferredRefs > 0 ? preferredRefs : automatic))
        let available = width - max(0, refs - automatic)
        author = available >= 560 ? min(192, available * 0.16) : 0
        date = available >= 710 ? min(164, available * 0.17) : 0
        message = min(450, max(0, width - refs - graph - author - date))
    }
}

struct HistoryColumnHeader: View {
    let columns: HistoryColumns
    var body: some View {
        HStack(spacing: 0) {
            heading("Branch / Tag", columns.refs)
            heading("Graph", columns.graph)
            heading("Commit message", columns.message)
            if columns.author > 0 { heading("Author", columns.author) }
            if columns.date > 0 { heading("Commit date / time", columns.date) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24).background(WorkspaceColors.sidebar)
    }

    private func heading(_ name: String, _ width: CGFloat) -> some View {
        Text(name.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .lineLimit(1).foregroundStyle(.secondary).padding(.leading, 6)
            .frame(width: width, alignment: .leading).clipped()
            .overlay(alignment: .trailing) { WorkspaceColors.divider.frame(width: 1) }
    }
}

struct CommitTable<Badges: View>: NSViewRepresentable {
    let graph: CommitGraph
    let columns: HistoryColumns
    let snapshot: RepositorySnapshot
    @Binding var selection: HistorySelection?
    let jump: CommitJump?
    let deletionChoices: (RepositoryReference) -> [BranchDeletion]
    let requestDelete: (BranchDeletion) -> Void
    let openActions: (RevisionPoint, RevisionOperation?) -> Void
    let openBatch: (CommitBatch) -> Void
    let createTag: (RevisionPoint) -> Void
    let canAct: Bool
    let onDrop: (BranchDrag, RevisionPoint) -> Bool
    @ViewBuilder let badges: ([RepositoryReference]) -> Badges

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.branchMenu = { [weak coordinator = context.coordinator] index, ref in coordinator?.branchMenu(at: index, clicked: ref) }
        table.root = snapshot.repository.root
        table.rowPoint = { [weak coordinator = context.coordinator] in coordinator?.point(at: $0) }
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([BranchDrag.commitType])
        table.allowsMultipleSelection = true
        table.style = .plain
        table.headerView = nil
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.rowHeight = 29
        table.intercellSpacing = .zero
        table.backgroundColor = NSColor(WorkspaceColors.history)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Commit history")
        let column = NSTableColumn(identifier: .init("commit"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.useWorkspaceScrollers()
        scroll.drawsBackground = false
        scroll.documentView = table
        table.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let layoutChanged = coordinator.parent.columns != columns
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        if coordinator.graphID != graph.id || coordinator.snapshotID != snapshot.id {
            coordinator.graphID = graph.id
            coordinator.snapshotID = snapshot.id
            coordinator.counts = WorkingChangeCounts(snapshot.repository.changes)
            let current = RepositoryReference.Kind.local.prefix + snapshot.repository.branch
            let ordered = snapshot.references.sorted { left, right in
                if (left.id == current) != (right.id == current) { return left.id == current }
                return left.id < right.id
            }
            coordinator.refs = Dictionary(grouping: ordered, by: \.commitID)
            table.reloadData()
        } else if layoutChanged {
            table.enumerateAvailableRowViews { rowView, _ in
                let cell = rowView.view(atColumn: 0)
                if let cell = cell as? CommitCell { cell.columns = columns }
                if let cell = cell as? NSHostingView<WorkingTreeRow> { cell.rootView.columns = columns }
            }
        }
        let selectedRows = coordinator.indexes(for: selection)
        if selectedRows != table.selectedRowIndexes {
            table.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
        if let jump, coordinator.jump != jump, let index = graph.indexByID[jump.commitID] {
            coordinator.jump = jump
            table.scrollRowToVisible(index + coordinator.commitOffset)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: CommitTable
        var graphID: UUID?
        var snapshotID: UUID?
        fileprivate var counts = WorkingChangeCounts([])
        var refs: [String: [RepositoryReference]] = [:]
        var jump: CommitJump?
        var updating = false

        init(_ parent: CommitTable) { self.parent = parent }

        var commitOffset: Int { parent.graph.hasWorkingTree ? 1 : 0 }

        func indexes(for selection: HistorySelection?) -> IndexSet {
            switch selection {
            case .workInProgress: return parent.graph.hasWorkingTree ? IndexSet(integer: 0) : []
            case .commit(let id): return indexes(forCommitIDs: [id])
            case .commits(let ids): return indexes(forCommitIDs: ids)
            case .stash, nil: return []
            }
        }

        private func indexes(forCommitIDs ids: [String]) -> IndexSet {
            IndexSet(ids.compactMap { parent.graph.indexByID[$0].map { $0 + commitOffset } })
        }

        // Graph rows are child-first. Store selections parent-first for cherry-pick.
        // The revert review reverses them before presenting the sequence.
        func commits(in rows: IndexSet) -> [GitCommit] {
            rows.reversed().compactMap { row in
                let index = row - commitOffset
                return parent.graph.rows.indices.contains(index) ? parent.graph.rows[index].commit : nil
            }
        }

        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection rows: IndexSet) -> IndexSet {
            guard parent.graph.hasWorkingTree, rows.count > 1 else { return rows }
            return rows.subtracting(IndexSet(integer: 0))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.graph.rows.count + commitOffset }

        func tableView(_ table: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if parent.graph.hasWorkingTree && row == 0 {
                let identifier = NSUserInterfaceItemIdentifier("workingTreeCell")
                let content = WorkingTreeRow(counts: counts, columns: parent.columns,
                                             hasParent: parent.snapshot.repository.headID != nil)
                if let cell = table.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<WorkingTreeRow> {
                    cell.rootView = content
                    return cell
                }
                let cell = NSHostingView(rootView: content)
                cell.identifier = identifier
                cell.sizingOptions = []
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("commitCell")
            let cell = table.makeView(withIdentifier: identifier, owner: self) as? CommitCell ?? CommitCell()
            cell.identifier = identifier
            let graph = parent.graph
            let item = graph.rows[row - commitOffset]
            let refs = refs[item.id] ?? []
            cell.configure(item, columns: parent.columns, lanes: graph.laneCount, head: item.id == parent.snapshot.repository.headID,
                           badges: refs.isEmpty ? nil : AnyView(parent.badges(refs).id(item.id)))
            return cell
        }

        func point(at row: Int) -> RevisionPoint? {
            let index = row - commitOffset
            guard parent.graph.rows.indices.contains(index) else { return nil }
            return RevisionPoint(commit: parent.graph.rows[index].id)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.canAct, let point = point(at: row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(point.oid, forType: BranchDrag.commitType)
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let table = tableView as? HistoryTableView else { return }
            let picked = commits(in: rowIndexes)
            guard let first = picked.first else { return }
            table.draggedCommits = BranchDrag(repository: parent.snapshot.repository.root,
                                              source: RevisionPoint(commit: first.id), commits: picked)
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            (tableView as? HistoryTableView)?.draggedCommits = nil
        }

        private func localDestination(at row: Int, info: NSDraggingInfo, table: NSTableView) -> RevisionPoint? {
            if let ref = BranchMouseView.reference(at: info.draggingLocation, window: table.window) {
                return ref.kind == .local ? RevisionPoint(ref) : nil
            }
            guard let point = point(at: row),
                  let local = refs[point.oid]?.first(where: { $0.kind == .local }) else { return nil }
            return RevisionPoint(local)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let hovered = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
            guard parent.canAct, BranchDrag.commit(from: info, in: parent.snapshot.repository.root) != nil,
                  localDestination(at: hovered, info: info, table: tableView) != nil else { return [] }
            tableView.setDropRow(hovered, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let drag = BranchDrag.commit(from: info, in: parent.snapshot.repository.root),
                  let target = localDestination(at: row, info: info, table: tableView) else { return false }
            return parent.onDrop(drag, target)
        }

        func branchMenu(at row: Int, clicked: RepositoryReference?) -> NSMenu? {
            guard let point = point(at: row) else { return nil }
            let branches = (refs[point.oid] ?? []).filter { clicked == nil || clicked?.id == $0.id }
            let menu = NSMenu()
            menu.autoenablesItems = false
            func addAction(_ label: String, _ point: RevisionPoint, _ operation: RevisionOperation?, to menu: NSMenu) {
                let item = NSMenuItem(title: label, action: #selector(openRevision(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (point, operation)
                item.isEnabled = parent.canAct
                menu.addItem(item)
            }
            let locals = parent.snapshot.references.filter { $0.kind == .local }
            let destination = locals.first(where: { $0.name == parent.snapshot.repository.branch }) ?? locals.first
            let revision = clicked.map(RevisionPoint.init) ?? point
            if case .commits(let ids) = parent.selection, ids.contains(point.oid) {
                for operation in CommitBatchOperation.allCases {
                    let label = operation.rawValue + " " + String(ids.count) + " selected commits…"
                    let item = NSMenuItem(title: label, action: #selector(reviewSelectedCommits(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = (ids, operation)
                    item.isEnabled = parent.canAct && destination != nil
                    menu.addItem(item)
                }
            } else {
                let tag = NSMenuItem(title: "Create Tag Here…", action: #selector(createTag(_:)), keyEquivalent: "")
                tag.target = self
                tag.representedObject = revision
                tag.isEnabled = parent.canAct
                menu.addItem(tag)
                addAction("Cherry-pick commit " + point.shortID + "…", point, .cherryPick, to: menu)
                if let destination {
                    addAction("Revert this commit on “" + destination.name + "”…", revision, .revert, to: menu)
                }
            }
            if let destination {
                addAction("Reset “" + destination.name + "” to this commit…", revision, .reset, to: menu)
            }
            if !branches.isEmpty { menu.addItem(.separator()) }
            for ref in branches {
                let branch = RevisionPoint(ref)
                addAction("Actions for “" + ref.name + "”…", branch, nil, to: menu)
                if ref.kind == .local, ref.upstreamID != nil {
                    addAction("Force push “" + ref.name + "” with lease…", branch, .forcePush, to: menu)
                }
                let choices = parent.deletionChoices(ref)
                guard !choices.isEmpty else { continue }
                let item = NSMenuItem(title: "Delete “" + ref.name + "”", action: nil, keyEquivalent: "")
                let scopes = NSMenu()
                scopes.autoenablesItems = false
                for choice in choices {
                    let option = NSMenuItem(title: choice.title + "…", action: #selector(deleteSelectedBranch(_:)), keyEquivalent: "")
                    option.target = self
                    option.representedObject = choice
                    scopes.addItem(option)
                }
                item.submenu = scopes
                item.isEnabled = !choices.isEmpty
                menu.addItem(item)
            }
            return menu
        }

        @objc private func createTag(_ item: NSMenuItem) {
            guard parent.canAct, let point = item.representedObject as? RevisionPoint else { return }
            parent.createTag(point)
        }

        @objc private func reviewSelectedCommits(_ item: NSMenuItem) {
            guard parent.canAct, let (ids, operation) = item.representedObject as? ([String], CommitBatchOperation) else { return }
            let commits = ids.compactMap { id in parent.graph.indexByID[id].map { parent.graph.rows[$0].commit } }
            let locals = parent.snapshot.references.filter { $0.kind == .local }.map(RevisionPoint.init)
            guard let target = locals.first(where: { $0.name == parent.snapshot.repository.branch }) ?? locals.first,
                  commits.count == ids.count else { return }
            parent.openBatch(CommitBatch(operation: operation, commits: commits, target: target, localBranches: locals))
        }

        @objc private func openRevision(_ item: NSMenuItem) {
            guard let (point, preferred) = item.representedObject as? (RevisionPoint, RevisionOperation?) else { return }
            parent.openActions(point, preferred)
        }

        @objc private func deleteSelectedBranch(_ item: NSMenuItem) {
            guard let choice = item.representedObject as? BranchDeletion else { return }
            parent.requestDelete(choice)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            if parent.graph.hasWorkingTree && table.selectedRowIndexes == IndexSet(integer: 0) {
                parent.selection = .workInProgress
            } else {
                parent.selection = HistorySelection.selectedCommits(commits(in: table.selectedRowIndexes).map(\.id))
            }
        }
    }
}

final class HistoryTableView: NSTableView {
    private static let tables = NSHashTable<HistoryTableView>.weakObjects()
    var root: URL?
    var draggedCommits: BranchDrag?
    var rowPoint: ((Int) -> RevisionPoint?)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.tables.add(self) } else { Self.tables.remove(self) }
    }

    static func revision(at event: NSEvent, in root: URL) -> RevisionPoint? {
        for table in tables.allObjects where table.window === event.window && table.root == root && !table.isHiddenOrHasHiddenAncestor {
            let point = table.convert(event.locationInWindow, from: nil)
            if table.visibleRect.contains(point) { return table.rowPoint?(table.row(at: point)) }
        }
        return nil
    }

    var branchMenu: ((Int, RepositoryReference?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        return branchMenu?(index, BranchMouseView.reference(at: event)) ?? super.menu(for: event)
    }
}

// Plain commit rows reuse the same two labels and draw their graph directly.
// Only rows carrying interactive branch or tag badges need a hosting view.
private final class CommitCell: NSTableCellView {
    private let subject = NSTextField(labelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private var initials: NSAttributedString?
    private var host: NSHostingView<AnyView>?
    private var row: CommitGraph.Row?
    private var lanes = 1
    private var head = false
    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        subject.font = .systemFont(ofSize: 12, weight: .medium)
        subject.lineBreakMode = .byTruncatingTail
        subject.maximumNumberOfLines = 1
        addSubview(subject)
        for field in [author, date] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: CommitGraph.Row, columns: HistoryColumns, lanes: Int, head: Bool, badges: AnyView?) {
        self.columns = columns
        self.row = row
        self.lanes = lanes
        self.head = head
        if row.commit.parents.count > 1 {
            let label = NSMutableAttributedString(string: "⑂ Merge  ", attributes: [.foregroundColor: NSColor.systemMint])
            label.append(NSAttributedString(string: row.commit.mergeRoute ?? row.commit.subject))
            subject.attributedStringValue = label
        } else {
            subject.stringValue = row.commit.subject
        }
        author.stringValue = row.commit.author
        date.stringValue = row.commit.date?.formatted(date: .numeric, time: .shortened) ?? ""
        initials = NSAttributedString(string: row.commit.authorInitials, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor(WorkspaceColors.history)
        ])
        toolTip = "\(row.commit.subject) — \(row.commit.author)"
        if let badges {
            if let host { host.rootView = badges }
            else {
                let view = NSHostingView(rootView: badges)
                view.sizingOptions = []
                host = view
                addSubview(view)
            }
        } else {
            host?.removeFromSuperview()
            host = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    var columns = HistoryColumns(width: 0, lanes: 1, preferredRefs: 0) {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        let c = columns
        let y = (bounds.height - 16) / 2
        let messageX = c.refs + c.graph
        host?.frame = CGRect(x: 5, y: 3, width: max(0, c.refs - 10), height: bounds.height - 6)
        subject.frame = CGRect(x: messageX + 5, y: y, width: max(0, c.message - 10), height: 16)
        author.frame = CGRect(x: messageX + c.message + 4, y: y, width: max(0, c.author - 8), height: 16)
        date.frame = CGRect(x: messageX + c.message + c.author + 4, y: y, width: max(0, c.date - 8), height: 16)
        author.isHidden = c.author == 0
        date.isHidden = c.date == 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row, let cg = NSGraphicsContext.current?.cgContext else { return }
        let c = columns
        let step = min(23, max(0, c.graph - 26) / CGFloat(max(1, lanes - 1)))
        func point(_ lane: Int, _ height: Double) -> CGPoint {
            CGPoint(x: c.refs + 13 + CGFloat(lane) * step, y: bounds.height * height)
        }
        let center = point(row.column, 0.5)
        let stripe = CGRect(x: center.x, y: 3, width: max(0, c.refs + c.graph - center.x), height: bounds.height - 6)
        let color = BranchColors.native(row.color)
        cg.setFillColor(color.withAlphaComponent(0.085).cgColor)
        cg.fill(stripe)
        cg.setFillColor(color.withAlphaComponent(0.8).cgColor)
        cg.fill(CGRect(x: stripe.maxX - 1, y: stripe.minY, width: 1, height: stripe.height))
        func tint(_ index: Int) -> CGColor { BranchColors.native(index).cgColor }
        cg.setLineWidth(2)
        for segment in row.segments {
            let start = point(segment.fromLane, segment.fromHeight)
            let end = point(segment.toLane, segment.toHeight)
            let middle = (start.y + end.y) / 2
            cg.setLineDash(phase: 0, lengths: segment.isWorkingTree ? [2, 3] : [])
            cg.setStrokeColor(segment.isWorkingTree ? NSColor.systemTeal.cgColor : tint(segment.color))
            cg.move(to: start)
            cg.addCurve(to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
            cg.strokePath()
        }
        cg.setLineDash(phase: 0, lengths: [])
        let dot = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
        if row.commit.parents.count > 1 {
            cg.move(to: CGPoint(x: center.x, y: center.y - 6))
            cg.addLine(to: CGPoint(x: center.x + 6, y: center.y))
            cg.addLine(to: CGPoint(x: center.x, y: center.y + 6))
            cg.addLine(to: CGPoint(x: center.x - 6, y: center.y))
            cg.closePath()
            cg.setFillColor(NSColor(WorkspaceColors.history).cgColor)
            cg.setStrokeColor(tint(row.color))
            cg.drawPath(using: .fillStroke)
        } else {
            cg.setFillColor(tint(row.color))
            let marker = dot.insetBy(dx: -5, dy: -5)
            cg.fillEllipse(in: marker)
            if let initials {
                let size = initials.size()
                initials.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            }
        }
        if head {
            cg.setStrokeColor(tint(row.color))
            cg.setLineWidth(1)
            cg.strokeEllipse(in: dot.insetBy(dx: -7, dy: -7))
        }
    }
}

private struct WorkingChangeCounts {
    enum Kind: String, CaseIterable {
        case modified, added, deleted, renamed, conflicted

        var symbol: String {
            switch self {
            case .modified: "pencil"
            case .added: "plus"
            case .deleted: "minus"
            case .renamed: "arrow.right"
            case .conflicted: "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .modified: .orange
            case .added: .green
            case .deleted, .conflicted: .red
            case .renamed: .cyan
            }
        }
    }

    var values: [Kind: Int] = [:]

    init(_ changes: [FileChange]) {
        for change in changes {
            let kind: Kind
            switch (change.staged, change.workingTree) {
            case (.conflict, _), (_, .conflict): kind = .conflicted
            case (_, .deleted), (.deleted, _): kind = .deleted
            case (.added, _), (.copied, _), (_, .untracked), (_, .added), (_, .copied): kind = .added
            case (.renamed, _), (_, .renamed): kind = .renamed
            default: kind = .modified
            }
            values[kind, default: 0] += 1
        }
    }
}

private struct WorkingTreeRow: View {
    let counts: WorkingChangeCounts
    var columns: HistoryColumns
    let hasParent: Bool

    var body: some View {
        let c = columns
        HStack(spacing: 0) {
            Color.clear.frame(width: c.refs)
            Canvas { context, size in
                let center = CGPoint(x: 12, y: size.height / 2)
                let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [1.5, 3])
                if hasParent {
                    var stem = Path()
                    stem.move(to: CGPoint(x: center.x, y: center.y + 7))
                    stem.addLine(to: CGPoint(x: center.x, y: size.height))
                    context.stroke(stem, with: .color(.teal), style: stroke)
                }
                let ring = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
                context.stroke(Path(ellipseIn: ring), with: .color(.teal), style: stroke)
            }
            .frame(width: c.graph)
            Text("// WIP")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 5)
            ForEach(WorkingChangeCounts.Kind.allCases, id: \.self) { kind in
                if let count = counts.values[kind] {
                    HStack(spacing: 3) {
                        Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                        Text(count, format: .number)
                    }
                    .fixedSize()
                    .help("\(count) \(kind.rawValue)")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.teal.opacity(0.07))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WIP, uncommitted changes")
        .accessibilityValue(WorkingChangeCounts.Kind.allCases.compactMap { kind in
            counts.values[kind].map { "\($0) \(kind.rawValue)" }
        }.joined(separator: ", "))
    }
}
