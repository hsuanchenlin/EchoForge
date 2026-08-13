import KeyboardShortcuts
import SwiftUI

/// The hint as it is drawn, given a binding.
///
/// Split from the view that resolves the binding so the row can be rendered - and
/// read back - without a preferences domain: `EngineShortcutHintRenderTests` draws
/// both of its states offscreen, which is the only way to prove the sentence
/// reaches the pixels.
struct EngineShortcutHintRow: View {

    /// How the bound shortcut reads - "⌥M" - or `nil` when the user has cleared it.
    let shortcut: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundColor(.accentColor)
            Text(EngineShortcutHint.text(shortcut: shortcut))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
    }
}

/// The engine shortcut, said once in the pane where engines are chosen.
///
/// It reads the binding rather than printing ⌥M, and it reads it again every time
/// the pane appears - which covers the one way it can go stale inside a running
/// Settings window: changing the key in the Shortcuts tab and coming back here.
/// Reading is all it does; see `EngineShortcutHint` for why that is a rule and not
/// an implementation detail.
struct EngineShortcutHintView: View {

    @State private var shortcut: String?

    var body: some View {
        EngineShortcutHintRow(shortcut: shortcut)
            .onAppear { shortcut = Self.boundShortcut() }
    }

    /// How the shortcut currently reads, or `nil` when the user has cleared it.
    /// `getShortcut` returns the stored binding, which for an untouched install is
    /// the default the app persisted at first launch.
    @MainActor
    private static func boundShortcut() -> String? {
        KeyboardShortcuts.getShortcut(for: .cycleEngine)?.description
    }
}

#Preview("Engine shortcut hint") {
    VStack(alignment: .leading, spacing: 12) {
        EngineShortcutHintRow(shortcut: "⌥M")
        EngineShortcutHintRow(shortcut: nil)
    }
    .padding()
    .frame(width: 520)
}
