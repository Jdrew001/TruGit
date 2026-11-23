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

    static func folderKey(_ path: String, kind: RepositoryReference.Kind) -> String {
        (kind == .remote ? "remote-branch-folder/" : "branch-folder/") + path
    }

    static func inheritRemoteExpansion(in preferences: [String: Bool], badges: [GraphReferenceBadge]) -> [String: Bool] {
        let migrationKey = "split-reference-sections"
        guard preferences[migrationKey] != true else { return preferences }

        var updated = preferences
        for badge in badges {
            let parts = badge.name.split(separator: "/")
            let remoteDepth = badge.reference.remoteTarget?.remote.split(separator: "/").count ?? 1
            guard parts.count > remoteDepth + 1 else { continue }
            for depth in (remoteDepth + 1)..<parts.count {
                let group = parts.prefix(depth)
                let key = folderKey(group.joined(separator: "/"), kind: .remote)
                let original = folderKey(group.dropFirst(remoteDepth).joined(separator: "/"), kind: .local)
                if updated[key] == nil { updated[key] = preferences[original] }
            }
        }
        updated[migrationKey] = true
        return updated
    }

    static func visibleRows(_ badges: [GraphReferenceBadge], currentBranch: String?,
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

    private static func appendRows(_ branches: [Path], parent: String, depth: Int, currentBranch: String?,
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
                                       containsCurrentBranch: currentBranch?.hasPrefix(path + "/") == true)))
            if isExpanded(path) {
                appendRows(children.map(\.next), parent: path + "/", depth: depth + 1,
                           currentBranch: currentBranch, isExpanded: isExpanded, to: &rows)
            }
        }
    }
}
