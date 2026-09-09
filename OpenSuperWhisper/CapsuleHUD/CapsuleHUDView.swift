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

    /// The pill's height while it is saying something about the microphone.
    ///
    /// The diagnostic gets a line of its own rather than a place on the meter's
    /// row: it names an input device, and a device name is long enough to push
    /// the duration counter off a single-row pill. The pill grows **downwards**
    /// only - see `pillTopInset` - so the thing the user has learned the position
    /// of does not move when a warning appears.
    static let expandedCapsuleHeight: CGFloat = 64

    /// Where the top of the pill sits inside the panel.
    ///
    /// A constant rather than "centred in the window", because the pill has two
    /// heights and a centred one would drift upwards as it grew - into the menu
    /// bar, which is the strip the panel's transparent top margin is deliberately
    /// allowed to overlap. `CapsuleHUDWindowController.origin` places the window
    /// from this same number, so the two cannot disagree.
    static let pillTopInset: CGFloat = 28

    static let windowSize = CGSize(width: 440, height: 128)

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
        //
        // Top-aligned with a fixed inset rather than centred, so a pill that
        // grows to carry a microphone diagnostic grows downwards into the panel's
        // spare room instead of upwards over the menu bar.
        .padding(.top, Self.pillTopInset)
        .frame(
            width: Self.windowSize.width, height: Self.windowSize.height, alignment: .top)
    }

    /// Whether the pill is carrying a line about the microphone.
    ///
    /// Only during the recording itself: a diagnostic is about a capture that is
    /// running, and one left on screen over "Transcribing…" would be describing
    /// audio nobody can do anything about any more.
    private var showsSignalDiagnostic: Bool {
        viewModel.state == .recording && viewModel.signal.isDiagnostic
    }

    private var pill: some View {
        content
            .frame(height: showsSignalDiagnostic ? Self.expandedCapsuleHeight : Self.capsuleHeight)
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
            .overlay(alignment: .bottom) {
                // The same countdown the card draws, inside the pill: its
                // 12 pt side padding keeps the 2 pt bar clear of the capsule's
                // bottom curve.
                if viewModel.state == .recording && viewModel.isConfirmingCancel {
                    CancelConfirmationBar()
                }
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
            VStack(alignment: .leading, spacing: 4) {
                row {
                    modeChip
                    if viewModel.isConfirmingCancel {
                        label("Press Esc to cancel", color: .orange)
                    } else {
                        CapsuleHUDWaveform(
                            levels: viewModel.levels,
                            sampleCount: CapsuleHUDViewModel.waveformSampleCount,
                            tint: CapsuleHUDWaveform.tint(for: viewModel.signal)
                        )
                        durationCounter
                    }
                }
                if showsSignalDiagnostic, !viewModel.isConfirmingCancel {
                    signalDiagnosticRow
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)
            .animation(.easeInOut(duration: 0.2), value: showsSignalDiagnostic)

        case .polishing(let work):
            VStack(alignment: .leading, spacing: 4) {
                row {
                    // The chip stays up through the wait, unlike the meter and
                    // the timer: this is when a spoken command is recognised, so
                    // it is the moment the chip changes from "Dictate" to "Ask"
                    // or "Translate …" and the one moment the user needs to see
                    // it.
                    modeChip
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14)
                    PulsingLabel(text: work.label)
                    cancelButton
                }
                if work == .transcribing, let partial = viewModel.partialText {
                    partialTranscriptRow(partial)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.partialText)

        case .awaitingChannelChoice:
            row {
                // The chip stays up, as it does through the decode: it names
                // the channel that was heard, which is what the picker in
                // front is asking about. No spinner - the wait is the user's.
                modeChip
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13, weight: .semibold))
                label("Choose a channel", color: .primary)
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

    /// The second line: what the signal is doing, and which input it came from.
    ///
    /// The device is named because the advice depends on it - "no signal" from
    /// the built-in microphone and "no signal" from a headset that never
    /// connected are different problems - and because the user cannot otherwise
    /// tell which input this app is on without leaving the app they are dictating
    /// into. It is truncated rather than allowed to widen the pill: a USB
    /// interface can name itself in forty characters.
    ///
    /// Nothing here is clickable. The panel refuses mouse events for the whole
    /// recording on purpose (`CapsuleHUDWindowController.acceptsMouseEvents`),
    /// because a HUD that swallowed clicks would take the top strip of the screen
    /// away from the app the user is dictating into. Acting on this lives in
    /// Settings → Setup Health, which has the microphone test beside it.
    @ViewBuilder private var signalDiagnosticRow: some View {
        if let text = CapsuleHUDView.signalDiagnosticText(
            viewModel.signal, microphoneName: viewModel.microphoneName) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.signal.symbolName ?? "mic")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CapsuleHUDWaveform.tint(for: viewModel.signal))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CapsuleHUDWaveform.tint(for: viewModel.signal))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.signal.announcement ?? text)
        }
    }

    /// The words the engine has committed so far, on the same second line the
    /// signal diagnostic uses while recording.
    ///
    /// The **tail** of the transcript rather than its head, because a decode
    /// that has been running for thirty seconds has already said the beginning
    /// and what a user wants to know is where it has got to. One line, truncated
    /// at the front and capped at the same width the diagnostic uses, so a long
    /// dictation cannot widen the pill.
    ///
    /// It is deliberately not an editable or selectable surface: the panel
    /// refuses mouse events for the whole session
    /// (`CapsuleHUDWindowController.acceptsMouseEvents`), because a HUD that
    /// swallowed clicks would take the top strip of the screen away from the app
    /// the user is dictating into.
    private func partialTranscriptRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 300, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .ignore)
        // Announced as what it is, so a screen reader does not read a growing
        // transcript as though the dictation were finished.
        .accessibilityLabel("Transcribed so far: \(text)")
    }

    /// "No signal · MacBook Pro Microphone", or just the state when the input has
    /// no name to give. A pure function so the wording can be asserted without a
    /// window server.
    static func signalDiagnosticText(
        _ signal: MicrophoneSignal, microphoneName: String?
    ) -> String? {
        guard let label = signal.shortLabel else { return nil }
        guard let microphoneName, !microphoneName.isEmpty else { return label }
        return "\(label) · \(microphoneName)"
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

    /// The bar colour, which carries the signal state as well as the accent.
    ///
    /// Colour never carries it *alone*: the second line beside the meter says the
    /// same thing in words, so a reader who cannot tell orange from the accent
    /// loses nothing. Defaulted so every other caller keeps the meter it had.
    var tint: Color = .accentColor

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
                    .fill(tint.opacity(opacity(forIndex: index)))
                    .frame(width: Self.barWidth, height: height(for: level))
            }
        }
        .frame(
            width: CGFloat(sampleCount) * Self.barWidth + CGFloat(sampleCount - 1) * Self.barSpacing,
            height: Self.maximumBarHeight
        )
        .accessibilityHidden(true)
    }

    /// What colour the meter draws in for one signal state.
    ///
    /// Orange for the two states that are damaging or wasting the recording, the
    /// ordinary accent otherwise. `low` is deliberately *not* orange: a quiet
    /// recording still transcribes, and painting every quiet dictation with a
    /// warning colour is how a warning stops being read.
    static func tint(for signal: MicrophoneSignal) -> Color {
        switch signal {
        case .measuring, .good, .low: return .accentColor
        case .noSignal, .clipping: return .orange
        }
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
    let quiet = CapsuleHUDViewModel()
    let polishing = CapsuleHUDViewModel()
    let complete = CapsuleHUDViewModel()
    let failed = CapsuleHUDViewModel()

    recording.beginSession(mode: CapsuleHUDMode(label: "Polish"))
    recording.beginRecording()
    for index in 0 ..< CapsuleHUDViewModel.waveformSampleCount {
        recording.pushLevel(.normalized(average: Float(index % 9) / 8))
    }
    quiet.beginSession(mode: .dictate, microphoneName: "MacBook Pro Microphone")
    quiet.beginRecording()
    for _ in 0 ..< CapsuleHUDViewModel.waveformSampleCount {
        quiet.pushLevel(.silent)
    }
    quiet.refreshSignal(at: Date().addingTimeInterval(MicrophoneSignalMonitor.graceInterval + 1))
    polishing.beginSession(mode: .dictate)
    polishing.beginRecording()
    polishing.beginPolishing(.transcribing)
    polishing.beginPolishing(.rewriting)
    complete.beginSession(mode: .dictate)
    complete.beginRecording()
    complete.complete()
    failed.beginSession(mode: .dictate)
    failed.beginRecording()
    failed.fail("No speech detected")

    return VStack(spacing: 0) {
        CapsuleHUDView(viewModel: recording)
        CapsuleHUDView(viewModel: quiet)
        CapsuleHUDView(viewModel: polishing)
        CapsuleHUDView(viewModel: complete)
        CapsuleHUDView(viewModel: failed)
    }
    .background(Color(.windowBackgroundColor))
}
