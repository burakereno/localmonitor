#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LocalMonitor"
BUNDLE_ID="dev.local.LocalMonitor.local"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Local Monitor.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Sources/LocalMonitor/Resources/AppIcon.icns"

REMOTE_LATEST_TAG="$(git -C "$ROOT_DIR" ls-remote --tags --refs origin 'v*' 2>/dev/null | awk '{ sub("refs/tags/", "", $2); print $2 }' | sort -Vr | head -1 || true)"
LOCAL_LATEST_TAG="$(git -C "$ROOT_DIR" tag -l 'v*' --sort=-v:refname | head -1)"
LATEST_TAG="${REMOTE_LATEST_TAG:-$LOCAL_LATEST_TAG}"
APP_VERSION="${LATEST_TAG#v}"
if [[ -z "$LATEST_TAG" || "$APP_VERSION" == "$LATEST_TAG" ]]; then
  APP_VERSION="0.1.0"
fi
APP_BUILD_NUMBER="$(echo "$APP_VERSION" | awk -F. '{print $3}')"
if [[ -z "$APP_BUILD_NUMBER" || "$APP_BUILD_NUMBER" == "0" ]]; then
  APP_BUILD_NUMBER="1"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

RESOURCE_BUNDLE="$(swift build --show-bin-path)/LocalMonitor_LocalMonitor.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/"
fi
mkdir -p "$APP_CONTENTS/Resources"
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP_CONTENTS/Resources/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Local Monitor</string>
  <key>CFBundleDisplayName</key>
  <string>Local Monitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
