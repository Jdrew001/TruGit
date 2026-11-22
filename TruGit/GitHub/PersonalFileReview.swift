import CryptoKit
import SwiftUI

struct ReviewFile: Identifiable {
    let file: PullFile
    let fingerprint: String
    var id: String { file.filename }
    var folder: String { (id as NSString).deletingLastPathComponent }
    var name: String { (id as NSString).lastPathComponent }

    init(_ file: PullFile) {
        self.file = file
        // The blob identifies binary content. Include the patch because a new
        // comparison base can change the diff while keeping the head blob.
        let parts = [file.sha, file.status, file.previousFilename ?? "", String(file.additions),
                     String(file.deletions), file.patch ?? ""]
        let data = Data(parts.joined(separator: "\0").utf8)
        fingerprint = Data(SHA256.hash(data: data)).base64EncodedString()
    }
}

struct PersonalFileReview: View {
    let files: [ReviewFile]
    @AppStorage private var marks: Data
    @State private var selection: String?

    init(files: [ReviewFile], login: String, repository: String, number: Int) {
        self.files = files
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                let groups = Dictionary(grouping: files, by: \.folder)
                ForEach(groups.keys.sorted(), id: \.self) { folder in
                    Label(folder.isEmpty ? "Repository root" : folder, systemImage: "folder")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(folder)
                        .padding(.top, 8)
                    ForEach(groups[folder] ?? []) { item in
                        Button { selection = item.id } label: {
                            HStack {
                                Image(systemName: saved[item.id] == item.fingerprint ? "checkmark.circle.fill" : "doc")
                                    .foregroundStyle(saved[item.id] == item.fingerprint ? PullStyle.mint : .secondary)
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(6).contentShape(Rectangle())
                            .background(item.id == current.id ? PullStyle.blue.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).help(item.id)
                        .accessibilityLabel(item.id)
                        .accessibilityValue(saved[item.id] == item.fingerprint ? "Reviewed" : "Unreviewed")
                        .accessibilityAddTraits(item.id == current.id ? .isSelected : [])
                    }
                }
            }.font(.caption).padding(8)
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
                    Text("+\(current.file.additions)").foregroundStyle(PullStyle.mint)
                    Text("−\(current.file.deletions)").foregroundStyle(.red)
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
            }.padding(12)
            Divider()
            ScrollView {
                if let patch = current.file.patch {
                    PatchText(text: patch).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("GitHub did not provide a text diff for this file.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }.id(current.id)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
