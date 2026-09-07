import Foundation

/// `echoforge settings` - the switches, as stored.
///
/// Two rules, both stated at `PreferenceInventory` and enforced here.
///
/// It reports **what is stored**, and reports "not set" for anything the user
/// has never touched, rather than filling in the app's default. A default
/// printed by this tool would be a copy of a value that lives beside its reason
/// in `AppPreferences`, and copies drift; "not set" is a true statement about
/// this Mac that no future change can make false.
///
/// And it prints **no credential**, which is true here by construction rather
/// than by filtering: the API key lives only in the Keychain, this tool never
/// opens the Keychain, and the row appears as `<redacted>` so its absence is
/// visible rather than silent. `CLISecrecyTests` scans this tool's sources for
/// any mention of the credential store.
enum SettingsCommand: CLICommand {
    static let spec = CommandSpec(
        name: "settings",
        summary: "Report Kongweh's user-facing settings, as stored.",
        usage: "settings [--json]",
        help: [
            "Reads the app's preferences domain. A setting the user has never changed is",
            "reported as not set rather than as its default: the defaults live in the app,",
            "beside the reasons they were chosen.",
            "",
            "Never prints the cloud API key. It is in the Keychain, and this tool does not",
            "open the Keychain - the row says <redacted> so you can see that it did not.",
        ])

    static func run(_ arguments: ParsedArguments, in environment: CLIEnvironment) async throws
        -> CommandResult
    {
        let preferences = environment.preferences
        guard preferences.isReadable else {
            throw CLIError(
                "Kongweh's preference reader could not provide values, so nothing here would be true. "
                    + "Reporting every setting as off "
                    + "would be worse than saying so.",
                exitCode: .sourceUnavailable)
        }

        let rows = PreferenceInventory.all.map { preference -> (InspectablePreference, StoredValue) in
            let raw = sanitizedValue(preferences.value(forKey: preference.key), for: preference)
            return (preference, StoredValue(raw, kind: preference.kind))
        }

        // The home directory is folded to `~` in the text rendering and left
        // verbatim in the JSON, and that split is deliberate. Several of these
        // values are absolute paths the user chose - the Whisper model, above
        // all - so the text a person pastes into an issue should not carry their
        // account name, while the document a script reads has to stay a usable
        // path.
        let redaction = Redaction(homeDirectory: NSHomeDirectory())
        return CommandResult(
            text: redaction.foldingHomeDirectory(in: text(for: rows)), json: json(for: rows))
    }

    static func sanitizedValue(_ raw: Any?, for preference: InspectablePreference) -> Any? {
        guard preference.key == PreferenceKeys.cloudBaseURL,
            let value = raw as? String
        else { return raw }
        guard var components = URLComponents(string: value) else {
            return value.contains("://") && value.contains("@") ? Redaction.marker : value
        }
        guard components.user != nil || components.password != nil else { return value }
        components.user = nil
        components.password = nil
        return components.string ?? Redaction.marker
    }

    static func text(for rows: [(InspectablePreference, StoredValue)]) -> String {
        var lines: [String] = []
        let withheldRows = PreferenceInventory.secrets + PreferenceInventory.withheldContent
        let sections = (rows.map { $0.0.section } + withheldRows.map(\.section))
            .reduce(into: [String]()) { result, section in
                if !result.contains(section) { result.append(section) }
            }
        for (index, section) in sections.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(section.uppercased())
            for (preference, value) in rows where preference.section == section {
                lines.append(
                    "  \(preference.label.padding(toLength: 32, withPad: " ", startingAt: 0))"
                        + value.display)
            }
            for withheld in withheldRows where withheld.section == section {
                lines.append(
                    "  \(withheld.label.padding(toLength: 32, withPad: " ", startingAt: 0))"
                        + "\(Redaction.marker)  (\(withheld.reason))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func json(for rows: [(InspectablePreference, StoredValue)]) -> JSONValue {
        .object([
            (
                "settings",
                .array(
                    rows.map { preference, value in
                        .object([
                            ("section", .string(preference.section)),
                            ("label", .string(preference.label)),
                            ("key", .string(preference.key)),
                            // `set` first, because it is the field a script has
                            // to branch on: `value` is null both for "not set"
                            // and for a stored null, and only this tells them
                            // apart.
                            ("set", .bool(value.isSet)),
                            ("value", value.json),
                        ])
                    })
            ),
            (
                "withheld",
                .array(
                    (PreferenceInventory.secrets + PreferenceInventory.withheldContent).map {
                        .object([
                            ("section", .string($0.section)),
                            ("label", .string($0.label)),
                            ("value", .string(Redaction.marker)),
                            ("reason", .string($0.reason)),
                        ])
                    })
            ),
        ])
    }
}

/// One stored preference, as read out of the domain.
///
/// The kind is what the inventory declared, and the value is whatever the plist
/// holds - which is not guaranteed to agree. A hand-edited domain, or a value
/// written by a newer build, can put a string where a number belongs; that is
/// reported as the mismatch it is rather than coerced, because a tool that
/// silently turned `"yes"` into `true` would hide exactly the corruption
/// somebody ran it to find.
struct StoredValue: Equatable {
    let isSet: Bool
    let display: String
    let json: JSONValue

    init(_ raw: Any?, kind: InspectablePreference.Kind) {
        guard let raw else {
            self.isSet = false
            self.display = "not set"
            self.json = .null
            return
        }
        self.isSet = true

        switch (kind, raw) {
        case (.boolean, let value as Bool):
            display = value ? "on" : "off"
            json = .bool(value)
        case (.number, let value as Int):
            display = String(value)
            json = .int(value)
        case (.number, let value as Double):
            display = String(value)
            json = .double(value)
        case (.text, let value as String):
            display = value.isEmpty ? "(empty)" : value
            json = .string(value)
        case (.list, let value as [Any]):
            let items = value.map { String(describing: $0) }
            display = items.isEmpty ? "(none)" : items.joined(separator: ", ")
            json = .array(items.map { .string($0) })
        case (.mapping, let value as [String: Any]):
            let pairs = value.keys.sorted().map { "\($0)=\(String(describing: value[$0]!))" }
            display = pairs.isEmpty ? "(none)" : pairs.joined(separator: ", ")
            json = .object(value.keys.sorted().map { ($0, .string(String(describing: value[$0]!))) })
        case (.opaque, let value as Data):
            // Present or absent, never decoded: it is a device identifier blob,
            // and printing it would print bytes nobody can act on.
            display = "set (\(value.count) bytes, not shown)"
            json = .object([("present", .bool(true)), ("bytes", .int(value.count))])
        default:
            display = "unexpected type (\(type(of: raw)))"
            json = .object([
                ("unexpectedType", .string(String(describing: type(of: raw)))),
                ("description", .string(Redaction.truncated(String(describing: raw)))),
            ])
        }
    }
}
