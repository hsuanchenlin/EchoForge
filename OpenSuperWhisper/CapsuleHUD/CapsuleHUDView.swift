import SwiftUI

/// The floating capsule: one pill at the top of the screen that says what the
/// app is doing with the user's voice right now.
///
/// Everything it draws comes from `CapsuleHUDViewModel`; it makes no decision of
/// its own beyond how to render one. The duration is the one exception, and it is
/// not really an exception: the counter redraws itself from a `TimelineView`
/// against the view model's `recordingStartedAt`, so no timer has to publish a
/// value 10 times a second to keep a label moving.
struct CapsuleHUDView: View {

    /// Geometry shared with `CapsuleHUDWindowController`. The panel is larger
    /// than the pill on purpose: the shadow is drawn outside the pill's own
    /// bounds, and anything outside the *window* bounds is cut off - the same
    /// constraint `IndicatorWindow` documents. The controller compensates for the
    /// margin when it places the window, so it is the pill that lands where it
    /// was asked to.
    static let capsuleHeight: CGFloat = 40
    static let windowSize = CGSize(width: 380, height: 96)

    @ObservedObject var viewModel: CapsuleHUDViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if viewModel.state == .idle {
                // Never on screen - the controller orders the panel out on
                // `.idle` - but a hosting view outliving the state must draw
                // nothing rather than an empty pill.
                Color.clear
            } else {
                pill
            }
        }
        // The root view must fill the panel: `NSHostingView` with default sizing
        // would shrink the window to the pill, and the window bounds would then
        // clip the shadow.
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    private var pill: some View {
        content
            .frame(height: Self.capsuleHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(Material.ultraThinMaterial)
                    .overlay {
                        // A hairline of definition. Material alone disappears
                        // against a light window and against a dark one, and the
                        // edge is what makes it read as an object rather than as
                        // a smudge over whatever is behind it.
                        Capsule(style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 10, y: 3)
            }
            .fixedSize()
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .connecting:
            row {
                modeChip
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14)
                label("Connecting…", color: .secondary)
            }

        case .recording:
            row {
                modeChip
                CapsuleHUDWaveform(
                    levels: viewModel.levels,
                    sampleCount: CapsuleHUDViewModel.waveformSampleCount
                )
                durationCounter
            }

        case .polishing(let work):
            row {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14)
                PulsingLabel(text: work.label)
                cancelButton
            }

        case .complete:
            row {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14, weight: .semibold))
                label("Inserted", color: .primary)
            }

        case .error(let message):
            row {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13, weight: .semibold))
                label(message, color: .orange)
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 14)
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            // Keeps a long failure sentence from pushing the pill wider than the
            // panel that has to contain it.
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var modeChip: some View {
        Text(viewModel.mode.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14))
            }
            .accessibilityLabel("Mode: \(viewModel.mode.label)")
    }

    /// Redraws itself rather than being pushed a value: a `TimelineView` costs
    /// one label per interval, where publishing an elapsed time would rebuild the
    /// whole capsule - material, waveform and all - at the same rate.
    private var durationCounter: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(CapsuleHUDViewModel.durationText(for: viewModel.elapsed(at: context.date)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Recording")
    }

    private var cancelButton: some View {
        Button {
            viewModel.cancel()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Stop and discard this dictation")
        .accessibilityLabel("Cancel")
    }
}

/// The level meter: the recent past of the user's voice, newest sample at the
/// right.
///
/// Solid bars and no gradients on purpose. This is the one part of the capsule
/// that changes 20 times a second, and it sits in front of a blur material -
/// keeping it to plain fills is what stops each sample re-rasterizing anything
/// expensive.
struct CapsuleHUDWaveform: View {
    let levels: [Float]
    let sampleCount: Int

    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 2
    static let minimumBarHeight: CGFloat = 3
    static let maximumBarHeight: CGFloat = 18

    /// Levels padded at the *left* with silence, so a dictation's first samples
    /// arrive at the right edge and travel leftwards instead of the whole meter
    /// stretching as the history fills up.
    private var padded: [Float] {
        guard levels.count < sampleCount else {
            return Array(levels.suffix(sampleCount))
        }
        return Array(repeating: 0, count: sampleCount - levels.count) + levels
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(Array(padded.enumerated()), id: \.offset) { index, level in
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(opacity(forIndex: index)))
                    .frame(width: Self.barWidth, height: height(for: level))
            }
        }
        .frame(
            width: CGFloat(sampleCount) * Self.barWidth + CGFloat(sampleCount - 1) * Self.barSpacing,
            height: Self.maximumBarHeight
        )
        .accessibilityHidden(true)
    }

    private func height(for level: Float) -> CGFloat {
        let span = Self.maximumBarHeight - Self.minimumBarHeight
        return Self.minimumBarHeight + CGFloat(min(1, max(0, level))) * span
    }

    /// Older samples fade, which is what makes a row of bars read as time passing
    /// rather than as a static equalizer.
    private func opacity(forIndex index: Int) -> Double {
        guard sampleCount > 1 else { return 1 }
        let age = Double(index) / Double(sampleCount - 1)
        return 0.35 + 0.65 * age
    }
}

/// A label that breathes while the app is thinking.
///
/// The pulse is on opacity alone: Core Animation interpolates that on the layer,
/// so the text is rasterized once no matter how long the wait lasts.
struct PulsingLabel: View {
    let text: String

    @State private var isDim = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .opacity(isDim ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
    }
}

#Preview("Capsule states") {
    let recording = CapsuleHUDViewModel()
    let polishing = CapsuleHUDViewModel()
    let complete = CapsuleHUDViewModel()
    let failed = CapsuleHUDViewModel()

    recording.beginSession(mode: CapsuleHUDMode(label: "Polish"))
    recording.beginRecording()
    for index in 0 ..< CapsuleHUDViewModel.waveformSampleCount {
        recording.pushLevel(Float(index % 9) / 8)
    }
    polishing.beginSession(mode: .dictate)
    polishing.beginRecording()
    polishing.beginPolishing(.rewriting)
    complete.beginSession(mode: .dictate)
    complete.beginRecording()
    complete.complete()
    failed.beginSession(mode: .dictate)
    failed.beginRecording()
    failed.fail("No speech detected")

    return VStack(spacing: 0) {
        CapsuleHUDView(viewModel: recording)
        CapsuleHUDView(viewModel: polishing)
        CapsuleHUDView(viewModel: complete)
        CapsuleHUDView(viewModel: failed)
    }
    .background(Color(.windowBackgroundColor))
}
