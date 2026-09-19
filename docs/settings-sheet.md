# Settings: the sheet, its tab bar, and shutting down

Settings is a **sheet**, it has **no `TabView`**, and `SettingsSheetLayout` owns what
follows. [setup-health.md](setup-health.md) covers the first tab's content and records the
last time the sheet had to get wider.

## The tab bar is this app's own control

The tab bar is `SettingsTabBar` (`OpenSuperWhisper/SettingsTabBar.swift`), because AppKit's
was not fixable from outside: a SwiftUI `TabView` in a sheet renders its tabs as one
`NSSegmentedControl`, and on macOS 26 that control drew its selection pill on the selected
segment's rect and its keyboard focus ring about 6 pt wider - on every tab, at 550 pt and
again at 680 pt. Widening the sheet did not settle it and no containment could, since both
rects are produced inside AppKit. The owned bar derives all four - the tab's frame, the
selection fill, the focus frame (`focusRingOutset` outside it) and the hit target - from one
frame per tab, so they cannot disagree. `SettingsTabBarGeometryTests` reads that back out of
rendered pixels; it can, because the ring is now an ordinary overlay rather than something
only a key window draws. Do not "simplify" this back to a `TabView`, and do not reach for
`focusEffectDisabled()` without the ring beside it - that removes the affordance rather than
fixing it.

## The bar sets the width

Its width is set by the tab bar and not by any pane: the bar is one row of titles, so the
tab titles and the sheet's width are a single decision. The 550 pt sheet was set when there
were four tabs and never revisited; by eight it was 122 pt short and every title truncated.
`SettingsTabBarFitTests` lays the bar out headlessly and fails when the titles stop fitting,
so adding a tab or a longer title says so at test time. Tab titles live in `SettingsTab`,
which is the list that test reads.

## Only the selected pane is built

That is a deliberate change: the `TabView` built every tab whenever Settings opened - the
measured fact that kept `CloudSettingsViewModel`'s initialiser off the Keychain - and only
deferred each pane's `onAppear` until it was displayed. That timing is what carries over, so
the `onAppear` refreshes several panes rely on still run when they did; what is new is that a
pane nobody opens (the Cloud one, which reads the Keychain in `onAppear`) is now never built
at all. A pane can no longer resize the bar either, since the bar is its sibling with a width
of its own; the segmented control *was* sized from the whole hosted tree, and at 680 pt a
900 pt pane took it from 648 to 657 and moved every segment as the user changed tabs.

What still contains a pane is `settingsPane()` (`SettingsSheetLayout.swift`), applied to the
pane on screen: `Color.clear` takes the offered width and reports none of its own, so the
pane is an overlay inside it and never speaks for the sheet. `frame(maxWidth:)` and
`frame(idealWidth:)` were measured and do not contain it; `frame(width:)` does but clips real
content; the modifier is deliberately un-clipped so nothing trims a focus frame at a pane's
edge.

## A visible sheet blocks restart

A visible window-modal sheet makes AppKit **refuse the quit Apple Event** loginwindow sends,
so an open Settings sheet cancels the user's restart and puts up *"'Kongweh' interrupted
restart"*. `Utils/PowerOffPresentationGuard.swift` is the one owner of that: it reads
`NSWorkspace.willPowerOffNotification` and broadcasts `.dismissModalPresentations`, and
`.dismissesOnPowerOff($binding)` takes each presentation down. Two things there are absolute
and both are measured, not reasoned:

- **The dismissal must go through the SwiftUI binding** - AppKit's sheet check runs before
  `applicationShouldTerminate`, so the delegate is never consulted, and `NSWindow.endSheet`
  never touches the state SwiftUI presents from.
- **Every `.sheet` and `.confirmationDialog` needs the modifier**, which a source scan in
  `ModalDismissalOnPowerOffTests` enforces; `.alert` is exempt because an alert measurably
  does not block termination while a confirmation dialog does.

The one presentation outside the guard's reach is `AppStyleMappingSettingsView`'s
`NSOpenPanel.runModal()`, which runs its own event loop - transient, and the user is at the
machine while it is up. The guard wins a race rather than proving a rule: taking a sheet down
costs ~270 ms and loginwindow quits apps one at a time, which is seconds.
