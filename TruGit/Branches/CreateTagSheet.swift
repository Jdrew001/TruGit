import SwiftUI

struct CreateTagSheet: View {
    let point: RevisionPoint
    let tags: Set<String>
    let remotes: [String]
    let create: (RevisionAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingName: Bool
    @State private var name = ""
    @State private var message = ""
    @State private var remote = ""

    private var tagName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Create Tag", systemImage: "tag").font(.title2.weight(.semibold))
            HStack {
                Text("Commit").foregroundStyle(.secondary)
                Text(point.shortID).monospaced()
                if point.reference != nil { Text(point.name).lineLimit(1).truncationMode(.middle) }
            }
            .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tag name").font(.headline)
                TextField("e.g. v1.0.0", text: $name).focused($editingName)
                if tags.contains(tagName) {
                    Text("This tag already exists in this repository.").font(.caption).foregroundStyle(.orange)
                } else if let next = Self.nextPatch(after: tags), name.isEmpty {
                    Button("Use " + next) { name = next }.buttonStyle(.link).font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Annotation").font(.headline)
                TextField("Optional tag message", text: $message, axis: .vertical).lineLimit(2...4)
            }
            if !remotes.isEmpty {
                Picker("Destination", selection: $remote) {
                    Text("Local repository only").tag("")
                    ForEach(remotes, id: \.self) { Text("Push to " + $0).tag($0) }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(remote.isEmpty ? "Create Tag" : "Create and Push Tag") {
                    let action = RevisionAction(operation: .tag, source: point, target: point, mainline: nil,
                                                name: tagName, tagMessage: message, pushTagTo: remote.isEmpty ? nil : remote)
                    dismiss()
                    create(action)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(tagName.isEmpty || tags.contains(tagName))
            }
        }
        .padding(22).frame(width: 400)
        .onAppear { editingName = true }
    }

    static func nextPatch(after tags: Set<String>) -> String? {
        let versions = tags.compactMap { name -> [Int]? in
            guard name.first == "v" else { return nil }
            let parts = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == 3, parts.count == 3,
                  zip(parts, numbers).allSatisfy({ $0 == String($1) && $1 >= 0 }) else { return nil }
            return numbers
        }
        guard let latest = versions.max(by: { $0.lexicographicallyPrecedes($1) }), latest[2] < Int.max else { return nil }
        return "v\(latest[0]).\(latest[1]).\(latest[2] + 1)"
    }
}
