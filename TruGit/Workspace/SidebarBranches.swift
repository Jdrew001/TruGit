import Foundation

enum SidebarBranchRow: Identifiable {
    struct Folder {
        let name: String
        let path: String
        let count: Int
        let depth: Int
        let containsCurrentBranch: Bool
    }

    case branch(GraphReferenceBadge, name: String, depth: Int)
    case folder(Folder)

    var id: String {
        switch self {
        case .branch(let badge, _, _): badge.id
        case .folder(let folder): "branch-folder/" + folder.path
        }
    }

    static func visibleRows(_ badges: [GraphReferenceBadge], currentBranch: String,
                            isExpanded: (String) -> Bool) -> [Self] {
        let branches = badges.map { Path(badge: $0, components: $0.name.split(separator: "/")[...]) }
        var rows: [Self] = []
        appendRows(branches, parent: "", depth: 0, currentBranch: currentBranch, isExpanded: isExpanded, to: &rows)
        return rows
    }

    private struct Path {
        let badge: GraphReferenceBadge
        let components: ArraySlice<Substring>

        var name: Substring { components.first ?? "" }
        var next: Self { Self(badge: badge, components: components.dropFirst()) }
    }

    private static func appendRows(_ branches: [Path], parent: String, depth: Int, currentBranch: String,
                                   isExpanded: (String) -> Bool, to rows: inout [Self]) {
        let folders = Dictionary(grouping: branches.filter { $0.components.count > 1 }, by: \.name)
        var shownFolders = Set<Substring>()

        // The input already puts the checked-out branch first and sorts other branches by name.
        for branch in branches {
            guard branch.components.count > 1 else {
                rows.append(.branch(branch.badge, name: String(branch.name), depth: depth))
                continue
            }
            guard shownFolders.insert(branch.name).inserted, let children = folders[branch.name] else { continue }
            let name = String(branch.name)
            let path = parent + name
            rows.append(.folder(Folder(name: name, path: path, count: children.count, depth: depth,
                                       containsCurrentBranch: currentBranch.hasPrefix(path + "/"))))
            if isExpanded(path) {
                appendRows(children.map(\.next), parent: path + "/", depth: depth + 1,
                           currentBranch: currentBranch, isExpanded: isExpanded, to: &rows)
            }
        }
    }
}
