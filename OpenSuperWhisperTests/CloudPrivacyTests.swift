import XCTest

@testable import OpenSuperWhisper

/// The claim this whole feature is judged by: **with the app as it ships,
/// nothing reaches a model provider.**
///
/// Not "the default is off" - that is a statement about a preference - but that
/// the code paths which would make a request refuse to make one. Each test here
/// drives a production entry point with the preferences a fresh install has and
/// asserts that a transport which would record any request was never called.
final class CloudPrivacyTests: IsolatedPreferencesTestCase {

    /// A transport that fails the test if anything is ever sent through it.
    private final class ForbiddenTransport: CloudHTTPPerforming, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock()
            _requests.append(request)
            lock.unlock()
            return (
                Data("{\"text\":\"this should never have been asked for\"}".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }
    }

    /// The headline assertion. A default install, both features, no request.
    func testADefaultInstallSendsNothingForEitherFeature() async throws {
        let transport = ForbiddenTransport()
        let credentials = InMemoryCloudCredentialStore(apiKey: "sk-a-key-that-exists-anyway")
        let settings = CloudSettings.current()

        for feature in CloudFeature.allCases {
            guard case .failure = CloudAccess.resolve(
                feature, settings: settings, credentials: credentials
            ) else {
                return XCTFail("\(feature.rawValue) was permitted on a default install")
            }
        }

        // And the engine, driven the way a dictation drives it: even holding a
        // key, with the preferences a fresh install has, it never reaches the
        // transport.
        let engine = CloudTranscriptionEngine(
            client: CloudClient(transport: transport),
            settings: { CloudSettings.current() },
            credentials: credentials,
            readAudio: { _ in Data("audio".utf8) }
        )
        do {
            _ = try await engine.transcribeAudio(
                url: URL(fileURLWithPath: "/tmp/a.wav"), settings: Settings()
            )
            XCTFail("a default install must not transcribe in the cloud")
        } catch let error as CloudRequestError {
            XCTAssertEqual(error, .notPermitted(.featureIsLocal(.transcription)))
        }

        XCTAssertEqual(transport.requests.count, 0, "nothing may be sent on a default install")
    }

    /// The engine the app actually runs on, on a default install, is a local
    /// one - so no dictation can take the cloud path however the rest of the app
    /// behaves.
    func testTheCloudEngineIsNotAvailableOnADefaultInstall() {
        XCTAssertNotEqual(AppPreferences.shared.selectedEngine, .cloud)
        XCTAssertFalse(EngineAvailability.current().isUsable(.cloud))
    }

    /// The cloud engine is never a stand-in. A dictation must not be uploaded
    /// because some *other* engine's download had not finished - which is what
    /// `EngineSelector`'s interim tiers do without asking anyone.
    func testTheCloudEngineIsNeverUsedAsAnInterimEngine() {
        let selection = EngineSelector.resolve(
            desired: .sensevoice,
            desiredWhisperModelPath: nil,
            // The user did once use the cloud engine, so it is what `lastReady`
            // holds - and it still may not stand in.
            lastReady: .cloud,
            lastReadyWhisperModelPath: nil,
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: EngineAvailability(usableEngines: [.cloud], whisperModelPaths: [])
        )

        XCTAssertNil(selection.active, "nothing local is ready, and the cloud may not stand in")
    }

    /// Recovery repairs a broken configuration silently, at launch, without
    /// asking. Recovering onto an engine that uploads the user's audio would
    /// make that the one change this app makes behind someone's back.
    func testRecoveryNeverRecoversOntoTheCloudEngine() {
        let outcome = EngineConfiguration.resolve(
            selectedEngine: .whisper,
            whisperModelPath: "/gone/ggml.bin",
            language: "en",
            fluidAudioModelVersion: "v3",
            availability: EngineAvailability(usableEngines: [.cloud], whisperModelPaths: [])
        )

        XCTAssertEqual(outcome, .unavailable, "no engine, rather than an engine that uploads")
    }

    /// Only translation has a cloud option, and it is a `nil` in the type rather
    /// than a comment: rewriting runs on every dictation whether or not the user
    /// was thinking about it, and the Ask panel carries whatever is on screen.
    func testRewritingAndAskHaveNoCloudPathAtAll() {
        XCTAssertNil(OnDeviceModelFeature.rewriting.cloudFeature)
        XCTAssertNil(OnDeviceModelFeature.ask.cloudFeature)
        // A history row is every dictation the user ever made, and "Fix with
        // AI" is a button on one. It reads the whole transcript, so it is
        // on-device only for exactly the reason rewriting is.
        XCTAssertNil(OnDeviceModelFeature.correction.cloudFeature)
        XCTAssertEqual(OnDeviceModelFeature.translation.cloudFeature, .translation)

        // Even with everything configured for the cloud, neither can produce a
        // cloud rewriter: `CloudFeature` has no case for them to resolve.
        let preferences = AppPreferences.shared
        preferences.cloudTranslationEnabled = true
        CloudConsent.grant(.translation, preferences: preferences)

        XCTAssertFalse(StyleRewriterFactory.makeRewriter(for: .rewriting) is CloudStyleRewriter)
        XCTAssertFalse(StyleRewriterFactory.makeRewriter(for: .ask) is CloudStyleRewriter)
    }

    /// The availability sentence must not claim a translation runs on this Mac
    /// while it is being sent to a provider - which is what reusing `.available`
    /// would have done.
    func testACloudFeatureNeverDescribesItselfAsOnDevice() {
        let cloud = StyleRewriteAvailability.cloudProvider(host: "api.openai.com")

        XCTAssertTrue(cloud.canRun)
        XCTAssertTrue(cloud.isCloud)
        let sentence = cloud.explanation(for: .translation)
        XCTAssertTrue(sentence.contains("api.openai.com"))
        XCTAssertFalse(sentence.lowercased().contains("on device"))
        XCTAssertFalse(StyleRewriteAvailability.available.isCloud)
    }

    /// The engine picker offers only engines that run here. Every row in it is
    /// one tap from being selected, and one tap must not be all it takes to
    /// start sending dictation to a company - the Cloud pane, where the consent
    /// sheet is, is the only way in.
    func testTheEnginePickerOffersNoCloudRow() {
        XCTAssertFalse(EngineCatalog.pickerOrder.contains(.cloud))
        for kind in EngineCatalog.pickerOrder {
            XCTAssertFalse(kind.usesCloudProvider, "\(kind)")
        }
    }

    /// The cloud engine still has to describe itself, because the Cloud pane and
    /// any future surface read `EngineCatalog` - and the first thing it says has
    /// to be the thing that matters.
    func testTheCloudEngineSaysThatRecordingsAreUploaded() {
        let entry = EngineCatalog.entry(for: .cloud)

        XCTAssertTrue(entry.notes.first?.contains("uploaded") == true)
        XCTAssertNil(entry.download, "there are no weights to download")
    }

    // MARK: - Source scans

    /// The invariants that cannot be expressed as types, read off the sources -
    /// the same tactic `AppStyleMappingTests` and `EngineWeightsPreparationTests`
    /// use, and for the same reason: what is guarded against is a future edit
    /// adding one line.
    func testNothingOutsideTheCloudModuleCanBuildACloudRequest() throws {
        try scanProductionSources { path, text in
            guard !path.hasPrefix("Cloud/") else { return }
            for symbol in ["CloudRequests.", "CloudCall("] {
                XCTAssertFalse(
                    text.contains(symbol),
                    "\(path) mentions \(symbol). A request to a provider may only be built inside "
                        + "Cloud/, behind CloudAccess, so that consent and the key are checked in one place."
                )
            }
        }
    }

    /// The API key lives in the Keychain and nowhere else. A preference is a
    /// plist any process running as the user can read and Time Machine copies.
    func testTheAPIKeyIsNeverStoredAsAPreference() throws {
        try scanProductionSources { path, text in
            if path != "Cloud/CloudCredentialStore.swift" {
                for symbol in ["kSecClass", "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate"] {
                    XCTAssertFalse(
                        text.contains(symbol),
                        "\(path) talks to the Keychain directly. KeychainCloudCredentialStore is the "
                            + "one place that does, so read, write and delete cannot disagree about "
                            + "which item they mean."
                    )
                }
            }
            guard path == "Utils/AppPreferences.swift" else { return }
            for forbidden in ["apiKey", "APIKey", "api_key", "secret"] where text.contains(forbidden) {
                XCTFail("AppPreferences mentions \(forbidden): the key belongs in the Keychain.")
            }
        }
    }

    private func scanProductionSources(_ check: (String, String) throws -> Void) throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        guard let files = FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String] else {
            throw XCTSkip("Sources are not beside the tests: \(sources.path)")
        }

        var scanned = 0
        for file in files where file.hasSuffix(".swift") {
            try check(file, try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8))
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found almost no sources, so it proved almost nothing")
    }
}
