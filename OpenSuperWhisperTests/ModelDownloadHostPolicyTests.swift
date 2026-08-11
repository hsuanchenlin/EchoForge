import XCTest

@testable import OpenSuperWhisper

/// Where model weights may come from.
///
/// The rule is a domain-suffix match rather than the updater's exact-host one,
/// and both halves of that need pinning: the CDN hostnames Hugging Face
/// redirects to are regional and change, so an exact list would break; and a
/// suffix match written carelessly is how `huggingface.co.evil.test` gets
/// accepted.
final class ModelDownloadHostPolicyTests: XCTestCase {

    func testAcceptsTheHostsEveryModelInTheAppIsPublishedOn() {
        // Copied from the catalogs rather than composed, so this agrees with
        // what the app actually asks for.
        for string in [
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true",
            "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true",
            "https://huggingface.co/FluidInference/sensevoice-small-coreml",
        ] {
            XCTAssertTrue(ModelDownloadHostPolicy.isAllowed(URL(string: string)!), string)
        }
    }

    /// Measured, not assumed: a real download of a whisper model redirected
    /// here. An exact-host allow-list would have refused it.
    func testAcceptsTheCDNHuggingFaceActuallyRedirectsTo() {
        XCTAssertTrue(ModelDownloadHostPolicy.isAllowed(
            URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/641ab5/9c7b9c?Expires=1")!
        ))
        XCTAssertTrue(ModelDownloadHostPolicy.isAllowed(
            URL(string: "https://cas-bridge.xethub.hf.co/xet-bridge-us/whatever")!
        ))
    }

    func testAcceptsTheReleaseHostsModelPacksArePublishedOn() {
        XCTAssertTrue(ModelDownloadHostPolicy.isAllowed(
            URL(string: "https://github.com/hsuanchenlin/EchoForge/releases/download/models/pack.tar.gz")!
        ))
        XCTAssertTrue(ModelDownloadHostPolicy.isAllowed(
            URL(string: "https://release-assets.githubusercontent.com/opaque/path")!
        ))
    }

    /// The suffix match must be on a domain boundary. Without the leading dot
    /// this is exactly how an allow-list gets talked past.
    func testRefusesAHostThatMerelyEndsWithAnAllowedNamesCharacters() {
        for string in [
            "https://huggingface.co.evil.test/model.bin",
            "https://nothuggingface.co/model.bin",
            "https://evilhf.co/model.bin",
        ] {
            XCTAssertFalse(ModelDownloadHostPolicy.isAllowed(URL(string: string)!), string)
        }
    }

    func testRefusesPlainHTTPEvenOnAnAllowedHost() {
        XCTAssertFalse(ModelDownloadHostPolicy.isAllowed(
            URL(string: "http://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!
        ))
    }

    func testRefusesAnythingElse() {
        XCTAssertFalse(ModelDownloadHostPolicy.isAllowed(URL(string: "https://example.invalid/model.bin")!))
        XCTAssertFalse(ModelDownloadHostPolicy.isAllowed(URL(string: "file:///tmp/model.bin")!))
        XCTAssertFalse(ModelDownloadHostPolicy.isAllowed(nil))
    }

    /// A refused download says which host it refused, because the only way to
    /// reach it is a URL in the app's own catalog pointing somewhere it should
    /// not - a bug to be read in a report, not a network hiccup.
    func testARefusalNamesTheHost() {
        let error = ModelDownloadHostPolicy.refusal(URL(string: "https://example.invalid/model.bin")!)
        XCTAssertTrue(error.localizedDescription.contains("example.invalid"), error.localizedDescription)
    }

    /// Every model URL the app ships has to pass its own policy - otherwise the
    /// check is a switch that turns downloads off.
    func testEveryModelURLTheAppShipsPassesThePolicy() throws {
        let sources = ["OpenSuperWhisper/Settings.swift", "OpenSuperWhisper/Onboarding/OnboardingModelCatalog.swift"]
        var checked = 0
        for relative in sources {
            let source = try String(contentsOf: Self.repositoryRoot.appendingPathComponent(relative), encoding: .utf8)
            for match in source.components(separatedBy: "URL(string: \"").dropFirst() {
                guard let literal = match.components(separatedBy: "\"").first,
                    literal.hasPrefix("http")
                else { continue }
                guard let url = URL(string: literal), url.path.contains("resolve") || url.path.contains("releases")
                else { continue }
                checked += 1
                XCTAssertTrue(ModelDownloadHostPolicy.isAllowed(url), "\(relative) downloads from \(literal)")
            }
        }
        XCTAssertGreaterThan(checked, 0, "found no download URLs to check - has the catalog moved?")
    }

    /// The test bundle sits inside the built products directory, so the
    /// repository is found by walking up from this file rather than from the
    /// bundle.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
