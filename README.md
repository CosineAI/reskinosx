# ElCapitanReskin

A native macOS “shell overlay” that approximates an El Capitan-style Dock + top bar, and uses Accessibility permission to integrate with the running desktop.

## What it does (current)

- Bottom “Dock” overlay window (blurred HUD style)
  - Shows a few pinned apps + running apps
  - Hover magnification + running dot
  - Click to launch / focus
- Top bar overlay window
  - Shows frontmost app name + clock
- Requests Accessibility permission on first launch
- Applies invasive Dock tweaks (auto-hide + faster reveal)

## Run

### Option A: SwiftPM (Terminal)

```bash
swift build
swift run
```

### Option B: Xcode

```bash
swift package generate-xcodeproj
open ElCapitanReskin.xcodeproj
```

## Permissions

- Accessibility: required for deeper window integration (overview/focus control).

## Hotkeys

- Cmd+Option+E: toggle overview overlay (basic placeholder UI for now)

## Notes

- This project uses AppKit windows and overlays. It is not App Store oriented.
- Newer macOS versions may restrict some overlay behavior across Spaces/fullscreen.
