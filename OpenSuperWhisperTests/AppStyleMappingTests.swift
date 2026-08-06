import XCTest
@testable import OpenSuperWhisper

/// A frontmost-app reader that answers whatever the test says, and records how
/// often it was asked.
///
/// It is also the privacy boundary in miniature: the protocol it conforms to has
/// exactly one member, so there is nothing else about the frontmost application
/// a fake - or the real reader - could hand to the app.
private final class StubFrontmostApplicationReader: FrontmostApplicationReading {
    var identifier: String?
    private(set) var readCount = 0

    init(identifier: String?) {
        self.identifier = identifier
    }

    func frontmostBundleIdentifier() -> String? {
        readCount += 1
        return identifier
    }
}

/// Pins app-aware style mapping: which app falls into which category, which
/// style a category asks for, how a user's own rule overrides it, and what the
/// app is allowed to know about the app it is dictating into.
///
/// The privacy invariant is the part with teeth. `docs/app-aware-style.md`
/// states it as an absolute - only a bundle identifier is read, nothing is
/// logged - and the assertions at the bottom of this file are what make
/// weakening it fail a test rather than pass a review.
final class AppStyleMappingTests: IsolatedPreferencesTestCase {

    private var previousReader: FrontmostApplicationReading!
    private var previousOwnIdentifier: String?

    override func setUp() {
        super.setUp()
        previousReader = AppDetector.reader
        previousOwnIdentifier = AppDetector.ownBundleIdentifier
    }

    override func tearDown() {
        AppDetector.reader = previousReader
        AppDetector.ownBundleIdentifier = previousOwnIdentifier
        previousReader = nil
        super.tearDown()
    }

    private func target(_ identifier: String) -> DictationTargetApp {
        DictationTargetApp(bundleIdentifier: identifier)
    }

    private func enabledStore(
        appOverrides: [String: AppStyleAssignment] = [:],
        categoryOverrides: [AppCategory: AppStyleAssignment] = [:]
    ) -> AppStyleMappingStore {
        AppStyleMappingStore(
            isEnabled: true, categoryOverrides: categoryOverrides, appOverrides: appOverrides
        )
    }

    /// The user's chosen style, as the pipeline would build it.
    private func chosenConfiguration(
        styleID: String = "concise", isEnabled: Bool = true, customPrompt: String = ""
    ) -> StyleRewriteConfiguration {
        StyleRewriteConfiguration.resolve(
            isEnabled: isEnabled, storedStyleID: styleID, customPrompt: customPrompt
        )
    }

    // MARK: - Category matching

    func testTheNamedChatAppsAreChatApps() {
        for identifier in [
            "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
            "com.whatsapp.WhatsApp", "net.whatsapp.WhatsApp", "com.tencent.xinWeChat",
        ] {
            XCTAssertEqual(
                AppCategoryCatalog.category(forBundleIdentifier: identifier), .workChat,
                "\(identifier) should be a chat app"
            )
        }
    }

    func testTheNamedMailClientsAreMailClients() {
        for identifier in ["com.apple.mail", "com.microsoft.Outlook", "re.spark.mail"] {
            XCTAssertEqual(
                AppCategoryCatalog.category(forBundleIdentifier: identifier), .email,
                "\(identifier) should be a mail client"
            )
        }
    }

    func testTheNamedEditorsAndTerminalsAreDeveloperTools() {
        for identifier in [
            "com.apple.dt.Xcode", "com.microsoft.VSCode",
            "com.apple.Terminal", "com.googlecode.iterm2",
        ] {
            XCTAssertEqual(
                AppCategoryCatalog.category(forBundleIdentifier: identifier), .developerTools,
                "\(identifier) should be a developer tool"
            )
        }
    }

    func testBrowsersAndNoteTakersAreRecognized() {
        XCTAssertEqual(AppCategoryCatalog.category(forBundleIdentifier: "com.apple.Safari"), .browser)
        XCTAssertEqual(AppCategoryCatalog.category(forBundleIdentifier: "com.google.Chrome"), .browser)
        XCTAssertEqual(AppCategoryCatalog.category(forBundleIdentifier: "com.apple.Notes"), .documentsNotes)
        XCTAssertEqual(AppCategoryCatalog.category(forBundleIdentifier: "md.obsidian"), .documentsNotes)
    }

    /// macOS compares bundle identifiers case-insensitively, and the app that
    /// writes `com.apple.Mail` and the one that reports `com.apple.mail` are the
    /// same app. A table that matched one spelling would work for some users and
    /// not others.
    func testLookupIgnoresCaseAndSurroundingSpace() {
        XCTAssertEqual(AppCategoryCatalog.category(forBundleIdentifier: "COM.APPLE.MAIL"), .email)
        XCTAssertEqual(AppCategoryCatalog.category(forBundleIdentifier: " com.Apple.Mail "), .email)
        XCTAssertEqual(target("Com.Tinyspeck.SlackMacgap").bundleIdentifier, "com.tinyspeck.slackmacgap")
    }

    func testAFamilyOfAppsIsMatchedByPrefix() {
        XCTAssertEqual(
            AppCategoryCatalog.category(forBundleIdentifier: "com.jetbrains.intellij"), .developerTools
        )
        XCTAssertEqual(
            AppCategoryCatalog.category(forBundleIdentifier: "com.jetbrains.pycharm"), .developerTools
        )
    }

    func testAnAppTheTableHasNeverHeardOfHasNoCategory() {
        XCTAssertNil(AppCategoryCatalog.category(forBundleIdentifier: "com.example.SomeNewApp"))
        XCTAssertNil(AppCategoryCatalog.category(forBundleIdentifier: ""))
    }

    /// The raw values are persisted as the keys of the per-category preference,
    /// so renaming one silently resets that user's choice.
    func testCategoryIdentifiersArePinned() {
        XCTAssertEqual(
            Set(AppCategory.allCases.map(\.rawValue)),
            ["workChat", "email", "developerTools", "documentsNotes", "browser"]
        )
    }

    // MARK: - Reading the frontmost app

    func testTheFrontmostAppIsReadAsABundleIdentifier() {
        let reader = StubFrontmostApplicationReader(identifier: "com.apple.Mail")
        AppDetector.reader = reader
        AppDetector.ownBundleIdentifier = "com.hsuanchenlin.EchoForge"

        let target = AppDetector.currentTarget()

        XCTAssertEqual(target?.bundleIdentifier, "com.apple.mail")
        XCTAssertEqual(target?.category, .email)
        // Asked once, and everything after that is a dictionary lookup on the
        // answer: resolving a style never goes back to the system for more.
        XCTAssertEqual(reader.readCount, 1)
    }

    /// Dictating in EchoForge's own window is not dictating *into* an app, and a
    /// rule for EchoForge would be a rule about nothing.
    func testThisAppIsNeverItsOwnDictationTarget() {
        AppDetector.ownBundleIdentifier = "com.hsuanchenlin.EchoForge"
        AppDetector.reader = StubFrontmostApplicationReader(identifier: "com.hsuanchenlin.echoforge")

        XCTAssertNil(AppDetector.currentTarget())
    }

    func testNoFrontmostAppResolvesToNoTarget() {
        AppDetector.reader = StubFrontmostApplicationReader(identifier: nil)
        XCTAssertNil(AppDetector.currentTarget())

        AppDetector.reader = StubFrontmostApplicationReader(identifier: "   ")
        XCTAssertNil(AppDetector.currentTarget())
    }

    // MARK: - Defaults

    func testChatGetsCasualAndMailGetsFormal() {
        let store = enabledStore()

        XCTAssertEqual(
            store.resolution(for: target("com.tinyspeck.slackmacgap")).assignment, .style("casual")
        )
        XCTAssertEqual(
            store.resolution(for: target("com.apple.mail")).assignment, .style("formal")
        )
    }

    func testDeveloperToolsAndDocumentsGetPolishing() {
        let store = enabledStore()

        XCTAssertEqual(
            store.resolution(for: target("com.apple.dt.Xcode")).assignment, .style("polish")
        )
        XCTAssertEqual(
            store.resolution(for: target("com.apple.Notes")).assignment, .style("polish")
        )
    }

    /// A browser is a mail client, a chat window and an editor on four tabs, and
    /// the only thing that would tell them apart is the address of the page -
    /// which is what this feature refuses to look at. So it defaults to the
    /// user's own choice rather than guessing.
    func testABrowserIsRecognizedButChoosesNothingByItself() {
        let store = enabledStore()
        let resolution = store.resolution(for: target("com.apple.Safari"))

        XCTAssertEqual(target("com.apple.Safari").category, .browser)
        XCTAssertEqual(resolution, .chosenStyle)
    }

    func testEveryCategoryHasABuiltInAnswerAndEveryNamedStyleExists() {
        for category in AppCategory.allCases {
            let assignment = AppStyleMappingStore.builtInCategoryStyles[category]
            XCTAssertNotNil(assignment, "\(category.rawValue) has no built-in answer")
            if let styleID = assignment?.styleID {
                XCTAssertNotNil(
                    StyleRewriteCatalog.style(id: styleID),
                    "\(category.rawValue) defaults to a style that does not exist: \(styleID)"
                )
            }
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertFalse(category.examples.isEmpty)
        }
    }

    // MARK: - Overrides

    func testARuleForOneAppBeatsTheRuleForItsKind() {
        let store = enabledStore(appOverrides: ["com.tinyspeck.slackmacgap": .style("formal")])
        let resolution = store.resolution(for: target("com.tinyspeck.slackmacgap"))

        XCTAssertEqual(resolution.assignment, .style("formal"))
        XCTAssertEqual(resolution.source, .appOverride)
    }

    func testAnAppRuleCanHandTheDecisionBackToTheChosenStyle() {
        let store = enabledStore(appOverrides: ["com.apple.mail": .chosenStyle])

        XCTAssertEqual(store.resolution(for: target("com.apple.mail")), .chosenStyle)
    }

    func testACategoryDefaultCanBeChanged() {
        let store = enabledStore(categoryOverrides: [.workChat: .style("bullets")])
        let resolution = store.resolution(for: target("com.tinyspeck.slackmacgap"))

        XCTAssertEqual(resolution.assignment, .style("bullets"))
        XCTAssertEqual(resolution.source, .category(.workChat))
    }

    func testRulesSurviveBeingSavedAndLoaded() {
        var store = AppStyleMappingStore(isEnabled: true)
        store.setAssignment(.style("bullets"), for: .developerTools)
        store.setAssignment(.style("formal"), forApp: "com.Tinyspeck.SlackMacgap")
        store.setAssignment(.chosenStyle, forApp: "com.apple.mail")
        store.save(to: AppPreferences.shared)

        let loaded = AppStyleMappingStore.load(from: AppPreferences.shared)

        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.assignment(for: .developerTools), .style("bullets"))
        // Stored under the one spelling everything compares against, so the rule
        // is found again whatever case the app reports itself in.
        XCTAssertEqual(loaded.appOverride(for: "com.tinyspeck.slackmacgap"), .style("formal"))
        XCTAssertEqual(loaded.appOverride(for: "COM.TINYSPECK.SLACKMACGAP"), .style("formal"))
        XCTAssertEqual(loaded.appOverride(for: "com.apple.mail"), .chosenStyle)
        XCTAssertEqual(loaded, store)
    }

    func testARemovedRuleIsGoneAfterAReload() {
        var store = AppStyleMappingStore(isEnabled: true)
        store.setAssignment(.style("formal"), forApp: "com.tinyspeck.slackmacgap")
        store.save(to: AppPreferences.shared)

        store.removeApp("com.Tinyspeck.SlackMacgap")
        store.save(to: AppPreferences.shared)

        XCTAssertNil(
            AppStyleMappingStore.load(from: AppPreferences.shared)
                .appOverride(for: "com.tinyspeck.slackmacgap")
        )
    }

    // MARK: - Falling back

    func testAFreshInstallMatchesNothing() {
        XCTAssertFalse(AppPreferences.shared.appAwareStyleEnabled)
        XCTAssertNil(storedPreference("appAwareStyleEnabled"))

        let store = AppStyleMappingStore.load(from: AppPreferences.shared)

        XCTAssertEqual(store, .disabled)
        XCTAssertEqual(store.resolution(for: target("com.tinyspeck.slackmacgap")), .chosenStyle)
    }

    func testTheFeatureBeingOffIsTheOnlyGate() {
        let off = AppStyleMappingStore(
            isEnabled: false, appOverrides: ["com.tinyspeck.slackmacgap": .style("formal")]
        )

        XCTAssertEqual(off.resolution(for: target("com.tinyspeck.slackmacgap")), .chosenStyle)
        XCTAssertEqual(
            off.configuration(chosenConfiguration(), for: target("com.tinyspeck.slackmacgap")).style.id,
            "concise"
        )
    }

    func testAnUnrecognizedAppKeepsTheChosenStyle() {
        let store = enabledStore()

        XCTAssertEqual(store.resolution(for: target("com.example.SomeNewApp")), .chosenStyle)
        XCTAssertEqual(store.resolution(for: nil), .chosenStyle)
    }

    /// A rule written by a newer build, or naming a style since removed, is not
    /// a licence to pick a different one.
    func testARuleNamingAnUnknownStyleFallsBackToTheChosenStyle() {
        let store = enabledStore(
            appOverrides: ["com.apple.mail": .style("a-style-this-build-has-never-heard-of")]
        )
        let resolution = store.resolution(for: target("com.apple.mail"))

        XCTAssertEqual(resolution, .chosenStyle)
        XCTAssertEqual(
            store.configuration(chosenConfiguration(), for: target("com.apple.mail")).style.id,
            "concise"
        )
    }

    /// The asymmetry the whole design rests on: an app may choose which style
    /// runs, never whether the model gets to see the words at all.
    func testAnAppRuleCannotSwitchRewritingOnOrRewriteTheCustomPrompt() {
        let store = enabledStore(appOverrides: ["com.apple.mail": .style("formal")])
        let base = chosenConfiguration(isEnabled: false, customPrompt: "Make it rhyme.")

        let configuration = store.configuration(base, for: target("com.apple.mail"))

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.isRunnable)
        XCTAssertEqual(configuration.customPrompt, "Make it rhyme.")
    }

    /// The user's choice is theirs. Matching an app is a decision about one
    /// dictation, and a week of dictating into Slack must not end with "Casual
    /// Chat" selected in Settings - the same rule `EngineSelector` follows.
    func testMatchingAnAppNeverRewritesTheChosenStyle() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = "concise"
        AppStyleMappingStore(isEnabled: true).save(to: preferences)

        _ = Settings(dictationTarget: target("com.tinyspeck.slackmacgap"))

        XCTAssertEqual(preferences.styleRewriteStyleID, "concise")
    }

    // MARK: - Through the pipeline

    func testSettingsCarriesTheMatchedStyleIntoTheDictation() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = "concise"
        AppStyleMappingStore(isEnabled: true).save(to: preferences)

        let slack = Settings(dictationTarget: target("com.tinyspeck.slackmacgap"))
        let mail = Settings(dictationTarget: target("com.apple.mail"))

        XCTAssertEqual(slack.styleRewrite.style.id, "casual")
        XCTAssertEqual(mail.styleRewrite.style.id, "formal")
        // Everything that is not the style is still the user's.
        XCTAssertTrue(slack.styleRewrite.isEnabled)
        XCTAssertEqual(slack.safeCorrectionEnabled, Settings().safeCorrectionEnabled)
    }

    /// A dropped file, a queued recording and a regenerate from history are not
    /// dictation into anything, and the app that happens to be frontmost while
    /// they run has no claim on them.
    func testATranscriptionWithNoDictationTargetUsesTheChosenStyle() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = "concise"
        AppStyleMappingStore(isEnabled: true).save(to: preferences)

        let settings = Settings()

        XCTAssertEqual(settings.styleRewrite.style.id, "concise")
    }

    /// The chip names what this dictation is going to do, so an app-matched
    /// style has to reach it - otherwise the capsule promises the style the user
    /// selected while the pipeline runs another one.
    func testTheCapsuleChipNamesTheAppMatchedStyle() {
        let preferences = AppPreferences.shared
        preferences.styleRewriteEnabled = true
        preferences.styleRewriteStyleID = "concise"
        AppStyleMappingStore(isEnabled: true).save(to: preferences)

        let settings = Settings(dictationTarget: target("com.tinyspeck.slackmacgap"))
        let mode = CapsuleHUDMode.forStyleRewrite(settings.styleRewrite)

        XCTAssertEqual(mode.label, StyleRewriteCatalog.style(id: "casual")?.shortName)
    }

    // MARK: - Privacy

    /// The invariant, as a shape rather than a promise: the whole of what this
    /// app carries about where a dictation is going is one bundle identifier, so
    /// there is nowhere for a window title, a document name or an address to be
    /// put even by accident.
    func testTheDictationTargetCarriesNothingButABundleIdentifier() {
        let mirror = Mirror(reflecting: target("com.apple.mail"))
        let fields = mirror.children.compactMap(\.label)

        XCTAssertEqual(fields, ["bundleIdentifier"])
    }

    /// What actually lands in the preferences domain is bundle identifiers,
    /// category identifiers and style identifiers. Nothing read off a window
    /// reaches the app, so nothing read off a window can be persisted.
    func testOnlyIdentifiersArePersisted() {
        var store = AppStyleMappingStore(isEnabled: true)
        store.setAssignment(.style("formal"), forApp: "com.tinyspeck.slackmacgap")
        store.setAssignment(.style("bullets"), for: .developerTools)
        store.save(to: AppPreferences.shared)

        let apps = storedPreference("appStyleMappings") as? [String: String] ?? [:]
        let categories = storedPreference("appStyleCategoryStyles") as? [String: String] ?? [:]

        XCTAssertEqual(Array(apps.keys), ["com.tinyspeck.slackmacgap"])
        XCTAssertEqual(Array(categories.keys), ["developerTools"])
        for value in Array(apps.values) + Array(categories.values) {
            XCTAssertNotNil(
                StyleRewriteCatalog.style(id: value),
                "\(value) is not a style identifier"
            )
        }
    }

    /// The invariant that cannot be expressed as a type: these files must not
    /// reach for a window title, a document, an address or the network, and must
    /// not log what they do read.
    ///
    /// A source scan rather than a behavioural test, because the failure being
    /// guarded against is a future edit adding one line - and the honest way to
    /// catch that is to read the lines. Skipped rather than failed when the
    /// sources are not beside the tests, so a test bundle run from somewhere
    /// else does not report a privacy failure it cannot see.
    func testTheAppAwareSourcesReadNothingButTheBundleIdentifier() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = ["AppDetector.swift", "AppStyleMapping.swift"].map {
            repositoryRoot.appendingPathComponent("OpenSuperWhisper/Rewriting/\($0)")
        }

        let forbidden = [
            // Window, document and address attributes - the things this feature
            // is defined by not reading.
            "kAXTitle", "kAXDocument", "kAXURL", "AXTitle", "AXDocument", "AXWebArea",
            "CGWindowListCopyWindowInfo", "localizedName", "NSPasteboard",
            // Nothing here leaves the process, by network or by log.
            "URLSession", "URLRequest", "print(", "NSLog", "os_log",
        ]

        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw XCTSkip("Sources are not beside the tests: \(source.path)")
            }
            let text = try String(contentsOf: source, encoding: .utf8)
            for symbol in forbidden {
                XCTAssertFalse(
                    text.contains(symbol),
                    "\(source.lastPathComponent) mentions \(symbol): app-aware style mapping may "
                        + "read the frontmost app's bundle identifier and nothing else, and may "
                        + "not log it."
                )
            }
        }
    }
}
