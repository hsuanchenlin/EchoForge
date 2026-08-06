import Foundation

/// Runs asynchronous work against a deadline that holds even when the work
/// itself does not cooperate.
///
/// It exists because both places this app calls the on-device language model -
/// the rewriting stage and the Ask panel - have to bound how long the user
/// waits, and `LanguageModelSession.respond(to:options:)` is a closed framework
/// call with no documented cancellation behaviour.
///
/// This was a `withThrowingTaskGroup` once, racing the work against a
/// `Task.sleep` that threw. That is wrong for this job: leaving a task group -
/// by return or by throw - implicitly cancels every remaining child, but the
/// group does not actually return to *its* caller until every one of those
/// children has finished. A cancelled `Task.sleep` throws almost instantly, but
/// a model call that keeps running after `cancel()` kept the group - and every
/// caller above it - blocked for as long as the model actually took, not for the
/// budget. Do not put this back into a task group.
///
/// Instead the work runs in its own unstructured `Task`, which this function
/// never awaits `.value` on. Whichever of the work or the timer resolves the
/// continuation first is what `run` returns; the loser is marked cancelled and
/// left running unobserved. Work that never checks `Task.isCancelled` therefore
/// still costs at most `budget`, never more - which is what "hard deadline" has
/// to mean here.
///
/// One limit this does not remove: cancelling the *caller's* task while
/// non-cooperative work is in flight still waits out the budget rather than
/// returning immediately, because the work's `Task` is unstructured and so is
/// not part of the caller's cancellation tree. That is bounded by `budget`,
/// where a plain `await` is not bounded at all.
enum AsyncDeadline {

    /// Thrown when the work did not finish inside its budget.
    struct Exceeded: Error, Equatable {}

    static func run<T: Sendable>(
        budget: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    await race.resolve(continuation, with: .success(value))
                } catch {
                    await race.resolve(continuation, with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
                work.cancel()
                await race.resolve(continuation, with: .failure(Exceeded()))
            }
        }
    }

    /// Resolves a race's continuation exactly once.
    ///
    /// The work task and the timeout task both race to resolve the same
    /// continuation, and `CheckedContinuation.resume` traps if called twice;
    /// this actor is what makes "whichever finishes first" a fact instead of a
    /// crash.
    private actor Race<T: Sendable> {
        private var isResolved = false

        func resolve(_ continuation: CheckedContinuation<T, Error>, with result: Result<T, Error>) {
            guard !isResolved else { return }
            isResolved = true
            continuation.resume(with: result)
        }
    }
}
