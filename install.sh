#!/bin/bash
# Installs or updates Dial in ~/Applications:
#   curl -fsSL https://raw.githubusercontent.com/Rythme19/Dial/main/install.sh | bash
# curl doesn't quarantine what it downloads, so macOS never shows the "unidentified developer" block.
set -euo pipefail
URL="${DIAL_URL:-https://github.com/Rythme19/Dial/releases/latest/download/Dial.zip}"
APP="$HOME/Applications/Dial.app"

[[ "$(uname -m)" == arm64 ]] || { echo "Dial needs a Mac with Apple silicon."; exit 1; }
(( $(sw_vers -productVersion | cut -d. -f1) >= 26 )) || { echo "Dial needs macOS 26 or later."; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "Downloading Dial…"
curl -fsSL "$URL" -o "$tmp/Dial.zip"
ditto -x -k "$tmp/Dial.zip" "$tmp"
codesign --verify --strict "$tmp/Dial.app" || { echo "The download is damaged. Try again."; exit 1; }

updating=false
if [[ -d "$APP" ]]; then
    updating=true
    pkill -x Dial 2>/dev/null || true
    rm -rf "$APP"
fi
mkdir -p "$HOME/Applications"
mv "$tmp/Dial.app" "$APP"
echo "Installed $APP"

# PDF, image and video actions use these free tools.
missing=()
command -v gs >/dev/null || [[ -x /opt/homebrew/bin/gs ]] || missing+=(ghostscript)
command -v ffmpeg >/dev/null || [[ -x /opt/homebrew/bin/ffmpeg ]] || missing+=(ffmpeg)
command -v cwebp >/dev/null || [[ -x /opt/homebrew/bin/cwebp ]] || missing+=(webp)
if (( ${#missing[@]} )); then
    brew=$(command -v brew || echo /opt/homebrew/bin/brew)
    if [[ -x "$brew" ]]; then
        answer=n
        { read -r -p "Install ${missing[*]} with Homebrew for the PDF, image and video actions? [Y/n] " answer </dev/tty; } 2>/dev/null || true
        if [[ "$answer" =~ ^[Nn] ]]; then echo "Skipped. Later, run: brew install ${missing[*]}"; else "$brew" install "${missing[@]}"; fi
    else
        echo "Some actions need ${missing[*]}. Install Homebrew (https://brew.sh), then run: brew install ${missing[*]}"
    fi
fi

# Each build has a new signature, so macOS forgets the old permissions: clear them and ask afresh.
$updating && tccutil reset All com.garbouj.dial >/dev/null 2>&1 || true

open "$APP"
cat <<'DONE'

Dial is running in the menu bar. Two last steps, once:
  1. Allow Dial in System Settings → Privacy & Security → Accessibility.
  2. The first time you use it, click Allow when Dial asks to control Finder.
Then select files in Finder and tap ⌥ Option + ⌘ Command.
DONE
