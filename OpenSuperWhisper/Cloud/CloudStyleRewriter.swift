import Foundation

/// The cloud backend for the rewriting stage, used by translation only.
///
/// It is a `StyleRewriting` implementation and nothing more, which is what makes
/// it an opt-in *provider* rather than a second pipeline: `TranslationRewrite`
/// builds the same `StyleRewriteRequest`, `AsyncDeadline` enforces the same hard
/// budget, and - the part that matters - `StyleRewriteGuard` checks the answer
/// with exactly the same rules. A cloud model that obeys a spoken "ignore all
/// previous instructions" is refused the same way the on-device one is, and the
/// user gets their transcript. See `docs/style-rewriting.md`.
///
/// The request's `sessionInstructions` become the system message and its `prompt`
/// becomes the user message, which is the same division the on-device path makes
/// between `LanguageModelSession(instructions:)` and `respond(to:)`. Nothing
/// about the prompts is rewritten for the cloud: the language rules that keep a
/// Chinese translation in the right script are properties of the request, and a
/// backend that reworded them would be a second place for them to drift.
///
/// **Only translation reaches this.** Style rewriting, the Ask panel and screen
/// queries stay on device unconditionally - `StyleRewriterFactory` is where that
/// is enforced, and `docs/cloud-api.md` says why translation is the one stage
/// with a cloud option.
struct CloudStyleRewriter: StyleRewriting {
    let call: CloudCall
    let client: CloudClient

    init(call: CloudCall, client: CloudClient = CloudClient()) {
        self.call = call
        self.client = client
    }

    func rewrite(_ request: StyleRewriteRequest) async throws -> String {
        try await client.complete(
            call,
            instructions: request.sessionInstructions,
            prompt: request.prompt
        )
    }
}
