import SwiftUI

enum HistorySelection: Hashable {
    case workInProgress
    case stash(String)
    case commit(String)
    case commits([String])

    static func selectedCommits(_ ids: [String]) -> Self? {
        guard let first = ids.first else { return nil }
        return ids.count == 1 ? .commit(first) : .commits(ids)
    }
}

struct BranchColors: Sendable {
    private(set) var byReference: [String: Int] = [:]
    private(set) var byTip: [String: Int] = [:]

    private let currentBranchIndex: Int?
    var currentBranchColor: Color { currentBranchIndex.map { Color(nsColor: Self.native($0)) } ?? .secondary }

    private static let currentBranchAccent = 4

    // Sidebar labels and graph strokes use the same hue families at different intensities.
    private static let palette = colors([
        0x27E5FF, 0xB687FF, 0x24E4BE, 0xFF70CF,
        0x60AAFF, 0xE696FF, 0x8AF9FA, 0x9399FF
    ])
    private static let graphPalette = colors([
        0x18B1D1, 0xA655F4, 0x18B69A, 0xE745AE,
        0x3387FF, 0xC56FEA, 0x61C6D7, 0x7588F2
    ])

    private static func colors(_ values: [Int]) -> [NSColor] {
        values.map { rgb in
            NSColor(srgbRed: CGFloat(rgb >> 16) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    init(references: [RepositoryReference], currentBranch: String) {
        let branches = references.filter { $0.kind != .tag }.sorted { $0.id < $1.id }
        let currentID = RepositoryReference.Kind.local.prefix + currentBranch
        var used: Set<Int> = branches.contains(where: { $0.id == currentID }) ? [Self.currentBranchAccent] : []
        for branch in branches {
            let index = branch.id == currentID ? Self.currentBranchAccent : Self.availableColor(for: branch.id, used: used)
            used.insert(index)
            byReference[branch.id] = index
            if byTip[branch.commitID] == nil || branch.id == currentID {
                byTip[branch.commitID] = index
            }
        }
        currentBranchIndex = byReference[currentID]
    }

    private static func availableColor(for ref: String, used: Set<Int>) -> Int {
        guard used.count < palette.count else { return used.count }
        let hash = ref.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        var index = Int(hash) % palette.count
        while used.contains(index) { index = (index + 1) % palette.count }
        return index
    }

    static func graph(_ index: Int) -> NSColor {
        if index < graphPalette.count { return graphPalette[index] }
        let color = native(index)
        return color.blended(withFraction: 0.20, of: .black) ?? color
    }

    func graphColor(for reference: RepositoryReference) -> Color {
        byReference[reference.id].map { Color(nsColor: Self.graph($0)) } ?? .orange
    }

    static func native(_ index: Int) -> NSColor {
        if index < palette.count { return palette[index] }
        // Additional refs use intermediate tones within the same teal-to-pink range.
        let offset = CGFloat(index - palette.count + 1)
        let degrees = 168 + 153 * (offset * 0.61803398875).truncatingRemainder(dividingBy: 1)
        let saturation = 0.46 + 0.28 * (offset * 0.41421356237).truncatingRemainder(dividingBy: 1)
        // Blue and violet need more light for small branch labels on the sidebar.
        let blueWeight = max(0, 1 - abs(degrees - 247) / 60)
        return NSColor(hue: degrees / 360, saturation: saturation * (1 - 0.49 * blueWeight), brightness: 1, alpha: 1)
    }

    func color(for reference: RepositoryReference) -> Color {
        byReference[reference.id].map { Color(nsColor: Self.native($0)) } ?? .orange
    }
}

struct CommitGraph: Sendable {
    struct Lane: Equatable, Sendable {
        let target: String
        let color: Int
        var isWorkingTree = false
    }

    struct Segment: Sendable {
        let fromLane: Int
        let toLane: Int
        let fromHeight: Double
        let toHeight: Double
        let color: Int
        var isWorkingTree = false
    }

    struct Row: Identifiable, Sendable {
        let commit: GitCommit
        let column: Int
        let color: Int
        let segments: [Segment]
        var id: String { commit.id }
    }

    let id = UUID()
    let indexByID: [String: Int]
    let rows: [Row]
    let laneCount: Int

    let hasWorkingTree: Bool

    init(commits: [GitCommit], hasWorkingTree: Bool = false, head: String? = nil, tipColors: [String: Int] = [:]) {
        self.hasWorkingTree = hasWorkingTree
        var layout = GraphLayout(workingTreeParent: hasWorkingTree ? head : nil, tipColors: tipColors)
        rows = commits.map { layout.add($0) }
        indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        laneCount = layout.maximumLanes
    }
}

private struct GraphLayout {
    // Empty slots are reusable. Removing a lane must never move the lanes beside it.
    private var lanes: [CommitGraph.Lane?] = []
    private var nextColor = 0
    private(set) var maximumLanes = 1

    let tipColors: [String: Int]

    init(workingTreeParent: String?, tipColors: [String: Int]) {
        self.tipColors = tipColors
        if let head = workingTreeParent {
            lanes = [.init(target: head, color: tipColors[head] ?? 0, isWorkingTree: true)]
            nextColor = 1
        }
    }

    mutating func add(_ commit: GitCommit) -> CommitGraph.Row {
        let existing = lanes.firstIndex { $0?.target == commit.id }
        let column = existing ?? availableColumn(near: 0)
        let incomingColor = existing.flatMap { lanes[$0]?.color }
        let color = tipColors[commit.id] ?? incomingColor ?? allocateColor()

        var segments = lanes.enumerated().compactMap { index, lane -> CommitGraph.Segment? in
            guard let lane else { return nil }
            return .init(fromLane: index, toLane: index, fromHeight: 0, toHeight: lane.target == commit.id ? 0.5 : 1,
                         color: lane.color, isWorkingTree: lane.isWorkingTree)
        }
        if let existing { lanes[existing] = nil }

        for (index, parent) in commit.parents.enumerated() {
            let destination = follow(parent, from: column, continuing: index == 0, color: color)
            segments.append(.init(fromLane: column, toLane: destination.column, fromHeight: 0.5, toHeight: 1,
                                  color: destination.color))
        }

        maximumLanes = max(maximumLanes, column + 1, lanes.count)
        return .init(commit: commit, column: column, color: color, segments: segments)
    }

    private mutating func follow(_ parent: String, from column: Int, continuing: Bool, color: Int) -> (column: Int, color: Int) {
        if let existing = lanes.firstIndex(where: { $0?.target == parent }), let lane = lanes[existing] {
            return (existing, lane.color)
        }
        let position = availableColumn(near: continuing ? column : column + 1)
        let parentColor = continuing ? color : (tipColors[parent] ?? allocateColor(avoiding: color))
        let lane = CommitGraph.Lane(target: parent, color: parentColor)
        if position == lanes.count { lanes.append(lane) }
        else { lanes[position] = lane }
        return (position, parentColor)
    }

    private func availableColumn(near preferred: Int) -> Int {
        lanes.indices.lazy.filter { lanes[$0] == nil }.min {
            (abs($0 - preferred), -$0) < (abs($1 - preferred), -$1)
        } ?? lanes.count
    }

    private mutating func allocateColor(avoiding adjacent: Int? = nil) -> Int {
        let used = Set(lanes.compactMap { $0?.color })
        while used.contains(nextColor) || nextColor == adjacent { nextColor += 1 }
        defer { nextColor += 1 }
        return nextColor
    }
}

