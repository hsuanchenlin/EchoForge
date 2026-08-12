import Foundation

/// What went wrong with a cloud request, in the words the user needs.
///
/// Every case is a sentence naming what to do about it, for the same reason
/// `TranscriptionError` is a `LocalizedError`: a failed dictation shows this
/// string on the kept recording and in the HUD, and "The operation couldn't be
/// completed. (NSURLErrorDomain error -1009.)" is not something anyone can act
/// on.
///
/// None of these ever carries the API key. The provider's own message is
/// included where there is one, redacted through `CloudRedaction` first, because
/// a provider that says "you have exceeded your current quota" has said the one
/// thing worth passing on.
enum CloudRequestError: LocalizedError, Equatable {
    /// The gate said no. Carries the reason so the user is told which of the
    /// six things is missing rather than "cloud is not available".
    case notPermitted(CloudAccessRefusal)

    /// The audio is larger than the endpoint accepts. Caught before the upload
    /// starts, because the alternative is spending the user's bandwidth to be
    /// told the same thing by a 413.
    case audioTooLarge(bytes: Int, limit: Int)

    /// 401 or 403: the key is wrong, expired, or not entitled to this model.
    case unauthorized(String?)

    /// 429: rate limited or out of quota, which providers report the same way.
    case rateLimited(String?)

    /// Any other 4xx. The user's configuration is wrong in a way only the
    /// provider can name - usually the model.
    case requestRefused(status: Int, message: String?)

    /// 5xx: the provider is having a bad day. Nothing here is wrong.
    case providerUnavailable(status: Int, message: String?)

    /// The request never completed: no network, DNS, TLS, or a timeout.
    case network(String)

    /// A 200 whose body was not what an OpenAI-compatible endpoint returns.
    /// Reached most often by pointing the app at something that is not one.
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted(let refusal):
            return refusal.explanation
        case .audioTooLarge(let bytes, let limit):
            return "This recording is \(Self.megabytes(bytes)) and the provider accepts up to "
                + "\(Self.megabytes(limit)). It was not uploaded - the audio is kept, so a shorter "
                + "recording or a local engine will still transcribe it."
        case .unauthorized(let message):
            return "The provider rejected the API key\(Self.detail(message)). "
                + "Check it in Settings → Cloud."
        case .rateLimited(let message):
            return "The provider is rate limiting this key or it is out of quota\(Self.detail(message))."
        case .requestRefused(let status, let message):
            return "The provider refused the request (HTTP \(status))\(Self.detail(message)). "
                + "Check the model name and base URL in Settings → Cloud."
        case .providerUnavailable(let status, let message):
            return "The provider is unavailable (HTTP \(status))\(Self.detail(message)). "
                + "Nothing is wrong with your settings - try again shortly."
        case .network(let message):
            return "Could not reach the provider: \(message)."
        case .malformedResponse(let message):
            return "The provider's reply could not be read: \(message). "
                + "Check that the base URL points at an OpenAI-compatible API."
        }
    }

    /// Whether a dictation that failed this way is worth keeping the audio for.
    ///
    /// All of them are, and that is the point of asking: every one of these is
    /// either transient or something the user can fix, and the audio transcribes
    /// perfectly well afterwards. The only reason the question exists is that the
    /// app's default for a failed dictation is to delete the recording, which is
    /// right for a decode that produced nothing and wrong for a request that
    /// never got sent.
    var keepsTheRecording: Bool { true }

    /// The short form, for the 200 pt indicator card and the capsule.
    var shortMessage: String {
        switch self {
        case .notPermitted: return "Cloud not set up"
        case .audioTooLarge: return "Recording too long"
        case .unauthorized: return "Cloud key refused"
        case .rateLimited: return "Cloud rate limited"
        case .requestRefused: return "Cloud refused it"
        case .providerUnavailable: return "Cloud unavailable"
        case .network: return "Cloud unreachable"
        case .malformedResponse: return "Cloud reply unreadable"
        }
    }

    private static func detail(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return ": \(message)"
    }

    private static func megabytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// How a request is actually sent.
///
/// A protocol so the whole client can be driven against a loopback server or a
/// stub - the same seam `StyleRewriting` gives the rewriting stage, and for the
/// same reason: every failure path above has to be assertable on a machine with
/// no API key and no network.
protocol CloudHTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport.
///
/// It owns its `URLSession` rather than taking `URLSession.shared`, and that is
/// not tidiness: `shared` has a seven-day `timeoutIntervalForResource`, which is
/// how a v0.5.0 update sat at 0% forever after a connection died silently
/// mid-transfer (see `CLAUDE.md`). A dictation upload that wedges the same way
/// would leave the user watching a HUD that never resolves.
///
/// The two timeouts split the way the updater's do: what gets a transfer
/// abandoned is **silence, not throughput**. The request timeout is an idle
/// interval - `URLSession` resets it on every byte transmitted or received - so
/// it catches a dead connection in minutes while a near-limit recording on a
/// slow uplink keeps moving and completes. The resource timeout is only the
/// backstop far above any legitimate call (`CloudTimeouts.resourceBackstop`),
/// never a cap a live upload can reach.
struct CloudURLSessionTransport: CloudHTTPPerforming {
    let session: URLSession

    init(timeout: TimeInterval = CloudTimeouts.request) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = CloudTimeouts.resourceBackstop
        // Nothing about a transcription is cacheable, and a cached copy of a
        // dictation's transcript on disk is a privacy cost with no benefit.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    init(session: URLSession) {
        self.session = session
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudRequestError.malformedResponse("the reply was not an HTTP response")
        }
        return (data, http)
    }
}

/// How long a cloud call may say nothing before it is abandoned.
enum CloudTimeouts {
    /// How long one dictation's call may be idle - no byte sent or received -
    /// before it is treated as dead. An idle interval rather than a total
    /// budget on purpose: a 25 MB recording on a 1 Mbit/s uplink takes longer
    /// than any fixed total, and it is moving the whole time, which is exactly
    /// what distinguishes it from the wedged transfer this exists to catch.
    /// Generous because it also covers the provider's own decode of a long
    /// recording, which arrives as one silent stretch after the upload.
    static let request: TimeInterval = 120

    /// Translation, which sends a few kilobytes of text. The rewriting stage
    /// races this against `StyleRewriteBudget` as well, and whichever is shorter
    /// wins - so this is a backstop, not the deadline the user feels.
    static let text: TimeInterval = 60

    /// The ceiling on one whole call, sitting far above the idle timeout rather
    /// than beside it - the shape `UpdateDownloadSettings.resourceTimeout`
    /// keeps, and for the same reason: a slow link is a normal way to make a
    /// large call, so no total-time cap may sit within a legal transfer's
    /// reach. It exists only for a connection that trickles forever.
    static let resourceBackstop: TimeInterval = 30 * 60
}

/// The two calls this app makes, and what it accepts back.
///
/// The response shapes are OpenAI's, decoded leniently: a compatible provider is
/// allowed to send extra fields, and several do. What is not allowed is silence -
/// an empty `text` or an empty `content` is a failure rather than an empty
/// transcript, because "the model returned nothing" and "you said nothing" have
/// to stay distinguishable.
struct CloudClient: Sendable {
    let transport: CloudHTTPPerforming

    init(transport: CloudHTTPPerforming = CloudURLSessionTransport()) {
        self.transport = transport
    }

    /// Sends one audio file and returns the transcript.
    func transcribe(
        _ call: CloudCall,
        audio: Data,
        fileName: String,
        mimeType: String,
        language: String?,
        prompt: String?
    ) async throws -> String {
        let request = CloudRequests.transcription(
            call: call,
            audio: audio,
            fileName: fileName,
            mimeType: mimeType,
            language: language,
            prompt: prompt,
            timeout: CloudTimeouts.request
        )
        let data = try await send(request, key: call.apiKey)
        return try Self.transcript(from: data)
    }

    /// Sends one text request and returns what the model wrote.
    func complete(_ call: CloudCall, instructions: String, prompt: String) async throws -> String {
        let request = CloudRequests.chat(
            call: call,
            instructions: instructions,
            prompt: prompt,
            timeout: CloudTimeouts.text
        )
        let data = try await send(request, key: call.apiKey)
        return try Self.completion(from: data)
    }

    // MARK: - Private

    private func send(_ request: URLRequest, key: String) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.perform(request)
        } catch let error as CloudRequestError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Redacted even here: a `URLError`'s failing-URL user info can carry
            // whatever was in the request, and this string is printed and stored.
            throw CloudRequestError.network(
                CloudRedaction.redacting(key, in: error.localizedDescription)
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.failure(status: response.statusCode, body: data, key: key)
        }
        return data
    }

    /// Maps a non-2xx onto the case that says what to do about it.
    static func failure(status: Int, body: Data, key: String) -> CloudRequestError {
        let message = providerMessage(in: body).map { CloudRedaction.redacting(key, in: $0) }
        switch status {
        case 401, 403: return .unauthorized(message)
        case 429: return .rateLimited(message)
        case 400..<500: return .requestRefused(status: status, message: message)
        default: return .providerUnavailable(status: status, message: message)
        }
    }

    /// `{"error": {"message": "…"}}`, which every OpenAI-compatible provider
    /// sends and none of them is obliged to. Falls back to the raw body, trimmed
    /// to something a sentence can hold, so an HTML error page from a misrouted
    /// base URL still tells the user something.
    static func providerMessage(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }

    static func transcript(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudRequestError.malformedResponse("it was not JSON")
        }
        guard let text = object["text"] as? String else {
            throw CloudRequestError.malformedResponse("it had no \"text\" field")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Not an error: a silent recording is a real thing, and every engine
            // here answers it with an empty transcript that the caller discards.
            return ""
        }
        return trimmed
    }

    static func completion(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudRequestError.malformedResponse("it was not JSON")
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw CloudRequestError.malformedResponse("it had no choices")
        }
        guard let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CloudRequestError.malformedResponse("the first choice had no message content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CloudRequestError.malformedResponse("the model returned an empty message")
        }
        return trimmed
    }
}
