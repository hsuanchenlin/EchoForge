import Foundation

/// Whether the rewriting stage is running right now, for the surfaces that say
/// what the app is doing.
///
/// It exists because the wait after a dictation is two different waits - the
/// engine turning audio into words, then the model rewriting them - and a HUD
/// that calls both "transcribing" is telling the user the second one is not
/// happening. `StyleRewriteService` publishes here and reads nothing back: no
/// decision in that file depends on this value, so the stage's contract - it can
/// only improve a transcript or leave it alone - is untouched.
///
/// One flag rather than a count because transcriptions are serialized
/// (`TranscriptionService.transcribeAudio` waits for the previous one), so there
/// is never more than one rewrite in flight.
@MainActor
final class StyleRewriteActivity: ObservableObject {
    static let shared = StyleRewriteActivity()

    @Published private(set) var isRewriting = false

    init() {}

    func begin() {
        isRewriting = true
    }

    func end() {
        isRewriting = false
    }
}
