#!/bin/bash
# BreakEnforcer installer.
# Double-click this file (or run from Terminal) to install on this Mac.
# Recompiles the Swift binaries so it works on any architecture (Apple
# Silicon or Intel) and removes the quarantine flag.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/BreakEnforcer.app"
APP_DST="/Applications/BreakEnforcer.app"

echo "================================================"
echo "  BreakEnforcer installer"
echo "================================================"
echo

if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: $APP_SRC not found."
    echo "Keep install.command in the same folder as BreakEnforcer.app."
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

# 1. Check Xcode Command Line Tools
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required (for the Swift compiler)."
    echo "A system dialog will pop up to install them. Click Install."
    echo
    xcode-select --install || true
    echo
    echo "Once the install finishes, run this installer again."
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

# 2. Stop any existing instance
echo "Stopping any running instance..."
pkill -f "MacOS/BreakEnforcer" 2>/dev/null || true
pkill -f "break_enforcer.py" 2>/dev/null || true
pkill -f "break_window" 2>/dev/null || true
sleep 1

# 3. Pick a destination /Applications has write access for, fall back to ~/Applications
if [ -w "/Applications" ]; then
    DEST_PARENT="/Applications"
else
    mkdir -p "$HOME/Applications"
    DEST_PARENT="$HOME/Applications"
    APP_DST="$DEST_PARENT/BreakEnforcer.app"
fi

echo "Installing to $DEST_PARENT/..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# 4. Strip quarantine xattr so Gatekeeper doesn't block the .app
echo "Removing quarantine flag..."
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# 5. Recompile Swift binaries from bundled source
echo "Compiling Swift binaries for this Mac..."
swiftc "$APP_DST/Contents/Resources/menubar.swift"      -o "$APP_DST/Contents/MacOS/BreakEnforcer"
swiftc "$APP_DST/Contents/Resources/break_window.swift" -o "$APP_DST/Contents/MacOS/break_window"
chmod +x "$APP_DST/Contents/MacOS/BreakEnforcer" "$APP_DST/Contents/MacOS/break_window"
echo "  compiled OK"

# 6. Refresh Launch Services
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
echo "Look for the eye icon in your menu bar (top right of the screen)."
echo
echo "To auto-start at login:"
echo "  System Settings  >  General  >  Login Items & Extensions"
echo "  Click + under 'Open at Login' and pick BreakEnforcer."
echo
echo "Read README.md for the full guide."
echo

read -n 1 -s -r -p "Press any key to close this window..."
echo
