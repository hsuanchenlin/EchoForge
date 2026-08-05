import Foundation

/// What the rewriting stage did to one transcript.
///
/// Every case that is not `applied` means the user got their transcript
/// unchanged, which is the point: this stage can fail in half a dozen ways and
/// none of them may cost the user their dictation.
enum StyleRewriteStatus: Equatable, Sendable {
    /// The user has rewriting switched off, or has selected the custom style
    /// without writing a prompt.
    case notRequested
    /// This Mac cannot rewrite. Carries why, for the Settings pane.
    case unavailable(StyleRewriteAvailability)
    /// There was no text to rewrite.
    case nothingToRewrite
    /// Longer than the model is asked to take in one go.
    case transcriptTooLong
    /// The rewrite was accepted. Carries the style so a caller can say which.
    case applied(styleID: String)
    /// The rewrite came back and failed the guard.
    case rejected(StyleRewriteRejection)
    /// The rewrite did not come back inside its budget.
    case timedOut
    /// The model itself failed - refused, ran out of context, or errored.
    case failed(String)

    var didRewrite: Bool {
        if case .applied = self { return true }
        return false
    }

    /// One sentence for the Settings preview and the console. Nil when there is
    /// nothing worth saying.
    var explanation: String? {
        switch self {
        case .notRequested:
            return nil
        case .unavailable(let availability):
            return availability.explanation
        case .nothingToRewrite:
            return "There was nothing to rewrite."
        case .transcriptTooLong:
            return "This dictation is too long to rewrite (over \(StyleRewriteService.maximumTranscriptCharacters) characters)."
        case .applied:
            return nil
        case .rejected(let rejection):
            return "Kept the original: \(rejection.explanation)"
        case .timedOut:
            return "Kept the original: the rewrite took too long."
        case .failed(let message):
            return "Kept the original: \(message)"
        }
    }
}

/// A transcript after the whole post-processing pipeline, rewriting included.
///
/// It carries three strings rather than one because each answers a different
/// question and none can be reconstructed from the others: `raw` is what the
/// engine heard, `transcript` is what the deterministic stages made of it - and
/// what the user gets if rewriting fails - and `final` is what the app actually
/// uses.
struct StyledTranscript: Equatable, Sendable {
    /// Exactly what the transcription engine returned.
    let raw: String
    /// The deterministic pipeline's output: terms dictionary and CJK spacing.
    let transcript: String
    /// What the app pastes, stores and shows.
    let final: String
    let status: StyleRewriteStatus

    /// The text worth keeping alongside `final` in history, or nil when
    /// post-processing changed nothing and a second copy would say nothing.
    var originalWorthKeeping: String? {
        raw == final ? nil : raw
    }

    /// A transcript that was never offered to the rewriting stage.
    static func unrewritten(_ processed: ProcessedText, status: StyleRewriteStatus) -> StyledTranscript {
        StyledTranscript(
            raw: processed.raw, transcript: processed.final, final: processed.final, status: status
        )
    }
}

/// The rewriting stage: the third and last stage of transcript post-processing,
/// after the terms dictionary and CJK spacing.
///
/// It is separate from `TextPostProcessor` on purpose. That type is
/// deterministic, synchronous and cannot fail; this one calls a language model,
/// is asynchronous, has a deadline and fails routinely. Merging them would make
/// the deterministic stages inherit an `async throws` signature and a failure
/// mode they do not have.
///
/// The contract in one line: **this stage can only improve a transcript or
/// leave it alone.** Every path out of `apply` returns usable text.
enum StyleRewriteService {

    /// Above this the transcript is not offered to the model at all.
    ///
    /// The on-device model has a context window, and a dictation that overruns
    /// it fails after the user has already waited the full budget for it. A
    /// dictation this long is also one nobody is waiting to paste in two
    /// seconds, so failing fast and keeping the transcript is the better trade.
    static let maximumTranscriptCharacters = 4000

    /// Runs the stage against an injected rewriter.
    ///
    /// Every input the decision depends on is a parameter - configuration,
    /// availability, the rewriter itself - so the tests state the situation
    /// rather than inheriting it from the Mac they run on.
    /// - Parameter budgetOverride: the deadline, when the caller wants to state
    ///   it. Production never does - `StyleRewriteBudget` decides - but a test
    ///   asserting the deadline is enforced should not have to wait the several
    ///   seconds a real dictation is allowed.
    static func apply(
        to processed: ProcessedText,
        configuration: StyleRewriteConfiguration,
        languageCode: String,
        availability: StyleRewriteAvailability,
        rewriter: StyleRewriting?,
        budgetOverride: TimeInterval? = nil
    ) async -> StyledTranscript {
        guard configuration.isRunnable else {
            return .unrewritten(processed, status: .notRequested)
        }
        guard !processed.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unrewritten(processed, status: .nothingToRewrite)
        }
        guard availability.canRun else {
            return .unrewritten(processed, status: .unavailable(availability))
        }
        // Availability and the rewriter are resolved separately, and the model
        // can become unavailable between the two. Reported as not-ready rather
        // than as the availability that was just read, which would print
        // "rewriting runs on this Mac" underneath a rewrite that did not run.
        guard let rewriter else {
            return .unrewritten(processed, status: .unavailable(.modelNotReady))
        }
        guard processed.final.count <= maximumTranscriptCharacters else {
            return .unrewritten(processed, status: .transcriptTooLong)
        }

        // Resolved from the transcript, not only from the setting, and resolved
        // once: the style instruction, the session rules and the prompt's own
        // heading all have to be written in the same language, or the model is
        // being shown two answers to "what language is this".
        let language = StyleRewriteLanguage.resolve(
            languageCode: languageCode, transcript: processed.final
        )
        let request = StyleRewriteRequest(
            text: processed.final,
            instruction: configuration.instruction(for: language),
            languageCode: languageCode,
            language: language
        )
        let budget = budgetOverride
            ?? StyleRewriteBudget.seconds(forCharacterCount: processed.final.count)

        let candidate: String
        do {
            candidate = try await rewrite(request, using: rewriter, budget: budget)
        } catch is StyleRewriteTimeout {
            return .unrewritten(processed, status: .timedOut)
        } catch is CancellationError {
            return .unrewritten(processed, status: .timedOut)
        } catch {
            return .unrewritten(processed, status: .failed(error.localizedDescription))
        }

        let verdict = StyleRewriteGuard.check(
            candidate: candidate,
            transcript: processed.final,
            mustSurvive: processed.mustSurviveTokens,
            shape: configuration.style.shape
        )

        switch verdict {
        case .accepted(let text):
            return StyledTranscript(
                raw: processed.raw,
                transcript: processed.final,
                final: text,
                status: .applied(styleID: configuration.style.id)
            )
        case .rejected(let rejection):
            return .unrewritten(processed, status: .rejected(rejection))
        }
    }

    /// The production entry point: resolves what this Mac can do, then runs the
    /// stage.
    ///
    /// Tests never reach the model through here - the same rule the engine
    /// loader follows, and for the same reason: a test host must not be able to
    /// start work that depends on the machine it happens to be running on.
    static func apply(to processed: ProcessedText, settings: Settings) async -> StyledTranscript {
        let isRunningTests = await MainActor.run { OpenSuperWhisperApp.isRunningTests }
        guard !isRunningTests else {
            return .unrewritten(processed, status: .notRequested)
        }
        guard settings.styleRewrite.isRunnable else {
            return .unrewritten(processed, status: .notRequested)
        }

        let availability = StyleRewriterFactory.availability()
        let result = await apply(
            to: processed,
            configuration: settings.styleRewrite,
            languageCode: settings.selectedLanguage,
            availability: availability,
            rewriter: StyleRewriterFactory.makeRewriter()
        )
        if let explanation = result.status.explanation, !result.status.didRewrite {
            print("Style rewrite: \(explanation)")
        }
        return result
    }

    /// Races the rewrite against its deadline without waiting on whichever
    /// loses.
    ///
    /// This was a `withThrowingTaskGroup` once, racing the rewrite against a
    /// `Task.sleep` that threw `StyleRewriteTimeout`. That is wrong for this
    /// job: leaving a task group - by return or by throw - implicitly
    /// cancels every remaining child, but the group does not actually return
    /// to *its* caller until every one of those children has finished. A
    /// cancelled `Task.sleep` throws almost instantly, but
    /// `LanguageModelSession.respond(to:options:)` is a closed framework
    /// call with no documented cancellation behaviour; if it keeps running
    /// after `cancel()`, the task group - and with it `apply`, and every
    /// caller up to `TranscriptionService.transcribeAudio` - stayed blocked
    /// for as long as the model actually took, not for the budget. Do not
    /// put this back into a task group.
    ///
    /// Instead the rewrite runs in its own unstructured `Task`, which this
    /// function never awaits `.value` on. Whichever of the rewrite or the
    /// timer resolves the continuation first is what `rewrite` returns; the
    /// loser is marked cancelled and left running unobserved. A rewriter
    /// that never checks `Task.isCancelled` therefore still costs at most
    /// `budget`, never more - which is what "hard deadline" has to mean
    /// here. `RewriteRace` exists only because two unstructured tasks are
    /// racing to resolve one continuation, and resolving it twice traps.
    ///
    /// One limit this does not remove: cancelling the *caller's* task (the
    /// app's Stop action) while a non-cooperative rewrite is in flight still
    /// waits out the budget rather than returning immediately, because the
    /// rewrite's `Task` is unstructured and so is not part of the caller's
    /// cancellation tree. That is bounded by `budget` now, where the old
    /// implementation was not bounded at all - a smaller version of the same
    /// problem, not a new one.
    private static func rewrite(
        _ request: StyleRewriteRequest, using rewriter: StyleRewriting, budget: TimeInterval
    ) async throws -> String {
        let race = RewriteRace()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let rewriteTask = Task {
                do {
                    let text = try await rewriter.rewrite(request)
                    await race.resolve(continuation, with: .success(text))
                } catch {
                    await race.resolve(continuation, with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                rewriteTask.cancel()
                await race.resolve(continuation, with: .failure(StyleRewriteTimeout()))
            }
        }
    }
}

/// The rewrite did not finish inside its budget.
struct StyleRewriteTimeout: Error, Equatable {}

/// Resolves a `rewrite` race's continuation exactly once.
///
/// The rewrite task and the timeout task both race to resolve the same
/// continuation, and `CheckedContinuation.resume` traps if called twice;
/// this actor is what makes "whichever finishes first" a fact instead of a
/// crash.
private actor RewriteRace {
    private var isResolved = false

    func resolve(
        _ continuation: CheckedContinuation<String, Error>, with result: Result<String, Error>
    ) {
        guard !isResolved else { return }
        isResolved = true
        continuation.resume(with: result)
    }
}
