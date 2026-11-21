import AppKit
import SwiftUI

struct GitErrorDetails: View {
    let title: String
    let message: String
    var retry: (() -> Void)? = nil
    var retryDisabled = false
    var retrying = false
    var dismiss: (() -> Void)? = nil

    @State private var expanded = false
    @State private var copied = false
    @State private var outputHeight: CGFloat = 24
    private let accent = Color(red: 1, green: 0.57, blue: 0.48)

    private var summary: String {
        let lines = message.split(whereSeparator: \.isNewline)
        for line in lines {
            for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            if line.hasPrefix("CONFLICT") { return String(line) }
        }
        return lines.first.map(String.init) ?? message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let retry {
                    Button(action: retry) {
                        Label(retrying ? "Retrying…" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(WorkspaceColors.accent)
                    .disabled(retryDisabled)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(message, forType: .string)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Error copied" : "Copy error")
                .help(copied ? "Copied" : "Copy full error")
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss error").help("Dismiss error")
                }
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
            Text(verbatim: summary)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(expanded ? "Hide details" : "Show details")
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkspaceColors.accent)
            if expanded {
                WorkspaceScrollView {
                    Text(verbatim: message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { outputHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(ceil(outputHeight), 144))
                .padding(8)
                .background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WorkspaceColors.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceColors.divider) }
        .onChange(of: message) { expanded = false; copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
