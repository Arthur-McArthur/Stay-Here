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

## Automated checks

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
