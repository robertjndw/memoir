import SwiftUI

/// Who was talking over a stretch of the recording, for colouring the waveform.
nonisolated struct SpeakerSpan: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var speaker: Speaker

    /// Spans must be sorted by start. Gaps of up to 1.5 s still count as the previous speaker,
    /// otherwise every pause between sentences shows up as a grey bar.
    static func speaker(at time: TimeInterval, in spans: [SpeakerSpan]) -> Speaker? {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let span = spans[low - 1]
        return time <= span.end + 1.5 ? span.speaker : nil
    }
}

/// Same colours as the speaker names in the transcript.
func speakerColor(_ speaker: Speaker?) -> Color {
    speaker == .me ? .accentColor : .primary
}

/// Scrubber drawn over the recording's waveform, coloured by speaker.
struct WaveformScrubber: View {
    /// Normalized loudness, nil while it is still being computed.
    let peaks: [Float]?
    let speakers: [SpeakerSpan]
    let duration: TimeInterval
    /// 0...1
    let progress: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var width: CGFloat = 1
    @State private var isHovered = false

    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let step = Self.barWidth + Self.gap
            let count = max(1, Int((size.width + Self.gap) / step))
            let levels = peaks.map { Self.resample($0, to: count) }
            let playedX = size.width * min(max(progress, 0), 1)
            let mid = size.height / 2

            for index in 0..<count {
                let x = CGFloat(index) * step
                let level = levels.map { CGFloat($0[index]) } ?? 0
                let height = max(Self.barWidth, level * size.height)
                let rect = CGRect(x: x, y: mid - height / 2, width: Self.barWidth, height: height)
                let time = duration * (Double(index) + 0.5) / Double(count)
                let color = speakerColor(SpeakerSpan.speaker(at: time, in: speakers))
                let played = x + Self.barWidth / 2 <= playedX
                context.fill(
                    Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                    with: .color(color.opacity(played ? 0.9 : 0.3))
                )
            }

            let playhead = CGRect(x: playedX - 1, y: 0, width: 2, height: size.height)
            context.fill(Path(roundedRect: playhead, cornerRadius: 1), with: .color(.primary))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onScrub(fraction(at: $0.location.x)) }
                .onEnded { onCommit(fraction(at: $0.location.x)) }
        )
        .pointerStyle(.columnResize)
        .animation(.smooth(duration: 0.4), value: peaks == nil)
    }

    private func fraction(at x: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1))
    }

    /// The loudest value in each output bar's range, so short peaks survive the downsampling.
    static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty, count > 0 else { return Array(repeating: 0, count: max(count, 0)) }
        return (0..<count).map { index in
            let lower = index * values.count / count
            let upper = max(lower + 1, (index + 1) * values.count / count)
            return values[lower..<min(upper, values.count)].max() ?? 0
        }
    }
}

/// Scrolling level history while recording. Each bar takes the colour of the louder source.
struct LiveWaveform: View {
    var barCount = 44

    @Environment(AppModel.self) private var model
    @State private var history: [AudioLevels] = []

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(barCount)
            let barWidth = max(1.5, step * 0.55)
            let mid = size.height / 2
            let padding = barCount - history.count

            for index in 0..<barCount {
                let sample = index >= padding ? history[index - padding] : AudioLevels()
                let level = CGFloat(max(sample.microphone, sample.system))
                // Speech sits low on a linear scale, so boost it a bit.
                let height = max(barWidth, pow(level, 0.7) * size.height)
                let x = CGFloat(index) * step + (step - barWidth) / 2
                let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
                let isSilent = level < 0.02
                let color: Color = isSilent ? .secondary : speakerColor(sample.microphone >= sample.system ? .me : .others)
                let age = min(1, 0.15 + Double(index) / 10)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity((isSilent ? 0.4 : 0.9) * age)))
            }
        }
        .task {
            while !Task.isCancelled {
                // Sampled here instead of read in body, so the canvas redraws once per tick and not
                // on every level update.
                history.append(model.levels)
                if history.count > barCount { history.removeFirst(history.count - barCount) }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
extension WaveformLoader {
    /// A plausible conversation shape for previews, which have no audio file.
    static let preview: [Float] = (0..<WaveformLoader.resolution).map { index in
        let t = Double(index)
        let envelope = 0.55 + 0.45 * sin(t / 37) * sin(t / 11)
        let jitter = abs(sin(t * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let pause = (index / 45) % 5 == 3 ? 0.08 : 1
        return Float(max(0.04, envelope * (0.35 + 0.65 * jitter) * pause))
    }
}

#Preview("Scrubber") {
    @Previewable @State var progress = 0.35
    let spans = (0..<20).map { SpeakerSpan(start: Double($0) * 120, end: Double($0) * 120 + 110, speaker: $0.isMultiple(of: 3) ? .me : .others) }
    VStack(spacing: 24) {
        WaveformScrubber(peaks: WaveformLoader.preview, speakers: spans, duration: 2400, progress: progress, onScrub: { progress = $0 }, onCommit: { progress = $0 })
            .frame(height: 36)
        WaveformScrubber(peaks: nil, speakers: [], duration: 2400, progress: 0, onScrub: { _ in }, onCommit: { _ in })
            .frame(height: 36)
    }
    .padding(24)
    .frame(width: 640)
}
#endif
