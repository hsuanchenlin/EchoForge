import Foundation

/// Fetching a channel feed, as a seam.
///
/// A protocol so the service can be tested against a feed the test wrote -
/// including the ones no server would send - without a network, and so nothing
/// in the tests ever reaches YouTube.
protocol YouTubeFeedFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

/// The real fetch: one small GET, on a session this type owns.
///
/// The session is **ephemeral and cookie-less** on purpose. This feature reads a
/// public document and must not carry, create or become a signed-in session:
/// nothing is logged into, no credentials are attached, and no cookie the user's
/// browser holds is involved. It is also not `URLSession.shared`, whose
/// seven-day `timeoutIntervalForResource` is exactly how a dead connection
/// becomes a request that never returns (`docs/upstream-issues.md` has the
/// updater's version of that story).
///
/// Redirects are followed only while they stay on YouTube's own hosts, the same
/// rule `UpdateManifest.isAllowedRedirectHost` applies to a download: an
/// allow-listed URL that redirects off the allow-list is not an allow-listed URL.
final class YouTubeFeedFetcher: NSObject, YouTubeFeedFetching, URLSessionTaskDelegate {

    /// Long enough for a slow link, short enough that a spoken command does not
    /// leave the user watching an overlay with nothing happening.
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // A queue rather than the delegate's own, so the redirect check below
        // runs off the main thread while a dictation is finishing.
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/atom+xml, application/xml", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: self)
        } catch {
            // Every transport failure is the same thing to the user: the lookup
            // did not happen and nothing was opened.
            throw YouTubeFeedError.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw YouTubeFeedError.malformed }
        guard http.statusCode == 200 else { throw YouTubeFeedError.httpStatus(http.statusCode) }
        guard data.count <= YouTubeFeedParser.maximumFeedBytes else {
            throw YouTubeFeedError.tooLarge
        }
        return data
    }

    /// Hosts a feed request may be redirected to. YouTube serves this document
    /// from its own domains, so the allow-list is the video host list plus the
    /// consent domain it sometimes bounces through - and nothing else.
    static func isAllowedRedirectHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return YouTubeVideoURL.allowedHosts.contains(host) || host == "consent.youtube.com"
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              Self.isAllowedRedirectHost(request.url?.host) else {
            // Refusing the redirect finishes the task on the redirect response
            // itself, so the check above reports it as the HTTP status it was -
            // a failure with a number in it rather than a silent empty feed.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
