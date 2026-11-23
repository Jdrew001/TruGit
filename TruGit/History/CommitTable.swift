import AppKit
import SwiftUI

private enum HistoryGraphStroke {
    static let laneInset: CGFloat = 14
    static let trailingLaneInset: CGFloat = 18
    static let laneSpacing: CGFloat = 25
    static let width: CGFloat = 2
    static let dash: [CGFloat] = [2, 3]
    static let workingTree = NSColor.systemTeal.withAlphaComponent(0.86)

    static func visibleMarkerX(_ laneX: CGFloat, in graph: CGRect) -> CGFloat {
        min(graph.maxX - trailingLaneInset, max(graph.minX + laneInset, laneX))
    }

    static func accentRect(in graph: CGRect) -> CGRect {
        CGRect(x: graph.maxX - 4, y: graph.minY + 3, width: 2, height: max(0, graph.height - 6))
    }

    static func addConnection(from start: CGPoint, to end: CGPoint, joining: Bool, in cg: CGContext) {
        cg.move(to: start)
        guard start.x != end.x else {
            cg.addLine(to: end)
            return
        }
        let radius = min(8, abs(end.x - start.x) * 0.65, (end.y - start.y) * 0.65)
        if joining {
            // Meet the destination's continuous stroke just above the row boundary.
            let join = CGPoint(x: end.x, y: end.y - 2)
            cg.addArc(tangent1End: CGPoint(x: start.x, y: join.y), tangent2End: join, radius: radius)
            cg.addLine(to: join)
        } else {
            cg.addArc(tangent1End: CGPoint(x: end.x, y: start.y), tangent2End: end, radius: radius)
            cg.addLine(to: end)
        }
    }
}

enum HistoryColumn: CaseIterable {
    case refs, graph, message, author, date

    var title: String {
        switch self {
        case .refs: "Branch / Tag"
        case .graph: "Graph"
        case .message: "Commit message"
        case .author: "Author"
        case .date: "Commit date / time"
        }
    }

    var limits: ClosedRange<CGFloat> {
        switch self {
        case .refs: 54...680
        case .graph: 54...680
        case .message: 120...1200
        case .author: 68...420
        case .date: 92...420
        }
    }

    func width(_ proposed: CGFloat) -> CGFloat {
        min(limits.upperBound, max(limits.lowerBound, proposed))
    }
}

struct HistoryColumns: Equatable {
    private let widths: [HistoryColumn: CGFloat]
    private let lanesWidth: CGFloat
    let totalWidth: CGFloat

    init(width: CGFloat, lanes: Int, preferred: [HistoryColumn: CGFloat] = [:]) {
        let lanesWidth = HistoryGraphStroke.laneInset + HistoryGraphStroke.trailingLaneInset
            + CGFloat(max(0, lanes - 1)) * HistoryGraphStroke.laneSpacing
        self.lanesWidth = lanesWidth
        let refs = min(216, max(72, width * 0.24))
        let graph = HistoryColumn.graph.width(min(width * 0.25, max(width * 0.12, min(254, lanesWidth))))
        let author = HistoryColumn.author.width(min(192, width * 0.16))
        let date = HistoryColumn.date.width(min(164, width * 0.17))
        let automatic: [HistoryColumn: CGFloat] = [
            .refs: refs, .graph: graph, .message: min(450, width - refs - graph - author - date),
            .author: author, .date: date
        ]
        let widths: [HistoryColumn: CGFloat] = HistoryColumn.allCases.reduce(into: [:]) { widths, column in
            let savedWidth = preferred[column] ?? 0
            widths[column] = column.width(savedWidth > 0 ? savedWidth : automatic[column, default: 0])
        }
        self.widths = widths
        totalWidth = HistoryColumn.allCases.reduce(0) { $0 + widths[$1, default: 0] }
    }

    subscript(_ column: HistoryColumn) -> CGFloat { widths[column] ?? column.limits.lowerBound }
    var refs: CGFloat { self[.refs] }
    var graph: CGFloat { self[.graph] }
    var message: CGFloat { self[.message] }
    var author: CGFloat { self[.author] }
    var date: CGFloat { self[.date] }
    var graphScrollLimit: CGFloat { max(0, lanesWidth - graph) }

    func clampGraphOffset(_ offset: CGFloat) -> CGFloat { min(graphScrollLimit, max(0, offset)) }
}

struct HistoryColumnHeader: View {
    let columns: HistoryColumns
    let resize: (HistoryColumn, CGFloat, Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HistoryColumn.allCases, id: \.self) { column in
                heading(column)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24).background(WorkspaceColors.sidebar)
    }

    private func heading(_ column: HistoryColumn) -> some View {
        Text(column.title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .lineLimit(1).foregroundStyle(.secondary).padding(.leading, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.trailing, 8)
            .frame(width: columns[column])
            .clipped()
            .overlay(alignment: .trailing) {
                WidthDivider(label: column.title + " column width", width: columns[column], limits: column.limits) {
                    resize(column, $0, $1)
                }.frame(width: 8)
            }
    }
}

struct HistoryGraphFooter: View {
    let columns: HistoryColumns
    @Binding var graphOffset: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.refs)
            HistoryGraphScroller(viewportWidth: columns.graph, scrollLimit: columns.graphScrollLimit, offset: $graphOffset)
                .padding(.horizontal, 4)
                .frame(width: columns.graph)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 12)
        .background(WorkspaceColors.history)
    }
}

private struct HistoryGraphScroller: NSViewRepresentable {
    let viewportWidth: CGFloat
    let scrollLimit: CGFloat
    @Binding var offset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScroller {
        let scroller = GraphScrollerControl(frame: NSRect(x: 0, y: 0, width: 100, height: 12))
        scroller.thumbThickness = 2
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.target = context.coordinator
        scroller.action = #selector(Coordinator.scrolled(_:))
        scroller.setAccessibilityLabel("Scroll graph horizontally")
        scroller.toolTip = "Scroll graph horizontally"
        return scroller
    }

    func updateNSView(_ scroller: NSScroller, context: Context) {
        context.coordinator.scroll = { part, fraction in
            let proposed: CGFloat
            switch part {
            case .decrementLine: proposed = offset - HistoryGraphStroke.laneSpacing
            case .incrementLine: proposed = offset + HistoryGraphStroke.laneSpacing
            case .decrementPage: proposed = offset - viewportWidth
            case .incrementPage: proposed = offset + viewportWidth
            default: proposed = fraction * scrollLimit
            }
            offset = min(scrollLimit, max(0, proposed))
        }
        scroller.knobProportion = viewportWidth / (viewportWidth + scrollLimit)
        scroller.doubleValue = Double(min(scrollLimit, max(0, offset)) / scrollLimit)
    }

    @MainActor final class Coordinator: NSObject {
        var scroll: ((NSScroller.Part, CGFloat) -> Void)?

        @objc func scrolled(_ scroller: NSScroller) {
            scroll?(scroller.hitPart, CGFloat(scroller.doubleValue))
        }
    }

    private final class GraphScrollerControl: WorkspaceScroller {
        override func accessibilityFrame() -> NSRect {
            guard let window else { return super.accessibilityFrame() }
            // This standalone scrollbar controls only the graph within the enclosing scroll view.
            return window.convertToScreen(convert(bounds, to: nil))
        }
    }
}

struct CommitTable<Badges: View>: NSViewRepresentable {
    @Environment(\.appZoom) private var zoom
    let graph: CommitGraph
    let columns: HistoryColumns
    let viewportWidth: CGFloat
    @Binding var graphOffset: CGFloat
    let historyScrolled: (CGFloat) -> Void
    let snapshot: RepositorySnapshot
    @Binding var selection: HistorySelection?
    let jump: CommitJump?
    let deletionChoices: (RepositoryReference) -> [BranchDeletion]
    let requestDelete: (BranchDeletion) -> Void
    let checkout: (RepositoryReference) -> Void
    let openActions: (RevisionPoint, RevisionOperation?) -> Void
    let openBatch: (CommitBatch) -> Void
    let createTag: (RevisionPoint) -> Void
    let canAct: Bool
    let onDrop: (BranchDrag, RevisionPoint) -> Bool
    let expandedBadges: ([GraphReferenceBadge]) -> AnyView
    @ViewBuilder let badges: ([GraphReferenceBadge], Int) -> Badges

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.branchMenu = { [weak coordinator = context.coordinator] index, ref in coordinator?.branchMenu(at: index, clicked: ref) }
        table.hoverReferences = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let point = coordinator.point(at: row), let badges = coordinator.badgesByCommit[point.oid] else { return nil }
            return (point.oid, badges, { coordinator.parent.expandedBadges(badges) })
        }
        table.root = snapshot.repository.root
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([BranchDrag.commitType, BranchDrag.referenceType])
        table.allowsMultipleSelection = true
        table.style = .plain
        table.headerView = nil
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.rowHeight = 29
        table.intercellSpacing = .zero
        table.backgroundColor = NSColor(WorkspaceColors.history)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Commit history")
        let column = NSTableColumn(identifier: .init("commit"))
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        column.resizingMask = []
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = HistoryCommitScrollView()
        scroll.scrollGraph = { [weak coordinator = context.coordinator, weak table] event in
            guard let table else { return false }
            let point = table.convert(event.locationInWindow, from: nil)
            return coordinator?.scrollGraph(with: event, at: point.x) ?? false
        }
        scroll.didScrollHorizontally = { [weak coordinator = context.coordinator] position in
            coordinator?.parent.historyScrolled(position)
        }
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.useWorkspaceScrollers()
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let layoutChanged = coordinator.parent.columns != columns
        let actionsChanged = coordinator.parent.canAct != canAct
        let offset = columns.clampGraphOffset(graphOffset)
        let offsetChanged = coordinator.displayedGraphOffset != offset
        updateColumnLayout(in: scroll, table: table)
        if actionsChanged || layoutChanged || offsetChanged || coordinator.graphID != graph.id || coordinator.snapshotID != snapshot.id {
            (table as? HistoryTableView)?.referencePreview.dismiss()
        }
        coordinator.parent = self
        coordinator.displayedGraphOffset = offset
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
            coordinator.badgesByCommit.removeAll(keepingCapacity: true)
            for badge in snapshot.referenceBadges {
                // Keep a single label even when only a remote tip is on the loaded page.
                if let anchor = badge.references.first(where: { graph.indexByID[$0.commitID] != nil }) {
                    coordinator.badgesByCommit[anchor.commitID, default: []].append(badge)
                }
            }
            table.reloadData()
        } else if actionsChanged {
            // Hosted badges capture their checkout and menu actions when their row is configured.
            table.reloadData()
        } else if layoutChanged || offsetChanged {
            table.enumerateAvailableRowViews { rowView, _ in
                let cell = rowView.view(atColumn: 0)
                if let cell = cell as? CommitCell {
                    if layoutChanged { cell.columns = columns }
                    cell.graphOffset = offset
                }
                if let cell = cell as? NSHostingView<WorkingTreeRow> {
                    var content = cell.rootView
                    content.columns = columns
                    content.graphOffset = offset
                    cell.rootView = content
                }
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

    private func updateColumnLayout(in scroll: NSScrollView, table: NSTableView) {
        let width = max(viewportWidth, columns.totalWidth)
        if table.tableColumns[0].width != width {
            table.tableColumns[0].width = width
        }
        if table.frame.width != width {
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
        }
        let hasOverflow = columns.totalWidth - viewportWidth > 0.5
        if scroll.hasHorizontalScroller != hasOverflow {
            scroll.hasHorizontalScroller = hasOverflow
            scroll.useWorkspaceScrollers()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: CommitTable
        var graphID: UUID?
        var snapshotID: UUID?
        var displayedGraphOffset: CGFloat = 0
        fileprivate var counts = WorkingChangeCounts([])
        var refs: [String: [RepositoryReference]] = [:]
        var badgesByCommit: [String: [GraphReferenceBadge]] = [:]
        var jump: CommitJump?
        var updating = false

        init(_ parent: CommitTable) { self.parent = parent }

        func scrollGraph(with event: NSEvent, at x: CGFloat) -> Bool {
            let columns = parent.columns
            guard columns.graphScrollLimit > 0, x >= columns.refs, x < columns.refs + columns.graph else { return false }
            let horizontal = event.scrollingDeltaX
            let vertical = event.scrollingDeltaY
            let delta: CGFloat
            if abs(horizontal) > abs(vertical) {
                delta = horizontal
            } else if horizontal == 0, vertical != 0, event.modifierFlags.contains(.shift) {
                delta = vertical
            } else {
                return false
            }
            let movement = event.hasPreciseScrollingDeltas ? delta / parent.zoom.wrappedValue.scale : delta * 22
            parent.graphOffset = columns.clampGraphOffset(parent.graphOffset - movement)
            return true
        }

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
                                             graphOffset: displayedGraphOffset,
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
            let badges = badgesByCommit[item.id] ?? []
            cell.graphOffset = displayedGraphOffset
            cell.configure(item, columns: parent.columns, head: item.id == parent.snapshot.repository.headID,
                           badges: badges.isEmpty ? nil : AnyView(parent.badges(badges, item.color).id(item.id)))
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

        private func drop(at info: NSDraggingInfo, table: NSTableView) -> (drag: BranchDrag, target: RevisionPoint, row: Int)? {
            let location = table.convert(info.draggingLocation, from: nil)
            let row = table.row(at: location)
            guard parent.canAct, let drag = BranchDrag.local(from: info, in: parent.snapshot.repository.root) else { return nil }
            let target: RevisionPoint
            if let ref = BranchMouseView.reference(at: info.draggingLocation, window: table.window) {
                target = RevisionPoint(ref)
            } else if let point = point(at: row) {
                let references = refs[point.oid] ?? []
                if drag.commits.isEmpty {
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitCell
                    let overLabelOrNode = cell.flatMap { $0.hoverAnchor(at: $0.convert(location, from: table)) } != nil
                    target = overLabelOrNode ? references.first.map(RevisionPoint.init) ?? point : point
                } else {
                    guard let branch = references.first(where: { $0.kind == .local }) else { return nil }
                    target = RevisionPoint(branch)
                }
            } else { return nil }
            return drag.canDrop(on: target) ? (drag, target, row) : nil
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let drop = drop(at: info, table: tableView) else { return [] }
            tableView.setDropRow(drop.row, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let drop = drop(at: info, table: tableView) else { return false }
            return parent.onDrop(drop.drag, drop.target)
        }

        func branchMenu(at row: Int, clicked: RepositoryReference?) -> NSMenu? {
            guard let revision = clicked.map(RevisionPoint.init) ?? point(at: row) else { return nil }
            let point = RevisionPoint(commit: revision.oid)
            let branches = clicked.map { [$0] } ?? refs[point.oid] ?? []
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
            let current = parent.snapshot.checkedOutBranch
            let destination = current ?? locals.first
            func addBranchShortcuts(_ ref: RepositoryReference) {
                let branch = RevisionPoint(ref)
                if let title = parent.snapshot.switchTitle(for: ref) {
                    let item = NSMenuItem(title: title, action: #selector(switchBranch(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ref
                    item.isEnabled = parent.canAct && parent.snapshot.checkoutBranch(for: ref).map(parent.snapshot.isCheckedOut) != true
                    menu.addItem(item)
                }
                if parent.snapshot.canMergeBranches(from: ref) {
                    addAction("Merge “" + ref.name + "” into…", branch, .merge, to: menu)
                }
            }
            if let clicked, clicked.kind != .tag {
                addBranchShortcuts(clicked)
                if !menu.items.isEmpty { menu.addItem(.separator()) }
            }
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
                if clicked == nil { addBranchShortcuts(ref) }
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

        @objc private func switchBranch(_ item: NSMenuItem) {
            guard let ref = item.representedObject as? RepositoryReference else { return }
            parent.checkout(ref)
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

private final class HistoryCommitScrollView: NSScrollView {
    var scrollGraph: ((NSEvent) -> Bool)?
    var didScrollHorizontally: ((CGFloat) -> Void)?
    private var reportedOffset: CGFloat = 0

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard clipView === contentView, clipView.bounds.minX != reportedOffset else { return }
        reportedOffset = clipView.bounds.minX
        // Native layout can correct the scroll position during a SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            didScrollHorizontally?(reportedOffset)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollGraph?(event) != true { super.scrollWheel(with: event) }
    }
}

final class HistoryTableView: NSTableView {
    private static let tables = NSHashTable<HistoryTableView>.weakObjects()
    var root: URL?
    var draggedCommits: BranchDrag?

    let referencePreview = GraphReferencePreview()
    var hoverReferences: ((Int) -> (String, [GraphReferenceBadge], () -> AnyView)?)?
    private var departingCommit: String?
    private var mouseMonitor: Any?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if NSEvent.pressedMouseButtons == 0, event.trackingArea === hoverArea, let window,
           !referencePreview.contains(event.locationInWindow, in: window) {
            referencePreview.dismiss()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: enclosingScrollView?.contentView)
        referencePreview.dismiss()
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func dismissPreview(_ notification: Notification) { referencePreview.dismiss() }

    private func updatePreview(for event: NSEvent) {
        if event.type == .keyDown { referencePreview.dismiss(); return }
        if referencePreview.contains(event.locationInWindow, in: event.window) {
            if event.type == .mouseMoved {
                referencePreview.updateHighlight(at: event.locationInWindow, in: event.window)
            } else if event.type == .scrollWheel {
                if referencePreview.scrolls {
                    // Resolve the row after the scroll view processes this event.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.referencePreview.updateHighlight(at: window.mouseLocationOutsideOfEventStream, in: window)
                    }
                } else { referencePreview.dismiss() }
            }
            return
        }
        guard event.type == .mouseMoved, let window, event.window === window, window.isKeyWindow,
              NSEvent.pressedMouseButtons == 0, !isHiddenOrHasHiddenAncestor else { referencePreview.dismiss(); return }
        showReferences(at: event.locationInWindow)
    }

    private func showReferences(at windowPoint: NSPoint, immediately: Bool = false) {
        let location = convert(windowPoint, from: nil)
        let index = row(at: location)
        guard visibleRect.contains(location), index >= 0, let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? CommitCell,
              let anchor = cell.hoverAnchor(at: cell.convert(location, from: self)),
              let (commitID, badges, content) = hoverReferences?(index) else {
            departingCommit = nil
            referencePreview.dismiss()
            return
        }
        // Let the pointer leave the source badge before opening that stack again.
        if let departingCommit, departingCommit == commitID { return }
        departingCommit = nil
        // Expanding a long label here would move the remote icon out from under the pointer.
        if let hit = BranchMouseView.reference(at: windowPoint, window: window), hit.kind == .remote,
           badges.contains(where: { $0.reference.kind == .local && $0.remotes.contains(hit) }) {
            referencePreview.dismiss()
            return
        }
        referencePreview.hover(badges, at: commitID, anchor: convert(anchor, from: cell), in: self,
                               immediately: immediately, content: content)
        referencePreview.updateHighlight(at: windowPoint, in: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { Self.tables.remove(self); return }
        Self.tables.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissPreview(_:)), name: NSWindow.didResignKeyNotification, object: window)
        if let clip = enclosingScrollView?.contentView {
            NotificationCenter.default.addObserver(self, selector: #selector(dismissPreview(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.updatePreview(for: event)
            return event
        }
    }

    static func updateDragPreview(in window: NSWindow?, repository: URL, at screenPoint: NSPoint?, leaving source: String? = nil) {
        guard let window else { return }
        for table in tables.allObjects where table.window === window && table.root == repository && !table.isHiddenOrHasHiddenAncestor {
            guard let screenPoint else {
                table.departingCommit = source
                table.referencePreview.dismiss()
                continue
            }
            let location = window.convertPoint(fromScreen: screenPoint)
            if table.referencePreview.contains(location, in: window) {
                table.referencePreview.updateHighlight(at: location, in: window)
            } else {
                table.showReferences(at: location, immediately: true)
            }
        }
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
    private var host: NSHostingView<AnyView>?
    private var row: CommitGraph.Row?
    private var head = false
    private var initials = ""
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

    func configure(_ row: CommitGraph.Row, columns: HistoryColumns, head: Bool, badges: AnyView?) {
        self.columns = columns
        self.row = row
        self.head = head
        initials = row.commit.authorInitials
        if row.commit.parents.count > 1 {
            let label = NSMutableAttributedString(string: "⑂ Merge  ", attributes: [.foregroundColor: NSColor.systemMint])
            label.append(NSAttributedString(string: row.commit.mergeRoute ?? row.commit.subject))
            subject.attributedStringValue = label
        } else {
            subject.stringValue = row.commit.subject
        }
        author.stringValue = row.commit.author
        date.stringValue = row.commit.date?.formatted(date: .numeric, time: .shortened) ?? ""
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

    var columns = HistoryColumns(width: 0, lanes: 1) {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    var graphOffset: CGFloat = 0 {
        didSet { if oldValue != graphOffset { needsDisplay = true } }
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
    }

    private var graphBounds: CGRect {
        CGRect(x: columns.refs, y: 0, width: columns.graph, height: bounds.height)
    }

    private func graphX(lane: Int) -> CGFloat {
        columns.refs + HistoryGraphStroke.laneInset + CGFloat(lane) * HistoryGraphStroke.laneSpacing - graphOffset
    }

    func hoverAnchor(at location: NSPoint) -> NSRect? {
        guard let host, let row else { return nil }
        if host.frame.contains(location) { return host.frame }
        let markerX = HistoryGraphStroke.visibleMarkerX(graphX(lane: row.column), in: graphBounds)
        let node = NSRect(x: markerX - 11, y: bounds.midY - 11, width: 22, height: 22)
        return node.contains(location) ? host.frame : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row, let cg = NSGraphicsContext.current?.cgContext else { return }
        let laneX = graphX(lane: row.column)
        let markerX = HistoryGraphStroke.visibleMarkerX(laneX, in: graphBounds)
        let marker = CGPoint(x: markerX, y: bounds.midY)
        let pinned = markerX != laneX
        let tint = BranchColors.graph(row.color)

        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setShouldAntialias(true)
        cg.setLineJoin(.round)
        cg.setLineWidth(HistoryGraphStroke.width)
        drawBranchLeader(tint, to: marker, in: cg)
        let accent = HistoryGraphStroke.accentRect(in: graphBounds)
        drawRowTint(tint, markerX: markerX, pinned: pinned, endingAt: accent, in: cg)
        cg.clip(to: CGRect(x: graphBounds.minX, y: 0, width: accent.maxX - graphBounds.minX, height: bounds.height))
        drawLanes(of: row, in: cg)
        drawNode(at: marker, tint: tint, isMerge: row.commit.parents.count > 1, pinned: pinned, in: cg)
        cg.setFillColor(tint.cgColor)
        cg.fill(accent)
    }

    private func drawRowTint(_ tint: NSColor, markerX: CGFloat, pinned: Bool, endingAt accent: CGRect, in cg: CGContext) {
        let start = max(graphBounds.minX, markerX - (pinned ? HistoryGraphStroke.laneInset : 0))
        cg.setFillColor(tint.withAlphaComponent(0.10).cgColor)
        cg.fill(CGRect(x: start, y: accent.minY, width: accent.maxX - start, height: accent.height))
    }

    private func drawBranchLeader(_ tint: NSColor, to center: CGPoint, in cg: CGContext) {
        guard let host else { return }
        cg.setFillColor(tint.withAlphaComponent(0.32).cgColor)
        cg.fill(CGRect(x: host.frame.maxX, y: center.y - 0.5, width: max(0, center.x - host.frame.maxX), height: 1))
    }

    private func drawLanes(of row: CommitGraph.Row, in cg: CGContext) {
        let turns = row.segments.filter { $0.fromLane != $0.toLane }.sorted {
            abs($0.toLane - $0.fromLane) > abs($1.toLane - $1.fromLane)
        }
        if !turns.isEmpty {
            let throughLanes = Set(row.segments.lazy.filter { $0.fromHeight == 0 && $0.toHeight == 1 }.map(\.fromLane))
            for turn in turns {
                let joining = throughLanes.contains(turn.toLane)
                drawSegment(turn, colorIndex: joining ? row.color : turn.color, joining: joining, in: cg)
            }
        }
        // Paint continuous lanes over crossings so they still read as uninterrupted tracks.
        for segment in row.segments where segment.fromLane == segment.toLane {
            drawSegment(segment, colorIndex: segment.color, joining: false, in: cg)
        }
    }

    private func drawSegment(_ segment: CommitGraph.Segment, colorIndex: Int, joining: Bool, in cg: CGContext) {
        let start = CGPoint(x: graphX(lane: segment.fromLane), y: bounds.height * segment.fromHeight)
        let end = CGPoint(x: graphX(lane: segment.toLane), y: bounds.height * segment.toHeight)
        let color = segment.isWorkingTree ? HistoryGraphStroke.workingTree
            : BranchColors.graph(colorIndex).withAlphaComponent(0.94)
        cg.setLineCap(segment.isWorkingTree ? .round : .butt)
        cg.setLineDash(phase: 0, lengths: segment.isWorkingTree ? HistoryGraphStroke.dash : [])
        cg.setStrokeColor(color.cgColor)
        HistoryGraphStroke.addConnection(from: start, to: end, joining: joining, in: cg)
        cg.strokePath()
    }

    private func drawNode(at center: CGPoint, tint: NSColor, isMerge: Bool, pinned: Bool, in cg: CGContext) {
        let showsInitials = !isMerge && !initials.isEmpty
        let radius: CGFloat = showsInitials ? 11 : (isMerge ? 5.5 : 4.5)
        let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let surface = NSColor(WorkspaceColors.history).cgColor
        cg.setLineDash(phase: 0, lengths: [])
        if head {
            let ring = dot.insetBy(dx: -2, dy: -2)
            cg.setFillColor(surface)
            cg.fillEllipse(in: ring)
            cg.setStrokeColor(tint.cgColor)
            cg.setLineWidth(1)
            cg.strokeEllipse(in: ring)
        }
        if isMerge {
            cg.move(to: CGPoint(x: center.x, y: center.y - radius))
            cg.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            cg.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            cg.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            cg.closePath()
            cg.setFillColor(tint.cgColor)
            cg.fillPath()
        } else {
            let fill = showsInitials ? tint.blended(withFraction: pinned ? 0.56 : 0.42, of: .black) ?? tint : tint
            cg.setFillColor(fill.cgColor)
            cg.fillEllipse(in: dot)
        }
        if showsInitials { drawInitials(at: center, radius: radius, pinned: pinned) }
    }

    private func drawInitials(at center: CGPoint, radius: CGFloat, pinned: Bool) {
        let label = initials as NSString
        let pointSize = min(10.5, radius)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pointSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(pinned ? 0.82 : 1)
        ]
        let availableWidth = radius * 2 - 3
        let labelWidth = label.size(withAttributes: attributes).width
        if labelWidth > availableWidth {
            attributes[.font] = NSFont.systemFont(ofSize: pointSize * availableWidth / labelWidth, weight: .bold)
        }
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
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
    var graphOffset: CGFloat
    let hasParent: Bool

    var body: some View {
        let c = columns
        HStack(spacing: 0) {
            Color.clear.frame(width: c.refs)
            Canvas { context, size in
                let graphBounds = CGRect(origin: .zero, size: size)
                let laneX = HistoryGraphStroke.laneInset - graphOffset
                let center = CGPoint(x: HistoryGraphStroke.visibleMarkerX(laneX, in: graphBounds), y: size.height / 2)
                let stroke = StrokeStyle(lineWidth: HistoryGraphStroke.width, lineCap: .round, dash: HistoryGraphStroke.dash)
                let color = Color(nsColor: HistoryGraphStroke.workingTree)
                if hasParent {
                    var stem = Path()
                    stem.move(to: CGPoint(x: laneX, y: center.y + 7))
                    stem.addLine(to: CGPoint(x: laneX, y: size.height))
                    context.stroke(stem, with: .color(color), style: stroke)
                }
                let ring = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
                context.stroke(Path(ellipseIn: ring), with: .color(color), style: stroke)
                context.fill(Path(HistoryGraphStroke.accentRect(in: graphBounds)), with: .color(color))
            }
            .frame(width: c.graph)
            .clipped()
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
