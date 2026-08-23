#!/bin/bash
# Builds Surf.app. WKWebView needs a real bundle identifier to launch its
# Web Content helper process, so a bare SwiftPM binary can't browse.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Surf.app"

# What a release stamps. A local build has no reason to care, and the default
# keeps `./scripts/bundle.sh` doing exactly what it always did.
VERSION="${SURF_VERSION:-0.1}"
BUILD="${SURF_BUILD:-1}"

# "-" is an ad-hoc signature, which is all a local build needs: unsigned
# binaries can't spawn WebKit's XPC services, and nothing else here checks.
# A release passes a Developer ID, and that is the one case that also needs
# the hardened runtime — notarization refuses a bundle without it.
IDENTITY="${SURF_SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Surf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Surf"

# yt-dlp is deliberately NOT bundled: it's a 40MB binary with its own release
# cadence. Surf resolves it at runtime — the managed copy the update manager
# downloads into Application Support (weekly, checksummed), or one on PATH.
# Everything other than stream downloads works with neither present.

# EasyList and EasyPrivacy, so a fresh install blocks on its first page rather
# than after its first weekly check. Refreshed in place from then on, into
# Application Support — these copies are only ever the floor.
#
# Not pinned or checksummed: these are filter rules Surf parses into
# declarative form for WebKit to match URLs against, with no path from them
# into Surf or into a page. Their publisher issues no checksums, so
# what stands in for one is the same check the runtime update makes: each list
# has to convert to tens of thousands of usable rules.
# Each entry is "name|url|minimum rules". The minimum is per list because they
# are not the same size: one floor for all three would either wave a truncated
# EasyList through or refuse a healthy small list outright.
for ENTRY in \
    "easylist|https://easylist.to/easylist/easylist.txt|40000" \
    "easyprivacy|https://easylist.to/easylist/easyprivacy.txt|30000" \
    "antiadblock|https://easylist-downloads.adblockplus.org/antiadblockfilters.txt|1000" \
    ; do
    LIST="${ENTRY%%|*}"
    REST="${ENTRY#*|}"
    LIST_URL="${REST%%|*}"
    LIST_MIN="${REST##*|}"
    LIST_CACHE="$ROOT/.build/vendor/$LIST.txt"

    if [ ! -f "$LIST_CACHE" ]; then
        mkdir -p "$(dirname "$LIST_CACHE")"
        echo "Fetching $LIST…"
        if curl -fsSL --retry 2 -o "$LIST_CACHE.tmp" "$LIST_URL"; then
            # A filter list is mostly rules. An error page is not.
            RULES=$(grep -c '^[^!#[:space:]]' "$LIST_CACHE.tmp" || true)
            if [ "${RULES:-0}" -ge "$LIST_MIN" ]; then
                mv "$LIST_CACHE.tmp" "$LIST_CACHE"
            else
                rm -f "$LIST_CACHE.tmp"
                echo "error: $LIST download isn't a usable filter list — refusing to bundle it." >&2
                exit 1
            fi
        else
            rm -f "$LIST_CACHE.tmp"
            # Not fatal: Surf fetches its own
            # copy on first launch, and a build shouldn't need network.
            echo "warning: couldn't fetch $LIST — blocking starts after the first update." >&2
        fi
    fi

    if [ -f "$LIST_CACHE" ]; then
        cp "$LIST_CACHE" "$APP/Contents/Resources/$LIST.txt"
    fi
done

# Surf's two faces. `ATSApplicationFontsPath` is what registers them at launch —
# no CTFontManager call anywhere — which also means they exist only in a built
# app: `swift run` gets the system font and a wordmark that looks a size off.
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT"/Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
# The licence travels with the fonts; OFL requires it be distributed alongside.
cp "$ROOT"/Resources/Fonts/OFL-*.txt "$APP/Contents/Resources/Fonts/"

# The app icon is an Icon Composer document. actool compiles it into the
# Assets.car that macOS 26 reads for the layered icon, plus an .icns for
# anything still asking the old question.
#
# Not fatal if it fails, for the same reason as the filter lists: a
# build shouldn't need Xcode installed, and an app with a generic icon browses
# exactly as well as one without.
if xcrun --find actool >/dev/null 2>&1; then
    if ! xcrun actool "$ROOT/Resources/AppIcon.icon" \
        --compile "$APP/Contents/Resources" \
        --app-icon AppIcon \
        --output-partial-info-plist "$ROOT/.build/icon-partial.plist" \
        --platform macosx --minimum-deployment-target 26.0 \
        --errors --warnings >/dev/null; then
        echo "warning: couldn't compile AppIcon.icon — the app will use a generic icon." >&2
    fi
else
    echo "warning: actool not found (needs Xcode) — the app will use a generic icon." >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Surf</string>
    <key>CFBundleDisplayName</key><string>Surf</string>
    <key>CFBundleExecutable</key><string>Surf</string>
    <key>CFBundleIdentifier</key><string>com.surf.browser</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Surf adds a recipe's remaining ingredients to your grocery list when you ask it to.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <!-- Without this Surf is not a browser as far as macOS is concerned: it
         never appears in the default-browser list, and no link ever reaches
         it. The code half is \`onOpenURL\` in SurfApp. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Web site URL</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array><string>http</string><string>https</string></array>
        </dict>
    </array>
    <!-- Alternate, not Owner: being the default browser is about http and
         https. Taking every .html file on the disk away from whatever opens
         them today is a separate decision, and not one an install should make
         on someone's behalf. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>HTML document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.html</string><string>public.xhtml</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Web location</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.url</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Signing. Ad-hoc for a local build; a real identity gets the hardened runtime
# and a timestamp, because those are what notarization checks for.
#
# The entitlements are not optional extras. WebKit's JavaScript JIT and the
# dlopen of the downloaded Kokoro runtime are both things the hardened runtime
# stops by default, and a signed build without them is an app whose pages
# don't run scripts and whose enhanced voice never loads.
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP" >/dev/null 2>&1
else
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/scripts/Surf.entitlements" \
        --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

echo "Built $APP ($VERSION build $BUILD)"
