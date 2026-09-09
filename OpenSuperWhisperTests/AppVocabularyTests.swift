import XCTest

@testable import OpenSuperWhisper

/// The profiles themselves: what they may contain, and how big they may be.
final class AppVocabularyProfileTests: XCTestCase {

    /// The caps are what stop this feature taking room from the thing that keeps
    /// a long dictation coherent. They are asserted against the built-ins rather
    /// than trusted, because the failure is silent.
    func testEveryProfileFitsInsideItsOwnCaps() {
        for profile in AppVocabularyCatalog.profiles {
            XCTAssertLessThanOrEqual(
                profile.terms.count, AppVocabularyProfile.maximumTerms,
                "\(profile.category.rawValue) carries more terms than the cap")
            XCTAssertLessThanOrEqual(
                profile.hint.count, AppVocabularyProfile.maximumHintCharacters,
                "\(profile.category.rawValue)'s sample passage is over the cap")
            XCTAssertFalse(profile.terms.isEmpty, "\(profile.category.rawValue) has no terms")
            XCTAssertFalse(profile.hint.isEmpty, "\(profile.category.rawValue) has no passage")
        }
    }

    func testNoProfileRepeatsATerm() {
        for profile in AppVocabularyCatalog.profiles {
            XCTAssertEqual(
                Set(profile.terms).count, profile.terms.count,
                "\(profile.category.rawValue) lists a term twice")
        }
    }

    func testAtMostOneProfilePerCategory() {
        let categories = AppVocabularyCatalog.profiles.map(\.category)
        XCTAssertEqual(Set(categories).count, categories.count)
    }

    /// Browsers get nothing, and that is a decision rather than an omission: a
    /// browser window is a mail client, a chat client and an editor on four
    /// tabs, and the only signal that would tell them apart is the page address
    /// - which this feature refuses to look at.
    func testBrowsersHaveNoProfile() {
        XCTAssertNil(AppVocabularyCatalog.profile(for: .browser))
    }

    /// The three kinds the brief names each have to be reachable from a real
    /// bundle identifier, or the feature is a table nobody's Mac matches.
    func testTheAppsInEachProfileResolveToIt() {
        let expectations: [(String, AppCategory)] = [
            ("com.apple.dt.Xcode", .developerTools),
            ("com.microsoft.VSCode", .developerTools),
            ("com.todesktop.230313mzl4w4u92", .developerTools),
            ("com.apple.Terminal", .developerTools),
            ("com.googlecode.iterm2", .developerTools),
            ("com.apple.mail", .email),
            ("com.tinyspeck.slackmacgap", .workChat),
            ("com.apple.MobileSMS", .workChat),
            ("com.hnc.Discord", .workChat),
            ("md.obsidian", .documentsNotes),
            ("com.apple.Notes", .documentsNotes),
        ]
        for (identifier, expected) in expectations {
            let target = DictationTargetApp(bundleIdentifier: identifier)
            XCTAssertEqual(target.category, expected, "\(identifier) fell into the wrong category")
            XCTAssertNotNil(
                AppVocabularyCatalog.profile(for: expected),
                "\(expected.rawValue) has no profile")
        }
    }
}

/// The rules: which app gets which profile, and the two ways a user turns one off.
final class AppVocabularyStoreTests: XCTestCase {

    private let xcode = DictationTargetApp(bundleIdentifier: "com.apple.dt.Xcode")
    private let mail = DictationTargetApp(bundleIdentifier: "com.apple.mail")
    private let safari = DictationTargetApp(bundleIdentifier: "com.apple.Safari")

    func testAStoreThatIsOffContributesNothing() {
        XCTAssertNil(AppVocabularyStore.disabled.profile(for: xcode))
        XCTAssertEqual(AppVocabularyStore.disabled.resolution(for: xcode).source, .none)
    }

    func testAnEnabledStoreResolvesTheCategoryProfile() {
        let store = AppVocabularyStore(isEnabled: true)
        XCTAssertEqual(store.profile(for: xcode)?.category, .developerTools)
        XCTAssertEqual(store.resolution(for: xcode).source, .category(.developerTools))
        XCTAssertEqual(store.profile(for: mail)?.category, .email)
    }

    func testNoAppMeansNoProfile() {
        XCTAssertNil(AppVocabularyStore(isEnabled: true).profile(for: nil))
    }

    func testACategoryWithNoProfileResolvesToNothing() {
        XCTAssertNil(AppVocabularyStore(isEnabled: true).profile(for: safari))
    }

    func testAnUnknownAppResolvesToNothing() {
        let unknown = DictationTargetApp(bundleIdentifier: "com.example.something")
        XCTAssertNil(AppVocabularyStore(isEnabled: true).profile(for: unknown))
    }

    func testASwitchedOffCategoryContributesNothing() {
        var store = AppVocabularyStore(isEnabled: true)
        store.setEnabled(false, for: .developerTools)
        XCTAssertNil(store.profile(for: xcode))
        // And the categories beside it are unaffected.
        XCTAssertNotNil(store.profile(for: mail))
    }

    /// A per-app exclusion beats the category, the way a per-app style rule does.
    func testAnExcludedAppBeatsItsCategory() {
        var store = AppVocabularyStore(isEnabled: true)
        store.exclude("com.apple.dt.Xcode")
        XCTAssertNil(store.profile(for: xcode))
        store.include("COM.APPLE.DT.XCODE")
        XCTAssertNotNil(store.profile(for: xcode))
    }

    /// Bundle identifiers are compared case-insensitively by macOS itself, so an
    /// exclusion added for one spelling has to be found again for the other.
    func testExclusionsAreStoredInOneSpelling() {
        var store = AppVocabularyStore(isEnabled: true)
        store.exclude("COM.Apple.DT.Xcode")
        XCTAssertEqual(store.sortedExcludedApps, ["com.apple.dt.xcode"])
        XCTAssertNil(store.profile(for: xcode))
    }

    /// The caps are applied on the way out, so a profile added later by somebody
    /// who did not read them is still bounded when it reaches the decoder.
    func testTheCapsAreAppliedWhenAProfileIsResolved() {
        let store = AppVocabularyStore(isEnabled: true)
        for profile in AppVocabularyCatalog.profiles {
            let resolved = store.profile(
                for: DictationTargetApp(bundleIdentifier: identifier(for: profile.category)))
            XCTAssertLessThanOrEqual(
                resolved?.terms.count ?? 0, AppVocabularyProfile.maximumTerms)
        }
    }

    private func identifier(for category: AppCategory) -> String {
        switch category {
        case .developerTools: return "com.apple.dt.Xcode"
        case .email: return "com.apple.mail"
        case .workChat: return "com.tinyspeck.slackmacgap"
        case .documentsNotes: return "md.obsidian"
        case .browser: return "com.apple.Safari"
        }
    }
}

/// The rules that hold this feature's shape, checked by reading its own sources.
final class AppVocabularyPrivacyTests: XCTestCase {

    private var contextDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Context")
    }

    /// The same rule `AppStyleMappingTests` holds for app-aware style, for the
    /// same reason and against the same list: the frontmost app's bundle
    /// identifier is the whole of the signal, and nothing here logs it or sends
    /// it anywhere.
    func testTheContextSourcesReadNothingButTheBundleIdentifier() throws {
        let forbidden = [
            "kAXTitle", "kAXDocument", "kAXURL", "AXTitle", "AXDocument", "AXWebArea",
            "CGWindowListCopyWindowInfo", "localizedName", "NSPasteboard",
            "URLSession", "URLRequest", "print(", "NSLog", "os_log",
        ]

        for (name, text) in try sources() {
            for symbol in forbidden {
                XCTAssertFalse(
                    text.contains(symbol),
                    "Context/\(name) mentions \(symbol): app vocabulary may read the frontmost "
                        + "app's bundle identifier and nothing else, and may not log it.")
            }
        }
    }

    /// The cloud endpoint takes a prompt and is deliberately never shown this
    /// one, exactly as it is never shown the personal terms dictionary.
    /// `CloudPrivacyTests` scans `Cloud/` for the dictionary; this is the other
    /// half of the same promise.
    func testNothingInTheCloudPathMentionsAppVocabulary() throws {
        let cloud = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Cloud")
        guard let files = FileManager.default.enumerator(atPath: cloud.path)?.allObjects
            as? [String]
        else { throw XCTSkip("Sources are not beside the tests: \(cloud.path)") }

        for name in files where name.hasSuffix(".swift") {
            let text = try String(contentsOf: cloud.appendingPathComponent(name), encoding: .utf8)
            for symbol in ["AppVocabulary", "appVocabulary"] {
                XCTAssertFalse(
                    text.contains(symbol),
                    "Cloud/\(name) mentions \(symbol). The provider is shown the typed prompt "
                        + "setting alone.")
            }
        }
    }

    /// One composer, one caller. The same rule `WhisperInitialPromptTests` holds
    /// for the dictionary: no engine may grow a stand-in for the prompt hook.
    func testOnlyWhisperReadsTheResolvedProfile() throws {
        let engines = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Engines")
        guard let files = FileManager.default.enumerator(atPath: engines.path)?.allObjects
            as? [String]
        else { throw XCTSkip("Sources are not beside the tests: \(engines.path)") }

        var readers: [String] = []
        for name in files where name.hasSuffix(".swift") {
            let text = try String(contentsOf: engines.appendingPathComponent(name), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let comment = line.range(of: "//") else { return line }
                    return line[line.startIndex ..< comment.lowerBound]
                }
                .joined(separator: "\n")
            if code.contains("settings.appVocabulary") {
                readers.append((name as NSString).lastPathComponent)
            }
        }

        XCTAssertEqual(
            readers, ["WhisperEngine.swift"],
            "only the engine with a decoding prompt may read the resolved profile")
    }

    private func sources() throws -> [(name: String, text: String)] {
        guard let files = FileManager.default.enumerator(atPath: contextDirectory.path)?
            .allObjects as? [String]
        else { throw XCTSkip("Sources are not beside the tests: \(contextDirectory.path)") }
        return try files
            .filter { $0.hasSuffix(".swift") }
            .map { name in
                (name, try String(
                    contentsOf: contextDirectory.appendingPathComponent(name), encoding: .utf8))
            }
    }
}

/// What the composed decoding prompt actually contains, and in what order.
final class AppVocabularyPromptTests: XCTestCase {

    /// A word is roughly a token here. The real tokenizer is the model's and is
    /// injected; this stands in for it so the ordering can be asserted without
    /// model weights, exactly as `WhisperInitialPromptTests` does.
    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).count
    }

    private var developerProfile: AppVocabularyProfile {
        AppVocabularyCatalog.profile(for: .developerTools)!
    }

    func testNoProfileLeavesThePromptExactlyAsItWas() {
        let withoutProfile = WhisperInitialPrompt.compose(
            userPrompt: "Meeting notes.", terms: [], tokenCount: wordCount)
        XCTAssertEqual(withoutProfile, "Meeting notes.")
    }

    func testAProfileReachesThePrompt() {
        let prompt = WhisperInitialPrompt.compose(
            userPrompt: "", terms: [], appVocabulary: developerProfile, tokenCount: wordCount)
        let unwrapped = try! XCTUnwrap(prompt)
        XCTAssertTrue(unwrapped.contains("camelCase"))
        XCTAssertTrue(unwrapped.contains(developerProfile.hint))
    }

    /// The priority, and the whole reason a profile is composed last: a budget
    /// that runs out drops the app's words and never one of the user's.
    func testTheUsersOwnDictionaryIsNeverCrowdedOutByAProfile() {
        let terms = [
            PersonalTerm(kind: .name, match: "arjun", replacement: "Arjun Raghunathan"),
            PersonalTerm(kind: .name, match: "kai", replacement: "Kai Lindqvist"),
        ]
        let prompt = WhisperInitialPrompt.compose(
            userPrompt: "",
            terms: terms,
            appVocabulary: developerProfile,
            // Room for the two names and very little else.
            tokenBudget: 5,
            tokenCount: wordCount)
        let unwrapped = try! XCTUnwrap(prompt)

        XCTAssertTrue(unwrapped.contains("Arjun Raghunathan"))
        XCTAssertTrue(unwrapped.contains("Kai Lindqvist"))
        XCTAssertFalse(unwrapped.contains("camelCase"))
    }

    /// And the user's typed prompt is never trimmed to make room for either.
    func testTheTypedPromptSurvivesAProfileThatCannotFit() {
        let typed = "one two three four five six"
        XCTAssertEqual(
            WhisperInitialPrompt.compose(
                userPrompt: typed, terms: [], appVocabulary: developerProfile,
                tokenBudget: 3, tokenCount: wordCount),
            typed)
    }

    /// The three pieces of conditioning are separated, so the decoder does not
    /// read the user's prompt, their dictionary and the app's passage as one
    /// run-on sentence.
    func testTheSectionsAreSeparated() {
        let prompt = WhisperInitialPrompt.compose(
            userPrompt: "Standup notes",
            terms: [PersonalTerm(kind: .name, match: "kai", replacement: "Kai Lindqvist")],
            appVocabulary: developerProfile,
            tokenCount: wordCount)
        let unwrapped = try! XCTUnwrap(prompt)

        XCTAssertTrue(unwrapped.hasPrefix("Standup notes. Kai Lindqvist. "), unwrapped)
    }
}
