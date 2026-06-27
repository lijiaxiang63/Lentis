#!/bin/bash
# package_app.sh — Lentis
# Builds a release binary and creates the .app bundle + DMG for distribution.
# Use --notarize to sign with Developer ID and notarize with Apple.
# Licensed under the MIT License. See LICENSE for details.
set -e

APP_NAME="Lentis"
# Bundle version. Override from CI (e.g. the release tag) via the environment;
# falls back to these defaults for local builds.
#   CFBundleShortVersionString (marketing version, e.g. 2.0.0)
APP_VERSION="${LENTIS_MARKETING_VERSION:-2.2.1}"
#   CFBundleVersion (build number, e.g. a monotonically increasing integer)
APP_BUILD="${LENTIS_BUILD_VERSION:-8}"
# Set to your own "Developer ID Application: ..." identity before using --notarize.
SIGNING_IDENTITY="Developer ID Application: CHANGE_ME"
NOTARY_PROFILE="Lentis"
NOTARIZE=false

# --- Sparkle auto-update (see AGENTS.md "Auto-update (Sparkle)") ---
# The appcast feed hosted as a GitHub Release asset (releases/latest/download
# redirects to the newest release's appcast.xml). Stable + no Pages dep.
SPARKLE_FEED_URL="${LENTIS_SPARKLE_FEED_URL:-https://github.com/lijiaxiang63/Lentis/releases/latest/download/appcast.xml}"
# EdDSA PUBLIC key (base64). Injected from the LENTIS_SPARKLE_PUBLIC_KEY env var
# by CI; empty for local builds → the key is omitted and Sparkle falls back to
# Apple code-signing verification only (fine for dev; releases must set it).
SPARKLE_PUBLIC_KEY="${LENTIS_SPARKLE_PUBLIC_KEY:-}"

if [[ "$1" == "--notarize" ]]; then
    NOTARIZE=true
fi

# Ensure we are in project root
cd "$(dirname "$0")/.."

echo "Building ${APP_NAME} ${APP_VERSION} (build ${APP_BUILD}, Release)..."
swift build -c release --arch arm64

BUILD_DIR=".build/release"
# SPM places the binary-target framework under the arch-specific build dir.
SPARKLE_FRAMEWORK=".build/arm64-apple-macosx/release/Sparkle.framework"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

echo "Creating App Bundle at ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "Copying Executable..."
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/"

# Embed Sparkle.framework (the only native dependency). cp -R preserves the
# versioned-framework symlinks (Versions/Current -> B, top-level symlinks) —
# do NOT use -L. Sparkle ships Downloader/Installer XPC services + an Updater
# helper app inside the framework.
if [[ -d "${SPARKLE_FRAMEWORK}" ]]; then
    mkdir -p "${FRAMEWORKS_DIR}"
    echo "Embedding Sparkle.framework..."
    cp -R "${SPARKLE_FRAMEWORK}" "${FRAMEWORKS_DIR}/"
    # The executable links @rpath/Sparkle.framework/...; SPM only sets
    # @loader_path (= Contents/MacOS). Add the Frameworks rpath so the dylib
    # resolves at runtime. Idempotent: skip if already present.
    if ! otool -l "${MACOS_DIR}/${APP_NAME}" | grep -q "path @executable_path/../Frameworks"; then
        install_name_tool -add_rpath @executable_path/../Frameworks "${MACOS_DIR}/${APP_NAME}"
    fi
    # Lentis is NOT sandboxed (uses Foundation.Process, NSWorkspace, full
    # filesystem access), so Sparkle's XPC services (Downloader.xpc /
    # Installer.xpc) are never invoked — they're only for sandboxed apps.
    # Remove them per Sparkle's own recommendation: saves ~space and avoids
    # the per-component entitlement signing --deep would clobber.
    # https://sparkle-project.org/documentation/sandboxing/#removing-xpc-services
    rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices" \
           "${FRAMEWORKS_DIR}/Sparkle.framework/XPCServices"
else
    echo "WARNING: Sparkle.framework not found at ${SPARKLE_FRAMEWORK} — the app will not auto-update." >&2
fi

echo "Copying SwiftPM Resources..."
cp -R "${BUILD_DIR}/Lentis_Lentis.bundle" "${RESOURCES_DIR}/"

echo "Copying App Icon..."
cp "AppIcon.icns" "${RESOURCES_DIR}/"

echo "Creating Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.kalicooper.lentis</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Lentis needs access to open image files.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Lentis needs access to open image files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Lentis needs access to open image files.</string>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>
EOF
# EdDSA public key — only when provided (releases). Omitting it disables EdDSA
# verification; Sparkle then relies on Apple code signing (OK for dev builds).
if [[ -n "${SPARKLE_PUBLIC_KEY}" ]]; then
    printf '    <key>SUPublicEDKey</key>\n    <string>%s</string>\n' "${SPARKLE_PUBLIC_KEY}" >> "${CONTENTS_DIR}/Info.plist"
fi
cat >> "${CONTENTS_DIR}/Info.plist" <<EOF
</dict>
</plist>
EOF

if $NOTARIZE; then
    echo "Code signing with Developer ID..."
    # Sign Sparkle component-by-component (inside-out), NOT with --deep.
    # --deep is deprecated by Apple and can clobber per-component entitlements
    # (e.g. Downloader.xpc's). The XPC services were removed above (non-sandboxed
    # app), so only the Autoupdate helper + Updater.app + the framework remain.
    # See Sparkle's code-signing guide:
    # https://sparkle-project.org/documentation/sandboxing/#code-signing
    if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
        SPARKLE_VER="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"
        codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${SPARKLE_VER}/Autoupdate"
        codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${SPARKLE_VER}/Updater.app"
        codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${FRAMEWORKS_DIR}/Sparkle.framework"
    fi
    codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${MACOS_DIR}/${APP_NAME}"
    codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "Signature OK"
else
    echo "Ad-hoc code signing (use --notarize for Developer ID signing)..."
    # Same inside-out sequence without --deep (consistency with the notarize
    # path; --deep is deprecated and unnecessary for ad-hoc signing too).
    if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
        SPARKLE_VER="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"
        codesign --force -s - "${SPARKLE_VER}/Autoupdate"
        codesign --force -s - "${SPARKLE_VER}/Updater.app"
        codesign --force -s - "${FRAMEWORKS_DIR}/Sparkle.framework"
    fi
    codesign --force -s - "${APP_BUNDLE}"
fi

echo "Successfully created ${APP_BUNDLE}"

# --- Create DMG for distribution ---
DMG_NAME="${APP_NAME}.dmg"
DMG_TEMP="dmg_tmp"

echo "Creating DMG at ${DMG_NAME}..."
rm -rf "${DMG_TEMP}" "${DMG_NAME}"
mkdir -p "${DMG_TEMP}"

cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_NAME}" \
    -quiet

rm -rf "${DMG_TEMP}"

if $NOTARIZE; then
    echo "Submitting ${DMG_NAME} for notarization..."
    xcrun notarytool submit "${DMG_NAME}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "${DMG_NAME}"

    echo ""
    echo "Successfully created and notarized ${DMG_NAME}"
else
    echo ""
    echo "Successfully created ${DMG_NAME} (not notarized)"
fi
echo "To install: open ${DMG_NAME} and drag ${APP_NAME} to Applications"
