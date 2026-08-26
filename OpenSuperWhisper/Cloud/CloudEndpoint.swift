import Foundation

/// Where the cloud path is willing to send anything, once the user's own base
/// URL has been checked.
///
/// This is the security boundary of the cloud module, and it is the same shape as
/// `UpdateManifest`: not a parser, but the one thing standing between a string a
/// user typed and "upload the audio of everything this person says, with an API
/// key attached". It cannot be an allow-list - the whole point is that any
/// OpenAI-compatible provider works - so it enforces the properties that hold
/// whoever the provider is:
///
/// - **HTTPS, or loopback.** A plaintext request would put both the dictation and
///   the bearer token on the wire. The one exception is a loopback address, and it
///   is not a loophole: `http://127.0.0.1:11434` is how the local
///   OpenAI-compatible servers people actually run (Ollama, LM Studio,
///   llama.cpp) are reached, and bytes sent there have not left the Mac at all.
/// - **No credentials in the URL.** `https://key@host/` would put the secret
///   somewhere this app redacts nothing from.
/// - **No query or fragment.** Endpoint paths are appended to this; a base URL
///   carrying `?foo=bar` produces a URL whose query is in the middle of the path.
///
/// Everything else is normalisation, and the trailing `/v1` is the one worth
/// naming: every provider's documentation quotes its base URL with the version
/// segment on it, so `https://api.openai.com/v1` is what a user pastes. Appending
/// `v1/audio/transcriptions` to that gives `/v1/v1/audio/transcriptions` and a
/// 404 the user has no way to read. It is stripped here instead.
struct CloudEndpoint: Equatable, Sendable {
    /// The provider's root, normalised: scheme, host, optional port, and any
    /// path prefix the provider needs, with no trailing slash and no `/v1`.
    let baseURL: URL

    /// OpenAI's own base URL, and the default a fresh install shows. Named here
    /// rather than in the preference so the default and the validator cannot
    /// disagree about what a valid base URL looks like.
    static let openAIBaseURL = "https://api.openai.com"

    /// The host, for the sentences that name where data is going. Never the full
    /// URL: a base URL can carry a path prefix a user would not expect to see
    /// quoted back at them in a HUD.
    var host: String { baseURL.host ?? baseURL.absoluteString }

    /// Speech-to-text. `POST` multipart, the OpenAI audio transcriptions shape.
    var transcriptions: URL { baseURL.appendingPathComponent("v1/audio/transcriptions") }

    /// Text generation, which is how translation is done. `POST` JSON, the
    /// OpenAI chat completions shape.
    var chatCompletions: URL { baseURL.appendingPathComponent("v1/chat/completions") }

    /// Whether this endpoint is on this machine, which is the difference between
    /// "sent to a provider" and "sent to a program you are running". The Settings
    /// pane says which, because a user pointing Kongweh at their own Ollama
    /// deserves to be told their dictation is still on their Mac.
    var isLoopback: Bool { CloudEndpoint.loopbackHosts.contains(baseURL.host?.lowercased() ?? "") }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]

    /// Reads a user-typed base URL, or says exactly why it was refused.
    static func resolve(_ text: String) -> Result<CloudEndpoint, CloudEndpointError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard var components = URLComponents(string: trimmed) else { return .failure(.notAURL) }

        guard components.query == nil, components.fragment == nil else {
            return .failure(.carriesAQueryOrFragment)
        }
        guard components.user == nil, components.password == nil else {
            return .failure(.carriesCredentials)
        }
        guard let host = components.host, !host.isEmpty else { return .failure(.hasNoHost) }

        let scheme = (components.scheme ?? "").lowercased()
        let isLoopback = loopbackHosts.contains(host.lowercased())
        switch scheme {
        case "https":
            break
        case "http" where isLoopback:
            break
        case "http":
            return .failure(.insecure(host: host))
        default:
            return .failure(.unsupportedScheme(scheme.isEmpty ? "none" : scheme))
        }

        // `/v1/` and `/` alike collapse to nothing: the endpoint properties above
        // append the version segment themselves, so exactly one of them exists in
        // the finished URL however the user wrote the base.
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path

        guard let url = components.url else { return .failure(.notAURL) }
        return .success(CloudEndpoint(baseURL: url))
    }
}

/// Why a base URL was refused, as something the Settings pane can say out loud.
///
/// A reason rather than a bool for the same reason `StyleRewriteAvailability`
/// carries one: "that is not a valid URL" under a field the user just typed a
/// perfectly good URL into is not a message anybody can act on.
enum CloudEndpointError: Error, Equatable, Sendable {
    case empty
    case notAURL
    case hasNoHost
    /// Plain HTTP to somewhere other than this machine, which would put the
    /// dictation and the API key on the wire in clear.
    case insecure(host: String)
    case unsupportedScheme(String)
    case carriesAQueryOrFragment
    case carriesCredentials

    var explanation: String {
        switch self {
        case .empty:
            return "Enter the provider's base URL, for example \(CloudEndpoint.openAIBaseURL)."
        case .notAURL:
            return "That is not a URL Kongweh can read."
        case .hasNoHost:
            return "That URL has no host. It should look like \(CloudEndpoint.openAIBaseURL)."
        case .insecure(let host):
            return "Kongweh will not send audio or an API key to \(host) over plain http. "
                + "Use https, or a local address such as http://127.0.0.1:11434."
        case .unsupportedScheme(let scheme):
            return "Kongweh cannot send requests over \(scheme). Use https."
        case .carriesAQueryOrFragment:
            return "The base URL must not have a query string or a #fragment - just the provider's address."
        case .carriesCredentials:
            return "Do not put a user name or password in the URL. The API key goes in the field below, "
                + "where it is stored in your Keychain."
        }
    }
}
