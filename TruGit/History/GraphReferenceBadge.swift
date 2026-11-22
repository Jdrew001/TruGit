import SwiftUI

/// One displayed name can point to several independently actionable Git refs.
struct GraphReferenceBadge: Identifiable, Sendable {
    let name: String
    let reference: RepositoryReference
    let remotes: [RepositoryReference]

    var id: String { reference.id }
    var references: [RepositoryReference] {
        reference.kind == .remote ? remotes : [reference] + remotes
    }

    static func grouped(_ references: [RepositoryReference], currentBranch: String, remoteNames: [String]) -> [Self] {
        let prefixes = remoteNames.sorted { $0.count > $1.count }.map { $0 + "/" }
        let branches = Dictionary(grouping: references.filter { $0.kind != .tag }) { ref in
            guard ref.kind == .remote else { return ref.name }
            if let target = ref.remoteTarget { return target.name }
            if let prefix = prefixes.first(where: { ref.name.hasPrefix($0) }) {
                return String(ref.name.dropFirst(prefix.count))
            }
            return ref.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ref.name
        }
        var badges = branches.compactMap { name, refs -> Self? in
            let local = refs.first { $0.kind == .local }
            let remotes = refs.filter { $0.kind == .remote }.sorted { $0.id < $1.id }
            guard let primary = local ?? remotes.first else { return nil }
            return Self(name: name, reference: primary, remotes: remotes)
        }
        badges += references.filter { $0.kind == .tag }.map { Self(name: $0.name, reference: $0, remotes: []) }
        let current = RepositoryReference.Kind.local.prefix + currentBranch
        return badges.sorted { left, right in
            if (left.id == current) != (right.id == current) { return left.id == current }
            if left.reference.kind != right.reference.kind && (left.reference.kind == .tag || right.reference.kind == .tag) {
                return right.reference.kind == .tag
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func width(checkedOut: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: checkedOut ? .semibold : .medium)
        let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
        let paired = reference.kind == .local && !remotes.isEmpty
        return ceil(nameWidth) + 10 + 21 + (paired ? 17 : 0) + (checkedOut ? 15 : 0)
    }
}

/// The branch name opens the local tip when available. Each location opens its own tip.
struct BranchLocationLabel<MenuItems: View>: View {
    let badge: GraphReferenceBadge
    let repository: URL
    var checkedOut = false
    var wraps = false
    let select: (RepositoryReference) -> Void
    let checkout: (RepositoryReference) -> Void
    let drop: (BranchDrag, RevisionPoint) -> Bool
    @ViewBuilder let menu: (RepositoryReference) -> MenuItems

    var body: some View {
        HStack(spacing: 0) {
            target(badge.reference) {
                HStack(spacing: 4) {
                    if checkedOut {
                        Image(systemName: "checkmark").fontWeight(.bold).frame(width: 11)
                    }
                    Text(verbatim: badge.name)
                        .lineLimit(wraps ? nil : 1)
                        .fixedSize(horizontal: false, vertical: wraps)
                        .truncationMode(.tail)
                    if badge.reference.kind != .remote || badge.remotes.count == 1 {
                        glyph(badge.reference)
                    }
                }
            }
            if badge.remotes.count > 1 {
                Menu {
                    ForEach(badge.remotes) { remote in
                        Menu(remote.name) {
                            Button("Show in Graph") { select(remote) }
                            menu(remote)
                        }
                    }
                } label: {
                    if badge.remotes.allSatisfy(\.isGitHubRemote) {
                        glyph(badge.remotes[0])
                    } else {
                        Image(systemName: "globe").frame(width: 19)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Remotes for " + badge.name)
                .help(badge.remotes.map(\.name).joined(separator: ", "))
            } else if badge.reference.kind == .local, let remote = badge.remotes.first {
                target(remote) { glyph(remote) }.fixedSize()
            }
        }
    }

    private func glyph(_ ref: RepositoryReference) -> some View {
        ReferenceLocationIcon(reference: ref).frame(width: 17, height: 17)
    }

    private func target(_ ref: RepositoryReference, @ViewBuilder content: () -> some View) -> some View {
        let location = checkedOut && ref.kind == .local ? "checked-out local branch" : ref.locationLabel
        return content()
            .contentShape(Rectangle())
            .modifier(BranchDragControl(reference: ref, repository: repository, onSelect: select, onCheckout: checkout, onDrop: drop))
            .contextMenu { menu(ref) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ref.name + ", " + location)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select(ref) }
            .help(ref.name + " · " + location + " · " + ref.commitID.prefix(7))
    }
}

struct ReferenceLocationIcon: View {
    let reference: RepositoryReference
    var size: CGFloat = 13

    var body: some View {
        Group {
            if reference.isGitHubRemote {
                Image("GitHubMark").resizable().scaledToFit()
            } else {
                Image(systemName: symbol).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch reference.kind {
        case .local: "laptopcomputer"
        case .remote: "globe"
        case .tag: "tag"
        }
    }
}
