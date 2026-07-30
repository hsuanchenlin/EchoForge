import XCTest
@testable import OpenSuperWhisper

/// Pins the matching rules of the personal terms dictionary.
///
/// Everything here is deterministic and runs with no model, no network and no
/// macOS version requirement, which is what makes this layer always-on.
final class PersonalTermsCorrectorTests: XCTestCase {

    private func corrected(_ text: String, _ terms: [PersonalTerm]) -> String {
        PersonalTermsCorrector.apply(terms, to: text).text
    }

    // MARK: - Nothing applies

    func testTextIsUnchangedWhenNoEntryMatches() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]
        let input = "我們明天早上開會討論預算"

        let result = PersonalTermsCorrector.apply(terms, to: input)

        XCTAssertEqual(result.text, input)
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertTrue(result.protectedRanges.isEmpty)
        XCTAssertFalse(result.changedText)
    }

    func testTextIsUnchangedWithAnEmptyDictionary() {
        let input = "我們使用Kubernetes部署服務"

        XCTAssertEqual(corrected(input, []), input)
    }

    func testEmptyTextIsUnchanged() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        XCTAssertEqual(corrected("", terms), "")
    }

    func testDisabledAndIncompleteEntriesDoNotFire() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群", isEnabled: false),
            PersonalTerm(kind: .replacement, match: "報告", replacement: "")
        ]

        XCTAssertEqual(corrected("在頂頂群裡發報告", terms), "在頂頂群裡發報告")
    }

    // MARK: - Chinese matching without word boundaries

    func testMatchesInsideChineseTextWithNoSpaces() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        // Chinese has no word spaces, so this cannot be a token-split replace.
        XCTAssertEqual(corrected("我把報告貼在頂頂群裡了", terms), "我把報告貼在釘釘群裡了")
    }

    func testMatchesAtTheStartAndEndOfTheText() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        XCTAssertEqual(corrected("頂頂群", terms), "釘釘群")
        XCTAssertEqual(corrected("頂頂群裡", terms), "釘釘群裡")
        XCTAssertEqual(corrected("請看頂頂群", terms), "請看釘釘群")
    }

    func testEveryOccurrenceIsCorrected() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        XCTAssertEqual(
            corrected("頂頂群和另一個頂頂群", terms),
            "釘釘群和另一個釘釘群"
        )
    }

    // MARK: - Mixed Chinese / English

    func testMatchesMixedChineseAndLatinEntries() {
        let terms = [
            PersonalTerm(kind: .name, match: "阿肯", replacement: "阿 Ken"),
            PersonalTerm(kind: .replacement, match: "第 3 個 sprint", replacement: "第三個 Sprint")
        ]

        // Both entries straddle scripts and one of them contains spaces, so
        // neither survives a whitespace-delimited word split. Spacing around
        // the result is left to CJK autocorrect, which runs after this stage.
        XCTAssertEqual(
            corrected("阿肯負責第 3 個 sprint 的驗收", terms),
            "阿 Ken負責第三個 Sprint 的驗收"
        )
    }

    func testMatchesALatinEntryEmbeddedInChineseWithNoSpaces() {
        let terms = [PersonalTerm(kind: .preferredSpelling, match: "k8s", replacement: "Kubernetes")]

        XCTAssertEqual(corrected("我們用k8s部署服務", terms), "我們用Kubernetes部署服務")
    }

    func testMatchingIsCaseSensitive() {
        let terms = [PersonalTerm(kind: .preferredSpelling, match: "k8s", replacement: "Kubernetes")]

        // Deliberate: a case-insensitive dictionary would make protecting
        // identifiers such as useState versus usestate impossible to express.
        XCTAssertEqual(corrected("我們用K8S部署", terms), "我們用K8S部署")
    }

    // MARK: - Longest match first, and overlaps

    func testLongerEntryWinsOverShorterOneAtTheSameStart() {
        let terms = [
            PersonalTerm(kind: .preferredSpelling, match: "臺北", replacement: "台北"),
            PersonalTerm(kind: .preferredSpelling, match: "臺北市", replacement: "臺北市政府")
        ]

        XCTAssertEqual(corrected("我住在臺北市", terms), "我住在臺北市政府")
    }

    func testLongestMatchWinsRegardlessOfEntryOrderInTheFile() {
        let short = PersonalTerm(kind: .replacement, match: "會議", replacement: "會談")
        let long = PersonalTerm(kind: .replacement, match: "會議記錄", replacement: "會議紀錄")

        // Order in the file must not decide the result when lengths differ.
        XCTAssertEqual(corrected("整理會議記錄", [short, long]), "整理會議紀錄")
        XCTAssertEqual(corrected("整理會議記錄", [long, short]), "整理會議紀錄")
    }

    func testEqualLengthEntriesResolveInFileOrder() {
        let first = PersonalTerm(kind: .replacement, match: "在座", replacement: "再坐")
        let second = PersonalTerm(kind: .replacement, match: "在座", replacement: "在坐")

        XCTAssertEqual(corrected("在座各位", [first, second]), "再坐各位")
        XCTAssertEqual(corrected("在座各位", [second, first]), "在坐各位")
    }

    func testEarlierOverlappingMatchWinsAndScanningResumesAfterIt() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "會議記", replacement: "X"),
            PersonalTerm(kind: .replacement, match: "議記錄", replacement: "Y")
        ]

        // Both are three characters; the one that starts first consumes the span.
        XCTAssertEqual(corrected("會議記錄", terms), "X錄")
    }

    func testOutputOfOneEntryIsNotRewrittenByAnother() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群"),
            PersonalTerm(kind: .replacement, match: "釘釘群", replacement: "企業微信群")
        ]

        // A single left-to-right pass: scanning resumes past what was written,
        // so corrections cannot cascade into each other.
        XCTAssertEqual(corrected("貼到頂頂群", terms), "貼到釘釘群")
    }

    // MARK: - Traditional / Simplified variants

    func testTraditionalEntryMatchesSimplifiedDictation() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        XCTAssertEqual(corrected("贴到顶顶群", terms), "贴到釘釘群")
    }

    func testSimplifiedEntryMatchesTraditionalDictation() {
        let terms = [PersonalTerm(kind: .replacement, match: "顶顶群", replacement: "釘釘群")]

        XCTAssertEqual(corrected("貼到頂頂群", terms), "貼到釘釘群")
    }

    func testTargetIsEmittedExactlyAsTypedAndTheRestOfTheScriptIsUntouched() {
        let terms = [PersonalTerm(kind: .preferredSpelling, match: "台北", replacement: "臺北")]

        // Test-only exception to Traditional fixtures: Simplified input is
        // required to prove variant folding never changes unmatched output.
        XCTAssertEqual(corrected("我们下周去台北出差", terms), "我们下周去臺北出差")

        // And a Traditional dictation of the same word is normalised to the
        // user's chosen spelling rather than left alone.
        XCTAssertEqual(corrected("我們下週去臺北出差", terms), "我們下週去臺北出差")
    }

    func testVariantMatchingDoesNotConvertUnmatchedText() {
        let terms = [PersonalTerm(kind: .replacement, match: "簡體", replacement: "簡體中文")]
        // Test-only exception to Traditional fixtures: an all-Simplified input
        // is required to prove a no-match correction is byte-for-byte inert.
        let input = "这句话没有任何一个词命中词典"

        XCTAssertEqual(corrected(input, terms), input)
    }

    // MARK: - Context hints

    func testEntryWithAContextHintOnlyFiresWhenTheHintIsPresent() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "在", replacement: "再", contextHint: "一次")
        ]

        // A blindly global 在 → 再 would wreck every other sentence; the hint is
        // what makes a homophone entry usable at all.
        XCTAssertEqual(corrected("我在辦公室", terms), "我在辦公室")
        XCTAssertEqual(corrected("請在說一次", terms), "請再說一次")
    }

    func testContextHintMatchesAcrossScriptVariants() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "帳號", replacement: "賬號", contextHint: "登錄")
        ]

        // Entry and hint are both Traditional; the dictation is Simplified.
        XCTAssertEqual(corrected("登录时帐号错误", terms), "登录时賬號错误")
    }

    func testEntryWithoutAContextHintAppliesEverywhere() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        XCTAssertEqual(corrected("頂頂群", terms), "釘釘群")
        XCTAssertEqual(corrected("開會前先看頂頂群", terms), "開會前先看釘釘群")
    }

    func testAHintLongerThanTheTextNeverFires() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "在", replacement: "再", contextHint: "請再說一次")
        ]

        XCTAssertEqual(corrected("在", terms), "在")
    }

    // MARK: - Never-correct entries

    func testProtectedEntryLeavesTheMatchedSpanExactlyAsSpoken() {
        let terms = [PersonalTerm(kind: .protect, match: "恰恰好")]

        let result = PersonalTermsCorrector.apply(terms, to: "這個時間點恰恰好")

        XCTAssertEqual(result.text, "這個時間點恰恰好")
        XCTAssertEqual(result.applied.map(\.kind), [.protect])
    }

    func testProtectedEntryReportsTheRangeItCovers() {
        let terms = [PersonalTerm(kind: .protect, match: "useState")]

        let result = PersonalTermsCorrector.apply(terms, to: "我們用useState管理狀態")

        XCTAssertEqual(result.protectedRanges, [3 ..< 11])
        let characters = Array(result.text)
        XCTAssertEqual(String(characters[result.protectedRanges[0]]), "useState")
    }

    func testProtectedRangesAreReportedForEveryOccurrence() {
        let terms = [PersonalTerm(kind: .protect, match: "useState")]

        let result = PersonalTermsCorrector.apply(terms, to: "useState和useState")

        XCTAssertEqual(result.protectedRanges, [0 ..< 8, 9 ..< 17])
    }

    func testProtectedRangesAreCorrectAfterAnEarlierSubstitutionChangesLength() {
        let terms = [
            PersonalTerm(kind: .preferredSpelling, match: "k8s", replacement: "Kubernetes"),
            PersonalTerm(kind: .protect, match: "useState")
        ]

        let result = PersonalTermsCorrector.apply(terms, to: "用k8s跑useState")

        // Ranges index the corrected text, not the input, so the seven extra
        // characters from the first entry have to be accounted for.
        let characters = Array(result.text)
        XCTAssertEqual(result.text, "用Kubernetes跑useState")
        XCTAssertEqual(String(characters[result.protectedRanges[0]]), "useState")
    }

    func testProtectedEntryBeatsAnOverlappingReplacementOfTheSameLength() {
        let protect = PersonalTerm(kind: .protect, match: "恰恰好")
        let replace = PersonalTerm(kind: .replacement, match: "恰恰好", replacement: "剛剛好")

        // File order breaks the tie, so a user who wants a phrase inviolable
        // puts the protect entry first - and it then wins.
        XCTAssertEqual(corrected("時間恰恰好", [protect, replace]), "時間恰恰好")
    }

    func testProtectedSpanIsNotRewrittenToTheEntrySpelling() {
        let terms = [PersonalTerm(kind: .protect, match: "臺北")]

        // "Never correct" means never correct, including the script. Rewriting
        // the span to the entry's spelling would be a correction.
        let result = PersonalTermsCorrector.apply(terms, to: "我在台北")

        XCTAssertEqual(result.text, "我在台北")
        XCTAssertEqual(result.applied.first?.matched, "台北")
        XCTAssertEqual(result.applied.first?.emitted, "台北")
    }

    // MARK: - The result surface later stages need

    func testAppliedTermsRecordWhatWasMatchedAndWhatWasWritten() {
        let replacement = PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")
        let name = PersonalTerm(kind: .name, match: "阿肯", replacement: "阿 Ken")

        let result = PersonalTermsCorrector.apply([replacement, name], to: "阿肯貼到頂頂群")

        XCTAssertEqual(result.applied, [
            AppliedTerm(termID: name.id, kind: .name, matched: "阿肯", emitted: "阿 Ken"),
            AppliedTerm(termID: replacement.id, kind: .replacement, matched: "頂頂群", emitted: "釘釘群")
        ])
    }

    func testMustSurviveTokensCoverEverySubstitutedAndProtectedSpan() {
        let terms = [
            PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群"),
            PersonalTerm(kind: .name, match: "阿肯", replacement: "阿 Ken"),
            PersonalTerm(kind: .protect, match: "useState")
        ]

        let result = PersonalTermsCorrector.apply(terms, to: "阿肯在頂頂群問useState")

        // This is the set a later rewriting stage would have to find intact in
        // its own output before that output could be accepted.
        XCTAssertEqual(result.mustSurviveTokens, ["阿 Ken", "釘釘群", "useState"])
    }

    func testMustSurviveTokensAreDeduplicatedInFirstSeenOrder() {
        let terms = [PersonalTerm(kind: .replacement, match: "頂頂群", replacement: "釘釘群")]

        let result = PersonalTermsCorrector.apply(terms, to: "頂頂群和頂頂群")

        XCTAssertEqual(result.mustSurviveTokens, ["釘釘群"])
        XCTAssertEqual(result.applied.count, 2, "both hits are still recorded")
    }

    func testAnEntryThatMatchesTextAlreadySpelledCorrectlyStillCounts() {
        let terms = [PersonalTerm(kind: .preferredSpelling, match: "台北", replacement: "臺北")]

        let result = PersonalTermsCorrector.apply(terms, to: "我在臺北")

        // The text did not change, but the span is still the user's pinned
        // spelling and must survive whatever comes next.
        XCTAssertEqual(result.text, "我在臺北")
        XCTAssertEqual(result.mustSurviveTokens, ["臺北"])
    }
}
