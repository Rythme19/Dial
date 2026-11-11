#!/bin/bash
# Builds Dial.app with the Command Line Tools (no Xcode needed).
#   ./build.sh           → build/Dial.app
#   ./build.sh install   → also copies it to ~/Applications
#   ./build.sh release   → also zips it to build/Dial.zip, the file install.sh downloads
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Dial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/*.swift -o "$APP/Contents/MacOS/Dial"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"   # regenerate with: swift design/icon.swift
# Hardened runtime: other processes can't inject code into Dial and borrow its Accessibility access.
codesign --force --options runtime --entitlements Dial.entitlements --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Dial 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Dial.app
    cp -R "$APP" ~/Applications/
    touch ~/Applications/Dial.app   # so Finder picks up the new icon
    open ~/Applications/Dial.app
    echo "Installed and started ~/Applications/Dial.app"
fi

if [[ "${1:-}" == "release" ]]; then
    rm -f build/Dial.zip
    ditto -c -k --keepParent "$APP" build/Dial.zip   # ditto keeps the signature intact
    echo "Zipped build/Dial.zip: attach it to a GitHub release"
fi
