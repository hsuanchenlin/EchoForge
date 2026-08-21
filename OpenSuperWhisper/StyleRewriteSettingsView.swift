import SwiftUI

/// The three stored values behind the Style pane.
///
/// Its own object rather than more properties on `SettingsViewModel` because
/// nothing here touches an engine, a model file or a download - the pane is
/// self-contained, and so is what it writes.
@MainActor
final class StyleRewriteSettingsModel: ObservableObject {

    @Published var isEnabled: Bool {
        didSet {
            AppPreferences.shared.styleRewriteEnabled = isEnabled
            if isEnabled { prewarmIfPossible() }
        }
    }

    @Published var selectedStyleID: String {
        didSet { AppPreferences.shared.styleRewriteStyleID = selectedStyleID }
    }

    @Published var customPrompt: String {
        didSet { AppPreferences.shared.styleRewriteCustomPrompt = customPrompt }
    }

    /// Read once when the pane opens. It can change while the app runs - Apple
    /// Intelligence finishes downloading, the user switches it off - so the pane
    /// refreshes it on appear rather than caching it for the session.
    @Published private(set) var availability: StyleRewriteAvailability

    init() {
        let preferences = AppPreferences.shared
        isEnabled = preferences.styleRewriteEnabled
        selectedStyleID = preferences.styleRewriteStyleID
        customPrompt = preferences.styleRewriteCustomPrompt
        availability = StyleRewriterFactory.availability()
    }

    func refreshAvailability() {
        availability = StyleRewriterFactory.availability()
    }

    var selectedStyle: StyleRewriteStyle {
        StyleRewriteCatalog.style(forStoredID: selectedStyleID)
    }

    /// The configuration the pipeline would use, as configured right now.
    var configuration: StyleRewriteConfiguration {
        StyleRewriteConfiguration(
            isEnabled: isEnabled, style: selectedStyle, customPrompt: customPrompt
        )
    }

    /// The configuration the preview uses: the same one, always enabled.
    ///
    /// Trying a style before committing to it is the point of the preview, and
    /// requiring the toggle first would make the only way to find out what a
    /// style does be to turn it on and dictate something.
    var previewConfiguration: StyleRewriteConfiguration {
        StyleRewriteConfiguration(
            isEnabled: true, style: selectedStyle, customPrompt: customPrompt
        )
    }

    /// True when the selected style cannot run as configured - the custom style
    /// with nothing written in it.
    var needsCustomPrompt: Bool {
        selectedStyle.isCustom && customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prewarmIfPossible() {
        StyleRewriterFactory.prewarmIfAvailable()
    }
}

/// Runs one rewrite against text the user typed, so a style or a custom prompt
/// can be judged before it is turned loose on dictation.
@MainActor
final class StyleRewritePreviewModel: ObservableObject {

    static let sampleText = """
    um so I think we should ship the thing on friday, and uh the budget is \
    like $2,500 for the whole quarter, does that work for you
    """

    @Published var input: String = StyleRewritePreviewModel.sampleText
    @Published private(set) var isRunning = false
    @Published private(set) var result: StyledTranscript?

    func run(configuration: StyleRewriteConfiguration, languageCode: String) async {
        isRunning = true
        result = nil
        defer { isRunning = false }

        // Deliberately the injectable entry point, with the real backend: the
        // preview is the one place that should show exactly what the pipeline
        // would do, guard verdict included.
        result = await StyleRewriteService.apply(
            to: .unchanged(input),
            configuration: configuration,
            languageCode: languageCode,
            availability: StyleRewriterFactory.availability(),
            rewriter: StyleRewriterFactory.makeRewriter(),
            fallbackChineseVariant: AppPreferences.shared.chineseOutputScript
        )
    }

    func reset() {
        result = nil
    }
}

/// The Style tab: whether dictation is rewritten, into what, and what that
/// looks like.
struct StyleRewriteSettingsView: View {
    @StateObject private var model = StyleRewriteSettingsModel()
    @StateObject private var preview = StyleRewritePreviewModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                availabilityRow
                enableToggle

                if model.isEnabled {
                    styleList
                    if model.selectedStyle.isCustom {
                        customPromptEditor
                    }
                    // Below the style list, because it is an exception to the
                    // choice made there rather than a second way to make it.
                    AppStyleMappingSettingsView()
                    previewSection
                }

                footer
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .onAppear { model.refreshAvailability() }
        .onDisappear { previewTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Style Rewriting")
                .font(.headline)
            Text("Rewrites what you dictate into a style you choose, on this Mac. Transcription, the dictionary and spacing are unaffected.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var availabilityRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.availability.canRun ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundColor(model.availability.canRun ? .secondary : .orange)
                .font(.system(size: 12))
            Text(model.availability.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(ThemePalette.panelSurface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var enableToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Rewrite dictation with a style", isOn: $model.isEnabled)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
            Text("Off by default. Rewriting is the only step that can change what your words mean, so when it is unavailable, too slow, or its result fails the safety checks, your transcript is used exactly as transcribed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Styles

    private var styleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 0) {
                ForEach(Array(StyleRewriteCatalog.styles.enumerated()), id: \.element.id) { index, style in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    styleRow(style)
                }
            }
            .background(ThemePalette.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
            )
        }
    }

    private func styleRow(_ style: StyleRewriteStyle) -> some View {
        Button {
            model.selectedStyleID = style.id
            preview.reset()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.selectedStyleID == style.id
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(model.selectedStyleID == style.id ? .accentColor : .secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(style.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customPromptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your instruction")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $model.customPrompt)
                .font(.system(size: 12))
                .frame(height: 70)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
                )
            Text("Written in the imperative, as one or two sentences - for example \"Rewrite this as a short email to a colleague, keeping every date and figure.\" The safety checks apply to your prompt exactly as they do to the built-in styles.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.needsCustomPrompt {
                Label("Nothing is rewritten until you write an instruction here.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try it")
                .font(.subheadline.weight(.medium))

            TextEditor(text: $preview.input)
                .font(.system(size: 12))
                .frame(height: 60)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button(preview.isRunning ? "Rewriting…" : "Rewrite") {
                    previewTask?.cancel()
                    previewTask = Task {
                        await preview.run(
                            configuration: model.previewConfiguration,
                            languageCode: AppPreferences.shared.whisperLanguage
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(preview.isRunning
                          || model.needsCustomPrompt
                          || preview.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if preview.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if let result = preview.result {
                previewResult(result)
            }
        }
    }

    /// The preview's result, as a comparison with what was typed in.
    ///
    /// A style is judged by what it changed, and the result on its own does not
    /// say that: read next to a sample the user wrote seconds ago, "we should
    /// ship on Friday" looks the same whether the style dropped two filler words
    /// or rewrote the sentence. So the words the rewrite dropped stay on screen,
    /// struck through, in the place they were said. When the rewrite declined or
    /// changed nothing there is no comparison to draw and the text stands alone.
    @ViewBuilder
    private func previewResult(_ result: StyledTranscript) -> some View {
        let segments = TextDiffUtil.compare(
            original: result.transcript, revised: result.final
        )
        let showsComparison = TextDiffUtil.hasVisibleChanges(in: segments)

        VStack(alignment: .leading, spacing: 6) {
            Group {
                if showsComparison {
                    TextDiffView(segments: segments)
                } else {
                    Text(result.final)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(ThemePalette.panelSurface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if showsComparison {
                TextDiffLegend()
            }

            // The reason is the useful half when a rewrite is declined: it is
            // the same check the dictation path runs, so a custom prompt can be
            // fixed here rather than by dictating and wondering.
            if let explanation = result.status.explanation {
                Label(explanation, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if result.status.didRewrite {
                Label("Rewritten with \(model.selectedStyle.name).", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Your original transcript is kept with every recording. Open a row in the history and choose \"Show original\" to see or copy exactly what was transcribed, or \"Compare\" to see what changed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
