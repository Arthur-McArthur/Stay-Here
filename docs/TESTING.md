# Validation

## Observed behavior

The original implementation was tested on Apple Silicon running macOS 26.7 with `AppleSpacesSwitchOnActivate=false` and `workspaces-auto-swoosh=false`.

A disposable native application was assigned to a desktop different from the active desktop. A separate observer recorded active Space changes and read the test window's actual Space membership from WindowServer.

| Test | Active desktop stayed put | Window on assigned desktop |
| --- | --- | --- |
| Persistence-launch flag alone | Yes | No |
| Persistence-launch flag + process assignment | Yes | Yes |
| Complete helper, three consecutive cold launches | Yes, zero recorded Space changes in all three runs | Yes, all three runs |

The complete helper also restored the previous foreground app and restored its temporary per-process launch flag after startup. The app's owner subsequently tested REAPER and reported that the behavior worked.

An isolated REAPER launch placed its windows on its assigned desktop. Its fresh-profile startup notice interrupted full automated qualification; that run is not evidence of complete end-to-end REAPER coverage. Raw host logs, application inventories, local paths, profile data, and research artifacts are deliberately not included in this repository.

## One-click Dock navigation

Version 0.2.0 was additionally tested on a single display with both automatic-switch preferences still disabled. A test helper with Accessibility access launched a disposable, natively assigned application: the active desktop stayed on Desktop 1 and its window appeared on Desktop 2. One simulated ordinary Dock click then produced a `dock-navigation` event and a completed native transition to Desktop 2. The cold-launch guard restored its temporary metadata before that click. This establishes the complete input-to-navigation path in the test process; the independently installed app must receive its own Accessibility grant.

Direct application activation, Dock accessibility press actions, and a direct user-generated process-focus request did not consistently navigate under the disabled automatic-switch settings. The navigation feature therefore uses enabled native desktop shortcuts. Modifier flags include the arrow keys' function flag; omitting that flag failed to trigger the default desktop shortcut in the native test.

Restoring both automatic-switch preferences, or leaving the Dock preference enabled with only the global preference disabled, allowed an isolated REAPER launch to switch desktops. A harmless test app alone did not expose the REAPER case. Keep both settings disabled when validating launch protection.

Additional acceptance checks:

- Grant Accessibility to the installed bundle, restart, and verify its `dock-navigation-armed` record reports permission.
- Repeat an intentional click over multiple desktop transitions.
- Launch a closed app by clicking its Dock icon: it must stay on its assigned desktop without following it.
- Check modifier clicks, context menus, dragging, and cancellation by another click or key press.
- Disable the optional Dock feature or revoke Accessibility: launch guarding must remain available.
- Multiple displays are deliberately not routed by the optional feature; full-screen and unusual app window behavior remain unqualified.

The final consistently signed installed bundle subsequently reported Accessibility permission and completed a normal browser's Dock-navigation route. Moving it to the main Applications folder and updating its login entry retained that permission. A later disposable-app check overlapped other Dock navigation, so its desktop snapshot alone is not independent proof of that click's route.

## Packaging checks

The build script compiles the native app, validates `Info.plist`, applies an ad-hoc signature, and verifies that signature. Installer tests use temporary directories and mocked service operations to exercise successful installation, rollback, dry runs, and refusal to remove an unrelated app. They do not launch apps or edit desktop assignments.

## Manual live test

Save any work before testing, since a failure may still change the active desktop.

1. Apply the tested Spaces settings described in the README.
2. Give a harmless test app a specific native desktop assignment.
3. Start Stay Here, then switch to another regular desktop.
4. Fully quit and launch the test app. Confirm that the active desktop stays unchanged.
5. Manually switch to the assigned desktop and confirm that its window is there and usable.
6. Repeat from the Dock, Spotlight, and a document opened with the app.
7. Repeat with the helper disabled to establish whether the original behavior is reproducible.
8. Check that startup focus is preserved, manual desktop changes still work, and the helper can be disabled or quit.

Full-screen Spaces, multiple displays, overlapping slow launches, and apps with unusual startup activation behavior should be reported separately. A passing build does not qualify those cases.
