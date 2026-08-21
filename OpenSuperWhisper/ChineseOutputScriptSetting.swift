import SwiftUI

/// The Chinese output script control, as it appears in the Language card of
/// Settings → Transcription.
///
/// Its own view rather than another block inside `Settings.swift`'s pane so that
/// `ChineseOutputScriptSettingRenderTests` can draw the real thing and read the
/// pixels back: the two script names are the only part of this app's interface
/// whose meaning *is* the glyphs, and "繁體" rendered as "繁体" would be a control
/// that contradicts itself while every string test still passed.
///
/// See `ChineseScriptNormalizer` and `docs/chinese-script.md` for what it
/// decides. It is offered only where it does something - Chinese, and
/// auto-detect, which may turn out to be Chinese - and the caller makes that
/// decision with `ChineseScriptVariant.mayBeChinese(languageCode:)`.
struct ChineseOutputScriptSetting: View {

    @Binding var script: ChineseScriptVariant

    /// Each option is named in its own script, which is the shortest possible
    /// demonstration of what it does and the only label a reader who has both
    /// installed cannot misread.
    static let traditionalLabel = "Traditional (繁體)"
    static let simplifiedLabel = "Simplified (简体)"

    static let title = "Chinese Output Script"

    /// Says what changes and, as importantly, what does not: this is an output
    /// setting, and a user must not read it as a switch that makes the app
    /// listen for Chinese or reach back into anything already recorded.
    static let explanation =
        "Chinese transcriptions are written in this script, whichever one the engine returns. "
            + "Other languages, your dictionary and History are not affected."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title)
                .font(.subheadline)

            Picker(Self.title, selection: $script) {
                Text(Self.traditionalLabel).tag(ChineseScriptVariant.traditional)
                Text(Self.simplifiedLabel).tag(ChineseScriptVariant.simplified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Self.title)
            .accessibilityHint(Self.explanation)

            Text(Self.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
