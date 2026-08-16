#!/bin/bash
# Builds Glass.app. WKWebView needs a real bundle identifier to launch its
# Web Content helper process, so a bare SwiftPM binary can't browse.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Glass.app"

# yt-dlp reassembles segmented video, which WebKit can't download. Pinned and
# checksummed rather than "latest": a build should produce the same app twice.
#
# To bump: pick a tag from github.com/yt-dlp/yt-dlp/releases and take the
# yt-dlp_macos line from that release's SHA2-256SUMS. Worth doing regularly —
# sites change their players and yt-dlp releases roughly monthly to keep up.
YTDLP_VERSION="2026.07.04"
YTDLP_SHA256="498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b"
YTDLP_CACHE="$ROOT/.build/vendor/yt-dlp-$YTDLP_VERSION"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Glass"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glass"

# Cached outside git: it's a 40MB binary with its own release cadence, and
# nothing about it belongs in the history of a Swift project.
if [ ! -f "$YTDLP_CACHE" ]; then
    mkdir -p "$(dirname "$YTDLP_CACHE")"
    echo "Fetching yt-dlp $YTDLP_VERSION…"
    if curl -fsSL --retry 2 -o "$YTDLP_CACHE.tmp" \
        "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos"; then
        # Verify before it is ever named as the real thing, let alone signed.
        if echo "$YTDLP_SHA256  $YTDLP_CACHE.tmp" | shasum -a 256 -c - >/dev/null 2>&1; then
            mv "$YTDLP_CACHE.tmp" "$YTDLP_CACHE"
        else
            rm -f "$YTDLP_CACHE.tmp"
            echo "error: yt-dlp checksum mismatch — refusing to bundle it." >&2
            exit 1
        fi
    else
        rm -f "$YTDLP_CACHE.tmp"
        # Not fatal: Glass falls back to a yt-dlp on PATH, and everything other
        # than stream downloads works regardless. A build shouldn't need network.
        echo "warning: couldn't fetch yt-dlp — stream downloads will need a system copy." >&2
    fi
fi

if [ -f "$YTDLP_CACHE" ]; then
    cp "$YTDLP_CACHE" "$APP/Contents/Resources/yt-dlp"
    chmod +x "$APP/Contents/Resources/yt-dlp"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Glass</string>
    <key>CFBundleDisplayName</key><string>Glass</string>
    <key>CFBundleExecutable</key><string>Glass</string>
    <key>CFBundleIdentifier</key><string>com.glass.browser</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: unsigned binaries can't spawn WebKit's XPC services.
# Nested code is signed first — signing the bundle seals what's inside it, so
# an unsigned helper added afterwards would invalidate the whole signature.
if [ -f "$APP/Contents/Resources/yt-dlp" ]; then
    codesign --force --sign - "$APP/Contents/Resources/yt-dlp" >/dev/null 2>&1
fi
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
