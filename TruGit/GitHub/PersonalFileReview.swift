import CryptoKit
import SwiftUI

struct ReviewFile: Identifiable, Sendable {
    let file: PullFile
    let fingerprint: String
    var id: String { file.filename }
    let folder: String
    let name: String

    init(_ file: PullFile) {
        self.file = file
        let path = file.filename as NSString
        folder = path.deletingLastPathComponent
        name = path.lastPathComponent
        // The blob identifies binary content. Include the patch because a new
        // comparison base can change the diff while keeping the head blob.
        let parts = [file.sha, file.status, file.previousFilename ?? "", String(file.additions),
                     String(file.deletions), file.patch ?? ""]
        let data = Data(parts.joined(separator: "\0").utf8)
        fingerprint = Data(SHA256.hash(data: data)).base64EncodedString()
    }

    nonisolated static func build(from files: [PullFile]) async -> [Self] {
        var seen = Set<String>()
        return files.compactMap { file in
            seen.insert(file.filename).inserted ? Self(file) : nil
        }
    }
}

struct PersonalFileReview: View {
    let files: [ReviewFile]
    @AppStorage private var marks: Data
    @Binding var selection: String?

    init(files: [ReviewFile], selection: Binding<String?>, login: String, repository: String, number: Int) {
        self.files = files
        _selection = selection
        let key = "personalFileReview.v1/\(login.lowercased())/\(repository.lowercased())/\(number)"
        _marks = AppStorage(wrappedValue: Data(), key)
    }

    var body: some View {
        let saved = (try? JSONDecoder().decode([String: String].self, from: marks)) ?? [:]
        let remaining = files.filter { saved[$0.id] != $0.fingerprint }
        let count = files.count - remaining.count
        let current = files.first { $0.id == selection } ?? remaining.first ?? files.first
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: remaining.isEmpty ? "checkmark.circle.fill" : "checklist")
                    .foregroundStyle(PullStyle.mint)
                Text("\(count) of \(files.count) reviewed").font(.callout.weight(.semibold))
                Spacer()
                Button("Next unreviewed") {
                    guard let current, let index = files.firstIndex(where: { $0.id == current.id }) else { return }
                    selection = (files.dropFirst(index + 1).first { saved[$0.id] != $0.fingerprint } ?? remaining.first)?.id
                }
                .disabled(!remaining.contains { $0.id != current?.id })
            }.padding(.horizontal, 12).padding(.vertical, 8)
            ProgressView(value: Double(count), total: Double(max(1, files.count)))
                .progressViewStyle(.linear).tint(PullStyle.mint)
                .accessibilityLabel("Personal review progress")
            if let current {
                GeometryReader { geometry in
                    let wide = geometry.size.width >= 640
                    HStack(alignment: .top, spacing: 0) {
                        if wide {
                            fileNavigator(current: current, saved: saved)
                                .frame(width: min(240, geometry.size.width * 0.28))
                                .background(PullStyle.rail)
                            Divider()
                        }
                        diffPane(current: current, saved: saved, showsPicker: !wide)
                    }
                }
            }
        }
    }

    private func fileNavigator(current: ReviewFile, saved: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed files").fontWeight(.semibold)
                Spacer()
                Text(files.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        let groups = Dictionary(grouping: files, by: \.folder)
                        ForEach(groups.keys.sorted(), id: \.self) { folder in
                            Label(folder.isEmpty ? "Repository root" : folder, systemImage: "folder")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(folder)
                                .padding(.top, 8).padding(.horizontal, 5)
                            ForEach(groups[folder] ?? []) { item in
                                fileRow(item, selected: item.id == current.id, reviewed: saved[item.id] == item.fingerprint)
                                    .id(item.id)
                            }
                        }
                    }
                    .font(.caption).padding(8)
                }
                .onChange(of: current.id) { _, file in proxy.scrollTo(file) }
            }
        }
    }

    private func fileRow(_ item: ReviewFile, selected: Bool, reviewed: Bool) -> some View {
        Button { selection = item.id } label: {
            HStack(spacing: 5) {
                Image(systemName: reviewed ? "checkmark.circle.fill" : fileIcon(item.file.status))
                    .foregroundStyle(reviewed ? PullStyle.mint : PullStyle.blue)
                    .frame(width: 15)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                changeTotals(item.file).font(.caption2.monospacedDigit())
            }
            .padding(.horizontal, 7).padding(.vertical, 7).contentShape(Rectangle())
            .background(selected ? PullStyle.blue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).help(item.id)
        .accessibilityLabel(item.id)
        .accessibilityValue(reviewed ? "Reviewed" : "Unreviewed")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fileIcon(_ status: String) -> String {
        switch status {
        case "added": "plus.square"
        case "removed": "minus.square"
        case "renamed": "arrow.right.square"
        default: "doc.text"
        }
    }

    private func diffPane(current: ReviewFile, saved: [String: String], showsPicker: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsPicker {
                Picker("File", selection: Binding(get: { current.id }, set: { selection = $0 })) {
                    ForEach(files) { item in
                        Text((saved[item.id] == item.fingerprint ? "✓ " : "") + item.id).tag(item.id)
                    }
                }.padding(8)
                Divider()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(current.id).font(.callout.monospaced().weight(.semibold))
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                HStack {
                    Text(current.file.status.capitalized).foregroundStyle(.secondary)
                    changeTotals(current.file).monospacedDigit()
                    Spacer()
                    Toggle("Reviewed", isOn: Binding(get: { saved[current.id] == current.fingerprint }, set: { marked in
                        selection = current.id
                        var updated = saved
                        updated[current.id] = marked ? current.fingerprint : nil
                        if let data = try? JSONEncoder().encode(updated) { marks = data }
                    }))
                    .toggleStyle(.checkbox)
                    .help("Save your review progress on this Mac")
                }.font(.caption)
            }.padding(12).background(PullStyle.inset)
            Divider()
            if let patch = current.file.patch, !patch.isEmpty {
                PatchText(text: patch, path: current.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("No text diff", systemImage: "doc",
                                       description: Text("GitHub did not provide a text diff for this file."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func changeTotals(_ file: PullFile) -> some View {
        HStack(spacing: 4) {
            if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(PullStyle.mint) }
            if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(PullStyle.amber) }
        }
        .fixedSize()
    }
}
