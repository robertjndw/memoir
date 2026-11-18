import SwiftUI

/// Compact horizontal meter. `level` is normalized 0...1.
struct LevelMeter: View {
    let symbol: String
    let label: LocalizedStringKey
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(4, proxy.size.width * CGFloat(min(max(level, 0), 1))))
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.08), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
    }
}

#Preview {
    VStack {
        LevelMeter(symbol: "mic.fill", label: "Microphone level", level: 0.6)
        LevelMeter(symbol: "speaker.wave.2.fill", label: "System audio level", level: 0.2)
    }
    .padding()
    .frame(width: 300)
}
