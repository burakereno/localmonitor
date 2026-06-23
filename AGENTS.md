# Agent Instructions

This project is a native macOS menu bar app built with Swift Package Manager,
SwiftUI, and AppKit.

## Project Commands

- Build debug: `swift build`
- Test: `swift test`
- Run debug app bundle: `./script/build_and_run.sh`
- Build release app bundle: `./scripts/build-app.sh`
- Kill local app: `pkill -x LocalMonitor || true`

## Verification Loop

After meaningful changes, run:

```sh
swift test
./scripts/build-app.sh
```

Use `./script/build_and_run.sh --verify` when launch verification is needed.
