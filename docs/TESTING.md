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

### 0.2.2 latency changes

The fixed 100 ms post-click dispatch delay was removed. Accessibility window focusing now overlaps the native desktop transition, and arrival verifies the window immediately instead of always repeating the focus operations and waiting another 80 ms. The guarded repair remains available when the window is not visible in front. Completion logs also report `clickElapsed`, measured from receipt of mouse-up.

The signed build and seven installer checks passed. An initial automated timing attempt encountered a locked desktop and produced no valid samples; that attempt is excluded. After unlocking, three user-performed Firefox Dock switches from D1 to D3 completed with the window verified visible in front. Navigation times were 0.381, 0.310, and 0.340 seconds, a median of 0.340 seconds versus the previous comparable median of 0.485 seconds (approximately 30% faster). Receipt-of-mouse-up to completion times were 0.384, 0.311, and 0.341 seconds. These are measurements on the qualified single-display host, not a guarantee for all apps or configurations.

### 0.2.1 direct-jump and visibility qualification

On the same single-display macOS 26 host, native numbered desktop actions jumped D1→D3 without visiting D2. Originally disabled actions were disabled again after posting, and the serialized saved shortcut preferences were byte-identical before and after the probe.

The installed, consistently signed 0.2.1 build retained its Accessibility grant. One simulated ordinary click on Firefox's Dock icon from D1 produced a direct D1→D3 transition. A separate WindowServer observer confirmed Firefox's exact window was on-screen and its process owned the top normal window on arrival. The helper recorded `windowVisible=true` and completion in approximately 0.49 seconds. The observer saw no intermediate D2. This checks the actual Firefox window, not just the active desktop or foreground process.

The direct action currently supports regular Desktops 1–9 on macOS 26 and a single display. Full-screen and multiple-display routing are excluded. Existing shortcut bindings are read without replacement; temporary runtime enabling is restored after delivery and on disable/quit.

A subsequent disposable-app cold launch stayed on its original desktop, followed by one Dock click that reached its assigned desktop with the window verified visible in front in approximately 0.60 seconds. Same-desktop Firefox navigation also recorded a verified visible window in approximately 0.17 seconds. The input handler no longer requires a second live hit-test after mouse-up, because the Dock may already be hidden or rearranged by then; drag displacement and process identity are still checked.

The prior arrow-navigation route could drop a subsequent shortcut or reach the destination without showing the requested window promptly. Its fixed delay and advisory app activation were replaced by the direct action and explicit window raise. `SLSManagedDisplayIsAnimating` was observed false across several real desktop changes, so it is not used as proof that a transition has settled.

### 0.2.0 preliminary observations

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
