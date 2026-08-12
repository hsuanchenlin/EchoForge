import Foundation

/// Keeps the API key out of everything that is not the request itself.
///
/// The key appears in exactly one place by design - the `Authorization` header -
/// and the ways it escapes are all mundane: a `print` of a `URLRequest`, an error
/// message that quotes the request that failed, a crash log carrying a header
/// dictionary. So nothing in this module prints a request, an error or a response
/// without passing it through here first, and `CloudRequestTests` asserts the key
/// is absent from every string these types produce.
///
/// The replacement keeps the first few characters. A user reading "no such key:
/// sk-proj-9f2…" can tell which of their keys is being used; "no such key:
/// ●●●●●" tells them nothing.
enum CloudRedaction {
    static let mask = "…redacted"

    /// Replaces every occurrence of `key` in `text`.
    static func redacting(_ key: String, in text: String) -> String {
        guard !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: hint(for: key))
    }

    /// How a key is referred to when it has to be referred to at all.
    static func hint(for key: String) -> String {
        guard key.count > 8 else { return "\(String(key.prefix(2)))\(mask)" }
        return "\(String(key.prefix(6)))\(mask)"
    }

    /// A request as something safe to print: method, URL, and the header names,
    /// with `Authorization` shown as a hint rather than a bearer token.
    ///
    /// The hint is there rather than omitted because the question this string
    /// gets printed to answer is usually "which key did that use" - and it is
    /// then passed through `redacting` as well, so a key that reached any other
    /// part of the request cannot ride out on it either.
    static func summary(of request: URLRequest, key: String) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "no url"
        let headers = (request.allHTTPHeaderFields ?? [:])
            .keys
            .sorted()
            .map { name in
                name.lowercased() == "authorization" ? "\(name): Bearer \(hint(for: key))" : name
            }
            .joined(separator: ", ")
        return redacting(key, in: "\(method) \(url) [\(headers)]")
    }
}

/// How the two cloud requests are built, kept apart from the sending.
///
/// Pure string and `Data` construction, the same split `StyleRewritePrompt` makes
/// for the same reason: the multipart body is fiddly, getting a boundary or a
/// `Content-Disposition` line wrong produces a 400 with no useful message, and
/// none of that needs a network to assert.
///
/// The wire format is OpenAI's, deliberately, because it is the one every other
/// provider implements. Nothing here is OpenAI-specific beyond that: the host,
/// the model names and the key are all the user's.
enum CloudRequests {

    /// What the transcription endpoint is asked to return. `json` rather than
    /// `verbose_json`: the app wants the text and nothing else, and the smaller
    /// response is one fewer thing for a compatible-but-not-identical provider to
    /// disagree about.
    static let transcriptionResponseFormat = "json"

    /// A boundary no audio file or model name can contain.
    static func makeBoundary() -> String { "echoforge-\(UUID().uuidString)" }

    /// The file part's name, made safe for its `Content-Disposition` line.
    ///
    /// APFS allows a double quote, a backslash, even a newline in a file name,
    /// and any of them interpolated raw ends the header early - the provider
    /// answers with an opaque 400 and the user is left with a kept recording
    /// and no readable reason. Providers key format detection off the extension
    /// and the MIME type, so replacing the offending characters loses nothing.
    static func headerSafeFileName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                continue
            }
            scalars.append(scalar == "\"" || scalar == "\\" ? "_" : scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "audio" : cleaned
    }

    /// The multipart body for a speech-to-text request.
    ///
    /// - Parameters:
    ///   - language: an ISO-639-1 code, or `nil` to let the provider detect it.
    ///     `auto` is this app's word for "detect", not a value any provider
    ///     understands, so the caller maps it to `nil` rather than sending it.
    ///   - prompt: the user's initial-prompt setting, which this endpoint accepts
    ///     verbatim as a decoding hint - the same string `WhisperEngine` passes
    ///     whisper.cpp.
    static func transcriptionBody(
        audio: Data,
        fileName: String,
        mimeType: String,
        model: String,
        language: String?,
        prompt: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        field("model", model)
        field("response_format", transcriptionResponseFormat)
        if let language, !language.isEmpty { field("language", language) }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            field("prompt", prompt)
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(headerSafeFileName(fileName))\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        return body
    }

    static func transcription(
        call: CloudCall,
        audio: Data,
        fileName: String,
        mimeType: String,
        language: String?,
        prompt: String?,
        boundary: String = makeBoundary(),
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: call.endpoint.transcriptions, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = transcriptionBody(
            audio: audio,
            fileName: fileName,
            mimeType: mimeType,
            model: call.model,
            language: language,
            prompt: prompt,
            boundary: boundary
        )
        authorize(&request, with: call)
        return request
    }

    /// The chat-completions body for one text request.
    ///
    /// Two messages, and the split is the same one the on-device path makes: the
    /// stage's rules go in the system message exactly as they go in
    /// `LanguageModelSession(instructions:)`, and the delimited transcript goes in
    /// the user message. That is what lets a cloud backend sit behind
    /// `StyleRewriting` without any stage knowing which model answered.
    static func chatBody(model: String, instructions: String, prompt: String, temperature: Double) -> Data {
        let payload: [String: Any] = [
            "model": model,
            // The same near-determinism the on-device rewriter asks for, and for
            // the same reason: a rewrite that comes back differently every time
            // is one nobody can trust or tune a prompt against.
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
        ]
        // `sortedKeys` so a test can assert on the body rather than on a
        // dictionary's iteration order.
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    static func chat(
        call: CloudCall,
        instructions: String,
        prompt: String,
        temperature: Double = 0.2,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: call.endpoint.chatCompletions, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = chatBody(
            model: call.model,
            instructions: instructions,
            prompt: prompt,
            temperature: temperature
        )
        authorize(&request, with: call)
        return request
    }

    /// The one place the key touches a request.
    private static func authorize(_ request: inout URLRequest, with call: CloudCall) {
        request.setValue("Bearer \(call.apiKey)", forHTTPHeaderField: "Authorization")
    }

    /// The content type for an audio file, from its extension.
    ///
    /// Providers key their format support off this and off the filename, and get
    /// it wrong when handed `application/octet-stream`. The list is the formats
    /// this app can produce or be handed: its own recordings are 16 kHz mono WAV
    /// (`AudioRecorder`), and a dropped file can be anything the queue accepts.
    static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav", "wave": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "oga": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mpga": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}
