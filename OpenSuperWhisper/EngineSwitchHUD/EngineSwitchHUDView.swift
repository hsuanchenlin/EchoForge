import SwiftUI

/// The pill the engine shortcut puts on screen: which engine dictation is on now.
///
/// Drawn like the dictation capsule - same material, same hairline border, same
/// 40 pt height - because it appears in the same place and a second visual
/// language for a second kind of pill would read as a second app. It is not the
/// capsule and cannot become one: nothing here follows a dictation, and
/// `IndicatorWindowManager`'s one-overlay-per-session rule is about the two
/// presentations of a *session*, which this is not (see `docs/capsule-hud.md`).
struct EngineSwitchHUDView: View {

    /// Geometry shared with `EngineSwitchHUD`. Wider than the capsule's window:
    /// the longest thing this says is an engine name and a model name together -
    /// "Engine: Paraformer-large (zh) after this dictation" - and the window has to
    /// hold the pill plus the transparent margin its shadow is drawn into.
    static let capsuleHeight: CGFloat = 40
    static let windowSize = CGSize(width: 480, height: 96)

    @ObservedObject var viewModel: EngineSwitchHUDViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let announcement = viewModel.announcement {
                pill(announcement)
            } else {
                // Never on screen - the controller orders the panel out - but a
                // hosting view outliving the message must draw nothing rather
                // than an empty pill.
                Color.clear
            }
        }
        // The root view must fill the panel: a hosting view left to size itself
        // shrinks the window to the pill, and the window bounds then clip the
        // pill's shadow.
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    private func pill(_ announcement: EngineSwitchAnnouncement) -> some View {
        let message = announcement.text
        return HStack(spacing: 10) {
            // A cloud for the one engine that is not on this Mac. The name and the
            // model are already in the message; the glyph is what makes "this
            // dictation is going to a provider" readable in the second the pill is
            // up, the same signal Settings gives that engine.
            Image(systemName: announcement.isCloud ? "cloud" : "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.capsuleHeight)
        .background {
            Capsule(style: .continuous)
                .fill(Material.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 10, y: 3)
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel(message)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }
}

#Preview("Engine overlay") {
    let switched = EngineSwitchHUDViewModel()
    let deferred = EngineSwitchHUDViewModel()
    let only = EngineSwitchHUDViewModel()

    switched.show(EngineSwitchAnnouncement(text: "Engine: Cloud - whisper-1", isCloud: true))
    deferred.show(
        EngineSwitchAnnouncement(text: "Engine: SenseVoice-Small after this dictation", isCloud: false)
    )
    only.show(
        EngineSwitchAnnouncement(text: "Whisper - large-v3-turbo is the only engine ready", isCloud: false)
    )

    return VStack(spacing: 0) {
        EngineSwitchHUDView(viewModel: switched)
        EngineSwitchHUDView(viewModel: deferred)
        EngineSwitchHUDView(viewModel: only)
    }
    .background(Color(.windowBackgroundColor))
}
