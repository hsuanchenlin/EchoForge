import Foundation

/// The canonical YouTube channel id - `UC` followed by 22 more characters - and
/// the only thing this app will build a feed request from.
///
/// It is checked rather than trusted because it is the one piece of user input
/// that becomes a network request. A handle (`@veritasium`), a legacy user name
/// or a search phrase would all have to be *resolved* by asking YouTube who they
/// mean, and resolving is exactly the step this feature does not have: no
/// search, no scraping, no guessing. So the id is validated by shape, and
/// anything that is not one is refused in Settings with a sentence saying where
/// to find the real one.
enum YouTubeChannelID {

    /// `UC` plus 22 characters of the URL-safe base64 alphabet: 24 in total.
    /// Measured against the ids YouTube actually publishes rather than read off
    /// documentation, which does not state a length.
    static let length = 24

    private static let allowedTail: Set<Character> = {
        var allowed = Set<Character>()
        allowed.formUnion("abcdefghijklmnopqrstuvwxyz")
        allowed.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        allowed.formUnion("0123456789")
        allowed.formUnion("-_")
        return allowed
    }()

    static func isValid(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == length else { return false }
        guard trimmed.hasPrefix("UC") else { return false }
        return trimmed.dropFirst(2).allSatisfy { allowedTail.contains($0) }
    }

    /// The id inside whatever the user pasted, or nil.
    ///
    /// Accepts the id on its own and a `…/channel/UC…` URL, because those are
    /// the two things that are already the id - the second one just has scenery
    /// around it. It deliberately does **not** accept a handle URL
    /// (`youtube.com/@name`), a `/c/` vanity URL or a video URL: none of those
    /// contain the id, and returning a guess for them would be this app
    /// inventing a channel to open.
    ///
    /// Pure string work, on purpose. Asking YouTube to resolve a handle would
    /// put a network call behind a Settings text field and make what the
    /// allowlist means depend on a service answering.
    static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isValid(trimmed) { return trimmed }

        guard let components = URLComponents(string: trimmed) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard let index = path.firstIndex(of: "channel"), index + 1 < path.count else {
            return nil
        }
        let candidate = path[index + 1]
        return isValid(candidate) ? candidate : nil
    }
}
