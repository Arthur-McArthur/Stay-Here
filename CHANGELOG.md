# Changelog

## 0.2.1

- Replace repeated arrow-key desktop transitions with one native jump to the destination desktop.
- Raise and unhide the exact clicked app window before arrival, then verify it is visible in front.
- Use the focused-window Accessibility attribute when other-desktop windows are missing from the ordinary window list.
- Restore any temporarily enabled desktop shortcut without replacing its existing binding.
- Keep a verified Dock press valid when the Dock hides or rearranges after mouse-up, while rejecting actual drags.

## 0.2.0

- Optional one-click Dock navigation for already-running apps, while keeping automatic desktop switching disabled for background launches.
- Accessibility permission control and a separate menu toggle for Dock navigation.
- Navigation follows native desktop shortcuts, checks process identity and desktop ordering, and cancels on newer user input.

## 0.1.2

- Custom pinned-monitor menu-bar icon.
- Initial public source distribution with build, per-user install, and uninstall scripts.
- Documentation of the required Spaces settings, launch-time behavior, and known validation limits.

## 0.1.1

- Compact icon-only menu-bar control.

## 0.1.0

- Initial launch guard using native desktop assignments, temporary LaunchServices metadata, and process placement.
