import Foundation

/// Where the app is willing to fetch model weights from.
///
/// The updater has had a host allow-list since it existed, because "download
/// this and replace the running application" is a remote code execution
/// primitive with extra steps. Model weights were the gap: they are downloaded
/// from URLs held in `Settings` and `OnboardingModelCatalog`, handed to
/// `URLSession` unexamined, and then loaded into the process by CoreML or
/// whisper.cpp. That is not as sharp an edge as replacing the app, but it is not
/// a blunt one either, and nothing was checking it.
///
/// Matched by **domain suffix** rather than by exact host, which is a deliberate
/// difference from `UpdateManifest.allowedDownloadHosts`. The updater's asset
/// lives at two hosts this project controls the publishing of; model weights are
/// served by Hugging Face's CDN, whose hostnames are regional and change without
/// notice - a download observed here redirected to `us.aws.cdn.hf.co`, and an
/// exact list would break the app the day that becomes `eu.aws.cdn.hf.co`. The
/// suffix rule still keeps the bytes inside domains this app has decided to
/// trust, and refuses everything else.
enum ModelDownloadHostPolicy {
    /// A host matches when it *is* one of these or is a subdomain of one.
    ///
    /// - `huggingface.co` / `hf.co`: where every model the app downloads is
    ///   published, and the CDN they redirect to.
    /// - `xethub.hf.co`: Hugging Face's content-addressed storage, which some
    ///   large files redirect through. Covered by `hf.co` and named here so the
    ///   reason is on the record.
    /// - The GitHub release hosts: model packs published by this project.
    static let allowedSuffixes: [String] = [
        "huggingface.co",
        "hf.co",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// The error a refused URL produces. A distinct message rather than a
    /// generic failure, because the only way to hit it is a URL in the app's own
    /// catalogs pointing somewhere it should not - which is a bug to be read in
    /// a report, not a network hiccup.
    static func refusal(_ url: URL?) -> Error {
        NSError(
            domain: "ModelDownload",
            code: -10,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "This model is not published where EchoForge downloads models from "
                    + "(\(url?.host ?? "no host")). It was not downloaded.",
            ]
        )
    }
}
