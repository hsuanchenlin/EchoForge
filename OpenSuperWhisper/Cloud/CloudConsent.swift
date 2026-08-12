import Foundation

/// The one-time explanation a user reads before anything they say leaves their
/// Mac, and the record that they read it.
///
/// It exists because the difference between "the setting was on" and "the person
/// agreed" is the whole of this feature's ethics. Every other setting in this app
/// changes what happens to the user's words on their own machine; these two send
/// them to a company. So the toggle is not the consent - accepting this is, the
/// acceptance is stored, and `CloudAccess` refuses the feature without it even if
/// the enable flag says otherwise.
///
/// Consent is per feature (`CloudFeature`) because the two send different things,
/// and it survives turning the feature off and on again: asking twice would train
/// people to click through it, which is the opposite of what it is for.
enum CloudConsent {

    /// The wording, kept here rather than in the view so it can be asserted.
    ///
    /// Four requirements, and `CloudConsentCopyTests` pins them: it names what
    /// leaves the Mac, it names where it goes, it says the choice can be
    /// undone, and it links the full disclosure (`docsURL`) - the sheet covers
    /// the pane footer that otherwise carries that link, at exactly the moment
    /// the user is deciding. Nothing here is hedged - "may be transmitted to
    /// third-party services" is how a privacy policy avoids saying that a
    /// company gets a recording of your voice.
    struct Copy: Equatable {
        let title: String
        let body: String
        let points: [String]
        let learnMore: String
        let confirm: String
        let cancel: String
    }

    /// The page whose table says exactly what is sent, when, and where. One URL
    /// for the sheet and the pane footer, so the two cannot drift apart.
    static let docsURL = URL(
        string: "https://github.com/hsuanchenlin/EchoForge/blob/master/docs/cloud-api.md"
    )!

    static func copy(for feature: CloudFeature, host: String, isLoopback: Bool) -> Copy {
        // A provider running on this Mac is a different disclosure, and pretending
        // otherwise would make the real warning less believable when it matters.
        let destination = isLoopback
            ? "the server you are running at \(host), on this Mac"
            : "\(host), a company outside your control"

        var points = [
            "EchoForge will upload \(feature.whatLeavesTheDevice) to \(destination).",
            "What happens to it there - how long it is kept, whether it trains a model - "
                + "is that provider's decision, not EchoForge's. Read their policy.",
            "Your API key is stored in your Mac's Keychain and sent only to this provider.",
            "You can switch back to on-device at any time in Settings → Cloud, and nothing "
                + "is uploaded while it is off.",
        ]
        if isLoopback {
            points[1] = "Because that address is on this Mac, the data does not leave it - "
                + "but it does leave EchoForge, and what the server does with it is up to you."
        }

        return Copy(
            title: "Send \(feature.name.lowercased()) to \(host)?",
            body: "EchoForge normally does all of this on your Mac, and it will keep doing so "
                + "for everything you do not turn on here.",
            points: points,
            learnMore: "What is sent, when, and where →",
            confirm: "Use \(host)",
            cancel: "Keep it on my Mac"
        )
    }

    /// Records that the sheet above was accepted for this feature.
    static func grant(_ feature: CloudFeature, preferences: AppPreferences = .shared) {
        var granted = Set(preferences.cloudConsentedFeatures)
        granted.insert(feature.consentKey)
        preferences.cloudConsentedFeatures = granted.sorted()
    }

    /// Forgets a consent, which also switches the feature off.
    ///
    /// Both halves, always: a stored consent with the feature off is a loaded
    /// gun, and a feature on with no consent is refused by `CloudAccess` anyway.
    /// Turning a feature off from the pane keeps its consent - this is the
    /// stronger "forget it" behind the pane's own reset button.
    static func revoke(_ feature: CloudFeature, preferences: AppPreferences = .shared) {
        preferences.cloudConsentedFeatures = preferences.cloudConsentedFeatures
            .filter { $0 != feature.consentKey }
        switch feature {
        case .transcription:
            if preferences.selectedEngine == .cloud {
                preferences.selectedEngine = CloudTranscriptionSelection.localEngineToRestore(preferences: preferences)
            }
        case .translation:
            preferences.cloudTranslationEnabled = false
        }
    }

    static func revokeEverything(preferences: AppPreferences = .shared) {
        for feature in CloudFeature.allCases { revoke(feature, preferences: preferences) }
    }
}

/// Turning cloud transcription on and off, which is a change of *engine*.
///
/// Kept in one place because it has to be reversible: switching to the cloud and
/// back must leave the user on the engine they were using, not on
/// `EngineKind.fallback` and a Whisper model they may not have downloaded. So the
/// engine in use is remembered on the way in and restored on the way out - the
/// same idea `lastReadyEngine` encodes for background preparation, and for the
/// same reason.
enum CloudTranscriptionSelection {

    /// Selects the cloud engine, remembering what to come back to.
    ///
    /// The caller is responsible for consent having been granted first;
    /// `CloudAccess` refuses the call either way, so the worst a mistake here can
    /// do is leave the user with an engine that refuses to transcribe and says
    /// why.
    static func enable(preferences: AppPreferences = .shared) {
        guard preferences.selectedEngine != .cloud else { return }
        preferences.cloudPreviousLocalEngine = preferences.selectedEngine
        preferences.selectedEngine = .cloud
    }

    /// Goes back to transcribing on this Mac.
    static func disable(preferences: AppPreferences = .shared) {
        guard preferences.selectedEngine == .cloud else { return }
        preferences.selectedEngine = localEngineToRestore(preferences: preferences)
    }

    /// The engine to return to: the one the user was on before choosing the
    /// cloud, then whatever last actually loaded, then the app-wide default.
    ///
    /// Never `.cloud`, whatever is stored - a remembered "previous local engine"
    /// of `.cloud` would make turning it off do nothing at all.
    static func localEngineToRestore(preferences: AppPreferences = .shared) -> EngineKind {
        let candidates = [preferences.cloudPreviousLocalEngine, preferences.lastReadyEngine]
        for candidate in candidates {
            if let candidate, !candidate.usesCloudProvider { return candidate }
        }
        return EngineKind.fallback
    }
}
