#!/bin/bash
# Take Five installer (Apple Silicon Macs only).
# Double-click to install. Pure copy + launch, no compilation needed.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/TakeFive.app"
APP_DST="/Applications/TakeFive.app"

echo "================================================"
echo "  Take Five installer"
echo "================================================"
echo

if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: $APP_SRC not found."
    echo "Keep install.command in the same folder as TakeFive.app."
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

# 1. Stop any existing instance (and any leftover from old name)
echo "Stopping any running instance..."
pkill -f "MacOS/TakeFive" 2>/dev/null || true
pkill -f "MacOS/BreakEnforcer" 2>/dev/null || true
pkill -f "break_enforcer.py" 2>/dev/null || true
pkill -f "break_window" 2>/dev/null || true
sleep 1

# 2. Pick a destination /Applications has write access for, fall back to ~/Applications
if [ -w "/Applications" ]; then
    DEST_PARENT="/Applications"
else
    mkdir -p "$HOME/Applications"
    DEST_PARENT="$HOME/Applications"
    APP_DST="$DEST_PARENT/TakeFive.app"
fi

echo "Installing to $DEST_PARENT/..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# 3. Strip quarantine xattr so Gatekeeper doesn't block the .app
echo "Removing quarantine flag..."
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# 4. Make sure binaries are executable (zip extraction sometimes drops the bit)
chmod +x "$APP_DST/Contents/MacOS/TakeFive" 2>/dev/null || true
chmod +x "$APP_DST/Contents/MacOS/break_window" 2>/dev/null || true

# 5. Refresh Launch Services
touch "$APP_DST"

echo
echo "================================================"
echo "  Installed at: $APP_DST"
echo "================================================"
echo
echo "Launching..."
open "$APP_DST"
sleep 2

echo
echo "Look for the 5 icon in your menu bar (top right of the screen)."
echo
echo "To auto-start at login:"
echo "  System Settings  >  General  >  Login Items & Extensions"
echo "  Click + under 'Open at Login' and pick Take Five."
echo

read -n 1 -s -r -p "Press any key to close this window..."
echo
