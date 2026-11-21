import SwiftUI

struct LaunchSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private static let halfBounce = 0.34
    private static let landingPause = 0.09
    static let displayTime = Duration.seconds(4 * halfBounce + 2 * landingPause)
    private let iconSize: CGFloat = 136

    private var icon: some View {
        let tile = RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
        return tile
            .fill(Color(red: 0.075, green: 0.085, blue: 0.13))
            .frame(width: iconSize, height: iconSize)
            .overlay {
                // The Dock artwork includes optical padding and a painted rim.
                // Sample just inside that rim so the splash has one continuous edge.
                Image("LaunchIcon", bundle: .main)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize * 1.31, height: iconSize * 1.31)
            }
            .clipShape(tile)
            .overlay {
                tile.strokeBorder(.linearGradient(colors: [.white.opacity(0.23), .white.opacity(0.06)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 0.75)
            }
    }

    var body: some View {
        Group {
            if reduceMotion {
                icon
            } else {
                icon.keyframeAnimator(initialValue: CGFloat.zero, trigger: animate) { image, offset in
                    image.offset(y: offset + 10)
                } keyframes: { _ in
                    CubicKeyframe(-24, duration: Self.halfBounce, startVelocity: -135, endVelocity: 0)
                    CubicKeyframe(0, duration: Self.halfBounce, startVelocity: 0, endVelocity: 135)
                    LinearKeyframe(0, duration: Self.landingPause)
                    CubicKeyframe(-20, duration: Self.halfBounce, startVelocity: -115, endVelocity: 0)
                    CubicKeyframe(0, duration: Self.halfBounce, startVelocity: 0, endVelocity: 115)
                    LinearKeyframe(0, duration: Self.landingPause)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear { animate = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening TruGit")
    }
}
