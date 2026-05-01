#!/bin/bash
set -e

BINARY_NAME="CepessaSessions"  # Package.swift target — binary paths, pkill, CFBundleExecutable
LOCAL_MODEL_RUNNER_NAME="CepessaLocalModelRunner"
RESOURCE_BUNDLE_NAME="CepessaSessions_CepessaSessions.bundle"
APP_NAME="Sessions"
BUNDLE_ID="me.cepessa.sessions.local"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BACKEND_DIR="$(dirname "$0")/Backend"
BACKEND_PID=""
TUNNEL_PID=""
TUNNEL_URL="${TUNNEL_URL:-}"

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

# Cleanup function to stop backend and tunnel on exit
cleanup() {
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "Stopping tunnel (PID: $TUNNEL_PID)..."
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Kill existing instances
pkill "$BINARY_NAME" 2>/dev/null || true
lsof -ti:8080 | xargs kill -9 2>/dev/null || true

# Start Cloudflare quick tunnel (auto-generates a *.trycloudflare.com URL)
if command -v cloudflared >/dev/null 2>&1; then
    echo "Starting Cloudflare quick tunnel..."
    TUNNEL_LOG=$(mktemp /tmp/cloudflared-XXXXXX.log)
    cloudflared tunnel --url http://localhost:8080 > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    for i in {1..20}; do
        TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then break; fi
        sleep 0.5
    done
    if [ -n "$TUNNEL_URL" ]; then
        rm -f "$TUNNEL_LOG"
    else
        echo "Warning: Could not get tunnel URL — using localhost (see $TUNNEL_LOG for details)"
        TUNNEL_URL="http://localhost:8080"
    fi
else
    echo "cloudflared not found — skipping tunnel"
    TUNNEL_URL="http://localhost:8080"
fi

# Start backend
echo "Starting backend..."
cd "$BACKEND_DIR"
if [ ! -d "venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
else
    source venv/bin/activate
fi
python main.py &
BACKEND_PID=$!
cd - > /dev/null

# Wait for backend to be ready
echo "Waiting for backend to start..."
for i in {1..30}; do
    if curl -s http://localhost:8080 > /dev/null 2>&1; then
        echo "Backend is ready!"
        break
    fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "Backend failed to start"
        exit 1
    fi
    sleep 0.5
done

# Build debug
swift build -c debug --package-path Desktop
swift build -c debug --package-path Desktop --product "$LOCAL_MODEL_RUNNER_NAME"

# Clean old app bundles from build dir
rm -rf "$BUILD_DIR/Omi Computer.app" "$BUILD_DIR/Omi Beta.app" "$BUILD_DIR/Cepessa Sessions Dev.app" "$BUILD_DIR/Cepessa Sessions.app" 2>/dev/null

# Create app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy binary
cp "Desktop/.build/debug/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
if [ -f "Desktop/.build/debug/$LOCAL_MODEL_RUNNER_NAME" ]; then
    cp "Desktop/.build/debug/$LOCAL_MODEL_RUNNER_NAME" "$APP_BUNDLE/Contents/MacOS/$LOCAL_MODEL_RUNNER_NAME"
    fix_local_model_runner_linkage "$APP_BUNDLE/Contents/MacOS/$LOCAL_MODEL_RUNNER_NAME"
fi

LLAMA_FRAMEWORK="Desktop/.build/debug/llama.framework"
if [ -d "$LLAMA_FRAMEWORK" ]; then
    cp -R "$LLAMA_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

# Copy and fix Info.plist
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 cepessa-sessions-dev" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Copy GoogleService-Info.plist for Firebase when this target includes one.
if [ -f "Desktop/Sources/GoogleService-Info.plist" ]; then
    cp Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"
fi

# Copy resource bundle (contains app assets like herologo.png, omi-with-rope-no-padding.webp, etc.)
SWIFT_BUILD_DIR="Desktop/.build/debug"
if [ -d "$SWIFT_BUILD_DIR/$RESOURCE_BUNDLE_NAME" ]; then
    cp -R "$SWIFT_BUILD_DIR/$RESOURCE_BUNDLE_NAME" "$APP_BUNDLE/Contents/Resources/"
    echo "Copied resource bundle"
else
    echo "Warning: Resource bundle not found at $SWIFT_BUILD_DIR/$RESOURCE_BUNDLE_NAME"
fi
for SWIFT_RESOURCE_BUNDLE in "$SWIFT_BUILD_DIR"/*.bundle; do
    [ -d "$SWIFT_RESOURCE_BUNDLE" ] || continue
    BUNDLE_BASENAME="$(basename "$SWIFT_RESOURCE_BUNDLE")"
    rm -rf "$APP_BUNDLE/Contents/Resources/$BUNDLE_BASENAME"
    cp -R "$SWIFT_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "Copied SwiftPM resource bundle $BUNDLE_BASENAME"
done

# Copy .env.app (app runtime secrets only) and add API URL
if [ -f ".env.app" ]; then
    cp .env.app "$APP_BUNDLE/Contents/Resources/.env"
else
    touch "$APP_BUNDLE/Contents/Resources/.env"
fi
# Set API URL to tunnel for development (overrides production default)
if grep -q "^OMI_API_URL=" "$APP_BUNDLE/Contents/Resources/.env"; then
    sed -i '' "s|^OMI_API_URL=.*|OMI_API_URL=$TUNNEL_URL|" "$APP_BUNDLE/Contents/Resources/.env"
else
    echo "OMI_API_URL=$TUNNEL_URL" >> "$APP_BUNDLE/Contents/Resources/.env"
fi
echo "Using backend: $TUNNEL_URL"

# Copy app icon
cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Sign app with a stable identity so TCC permissions persist across rebuilds.
# Auto-detect: Developer ID > Apple Development > ad-hoc fallback.
SIGN_IDENTITY="${OMI_SIGN_IDENTITY:-}"
chmod -R u+w "$APP_BUNDLE"
find "$APP_BUNDLE" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "$APP_BUNDLE" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
SIGNING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cepessa-dev-signing.XXXXXX")
SIGNING_APP_BUNDLE="$SIGNING_ROOT/$APP_NAME.app"
ditto --norsrc --noextattr --noqtn --noacl "$APP_BUNDLE" "$SIGNING_APP_BUNDLE"
chmod -R u+w "$SIGNING_APP_BUNDLE"
APP_BUNDLE="$SIGNING_APP_BUNDLE"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
    fi
fi
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: $SIGN_IDENTITY"
    if [ -d "$APP_BUNDLE/Contents/Frameworks/llama.framework" ]; then
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/llama.framework"
    fi
    codesign --force --options runtime --entitlements Desktop/Cepessa.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo ""
    echo "ERROR: No signing identity found. Ad-hoc signing causes macOS to reset"
    echo "       Screen Recording permissions for ALL Omi apps (including prod/beta)."
    echo ""
    echo "  Fix: Install an Apple Development certificate in Keychain Access,"
    echo "       or set OMI_SIGN_IDENTITY to a valid identity."
    echo ""
    exit 1
fi

echo "Dev build complete: $APP_BUNDLE"
echo ""
echo "=== Services Running ==="
echo "Backend:  http://localhost:8080 (PID: $BACKEND_PID)"
if [ -n "$TUNNEL_PID" ]; then
echo "Tunnel:   $TUNNEL_URL (PID: $TUNNEL_PID)"
else
echo "Tunnel:   not running (using $TUNNEL_URL)"
fi
echo "========================"
echo ""
open "$APP_BUNDLE"

# Wait for backend process (keeps script running and shows logs)
echo "Press Ctrl+C to stop..."
wait "$BACKEND_PID"
