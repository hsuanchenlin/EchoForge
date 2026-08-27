import AppKit
import SwiftUI

/// One recording, as a card in the main window's history.
///
/// The card is the app's only durable surface, so it has to answer four
/// questions at a glance and in either colour scheme: what produced this row
/// (`HistoryProvenanceBadge`), when and how long, what was heard, and - while
/// something is still running - how far along it is. `HistoryRowMetrics` decides
/// how those are arranged; this view decides what they say.
///
/// Two rules carry the layout. Nothing here hard-codes a padding or an icon
/// size that `HistoryRowMetrics` does not name, so both tiers are designed in
/// one place rather than drifting apart in branches. And nothing may lay itself
/// out wider than the row is offered - every multi-line string is
/// `fixedSize(horizontal: false, vertical: true)` and every one-line one either
/// truncates deliberately or sits inside a `ViewThatFits` that stacks instead.
/// `HistoryRowRenderTests` draws both tiers and reads the pixels back.
struct RecordingRow: View {
    let recording: Recording
    let searchQuery: String
    let onDelete: () -> Void
    let onRegenerate: () -> Void

    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var showTranscription = false
    @State private var showOriginal = false
    @State private var showComparison = false
    /// Compared once, when the comparison is opened.
    ///
    /// The row rebuilds on hover, and a transcript of a long dictation is a lot
    /// of words to line up against another one; doing it in `body` would put
    /// that work behind every mouse move across the history.
    @State private var comparisonSegments: [TextDiffSegment] = []
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.historyRowMetrics) private var metrics
    /// Hover is a pointer affordance and nothing else. With VoiceOver on there
    /// is no pointer, so the actions are simply present - a button that exists
    /// only while a mouse is over it is a button a VoiceOver user does not have.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    // MARK: - What the row is

    /// What the engine heard, when post-processing changed it into something
    /// else.
    ///
    /// This is the half of the rewriting feature that makes it safe to use: the
    /// styled text is what the app pasted, and the words the user actually said
    /// are still here, one click away, in the row next to it.
    private var originalTranscription: String? {
        guard let original = recording.rawTranscription, !original.isEmpty,
              original != recording.transcription else { return nil }
        return original
    }

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    private var isPending: Bool {
        recording.status == .pending || recording.status == .converting
            || recording.status == .transcribing
    }

    private var isRegenerating: Bool {
        recording.isRegeneration && isPending
    }

    private var hasFailed: Bool {
        recording.status == .failed
    }

    private var statusText: String {
        switch recording.status {
        case .pending: return "In queue..."
        case .converting: return "Converting..."
        case .transcribing: return "Transcribing..."
        case .completed: return ""
        case .failed: return "Failed"
        }
    }

    private var displayText: String {
        if recording.transcription.isEmpty
            || recording.transcription == "Starting transcription..."
            || recording.transcription == "In queue..."
        {
            return ""
        }
        return recording.transcription
    }

    /// Whether the quick actions are on screen at all.
    ///
    /// Hover is the ordinary way in. The exceptions are states where an action
    /// is the point of the row rather than a convenience: audio that is playing
    /// needs its stop button, and a queued or failed row needs its delete.
    private var showsActions: Bool {
        isHovered || isPlaying || voiceOverEnabled || isPending || hasFailed
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            header
            body(for: recording)
            footer
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .shadow(
            color: ThemePalette.cardShadow(colorScheme, elevated: isHovered),
            radius: isHovered ? 10 : 4,
            x: 0,
            y: isHovered ? 4 : 1
        )
        .contentShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering }
        }
        .animation(.easeInOut(duration: 0.2), value: showsActions)
        .animation(.easeInOut(duration: 0.2), value: isRegenerating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.label, action: action.perform)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .fill(ThemePalette.cardSurface(colorScheme, hovered: isHovered))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .strokeBorder(
                ThemePalette.cardStroke(colorScheme, hovered: isHovered, failed: hasFailed),
                lineWidth: 1
            )
    }

    /// One sentence for VoiceOver, before the row's own elements are read.
    ///
    /// Named parts only - the kind, when, how long - and never the transcript,
    /// which is its own selectable element further in and can be thousands of
    /// words long.
    private var accessibilitySummary: String {
        var parts = [recording.provenance.kind.accessibilityLabel]
        parts.append(HistoryTimestamp.relative(for: recording.timestamp))
        parts.append(TextUtil.formatDuration(recording.duration))
        if hasFailed { parts.append("Transcription failed") }
        if isPending { parts.append(statusText) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Header

    /// The badge and the metadata chips.
    ///
    /// `ViewThatFits` rather than a tier branch alone: the widest badge on this
    /// row ("YouTube command - not opened") plus two chips does not fit on one
    /// line at every width above the threshold or at every dynamic type size,
    /// and the honest answer to that is to stack rather than to truncate a
    /// timestamp into nothing.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if metrics.stacksMetadata {
                stackedHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        badgePill
                        Spacer(minLength: 8)
                        metadataChips
                    }
                    stackedHeader
                }
            }

            if let detail = recording.provenance.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            badgePill
            metadataChips
        }
    }

    private var badgePill: some View {
        HistoryProvenanceBadge(provenance: recording.provenance, showsDetail: false)
    }

    private var metadataChips: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let relativeTimestamp = HistoryTimestamp.relative(
                for: recording.timestamp, now: context.date)
            HStack(spacing: 6) {
                HistoryMetadataChip(
                    systemImage: "clock",
                    text: relativeTimestamp,
                    accessibilityLabel: "Recorded \(relativeTimestamp)"
                )
                HistoryMetadataChip(
                    systemImage: "waveform",
                    text: TextUtil.formatDuration(recording.duration),
                    accessibilityLabel: "Duration \(TextUtil.formatDuration(recording.duration))",
                    isMonospacedDigit: true
                )
            }
            .fixedSize()
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            if isPending, !isRegenerating {
                pendingSection
            }

            if hasFailed {
                failureSection
            } else if !displayText.isEmpty {
                transcriptSection
            } else if !isPending {
                Text("No speech detected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A queued or running transcription that is not a regeneration: the file it
    /// came from, and how far along it is.
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sourceFileName = recording.sourceFileName {
                Text(sourceFileName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            progressStrip
        }
    }

    /// The ring, the percentage and the phase, as one line.
    private var progressStrip: some View {
        HStack(spacing: 8) {
            TranscriptionProgressRing(
                progress: recording.progress,
                isIndeterminate: recording.status == .pending
            )

            if recording.status != .pending {
                Text("\(Int(recording.progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: recording.progress)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            recording.status == .pending
                ? statusText
                : "\(statusText) \(Int(recording.progress * 100)) percent")
    }

    /// A dictation that failed, and - because `DictationFailureOutcome` keeps
    /// the recording - whatever text there was.
    ///
    /// The badge is the clean part: one line, one colour, and the reason under
    /// it in the row's ordinary secondary style rather than in red, so a long
    /// explanation stays readable instead of shouting.
    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Transcription failed")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(ThemePalette.failureText(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(ThemePalette.failureFill(colorScheme))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Transcription failed")

            if !recording.transcription.isEmpty {
                Text(recording.transcription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TranscriptionView(
                    transcribedText: displayText,
                    searchQuery: searchQuery,
                    isExpanded: $showTranscription
                )

                if isRegenerating {
                    ShimmerOverlay()
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
            }

            if let original = originalTranscription {
                originalTranscriptionSection(original)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(ThemePalette.cardStroke(colorScheme, hovered: false, failed: false))

            if metrics.wrapsActionBarWhenTight {
                // The bar stays on the footer row while it fits and drops to a
                // line of its own when it does not - which at this width is
                // what a regeneration's progress strip does to it.
                ViewThatFits(in: .horizontal) {
                    inlineFooter
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            footerTimestamp
                            if isRegenerating { regenerationStrip }
                            Spacer(minLength: 0)
                        }
                        if showsActions { actionBar }
                    }
                }
            } else {
                inlineFooter
            }
        }
    }

    private var inlineFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            footerTimestamp
            if isRegenerating { regenerationStrip }
            Spacer(minLength: 8)
            if showsActions { actionBar }
        }
    }

    private var actionBar: some View {
        HStack(spacing: metrics.actionSpacing) {
            Spacer(minLength: 0)
            quickActions
        }
        .transition(.opacity)
    }

    private var footerTimestamp: some View {
        Group {
            if metrics.showsFullDateInFooter {
                Text(HistoryTimestamp.absolute(for: recording.timestamp))
            } else {
                Text(recording.timestamp, style: .time)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityLabel(HistoryTimestamp.absolute(for: recording.timestamp))
    }

    /// A regeneration reuses the row it is replacing, so its progress belongs
    /// beside the timestamp rather than above the old transcript.
    private var regenerationStrip: some View {
        HStack(spacing: 6) {
            TranscriptionProgressRing(
                progress: recording.progress,
                isIndeterminate: recording.status == .pending
            )
            if recording.status != .pending {
                Text("\(Int(recording.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: recording.progress)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Regenerating, \(statusText)")
    }

    /// The row's actions, as data.
    ///
    /// One list, read twice: once to draw the hover bar and once to register
    /// the same actions with VoiceOver. Hover is a pointer affordance and a
    /// VoiceOver user has no pointer, so a bar that was the only way to reach
    /// delete would be no way at all for them - and two hand-written copies of
    /// the same four actions is how one of them silently loses a case.
    private var actions: [HistoryRowAction] {
        HistoryRowActionKind.available(for: recording.status).map { kind in
            HistoryRowAction(
                kind: kind,
                systemImage: kind.symbolName(isPlaying: isPlaying),
                label: kind.label(isPlaying: isPlaying),
                tint: kind == .play && isPlaying
                    ? ThemePalette.failureText(colorScheme) : nil,
                perform: { perform(kind) })
        }
    }

    private func perform(_ kind: HistoryRowActionKind) {
        switch kind {
        case .play:
            if isPlaying {
                audioRecorder.stopPlaying()
            } else {
                audioRecorder.playRecording(url: recording.url)
            }
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recording.transcription, forType: .string)
        case .regenerate:
            onRegenerate()
        case .delete:
            if isPlaying { audioRecorder.stopPlaying() }
            onDelete()
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        ForEach(actions) { action in
            HistoryActionButton(action: action, metrics: metrics)
        }
    }

    // MARK: - The original, and the comparison

    /// The two collapsed disclosures under a post-processed row: what the engine
    /// heard, and what post-processing did to it.
    ///
    /// Both are collapsed by default because the styled text is the answer the
    /// user asked for. "Show original" is present at all because it is the only
    /// copy of what they said; "Compare" is what turns that copy into an answer
    /// to the question the row actually raises - which of these words are mine?
    @ViewBuilder
    private func originalTranscriptionSection(_ original: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { disclosureControls(original) }
                VStack(alignment: .leading, spacing: 6) { disclosureControls(original) }
            }

            if showOriginal {
                Text(original)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ThemePalette.insetSurface(colorScheme))
                    )
                    .transition(.opacity)
            }

            if showComparison {
                VStack(alignment: .leading, spacing: 6) {
                    TextDiffView(segments: comparisonSegments, font: .caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ThemePalette.insetSurface(colorScheme))
                        )

                    if TextDiffUtil.hasVisibleChanges(in: comparisonSegments) {
                        TextDiffLegend()
                    } else {
                        // CJK spacing is a real post-processing change that the
                        // comparison deliberately does not mark up, and a panel
                        // with nothing struck through in it and no explanation
                        // reads as a bug.
                        Label("Only spacing or capitalisation changed here.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
        }
        // A regeneration replaces the transcript underneath an open comparison
        // - sometimes only the raw side, when the final text lands unchanged -
        // and a comparison against text the row no longer shows is worse than
        // none.
        .onChange(of: recording.transcription) { _, _ in
            refreshComparison(against: original)
        }
        .onChange(of: recording.rawTranscription) { _, _ in
            refreshComparison(against: original)
        }
    }

    @ViewBuilder
    private func disclosureControls(_ original: String) -> some View {
        HStack(spacing: 12) {
            disclosureButton(
                title: showOriginal ? "Hide original" : "Show original",
                isExpanded: showOriginal,
                help: "What the transcription engine heard, before post-processing"
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { showOriginal.toggle() }
            }

            disclosureButton(
                title: showComparison ? "Hide comparison" : "Compare",
                isExpanded: showComparison,
                help: "The original with the words post-processing dropped struck through"
            ) {
                if !showComparison {
                    comparisonSegments = TextDiffUtil.compare(
                        original: original, revised: displayText)
                }
                withAnimation(.easeInOut(duration: 0.15)) { showComparison.toggle() }
            }

            if showOriginal {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(original, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy the original")
                .accessibilityLabel("Copy the original transcription")
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
    }

    private func refreshComparison(against original: String) {
        guard showComparison else { return }
        comparisonSegments = TextDiffUtil.compare(original: original, revised: displayText)
    }

    private func disclosureButton(
        title: String, isExpanded: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}

// MARK: - Parts

/// One piece of metadata, as a pill.
///
/// Fixed to one line and sized to its own text: a chip that wrapped would push
/// the row's height around as the clock ticked past "an hour ago".
struct HistoryMetadataChip: View {
    let systemImage: String
    let text: String
    var accessibilityLabel: String
    var isMonospacedDigit: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(isMonospacedDigit ? .caption2.monospacedDigit() : .caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(ThemePalette.chipSurface(colorScheme))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The ring beside a transcription that is still running.
///
/// Two behaviours, one shape: a determinate trim once the engine reports bytes,
/// and a rotating arc while the row is only queued. A queued row used to show a
/// static clock glyph, which is indistinguishable from a row that is stuck.
struct TranscriptionProgressRing: View {
    let progress: Float
    var isIndeterminate: Bool = false
    var diameter: CGFloat = 15
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2)

            Circle()
                .trim(from: 0, to: isIndeterminate ? 0.25 : CGFloat(progress))
                .stroke(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(isIndeterminate ? (spin ? 270 : -90) : -90))
                .animation(
                    isIndeterminate ? nil : .linear(duration: 0.1),
                    value: progress
                )
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard isIndeterminate else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// One of the row's quick actions.
///
/// A square hit target rather than a bare glyph, because the glyphs are small
/// and sit next to each other; the tinted background appears on hover so the
/// bar reads as a bar rather than as four floating symbols.
struct HistoryActionButton: View {
    let action: HistoryRowAction
    let metrics: HistoryRowMetrics

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var foreground: Color {
        if let tint = action.tint { return tint }
        if action.isDestructive, isHovered { return ThemePalette.failureText(colorScheme) }
        return .secondary
    }

    var body: some View {
        Button(action: action.perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: metrics.actionIconSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: metrics.actionHitTarget, height: metrics.actionHitTarget)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered
                              ? ThemePalette.chipSurface(colorScheme)
                              : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(action.label)
        .accessibilityLabel(action.label)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

/// One of the four things a history row can do to itself.
///
/// A value rather than a view so the hover bar and the VoiceOver action list
/// are two readings of one list. See `RecordingRow.actions`.
struct HistoryRowAction: Identifiable {
    let kind: HistoryRowActionKind
    let systemImage: String
    let label: String
    var tint: Color? = nil
    let perform: () -> Void

    var id: String { kind.rawValue }
    var isDestructive: Bool { kind.isDestructive }
}
