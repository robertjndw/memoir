import SwiftUI

/// Close to the colours Apple uses for Siri and Writing Tools. Used for everything that
/// marks generated content or the model working.
enum IntelligencePalette {
    static let colors: [Color] = [
        Color(red: 0.74, green: 0.51, blue: 0.95),
        Color(red: 0.96, green: 0.73, blue: 0.92),
        Color(red: 0.55, green: 0.62, blue: 1.00),
        Color(red: 1.00, green: 0.40, blue: 0.47),
        Color(red: 1.00, green: 0.73, blue: 0.44),
        Color(red: 0.78, green: 0.53, blue: 1.00),
    ]

    static let linear = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The first color is repeated at the end so the seam disappears while the gradient rotates.
    static func angular(rotation: Angle) -> AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center, angle: rotation)
    }
}

extension View {
    /// Animated gradient border, shown while the model is working.
    func intelligenceGlow(isActive: Bool, cornerRadius: CGFloat) -> some View {
        modifier(IntelligenceGlow(isActive: isActive, cornerRadius: cornerRadius))
    }
}

private struct IntelligenceGlow: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GlowRim(cornerRadius: cornerRadius)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(.smooth(duration: 0.5), value: isActive)
    }
}

private struct GlowRim: View {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            // One rotation every six seconds.
            let degrees = (context.date.timeIntervalSinceReferenceDate * 60).truncatingRemainder(dividingBy: 360)
            let gradient = IntelligencePalette.angular(rotation: .degrees(degrees))
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 8).blur(radius: 10).opacity(0.55)
                shape.strokeBorder(gradient, lineWidth: 3).blur(radius: 3).opacity(0.7)
                shape.strokeBorder(gradient, lineWidth: 1.2)
            }
        }
    }
}

/// Secondary text with a highlight sweeping across it.
struct ShimmeringText: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweep: TimeInterval = 1.4
    private static let cycle: TimeInterval = 2.2

    var body: some View {
        if reduceMotion {
            Text(title).foregroundStyle(.secondary)
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
                // Rests past the trailing edge between sweeps.
                let phase = elapsed < Self.sweep ? -0.4 + 1.8 * (elapsed / Self.sweep) : 1.4
                Text(title).foregroundStyle(
                    LinearGradient(
                        colors: [.secondary, .primary, .secondary],
                        startPoint: UnitPoint(x: phase - 0.35, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.35, y: 0.5)
                    )
                )
            }
        }
    }
}

/// Sparkles and a shimmering label, for model work without measurable progress.
struct IntelligenceActivity: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(IntelligencePalette.linear)
                .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            ShimmeringText(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#Preview("Activity") {
    VStack(spacing: 24) {
        IntelligenceActivity("Thinking...")
        IntelligenceActivity("Summarizing...")
        Text("Ask a question")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 360, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .intelligenceGlow(isActive: true, cornerRadius: 20)
    }
    .padding(40)
}
