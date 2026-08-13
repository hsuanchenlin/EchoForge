import Foundation

/// The one place a user's engine choice is carried out.
///
/// Choosing an engine is never just a preference write: the language may have to
/// come with it, the cloud engine has bookkeeping of its own
/// (`CloudTranscriptionSelection`), the running service has to be told, and every
/// surface showing the engine has to catch up. There are now three ways to make
/// that choice - the Settings picker, the Cloud pane's toggle and the engine
/// shortcut - and three copies of that sequence would be three chances for one of
/// them to do four of the five things.
///
/// So this is the sequence, once. It is deliberately *not* a second source of
/// truth: what is persisted is still `AppPreferences.selectedEngine` and nothing
/// else, and this only decides what has to happen alongside writing it.
@MainActor
enum EngineSelectionCommand {

    /// Selects `engine` as the engine the user wants.
    ///
    /// The steps, in this order and for these reasons:
    ///
    /// 1. **The cloud engine goes through `CloudTranscriptionSelection`**, so the
    ///    engine to come back to is remembered on the way in. Choosing it here
    ///    does not grant consent and cannot: `CloudAccess` refuses the call
    ///    without one, which is why the only callers that offer it are the Cloud
    ///    pane (which shows the sheet) and the shortcut (which only offers the
    ///    cloud once consent is already recorded).
    /// 2. **The language follows the engine when it has to.** An engine paired
    ///    with a language it only mis-transcribes is the one pairing this app
    ///    never leaves a user in - the same rule onboarding, Settings and
    ///    `EngineConfiguration.resolve` all apply.
    /// 3. **`.appPreferencesLanguageChanged` is posted only when the language
    ///    actually moved**, and before the reload. Only when it moved because that
    ///    is what the notification means, and every observer of it - the menu bar's
    ///    language submenu, `TranscriptionService`'s re-resolve - has nothing to do
    ///    otherwise. Before the reload because the re-resolve it triggers is
    ///    deliberately download-free and must not be the last word: choosing an
    ///    engine is exactly the request to fetch what it needs.
    /// 4. **`.selectedEngineChanged` is posted** so a Settings window that is open
    ///    shows the engine that is actually selected. The shortcut can be pressed
    ///    with the pane in front of the user.
    /// 5. **The service is reloaded last**, with downloads allowed, which is what
    ///    makes choosing an engine non-modal: `EngineSelector` keeps dictation on
    ///    whatever is ready while the choice is prepared.
    static func select(_ engine: EngineKind, preferences: AppPreferences = .shared) {
        guard preferences.selectedEngine != engine else { return }

        if engine.usesCloudProvider {
            CloudTranscriptionSelection.enable(preferences: preferences)
        } else {
            preferences.selectedEngine = engine
        }

        let supported = LanguageUtil.supportedLanguages(
            engine: engine,
            fluidAudioModelVersion: preferences.fluidAudioModelVersion
        )
        if !supported.contains(preferences.whisperLanguage) {
            preferences.whisperLanguage = LanguageUtil.fallbackLanguage(engine: engine)
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
        NotificationCenter.default.post(name: .selectedEngineChanged, object: nil)

        TranscriptionService.shared.reloadEngine()
    }
}
