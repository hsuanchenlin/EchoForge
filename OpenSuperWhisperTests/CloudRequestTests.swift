import XCTest

@testable import OpenSuperWhisper

/// What is actually put on the wire, and what is kept off it.
///
/// Pure construction, so the multipart body - fiddly, and answered by providers
/// with an unreadable 400 when it is wrong - is asserted without a network.
final class CloudRequestTests: XCTestCase {

    private let key = "sk-proj-abcdefghijklmnop"

    private func call(
        base: String = CloudEndpoint.openAIBaseURL,
        model: String = "whisper-1",
        feature: CloudFeature = .transcription
    ) throws -> CloudCall {
        CloudCall(
            feature: feature,
            endpoint: try CloudEndpoint.resolve(base).get(),
            model: model,
            apiKey: key
        )
    }

    private func body(of request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    func testTheTranscriptionRequestCarriesTheModelTheFileAndTheKey() throws {
        let request = CloudRequests.transcription(
            call: try call(),
            audio: Data("RIFFfake-audio".utf8),
            fileName: "1739397600.wav",
            mimeType: "audio/wav",
            language: "en",
            prompt: nil,
            boundary: "BOUNDARY",
            timeout: 60
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=BOUNDARY"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")

        let body = body(of: request)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.contains("filename=\"1739397600.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains("RIFFfake-audio"))
        XCTAssertTrue(body.hasSuffix("--BOUNDARY--\r\n"))
    }

    /// `auto` is this app's word for "detect it", not a value any provider knows.
    /// Sending it asks for a language called "auto"; the field is omitted
    /// instead, which is how the endpoint is told to detect.
    func testAutoDetectSendsNoLanguageFieldAtAll() throws {
        let request = CloudRequests.transcription(
            call: try call(),
            audio: Data("x".utf8),
            fileName: "a.wav",
            mimeType: "audio/wav",
            language: nil,
            prompt: "   ",
            boundary: "B",
            timeout: 60
        )

        XCTAssertFalse(body(of: request).contains("name=\"language\""))
        XCTAssertFalse(body(of: request).contains("name=\"prompt\""), "a blank prompt is not a prompt")
    }

    /// APFS allows quotes, backslashes and newlines in a file name, and any of
    /// them interpolated raw ends the Content-Disposition header early - an
    /// opaque provider 400 with no readable reason. A dropped file's name goes
    /// through `headerSafeFileName` instead.
    func testAFileNameThatWouldBreakTheHeaderIsSentSafely() {
        let body = CloudRequests.transcriptionBody(
            audio: Data("x".utf8),
            fileName: "a\"b\r\nc.wav",
            mimeType: "audio/wav",
            model: "whisper-1",
            language: nil,
            prompt: nil,
            boundary: "B"
        )

        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("filename=\"a_bc.wav\""))
        XCTAssertEqual(
            CloudRequests.headerSafeFileName("\r\n \t"), "audio",
            "a name that sanitises away entirely still has to name the part"
        )
    }

    /// The initial-prompt setting reaches the endpoint, which accepts it as the
    /// same kind of decoding hint `WhisperEngine` passes whisper.cpp.
    func testTheInitialPromptIsPassedThroughWhenThereIsOne() throws {
        let request = CloudRequests.transcription(
            call: try call(),
            audio: Data("x".utf8),
            fileName: "a.wav",
            mimeType: "audio/wav",
            language: nil,
            prompt: "EchoForge, GRDB",
            boundary: "B",
            timeout: 60
        )

        XCTAssertTrue(body(of: request).contains("name=\"prompt\"\r\n\r\nEchoForge, GRDB"))
    }

    /// The chat request's two messages are the same split the on-device path
    /// makes between session instructions and the prompt - which is what lets a
    /// cloud backend sit behind `StyleRewriting` unnoticed.
    func testTheChatRequestSendsTheStageSInstructionsAsTheSystemMessage() throws {
        let request = CloudRequests.chat(
            call: try call(model: "gpt-4o-mini", feature: .translation),
            instructions: "You translate text.",
            prompt: "Translate this.",
            temperature: 0.2,
            timeout: 30
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(payload["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(payload["temperature"] as? Double, 0.2)

        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "You translate text.")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "Translate this.")
    }

    /// Providers key their format support off the content type as well as the
    /// filename, and answer `application/octet-stream` with a refusal.
    func testTheContentTypeFollowsTheFileTheAppActuallyRecorded() {
        XCTAssertEqual(CloudRequests.mimeType(forExtension: "wav"), "audio/wav")
        XCTAssertEqual(CloudRequests.mimeType(forExtension: "M4A"), "audio/mp4")
        XCTAssertEqual(CloudRequests.mimeType(forExtension: "mp3"), "audio/mpeg")
        XCTAssertEqual(CloudRequests.mimeType(forExtension: "sqlite"), "application/octet-stream")
    }

    // MARK: - Redaction

    /// The summary is what gets printed. If the key survives it, the key is in
    /// the console, in a screen share and in every bug report attached to one.
    func testARequestSummaryNeverCarriesTheKey() throws {
        let request = CloudRequests.chat(
            call: try call(feature: .translation),
            instructions: "i",
            prompt: "p",
            timeout: 30
        )

        let summary = CloudRedaction.summary(of: request, key: key)

        XCTAssertFalse(summary.contains(key))
        XCTAssertTrue(summary.contains("Authorization"), "the header is named, its value is not")
        XCTAssertTrue(summary.contains("sk-pro…redacted"), "enough to tell which key, not enough to use it")
    }

    /// A provider that echoes the key back in its error message - which happens -
    /// must not be able to smuggle it into a string the app stores on a recording.
    func testAProviderMessageQuotingTheKeyIsRedactedBeforeItIsShown() {
        let body = Data("{\"error\":{\"message\":\"Incorrect API key provided: \(key)\"}}".utf8)

        let error = CloudClient.failure(status: 401, body: body, key: key)

        guard case .unauthorized(let message) = error else {
            return XCTFail("a 401 is an unauthorized, not \(error)")
        }
        XCTAssertFalse(try XCTUnwrap(message).contains(key))
        XCTAssertFalse(try XCTUnwrap(error.errorDescription).contains(key))
    }

    /// A key short enough that a six-character prefix would be most of it still
    /// gets a prefix short enough to be useless.
    func testAShortKeyIsHintedAtEvenMoreBriefly() {
        XCTAssertEqual(CloudRedaction.hint(for: "abc"), "ab…redacted")
    }

    // MARK: - Responses

    func testATranscriptionResponseIsReadAsItsText() throws {
        XCTAssertEqual(
            try CloudClient.transcript(from: Data("{\"text\":\"  hello there \"}".utf8)),
            "hello there"
        )
    }

    /// A silent recording is a real thing and every engine here answers it with
    /// an empty transcript the caller discards - so an empty `text` is not a
    /// failure.
    func testAnEmptyTranscriptIsSilenceRatherThanAnError() throws {
        XCTAssertEqual(try CloudClient.transcript(from: Data("{\"text\":\"\"}".utf8)), "")
    }

    /// Pointing the app at something that is not an OpenAI-compatible API is the
    /// commonest way to reach this, so the message says to check the base URL.
    func testABodyThatIsNotTheExpectedShapeIsReportedAsSuch() {
        XCTAssertThrowsError(try CloudClient.transcript(from: Data("<html>nope</html>".utf8))) { error in
            XCTAssertEqual(error as? CloudRequestError, .malformedResponse("it was not JSON"))
        }
        XCTAssertThrowsError(try CloudClient.transcript(from: Data("{\"ok\":true}".utf8))) { error in
            XCTAssertEqual(error as? CloudRequestError, .malformedResponse("it had no \"text\" field"))
        }
    }

    func testAChatResponseIsReadAsItsFirstChoice() throws {
        let body = Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Hola\"}}]}".utf8)

        XCTAssertEqual(try CloudClient.completion(from: body), "Hola")
    }

    /// An empty completion is a failure, unlike an empty transcript: the user
    /// asked for a translation of words that exist, and "" is the model
    /// answering nothing rather than the microphone hearing nothing.
    func testAnEmptyCompletionIsAFailure() {
        let body = Data("{\"choices\":[{\"message\":{\"content\":\"  \"}}]}".utf8)

        XCTAssertThrowsError(try CloudClient.completion(from: body))
    }

    /// Each status maps onto the sentence that names what to do about it, which
    /// is the difference between a user fixing their key and a user filing a bug.
    func testEachFailureStatusBecomesTheAdviceThatFitsIt() {
        let empty = Data()

        XCTAssertEqual(CloudClient.failure(status: 401, body: empty, key: key), .unauthorized(nil))
        XCTAssertEqual(CloudClient.failure(status: 403, body: empty, key: key), .unauthorized(nil))
        XCTAssertEqual(CloudClient.failure(status: 429, body: empty, key: key), .rateLimited(nil))
        XCTAssertEqual(
            CloudClient.failure(status: 404, body: empty, key: key),
            .requestRefused(status: 404, message: nil)
        )
        XCTAssertEqual(
            CloudClient.failure(status: 503, body: empty, key: key),
            .providerUnavailable(status: 503, message: nil)
        )
    }

    /// A 5xx says the user's settings are fine, because they are, and a user
    /// sent to check their key over a provider outage will change something that
    /// was correct.
    func testAProviderOutageSaysNothingIsWrongWithTheSettings() throws {
        let message = try XCTUnwrap(
            CloudRequestError.providerUnavailable(status: 500, message: nil).errorDescription
        )

        XCTAssertTrue(message.contains("Nothing is wrong with your settings"))
    }

    /// An HTML error page from a misrouted base URL still tells the user
    /// something, trimmed to what a sentence can hold.
    func testANonJSONErrorBodyIsStillQuotedBack() {
        let html = Data(String(repeating: "x", count: 500).utf8)

        XCTAssertEqual(CloudClient.providerMessage(in: html)?.count, 200)
    }
}
