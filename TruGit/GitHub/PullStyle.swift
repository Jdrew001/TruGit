import SwiftUI

enum PullStyle {
    static let canvas = Color(red: 0.055, green: 0.068, blue: 0.078)
    static let rail = Color(red: 0.076, green: 0.09, blue: 0.104)
    static let surface = Color(red: 0.101, green: 0.118, blue: 0.133)
    static let inset = Color(red: 0.068, green: 0.082, blue: 0.094)
    static let stroke = Color.white.opacity(0.12)
    static let mint = Color(red: 0.41, green: 0.89, blue: 0.77)
    static let violet = Color(red: 0.75, green: 0.65, blue: 0.99)
    static let amber = Color(red: 1, green: 0.72, blue: 0.42)
    static let blue = Color(red: 0.52, green: 0.74, blue: 1)
}

struct PullPrimaryButton: ButtonStyle {
    var tint = PullStyle.mint
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(enabled ? PullStyle.canvas : Color.secondary)
            .background(enabled ? tint.opacity(configuration.isPressed ? 0.7 : 1) : PullStyle.surface,
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

struct PullAvatar: View {
    let name: String
    var size: CGFloat = 27
    private var tint: Color {
        let palette = [PullStyle.blue, PullStyle.violet, PullStyle.mint, PullStyle.amber]
        let index = name.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[index]
    }

    var body: some View {
        Text(String(name.prefix(2)).uppercased())
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(tint.opacity(0.15), in: Circle())
            .overlay { Circle().strokeBorder(tint.opacity(0.25)) }.accessibilityHidden(true)
    }
}

struct PullStatus: View {
    let status: PullRequestStatus

    var body: some View {
        let color: Color = switch status {
        case .open: PullStyle.mint
        case .draft: .secondary
        case .closed: PullStyle.amber
        case .merged: PullStyle.violet
        }
        Text(status.rawValue).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

extension View {
    func pullCard() -> some View {
        self.background(PullStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(PullStyle.stroke).allowsHitTesting(false) }
    }
}

struct PullMessage: View {
    private let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        PagedPullMessage(source: source).id(source)
    }
}

private struct PagedPullMessage: View {
    let source: String
    @State private var fragments: [Fragment] = []
    @State private var requested: String.Index?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fragments) { fragment in
                Text(fragment.content).textSelection(.enabled).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = fragments.last?.next {
                Button("Show more of message") { requested = next }
                    .buttonStyle(.link).font(.caption)
                    .disabled(requested == next)
            }
        }
        .task(id: requested) {
            let start = requested ?? source.startIndex
            guard fragments.last?.id != start else { return }
            let fragment = await Fragment.render(source, at: start)
            if !Task.isCancelled { fragments.append(fragment) }
        }
    }

    private struct Fragment: Identifiable, Sendable {
        let id: String.Index
        let content: AttributedString
        let next: String.Index?

        nonisolated static func render(_ source: String, at start: String.Index) async -> Self {
            let limit = source.index(start, offsetBy: 6_000, limitedBy: source.endIndex) ?? source.endIndex
            // Split long messages at a nearby newline when possible so ordinary Markdown stays intact.
            var end = limit
            if limit < source.endIndex {
                let lowerBound = source.index(limit, offsetBy: -750)
                if let newline = source[lowerBound..<limit].lastIndex(of: "\n") { end = source.index(after: newline) }
            }
            let text = String(source[start..<end])
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let content = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
            return Self(id: start, content: content, next: end < source.endIndex ? end : nil)
        }
    }
}
