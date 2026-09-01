import SwiftUI

/// The bilingual path, said out loud under the engine rows it is about.
///
/// Mixing English into Mandarin - `把 PR 開到 feature/login 再 @James` - is ordinary
/// speech for this app's users, and it is the one thing three of the four local
/// engines cannot do at all. No arrangement of four names carries that, so the
/// pane says it.
///
/// Deliberately a **statement rather than an offer**: it takes no selected engine
/// and carries no Switch button, because the rows above it are one tap each and
/// this is a fact about them rather than a nag. It is shown to everyone for the
/// same reason - a user who has not started mixing languages yet is exactly the
/// one who does not know the app can.
///
/// Both sentences come from `EngineCatalog`, so this cannot become a second copy
/// of the copy, and the model name the FunASR licence requires cannot be dropped
/// here while it survives in the picker. Split out as its own row for the same
/// reason `EngineShortcutHintRow` is: `BilingualEngineHintRenderTests` draws it
/// offscreen and reads it back, which is the only way to prove the sentence
/// reaches the pixels rather than only the string table.
///
/// `docs/bilingual-dictation.md` is the whole story.
struct BilingualEngineHintRow: View {

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "character.bubble")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(EngineCatalog.bilingualHint)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(EngineCatalog.bilingualHintDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Bilingual engine hint") {
    BilingualEngineHintRow()
        .padding()
        .frame(width: 520)
}
