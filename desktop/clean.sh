#!/bin/bash
# Full cleanup script - removes app and all permissions/data

BUNDLE_ID="me.cepessa.sessions"
BUNDLE_ID_DEV="me.cepessa.sessions.local"

echo "=== Full Cepessa Sessions Cleanup ==="

# Kill the app if running
echo "Killing app..."
pkill -9 "Cepessa Sessions" 2>/dev/null || true

# Remove apps from Applications (all variants)
for app in "/Applications/Cepessa Sessions.app" "/Applications/Cepessa Sessions Ready.app"; do
    if [ -d "$app" ]; then
        echo "Removing $app..."
        rm -rf "$app"
    fi
done

# Remove from build folders (all variants)
for app in \
    "build/Cepessa Sessions.app" \
    "build/Cepessa Sessions Ready.app" \
    "Desktop/Build/Cepessa Sessions.app" \
    "Desktop/Build/Cepessa Sessions Ready.app"; do
    if [ -d "$app" ]; then
        echo "Removing $app..."
        rm -rf "$app"
    fi
done

# Reset all TCC permissions (works fully once app is removed)
echo "Resetting all TCC permissions..."
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
tccutil reset All "$BUNDLE_ID_DEV" 2>/dev/null || true

# Delete user defaults
echo "Deleting user defaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults delete "$BUNDLE_ID_DEV" 2>/dev/null || true

# Clean up Library folders
echo "Cleaning Library folders..."
for id in "$BUNDLE_ID" "$BUNDLE_ID_DEV"; do
    rm -rf ~/Library/Application\ Support/"$id" 2>/dev/null || true
    rm -rf ~/Library/Caches/"$id" 2>/dev/null || true
    rm -rf ~/Library/Preferences/"$id".plist 2>/dev/null || true
done

# Kill System Settings and tccd to force refresh
echo "Restarting system services..."
killall "System Settings" 2>/dev/null || true
killall tccd 2>/dev/null || true

echo ""
echo "=== Cleanup complete ==="
echo "Note: Notification permissions must be reset manually in System Settings"
