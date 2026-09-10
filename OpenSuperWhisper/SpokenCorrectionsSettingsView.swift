import SwiftUI

/// The two toggles that govern the spoken-correction stage, and the whole list
/// of what it listens for.
///
/// The list is not decoration. This stage *deletes* words, so a user has to be
/// able to see the exact phrases before they switch it on and after something
/// surprises them - the same reason the personal terms dictionary is a file they
/// can read. Everything shown here comes from `SpokenCorrectionGrammar`, so the
/// pane cannot drift from what the reducer actually does.
@MainActor
final class SpokenCorrectionsViewModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { AppPreferences.shared.spokenCorrectionsEnabled = isEnabled }
    }

    @Published var removesFillerWords: Bool {
        didSet { AppPreferences.shared.fillerWordRemovalEnabled = removesFillerWords }
    }

    init() {
        let prefs = AppPreferences.shared
        self.isEnabled = prefs.spokenCorrectionsEnabled
        self.removesFillerWords = prefs.fillerWordRemovalEnabled
    }

    func refresh() {
        let prefs = AppPreferences.shared
        if isEnabled != prefs.spokenCorrectionsEnabled { isEnabled = prefs.spokenCorrectionsEnabled }
        if removesFillerWords != prefs.fillerWordRemovalEnabled {
            removesFillerWords = prefs.fillerWordRemovalEnabled
        }
    }
}

struct SpokenCorrectionsSettingsView: View {
    @StateObject private var viewModel = SpokenCorrectionsViewModel()
    @State private var isShowingPhrases: Bool

    /// - Parameter isShowingPhrases: whether the phrase list starts open.
    ///   Collapsed in the app - the list is long and is there to be consulted
    ///   rather than read - and opened by the render test, which exists to check
    ///   that it fits the pane when it is.
    init(isShowingPhrases: Bool = false) {
        _isShowingPhrases = State(initialValue: isShowingPhrases)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spoken Corrections")
                .font(.headline)
                .foregroundColor(.primary)

            toggleRow(
                title: "Act on spoken corrections",
                caption: "Say “scratch that” to drop what you just said, “delete the last sentence”, “replace Friday with Monday”, or “start over”. A phrase only counts when you pause around it, so “I want to scratch that itch” is dictated as spoken. Entirely on-device and rule-based: no AI model, no network.",
                isOn: $viewModel.isEnabled
            )

            toggleRow(
                title: "Remove hesitation sounds",
                caption: "Drops “um”, “uh” and “erm”, and a “like” or “you know” that stands on its own between pauses. A word inside a sentence is never touched, and nothing inside quotation marks or backticks is.",
                isOn: $viewModel.removesFillerWords,
                isDisabled: !viewModel.isEnabled
            )

            Text("Corrections apply to dictation only. A dropped audio file, a regenerated transcript and a spoken Voice Edit instruction are transcribed exactly as they are. What the engine heard is always kept beside the corrected text, under “Show original” in History.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            phraseDisclosure
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .onAppear { viewModel.refresh() }
    }

    private func toggleRow(
        title: String, caption: String, isOn: Binding<Bool>, isDisabled: Bool = false
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
                .disabled(isDisabled)
        }
        .opacity(isDisabled ? 0.55 : 1)
    }

    /// Every phrase, grouped the way the reducer groups them.
    private var phraseDisclosure: some View {
        DisclosureGroup(isExpanded: $isShowingPhrases) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SpokenCorrectionsSettingsView.groups, id: \.title) { group in
                    phraseGroup(group)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replace")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    chips(SpokenCorrectionsSettingsView.replacementExamples)
                }
                if viewModel.removesFillerWords {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hesitation sounds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        chips(SpokenCorrectionGrammar.hesitationSounds.sorted())
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("What Kongweh listens for")
                .font(.subheadline)
        }
        .accessibilityHint("Lists every phrase that is treated as a correction")
    }

    private func phraseGroup(_ group: PhraseGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title)
                .font(.caption)
                .foregroundColor(.secondary)
            chips(
                SpokenCorrectionGrammar.triggers
                    .filter { $0.kind == group.kind }
                    .map(\.phrase))
        }
    }

    private func chips(_ phrases: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(phrases, id: \.self) { phrase in
                Text(phrase)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07)))
            }
        }
    }

    struct PhraseGroup {
        let title: String
        let kind: SpokenCorrectionKind
    }

    /// The headings, in the order the pane shows them. Switched exhaustively in
    /// the test so a new kind has to be given a heading rather than quietly
    /// vanishing from the list a user is asked to trust.
    static let groups: [PhraseGroup] = [
        PhraseGroup(title: "Drop what you just said", kind: .deletePhrase),
        PhraseGroup(title: "Drop the last sentence", kind: .deleteSentence),
        PhraseGroup(title: "Start again", kind: .startOver),
    ]

    /// Spelled as a person would say them, because the two halves are the
    /// speaker's own words and a bare "replace … with …" reads as a template.
    static let replacementExamples = [
        "replace Friday with Monday", "change three to four", "把星期五改成星期一",
    ]
}
