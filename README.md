# Local Monitor

Local Monitor is a native macOS menu bar app for managing local web projects and listening ports.

## Install

Download the latest macOS build from GitHub Releases:

[Download LocalMonitor.dmg](https://github.com/burakereno/localmonitor/releases/latest)

Open the DMG, drag **Local Monitor.app** to Applications, then launch it from Applications.

If macOS blocks the first launch, run:

```sh
xattr -cr "/Applications/Local Monitor.app"
```

## Updates

Release builds check GitHub Releases for updates from inside the app. Every push to `main` automatically builds a new DMG release and increments the patch version.

## Development

```sh
swift test
./scripts/build-app.sh
```
