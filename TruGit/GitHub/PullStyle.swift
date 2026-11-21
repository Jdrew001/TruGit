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
    let pull: GitHubPull
    var body: some View {
        let color = pull.mergedAt != nil ? PullStyle.violet : pull.state == "closed" ? PullStyle.amber : pull.draft == true ? .secondary : PullStyle.mint
        Text(pull.status).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.13), in: Capsule())
    }
}

extension View {
    func pullCard() -> some View {
        self.background(PullStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(PullStyle.stroke).allowsHitTesting(false) }
    }
}

struct PullMessage: View {
    private let content: AttributedString

    init(_ source: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        content = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    var body: some View {
        Text(content).textSelection(.enabled).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}
