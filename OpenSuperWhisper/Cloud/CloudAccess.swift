import Foundation

/// Everything the cloud path reads out of preferences, as one value.
///
/// A snapshot rather than a set of reads, for the same reason `EngineAvailability`
/// is one: the decision below has to be a pure function of it, so every refusal
/// can be asserted without a Keychain, a network or a Mac configured any
/// particular way.
///
/// The API key is deliberately **not** in here. It lives in the Keychain, is
/// fetched last and only once everything else has already said yes, and is never
/// copied into a value that gets logged, compared or carried around. See
/// `CloudCredentialStoring`.
struct CloudSettings: Equatable, Sendable {
    /// Whether this build has the cloud path at all (`CloudBuild`).
    var isCompiledIn: Bool

    /// The engine the user chose. Transcription runs in the cloud exactly when
    /// this is `.cloud`, and there is deliberately no second "cloud transcription
    /// is on" preference beside it: the app already has one persisted answer to
    /// "which engine transcribes", and a second one would be free to disagree
    /// with it. Translation has no engine, so it gets its own flag.
    var selectedEngine: EngineKind

    var translationEnabled: Bool

    /// What the user typed in the base-URL field, unvalidated. `CloudEndpoint`
    /// is the only thing that decides whether it is usable.
    var baseURLText: String

    var transcriptionModel: String
    var translationModel: String

    /// The features whose one-time consent sheet has been accepted. Recorded
    /// rather than inferred from the enable flags: turning a feature off and on
    /// again must not silently re-consent, and turning it on must never be
    /// possible without having consented once.
    var consentedFeatures: Set<CloudFeature>

    /// Whether the user has asked for this feature to run in the cloud.
    func isEnabled(_ feature: CloudFeature) -> Bool {
        switch feature {
        case .transcription: return selectedEngine == .cloud
        case .translation: return translationEnabled
        }
    }

    func hasConsented(to feature: CloudFeature) -> Bool { consentedFeatures.contains(feature) }

    static func current(preferences: AppPreferences = .shared) -> CloudSettings {
        CloudSettings(
            isCompiledIn: CloudBuild.isCompiledIn,
            selectedEngine: preferences.selectedEngine,
            translationEnabled: preferences.cloudTranslationEnabled,
            baseURLText: preferences.cloudBaseURL,
            transcriptionModel: preferences.cloudTranscriptionModel,
            translationModel: preferences.cloudTranslationModel,
            consentedFeatures: Set(preferences.cloudConsentedFeatures.compactMap(CloudFeature.init(rawValue:)))
        )
    }
}

/// One permitted cloud call: where, with what key, using which model.
///
/// Only `CloudAccess.resolve` can produce one, which is the whole design. Nothing
/// in this app can build a request to a provider without holding one of these,
/// and holding one means every gate - compiled in, enabled for this feature,
/// consented to, a usable base URL, a model named, a key present - has already
/// said yes.
struct CloudCall: Sendable {
    let feature: CloudFeature
    let endpoint: CloudEndpoint
    let model: String
    let apiKey: String
}

/// Why a cloud call was refused.
///
/// Every case is a sentence the user can act on, because every case is something
/// they can change. The two that are not mistakes - the build has no cloud path,
/// the feature is set to Local - come first, and that ordering is load-bearing:
/// see `CloudAccess.resolve`.
enum CloudAccessRefusal: Error, Equatable, Sendable {
    /// An offline-only build. Nothing in the cloud module can run.
    case notInThisBuild
    /// The user has this feature set to run locally, which is the default.
    case featureIsLocal(CloudFeature)
    /// The feature is on but its one-time consent has never been accepted. Only
    /// reachable if a preference was edited by hand or written by another build.
    case consentNotGiven(CloudFeature)
    case baseURLRefused(CloudEndpointError)
    case noModelNamed(CloudFeature)
    case noAPIKey

    var explanation: String {
        switch self {
        case .notInThisBuild:
            return "This build of EchoForge has no cloud path. Everything runs on your Mac."
        case .featureIsLocal(let feature):
            return "\(feature.name) is set to run on this Mac."
        case .consentNotGiven(let feature):
            return "\(feature.name) has not been turned on for the cloud. "
                + "Settings → Cloud is where that choice is made."
        case .baseURLRefused(let error):
            return error.explanation
        case .noModelNamed(let feature):
            return "No model is named for \(feature.name.lowercased()). Enter one in Settings → Cloud."
        case .noAPIKey:
            return "No API key is stored. Add one in Settings → Cloud - it is kept in your Keychain."
        }
    }

    /// Whether this refusal means the user misconfigured something, as opposed to
    /// simply not having asked for the cloud.
    ///
    /// The difference decides whether anything is said at all: a dictation that
    /// ran locally because the user wants it to run locally is not an event, and
    /// reporting one would be noise on every single transcription.
    var isMisconfiguration: Bool {
        switch self {
        case .notInThisBuild, .featureIsLocal:
            return false
        case .consentNotGiven, .baseURLRefused, .noModelNamed, .noAPIKey:
            return true
        }
    }
}

/// The one function that decides whether anything may be sent to a model
/// provider.
///
/// It exists so that "nothing leaves this Mac unless the user asked for it" is a
/// property of one pure function rather than of every call site remembering to
/// check. `CloudPrivacyTests` drives it with the preferences a fresh install has
/// and asserts both features are refused, and the production paths -
/// `EngineAvailability.current`, `CloudTranscriptionEngine`,
/// `StyleRewriterFactory` - have no other way in.
enum CloudAccess {

    /// - Parameters:
    ///   - credentials: consulted **last**, and only once every other gate has
    ///     passed. That ordering is deliberate: a default install must not so
    ///     much as read the Keychain, and a Keychain read on an unsigned build
    ///     can put a modal prompt in front of the user.
    static func resolve(
        _ feature: CloudFeature,
        settings: CloudSettings,
        credentials: CloudCredentialStoring
    ) -> Result<CloudCall, CloudAccessRefusal> {
        guard settings.isCompiledIn else { return .failure(.notInThisBuild) }
        guard settings.isEnabled(feature) else { return .failure(.featureIsLocal(feature)) }
        guard settings.hasConsented(to: feature) else { return .failure(.consentNotGiven(feature)) }

        let endpoint: CloudEndpoint
        switch CloudEndpoint.resolve(settings.baseURLText) {
        case .success(let resolved): endpoint = resolved
        case .failure(let error): return .failure(.baseURLRefused(error))
        }

        let model = settings.model(for: feature).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return .failure(.noModelNamed(feature)) }

        guard let apiKey = credentials.apiKey() else { return .failure(.noAPIKey) }

        return .success(CloudCall(feature: feature, endpoint: endpoint, model: model, apiKey: apiKey))
    }

    /// Whether this feature would run in the cloud, without fetching the key.
    ///
    /// For the surfaces that only need to know which side of the line they are on
    /// - the Settings pane's summary, the availability sentence - so reading them
    /// never touches the Keychain.
    static func isCloudSelected(_ feature: CloudFeature, settings: CloudSettings) -> Bool {
        settings.isCompiledIn && settings.isEnabled(feature) && settings.hasConsented(to: feature)
    }

    /// The production resolution, for callers that are not being tested.
    static func resolve(_ feature: CloudFeature) -> Result<CloudCall, CloudAccessRefusal> {
        resolve(feature, settings: .current(), credentials: KeychainCloudCredentialStore())
    }
}

extension CloudSettings {
    /// The model this feature is asked for. Two fields rather than one because
    /// they name different kinds of model - a speech model and a text model - and
    /// no provider offers one string that is both.
    func model(for feature: CloudFeature) -> String {
        switch feature {
        case .transcription: return transcriptionModel
        case .translation: return translationModel
        }
    }
}
