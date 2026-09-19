# The in-app updater

`OpenSuperWhisper/Updates/` is the About pane and `EchoForgeCore/Updates/` is the updater
both the app and the `echoforge` tool ([cli.md](cli.md)) run. Nothing there runs on its own:
checking, downloading and installing are three separate user actions, and there is no
launch-time or background check to add one to.

[release_build.md](release_build.md) is the other half - what a release publishes for this
code to find.

## The session outlives the pane

The update session is **app-lifetime, not pane-lifetime**: `UpdateViewModel.shared`, which
`AboutSettingsView` observes rather than owns. Settings builds only the tab that is showing,
so while that state lived in the pane's `@StateObject` every tab switch destroyed the transfer
with the view, and the pane came back offering to start the 222 MB download again. It is
created on first use, so a user who never opens About never constructs an updater, and
`AppDelegate.applicationWillTerminate` reaches it through `sharedIfCreated` for that reason,
and so does `SettingsView.onAppear`, which drops a `.upToDate` or `.failed` from an earlier
visit (`settingsDidOpen`): an app-lifetime session outlives the question its answers were to,
and only those two are answers rather than work - everything in flight, `.readyToInstall` and
a live `.available` offer all survive, and a tab switch never resets anything.

## Quitting mid-transfer

Quitting cancels an in-flight transfer - the partial survives in Caches, so the next launch
resumes - and touches no staged bundle in any state, `.installing` least of all. `.verifying`
is the state cancelling cannot reach: it is `Task.detached` work whose value is awaited, and
`applicationWillTerminate` can neither delay the exit nor await the `defer` that unmounts the
disk image. So `UpdateInstaller.prepareForTermination` **stands the commands down first and
detaches second**. Detaching first is a race it loses: a command is a child process, so an
`hdiutil attach` still running outlives the app, and a detach issued against a mount that has
not appeared yet takes down nothing before the attach finishes and mounts it. That ordering
is only meaningful because `SystemCommandRunner` launches and sweeps under one lock - a
caller-side check before `run` can always be overtaken by the launch it guards - and because
the sweep *waits* for what it signalled: `terminate()` only raises SIGTERM, so without a
bounded wait the detach would still be racing an attach that had been told to stop but had
not finished mounting. `runDuringTermination` is the one way past the refusal, for the detach
itself. `verifyAndStage` also refuses to start mounting once termination has begun, since the
last byte can land on the way out. Everything killed or refused here fails, and none of those
failures may discard the partial.

`UpdateSessionPersistenceTests` holds all of it, asserting the mount is *gone* rather than
that a detach was issued, and tearing down a real `NSHostingView` because the original
failure was a SwiftUI lifetime; the sweep's own bounded wait is pinned against real processes
in `SystemCommandRunnerTerminationTests`.

## The security boundary

`UpdateManifest` is the security boundary, not a parser: it is the only thing standing between
release metadata and "replace the running application", so it accepts an exact asset name,
an HTTPS URL on GitHub's release hosts under this repository, and a `vX.Y.Z` tag - and
refuses everything else with a reason. `DownloadedBuildRequirements` then checks the
downloaded bundle's identifier and version, and `codesign --verify --deep --strict` checks it
was not modified since signing. That signature is **ad-hoc**, so it proves integrity and not
authorship; the allow-list is what carries the rest. Do not weaken either half -
`UpdateCheckerTests` asserts the refusals.

The allow-list check on the initial URL is not enough by itself: GitHub's API always returns
a `github.com` link, but the bytes are served from a redirect to its object store, so the
download re-checks every redirect it follows against the same host allow-list
(`UpdateManifest.isAllowedRedirectHost`) before continuing.

Releases publish a `.sha256` sidecar and the updater checks it (`UpdateManifest.checksumURL`).
A release without one still installs - none before v0.5.2 published any - but a sidecar that
exists and does not match, or cannot be read, fails the install rather than being skipped.

## The download

The download is written around one measured platform fact: **`URLSession` delivers progress
callbacks only to a session's own delegate, never to one passed per task** - four megabytes
produced zero callbacks that way and fourteen the other. That is why `ResumableDownload` owns
the session it runs on instead of the installer holding a shared one, and it is worth
re-measuring before anyone "simplifies" it back.

The **download** must never run on `URLSession.shared`: its `timeoutIntervalForResource` is
seven days, which is how a 0.5.0 update sat at 0% forever after a connection died silently
mid-transfer. The *check* is a different case and deliberately stays on `.shared`
(`GitHubReleaseMetadataFetcher`): it is one small GET whose request carries its own 20 s
`timeoutInterval`, so it cannot wedge the same way.

A transfer **resumes**. The partial file and the validator it was fetched with live under
Caches (`PartialDownloadStore`), and the next attempt asks for `bytes=<n>-` conditioned on
`If-Range`, so a failure at 95% of a large asset costs one press rather than the whole
download again. `ResumeDecision` is where the server's answer is read, as a pure function:
appending a 200's whole-file body onto an existing partial produces a file of exactly the
right length made of the wrong bytes, and that is the failure the whole shape is arranged
around. A partial survives a failed or cancelled *download* and never survives a failed
*verification*. `ResumableFileDownloader` is the same transfer for callers that only need
the bytes - `ModelPackInstaller` is the other one - and `StallWatchdog` is shared by both.

Progress is reported as **bytes**, not a fraction: `0%` used to cover everything from an
unanswered request to the first 1.1 MB of a 212 MB asset, so a slow download and a dead one
looked identical. `DownloadProgress` carries the counts, `UpdateProgress.connecting` is the
stretch before the first byte, and `DownloadProgressText` owns the wording.

`UpdateDownloadSettings` carries the configuration and the stall interval, and the watchdog
it feeds measures **silence, not throughput** - a slow link is a normal way to take a 222 MB
update and must complete, so nothing there may become a rate floor or a cap on total transfer
time. `UpdateDownloadWatchdogTests` drives all of it against a real loopback HTTP server,
because a `URLProtocol` stub hands `URLSession` the body in one piece and so cannot show
progress arriving at all.

## The pane's states

A download can be cancelled (back to `.available`), a failure carries the release so it can
be retried in one press, and `.verifying` is its own state so the seconds `hdiutil` and
`codesign` take are never shown as a download that has stopped moving.

## The swap

The swap runs in a detached shell script that waits for the app to exit first, because a
running bundle cannot replace itself; `UpdateInstaller` documents the sequence. Two
consequences of that wait are load-bearing, and both once made "Install and Relaunch" quietly
reopen the old version:

- From `UpdateState.installing` onward the staged bundle belongs to the script, so nothing
  may delete it on the way out - a failed `mv` is not a visible failure, it is the rollback
  trap silently restoring the old bundle and relaunching it.
- Quitting has to actually happen, promptly, since the script is already spinning on this
  pid: `NSApplication.terminate` is a request that a window or sheet can delay, so
  `RunningApplicationTerminator` backs it with a forced exit.

`UpdateInstallerTests` pins both, plus that the script is written outside the staging
directory it deletes.
