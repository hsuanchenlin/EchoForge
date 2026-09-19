# Permissions

`OpenSuperWhisper/PermissionsManager.swift` owns the permission state the root view switches
on. [setup-health.md](setup-health.md) is the tab that reports it to the user.

## What gates the app

`isMissingRequiredPermission` is the switch: microphone and Accessibility only. Input
Monitoring and Screen Recording are conditional on the shortcut being used and must never
gate the app, and Screen Recording is not part of the polled check either
([screen-context.md](screen-context.md)).

## Accessibility has no completion handler

Accessibility is the one grant made entirely outside the app, with no completion handler to
hang off the way microphone and Input Monitoring have; the file documents the triggers that
stand in for one and why the obvious-looking `NSWorkspace` notification is not among them.

Requesting it goes through the same seam: `requestAccessibilityPermissionOrOpenSystemPreferences`
calls the prompt API (`AXIsProcessTrustedWithOptions`) and opens System Settings beside it -
not after it, since the prompt is asynchronous and the call answers only whether the process
is trusted now - because only the prompt call registers the bundle in the Accessibility trust
list: an app sent straight to the pane has no switch to flip, which is the regression this
path has shipped twice.

## The seam

Statuses are read, and that prompt requested, through `PermissionStatusReading` so the
refresh, transition and request logic is testable at all - `PermissionsManagerRefreshTests`
pins it, and the real TCC calls are exactly what that seam leaves out.
