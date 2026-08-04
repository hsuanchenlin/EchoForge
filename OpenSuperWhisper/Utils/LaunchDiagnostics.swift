//
//  LaunchDiagnostics.swift
//  OpenSuperWhisper
//
//  A launch-time self-check that exists so a release package can be proven to
//  run before it is published.
//

import Foundation
import MachO

/// Reports which of the app's own embedded libraries dyld actually mapped, then
/// exits - without starting the UI or touching any of the user's data.
///
/// This exists because of the v0.3.0 release: every embedded dylib was signed,
/// `codesign --verify --deep --strict` passed on the whole bundle, and the app
/// still could not start on any Mac. Hardened runtime turns on library
/// validation, which refuses to map a library whose Team ID differs from the
/// process's, and two independently ad-hoc-signed Mach-O files never share one.
/// Nothing short of *starting the process* catches that, so
/// `Scripts/verify_release_package.sh` starts it - and needs a way to do so that
/// is safe to run against a build the operator is about to ship.
///
/// Launching the real app would not have been safe: `applicationDidFinishLaunching`
/// installs the starter model, repairs the engine selection and migrates the
/// recordings database, all against the live `~/Library/Application Support`
/// directory of whoever is packaging the release. This hook runs before any of
/// that, from `OpenSuperWhisperApp.init()`, at a point where dyld has by
/// definition finished mapping every `LC_LOAD_DYLIB` - the process would not be
/// executing at all otherwise.
enum LaunchDiagnostics {
    /// Set this in the environment to make the app report its loaded libraries
    /// and exit instead of starting.
    static let environmentKey = "ECHOFORGE_LAUNCH_CHECK"

    /// Printed on the last line of a successful check. The verifier matches on
    /// it rather than on the exit status alone, so a bundle that predates this
    /// hook - v0.3.0 among them - is reported as unverifiable rather than
    /// silently passing.
    static let successMarker = "ECHOFORGE_LAUNCH_CHECK: ok"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// Prints the report and terminates the process. Never returns.
    static func runAndExit() -> Never {
        let report = report(
            loadedImagePaths: loadedImagePaths(),
            bundlePath: Bundle.main.bundlePath
        )
        for line in report.lines {
            print(line)
        }
        print(successMarker)
        // `exit` rather than returning: the caller is the `@main` App's
        // initialiser, and there is no other way out of it that does not go on
        // to build the UI.
        exit(0)
    }

    struct Report {
        /// Every mapped image that lives inside the app bundle, bundle-relative,
        /// sorted. The main executable is one of them.
        let bundleImages: [String]

        var lines: [String] {
            bundleImages.map { "loaded: \($0)" }
        }
    }

    /// The pure half, so the filtering is testable without launching anything.
    ///
    /// Only images inside the bundle are reported: the system libraries dyld
    /// maps are not this app's packaging problem, and listing them would bury
    /// the two lines that matter.
    ///
    /// Both sides are canonicalised first. `Bundle.main.bundlePath` is
    /// standardised and `_dyld_get_image_name` hands back whatever string the
    /// process was launched with, so a bundle run from `/var/folders/…` or from
    /// a path with a doubled slash would otherwise match nothing and report an
    /// app that loaded everything as having loaded nothing. Symlink resolution
    /// only applies to paths that exist, which is every path that reaches here.
    static func report(loadedImagePaths: [String], bundlePath: String) -> Report {
        let root = canonicalPath(bundlePath) + "/"
        let inBundle = loadedImagePaths
            .map(canonicalPath)
            .filter { $0.hasPrefix(root) }
            .map { String($0.dropFirst(root.count)) }
        return Report(bundleImages: Set(inBundle).sorted())
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func loadedImagePaths() -> [String] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return String(cString: name)
        }
    }
}
