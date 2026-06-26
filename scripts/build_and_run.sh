#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ "$MODE" == "run" || "$MODE" == "--debug" || "$MODE" == "debug" ||
      "$MODE" == "--logs" || "$MODE" == "logs" || "$MODE" == "--telemetry" ||
      "$MODE" == "telemetry" || "$MODE" == "--verify" || "$MODE" == "verify" ]]; then
  if [[ $# -gt 0 ]]; then shift; fi
else
  MODE="run"
fi

APP_NAME="Lentis"
BUNDLE_ID="com.kalicooper.lentis"
MIN_SYSTEM_VERSION="26.0"
# Sparkle feed — same as package_app.sh. The debug bundle points at the real
# feed so "Check for Updates…" works during dev (a debug build's CFBundleVersion
# is low, so Sparkle will find the latest release; it won't auto-install over a
# dev build because of Apple code-sign mismatch, but the check + alert works).
SPARKLE_FEED_URL="${LENTIS_SPARKLE_FEED_URL:-https://github.com/lijiaxiang63/Lentis/releases/latest/download/appcast.xml}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="Lentis_Lentis.bundle"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR"
BUILD_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
# SPM places the binary-target framework under the arch-specific build dir.
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -d "$BUILD_DIR/$RESOURCE_BUNDLE_NAME" ]]; then
  mkdir -p "$APP_CONTENTS/Resources"
  cp -R "$BUILD_DIR/$RESOURCE_BUNDLE_NAME" "$APP_CONTENTS/Resources/"
fi

# Embed Sparkle.framework so the debug bundle can load it (the executable links
# @rpath/Sparkle.framework/...). Mirrors package_app.sh: cp -R preserves the
# versioned symlinks, and the @executable_path/../Frameworks rpath is added
# (idempotent) so dyld finds it without falling back to the build directory.
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP_FRAMEWORKS"
  cp -R "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/"
  if ! otool -l "$APP_BINARY" | grep -q "path @executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BINARY"
  fi
fi

plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
# Sparkle keys — mirror package_app.sh so the debug bundle's "Check for Updates…"
# menu item has a feed URL + auto-check enabled. SUPublicEDKey is omitted (dev
# builds are ad-hoc signed; EdDSA verification is a release-only concern).
plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$INFO_PLIST"
plutil -insert SUEnableAutomaticChecks -bool true "$INFO_PLIST"

# Ad-hoc sign the bundle (re-signs the embedded framework too) so Gatekeeper /
# library validation don't block loading Sparkle in the debug bundle.
codesign --force --deep -s - "$APP_BUNDLE" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args "$@"
}

case "$MODE" in
  run)
    open_app "$@"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" "$@"
    ;;
  --logs|logs)
    open_app "$@"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app "$@"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app "$@"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [app arguments...]" >&2
    exit 2
    ;;
esac
