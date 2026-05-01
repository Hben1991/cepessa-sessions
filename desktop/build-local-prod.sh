#!/bin/bash
set -e

###############################################################################
# BUILD LOCAL PRODUCTION VERSION FOR TESTING
# Builds with production bundle ID but doesn't release or notarize
# This script mirrors reset-and-run.sh cleanup but uses production bundle ID
###############################################################################

BINARY_NAME="CepessaSessions"  # Package.swift target — binary paths, pkill, CFBundleExecutable
LOCAL_MODEL_RUNNER_NAME="CepessaLocalModelRunner"
RESOURCE_BUNDLE_NAME="CepessaSessions_CepessaSessions.bundle"
APP_NAME="Cepessa Sessions"
BUNDLE_ID="me.cepessa.sessions"
BUNDLE_ID_DEV="me.cepessa.sessions.local"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"
SIGN_IDENTITY="${OMI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"
VERSION="0.0.0-local"

fix_local_model_runner_linkage() {
    local runner_path="$1"
    [ -f "$runner_path" ] || return 0

    install_name_tool -add_rpath "@executable_path/../Frameworks" "$runner_path" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$runner_path" 2>/dev/null || true
    install_name_tool \
        -change "@rpath/llama.framework/Versions/Current/llama" \
        "@loader_path/../Frameworks/llama.framework/Versions/Current/llama" \
        "$runner_path" 2>/dev/null || true
}

echo "=============================================="
echo "  Building Local Production Version"
echo "  Bundle ID: $BUNDLE_ID"
echo "=============================================="
echo ""

# Kill existing app
echo "[1/7] Stopping existing app..."
pkill -f "$BINARY_NAME" 2>/dev/null || true
pkill -f "Omi" 2>/dev/null || true
sleep 1

# =============================================================================
# STEP 2: RESET TCC PERMISSIONS (before deleting apps!)
# =============================================================================
echo "[2/7] Resetting TCC permissions..."
# Reset BOTH bundle IDs to handle switching between dev and prod
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
tccutil reset All "$BUNDLE_ID_DEV" 2>/dev/null || true

# Belt-and-suspenders: Also clean user TCC database directly via sqlite3
# Note: System TCC database (Screen Recording) is SIP-protected - only tccutil can reset it
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client LIKE '%com.omi.computer-macos%';" 2>/dev/null || true
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client LIKE '%com.omi.desktop%';" 2>/dev/null || true

# =============================================================================
# STEP 3: CLEAN ALL CONFLICTING APP BUNDLES
# =============================================================================
echo "[3/7] Cleaning up conflicting bundles..."

# Main locations
rm -rf "$APP_PATH" 2>/dev/null || true
rm -rf "$APP_BUNDLE" 2>/dev/null || true
rm -rf "/Applications/Omi.app" 2>/dev/null || true
rm -rf "/Applications/Omi Computer.app" 2>/dev/null || true
rm -rf "/Applications/Omi Dev.app" 2>/dev/null || true
rm -rf "$HOME/Desktop/Omi.app" 2>/dev/null || true
rm -rf "$HOME/Downloads/Omi.app" 2>/dev/null || true

# Xcode DerivedData (old builds with same bundle ID)
echo "  Cleaning Xcode DerivedData..."
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Omi.app" -type d 2>/dev/null | while read app; do
    echo "    Removing: $app"
    rm -rf "$app"
done
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Omi Computer.app" -type d 2>/dev/null | while read app; do
    echo "    Removing: $app"
    rm -rf "$app"
done
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Omi Beta.app" -type d 2>/dev/null | while read app; do
    echo "    Removing: $app"
    rm -rf "$app"
done
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Omi Dev.app" -type d 2>/dev/null | while read app; do
    echo "    Removing: $app"
    rm -rf "$app"
done

# DMG staging directories
echo "  Cleaning DMG staging directories..."
rm -rf /private/tmp/omi-dmg-staging-* /private/tmp/omi-dmg-test-* 2>/dev/null || true

# Apps in Trash (STILL registered in Launch Services!)
echo "  Cleaning Omi apps from Trash..."
find "$HOME/.Trash" -maxdepth 1 -name "*OMI*" -o -name "*Omi*" 2>/dev/null | while read item; do
    if [ -e "$item" ]; then
        echo "    Removing: $item"
        rm -rf "$item"
    fi
done

# Eject mounted DMG volumes
echo "  Ejecting mounted Omi DMG volumes..."
for vol in /Volumes/Omi* /Volumes/OMI* /Volumes/dmg.*; do
    if [ -d "$vol" ] 2>/dev/null; then
        echo "    Ejecting: $vol"
        diskutil eject "$vol" 2>/dev/null || hdiutil detach "$vol" 2>/dev/null || true
    fi
done 2>/dev/null || true

# =============================================================================
# STEP 4: RESET LAUNCH SERVICES DATABASE
# =============================================================================
echo "[4/7] Resetting Launch Services database..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user 2>/dev/null || true

# Build release
echo "[5/7] Building release binary..."
swift build -c release --package-path Desktop
swift build -c release --package-path Desktop --product "$LOCAL_MODEL_RUNNER_NAME"

# Create app bundle
echo "[6/7] Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

BINARY_PATH=$(swift build -c release --package-path Desktop --show-bin-path)/"$BINARY_NAME"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

LOCAL_MODEL_RUNNER_PATH=$(swift build -c release --package-path Desktop --show-bin-path)/"$LOCAL_MODEL_RUNNER_NAME"
if [ -f "$LOCAL_MODEL_RUNNER_PATH" ]; then
    cp "$LOCAL_MODEL_RUNNER_PATH" "$APP_BUNDLE/Contents/MacOS/$LOCAL_MODEL_RUNNER_NAME"
fi

# Copy Sparkle framework
SPARKLE_FRAMEWORK="$(swift build -c release --package-path Desktop --show-bin-path)/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

LLAMA_FRAMEWORK="$(swift build -c release --package-path Desktop --show-bin-path)/llama.framework"
if [ -d "$LLAMA_FRAMEWORK" ]; then
    cp -R "$LLAMA_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

# Add rpath for Sparkle
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true
if [ -f "$APP_BUNDLE/Contents/MacOS/$LOCAL_MODEL_RUNNER_NAME" ]; then
    fix_local_model_runner_linkage "$APP_BUNDLE/Contents/MacOS/$LOCAL_MODEL_RUNNER_NAME"
fi

# Copy resources
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
if [ -f "Desktop/Sources/GoogleService-Info.plist" ]; then
    cp Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"
fi

# Copy resource bundle
SWIFT_BUILD_DIR=$(swift build -c release --package-path Desktop --show-bin-path)
if [ -d "$SWIFT_BUILD_DIR/$RESOURCE_BUNDLE_NAME" ]; then
    cp -R "$SWIFT_BUILD_DIR/$RESOURCE_BUNDLE_NAME" "$APP_BUNDLE/Contents/Resources/"
fi
for SWIFT_RESOURCE_BUNDLE in "$SWIFT_BUILD_DIR"/*.bundle; do
    [ -d "$SWIFT_RESOURCE_BUNDLE" ] || continue
    BUNDLE_BASENAME="$(basename "$SWIFT_RESOURCE_BUNDLE")"
    rm -rf "$APP_BUNDLE/Contents/Resources/$BUNDLE_BASENAME"
    cp -R "$SWIFT_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
done

# Copy icon
cp omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns" 2>/dev/null || true

# Copy .env.app
if [ -f ".env.app" ]; then
    cp ".env.app" "$APP_BUNDLE/Contents/Resources/.env"
fi

# Update Info.plist with production bundle ID
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_BUNDLE/Contents/Info.plist"

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Strip extended attributes and sign
echo "[7/7] Signing app..."
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "$APP_BUNDLE" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true

SIGNING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cepessa-prod-signing.XXXXXX")
SIGNING_APP_BUNDLE="$SIGNING_ROOT/$APP_NAME.app"
ditto --norsrc --noextattr --noqtn --noacl "$APP_BUNDLE" "$SIGNING_APP_BUNDLE"
chmod -R u+w "$SIGNING_APP_BUNDLE"
APP_BUNDLE="$SIGNING_APP_BUNDLE"

# Sign Sparkle components
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
LLAMA_FW="$APP_BUNDLE/Contents/Frameworks/llama.framework"
if [ -d "$SPARKLE_FW" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Updater.app" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi
if [ -d "$LLAMA_FW" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$LLAMA_FW"
fi

# Sign main app with release entitlements
codesign --force --options runtime --entitlements Desktop/Cepessa-Release.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

# Install to /Applications
echo ""
echo "Installing to /Applications..."
rm -rf "$APP_PATH"
ditto "$APP_BUNDLE" "$APP_PATH"
chmod -R u+w "$APP_PATH"
find "$APP_PATH" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "$APP_PATH" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true

# Re-register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH"

# Reset UserDefaults for fresh onboarding (both bundle IDs)
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults delete "$BUNDLE_ID_DEV" 2>/dev/null || true

# Remove quarantine and launch
xattr -cr "$APP_PATH"

echo ""
echo "=============================================="
echo "  Build Complete!"
echo "=============================================="
echo ""
echo "App installed: $APP_PATH"
echo "Bundle ID: $BUNDLE_ID"
echo ""
echo "Starting app..."
open "$APP_PATH"
