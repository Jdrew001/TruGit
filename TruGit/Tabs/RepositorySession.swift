import Foundation

struct RepositorySession {
    private static let key = "repositorySession.v1"
    var paths: [String]
    var selectedPath: String?
    var aliases: [String: String]

    var groups: [RepositoryTabGroup]

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key)
        paths = saved?["paths"] as? [String] ?? []
        selectedPath = saved?["selectedPath"] as? String
        aliases = saved?["aliases"] as? [String: String] ?? [:]
        groups = (saved?["groups"] as? Data).flatMap { try? PropertyListDecoder().decode([RepositoryTabGroup].self, from: $0) } ?? []
    }

    func save() {
        var values: [String: Any] = ["paths": paths, "aliases": aliases]
        values["selectedPath"] = selectedPath
        values["groups"] = try? PropertyListEncoder().encode(groups)
        UserDefaults.standard.set(values, forKey: Self.key)
    }
}

// These raw values are stored in existing repository sessions.
enum TabGroupColor: Int, CaseIterable {
    case cyan = 0, purple = 1, mint = 2, pink = 3, blue = 4, orange = 5
}

struct RepositoryTabGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var color: TabGroupColor { TabGroupColor(rawValue: colorIndex) ?? .cyan }
    var collapsed = false
    var members: Set<String>
}

enum TabDestination {
    case beside(String, after: Bool)
    case group(UUID)
    case end
}

enum GroupDestination {
    case beside(String, after: Bool)
    case end
}

enum TabOrganizationChange {
    case moveGroup(UUID, GroupDestination)
    case move(String, TabDestination)
    case create(String, name: String)
    case rename(UUID, String)
    case setColor(UUID, TabGroupColor)
    case toggle(UUID)
    case removeFromGroup(String)
    case ungroup(UUID)
}

extension RepositorySession {
    mutating func apply(_ change: TabOrganizationChange) {
        switch change {
        case .moveGroup(let id, let destination):
            moveGroup(id, to: destination)
        case .move(let path, let destination):
            move(path, to: destination)
        case .create(let path, let proposedName):
            let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard paths.contains(path), !name.isEmpty else { return }
            detach(path)
            let used = Set(groups.map(\.colorIndex))
            let palette = TabGroupColor.allCases
            let color = palette.first { !used.contains($0.rawValue) } ?? palette[groups.count % palette.count]
            groups.append(RepositoryTabGroup(id: UUID(), name: name, colorIndex: color.rawValue, members: [path]))
        case .rename(let id, let value):
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) { groups[index].name = name }
        case .setColor(let id, let color):
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].colorIndex = color.rawValue }
        case .toggle(let id):
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].collapsed.toggle() }
        case .removeFromGroup(let path):
            detach(path)
        case .ungroup(let id):
            groups.removeAll { $0.id == id }
        }
    }

    mutating func revealTab(_ path: String) {
        if let index = groups.firstIndex(where: { $0.members.contains(path) }) { groups[index].collapsed = false }
    }

    mutating func removeTab(_ path: String) {
        paths.removeAll { $0 == path }
        setGroup(nil, for: path)
    }

    private mutating func moveGroup(_ id: UUID, to destination: GroupDestination) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        let members = paths.filter(group.members.contains)
        var remaining = paths.filter { !group.members.contains($0) }
        let insertion: Int
        switch destination {
        case .beside(let path, let after):
            guard let index = remaining.firstIndex(of: path) else { return }
            if let neighbor = groups.first(where: { $0.members.contains(path) }) {
                let edge = after ? remaining.lastIndex(where: neighbor.members.contains)
                                 : remaining.firstIndex(where: neighbor.members.contains)
                guard let edge else { return }
                insertion = after ? edge + 1 : edge
            } else {
                insertion = after ? index + 1 : index
            }
        case .end:
            insertion = remaining.endIndex
        }
        remaining.insert(contentsOf: members, at: insertion)
        paths = remaining
    }

    private mutating func move(_ path: String, to destination: TabDestination) {
        guard paths.contains(path) else { return }
        let groupID: UUID?
        let next: String?
        switch destination {
        case .beside(let target, let after):
            guard path != target, let index = paths.firstIndex(of: target) else { return }
            next = after ? paths.dropFirst(index + 1).first : target
            groupID = groups.first { $0.members.contains(target) }?.id
        case .group(let id):
            guard let group = groups.first(where: { $0.id == id }),
                  let last = paths.lastIndex(where: { group.members.contains($0) }) else { return }
            next = paths.dropFirst(last + 1).first
            groupID = id
        case .end:
            next = nil
            groupID = nil
        }
        setGroup(groupID, for: path)
        place(path, before: next)
    }

    // Removing a middle member leaves the remaining group together in the strip.
    private mutating func detach(_ path: String) {
        guard let group = groups.first(where: { $0.members.contains(path) }),
              let last = paths.lastIndex(where: { group.members.contains($0) }) else { return }
        let next = paths.dropFirst(last + 1).first
        setGroup(nil, for: path)
        place(path, before: next)
    }

    private mutating func setGroup(_ id: UUID?, for path: String) {
        for index in groups.indices {
            if groups[index].id == id { groups[index].members.insert(path) }
            else { groups[index].members.remove(path) }
        }
        groups.removeAll { $0.members.isEmpty }
    }

    private mutating func place(_ path: String, before next: String?) {
        guard next != path else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: next.flatMap { paths.firstIndex(of: $0) } ?? paths.endIndex)
    }
}
