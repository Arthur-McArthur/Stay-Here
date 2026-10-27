# Stay Here

**Open an app on its assigned macOS desktop without being dragged there with it.**

If an app belongs on Desktop 2 and you launch it while working on Desktop 1, Stay Here keeps its window on Desktop 2 and leaves you on Desktop 1. A small pinned-monitor icon lives in the menu bar.

Stay Here reads your existing **Dock → Options → Assign To → This Desktop** assignments. It does not replace or rewrite them.

## Status and requirements

- Experimental and open source under the [MIT license](LICENSE).
- Requires macOS 26 or later and Xcode Command Line Tools to build.
- Tested on Apple Silicon with macOS 26.7. Other macOS versions and Intel Macs have not been behaviorally qualified.
- Uses private LaunchServices and SkyLight APIs. Apple can change these APIs, so compatibility with future updates is not guaranteed.
- No SIP changes or administrator access are required. The launch guard works without Accessibility access; optional one-click Dock navigation requires it.

This guards **new app launches**. It is not a general blocker for every possible focus or desktop change made by an already-running app. Full-screen Spaces and multiple displays need more testing.

## Set up Spaces

The tested configuration has both of these settings disabled:

```sh
defaults write -g AppleSpacesSwitchOnActivate -bool false
defaults write com.apple.dock workspaces-auto-swoosh -bool false
killall Dock
```

The first corresponds to **System Settings → Desktop & Dock → Mission Control → “When switching to an application, switch to a Space with open windows for the application.”** The second disables the Dock's separate automatic window-follow behavior. Restarting the Dock briefly hides it; it does not quit your apps.

These settings also change normal app navigation: Command-Tab may no longer take you to an app's other desktop, and the native Dock can require another click. Stay Here's **One-click Dock switching** option restores intentional Dock navigation while leaving automatic switching off. Record your old values first if you may want to restore them:

```sh
defaults read -g AppleSpacesSwitchOnActivate
defaults read com.apple.dock workspaces-auto-swoosh
```

Stay Here and its installer do not write these preferences. The installer checks that they are disabled and otherwise stops with instructions.

## Build and install

Install Apple's Command Line Tools if needed:

```sh
xcode-select --install
```

Then clone and install:

```sh
git clone https://github.com/Arthur-McArthur/Stay-Here.git
cd Stay-Here
./scripts/build.sh
python3 scripts/manage.py install
```

The installer starts the app immediately and enables it at login. It installs only for the current user:

| Item | Location |
| --- | --- |
| App | `~/Applications/Stay Here.app` |
| Login agent | `~/Library/LaunchAgents/com.arthurmcarthur.stay-here.plist` |
| Local logs | `~/Library/Logs/Stay Here/` |

Run without installing or enabling login startup:

```sh
open -g "build/Stay Here.app"
```

Quit a manually opened copy before installing, so there is only one helper running. Local builds are ad-hoc signed, not Developer ID signed or notarized; this project does not include a notarized download.

Ad-hoc builds can lose their Accessibility grant when rebuilt. If you have a code-signing certificate, use the same identity for each build, for example `STAY_HERE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh`. Grant Accessibility after installing that signed build. The project includes no signing certificates or private keys.

## Use

Click the pinned-monitor icon to toggle **Keep this desktop when apps open**, or choose **Quit Stay Here**. Quitting stops it for the current session; the installed login agent will start it at your next login.

To enable one-click navigation, choose **Enable one-click Dock switching…** and allow Stay Here under **System Settings → Privacy & Security → Accessibility**. Restart Stay Here after granting access. Once allowed, the menu item becomes **One-click Dock switching**, which you can turn off separately.

With this option enabled, one ordinary left-click on an already-running app's Dock icon follows its window to the other desktop. Clicking a closed app still launches it on its assigned desktop and leaves you where you are. Modified clicks, drags, and apps still starting are left to macOS. A new click, key press, or scroll cancels pending navigation.

One-click navigation currently supports a single display. It uses your enabled **Move left a space / Move right a space** keyboard shortcuts, honoring custom bindings. Keep those shortcuts enabled under **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**. Crossing several desktops uses their normal transition animations. Multiple displays remain unsupported by this optional feature.

To include another app, go to its desired desktop, then right-click its Dock icon and choose **Options → Assign To → This Desktop**. Stay Here reads the assignment on that app's next launch. No helper restart is needed.

It automatically covers all apps assigned to a specific regular desktop. Apps set to **None** or **All Desktops** are left alone. There is currently no per-app inclusion/exclusion menu.

## Uninstall

```sh
python3 scripts/manage.py uninstall
```

This stops the installed helper and removes its app and login agent. It preserves your desktop assignments, the Spaces preferences you configured, and local logs. Quit any manually opened build separately.

Preview installation or removal without changing anything:

```sh
python3 scripts/manage.py install --dry-run
python3 scripts/manage.py uninstall --dry-run
```

## How it works

For an app launching onto another assigned desktop, Stay Here:

1. Reads the native app binding and resolves its current Space ID.
2. Temporarily sets that process's LaunchServices persistence-launch flag, which bypasses the Dock's app-ready desktop jump.
3. Uses `SLSProcessAssignToSpace` to place the process on the desktop it is already assigned to.
4. Restores foreground focus only while you remain on the original desktop.
5. Restores the temporary launch flag after the app reports readiness and a short grace period, or when the helper is disabled or quits.

The launch guard never switches the active Space. Process identity checks use the PID, LaunchServices ASN, bundle ID, executable path, and launch date when available. An originally absent persistence flag is restored as `false`; an existing `true` flag is preserved.

One-click Dock navigation is a separate input path. Accessibility hit-testing identifies the clicked Dock item and its exact application URL. Only an existing, finished-launching process with a window on another Space is eligible. After an unmodified click, Stay Here posts the native desktop-navigation shortcut, verifies each transition, then focuses the selected app. It does not change the automatic-switch settings or move the app's windows. Navigation stops if the process identity, desktop ordering, permissions, or user intent changes.

The app makes no network requests and contains no telemetry. Diagnostic logs contain process IDs, bundle identifiers, Space IDs, and API results, not window titles or project contents. Mouse events identify Dock clicks; key-down and scroll notifications only cancel navigation. Typed characters are never inspected or logged.

## Development and validation

```sh
./scripts/build.sh
python3 -m unittest discover -s tests -v
```

See [validation notes](docs/TESTING.md) for the live test procedure, observed results, and limitations. CI builds and checks packaging; it does not demonstrate live Spaces behavior.

Optional diagnostic arguments, passed to the executable inside the app:

```sh
"build/Stay Here.app/Contents/MacOS/StayHere" --headless --duration 30
"build/Stay Here.app/Contents/MacOS/StayHere" --headless --duration 30 --only-bundle com.apple.TextEdit
```

Run only one copy at a time. A test app must have a native desktop assignment for the guard to act.

## Reporting problems

Include your macOS version, Mac architecture, display arrangement, the affected app's version, its Dock assignment, and whether the launch came from the Dock, Spotlight, or a file. Review logs for app identifiers you do not want to publish before attaching them to an issue.
