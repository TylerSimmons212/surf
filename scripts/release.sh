#!/bin/bash
# Builds a Surf.dmg that opens on someone else's Mac without an argument.
#
# Three things have to be true for that, and only the first is obvious. The app
# must be signed with a Developer ID rather than ad-hoc, because an ad-hoc
# signature means nothing off this machine. It must carry the hardened runtime,
# because notarization refuses anything else. And it must be notarized and
# stapled, because since Catalina an un-notarized download is refused outright,
# and since Sequoia the right-click-Open escape hatch is gone too — the person
# you sent it to has to go into System Settings to run it at all.
#
# Notarization needs an App Store Connect credential. This script never sees it:
# it names a keychain profile you create once, and the credential stays in your
# keychain. See the message under "no notary profile" below.
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: scripts/release.sh <version>     e.g. scripts/release.sh 0.2.0" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Surf.app"
DIST="$ROOT/.build/dist"
DMG="$DIST/Surf-$VERSION.dmg"
PROFILE="${SURF_NOTARY_PROFILE:-surf-notary}"
REPO="${SURF_REPO:-TylerSimmons212/surf}"

# Publishing is opt-in. Everything up to it is local and repeatable; this is
# the step that puts a build in front of other people, and it should not
# happen because someone re-ran a build script.
PUBLISH="${SURF_PUBLISH:-0}"
[ "${2:-}" = "--publish" ] && PUBLISH=1

# The build number has to rise for every release even when the version string
# repeats; seconds since epoch is monotonic and needs no state file.
BUILD="${SURF_BUILD:-$(date +%s)}"

# The one Developer ID on this machine, unless told otherwise. Matched on the
# certificate name rather than the hash so a renewed certificate keeps working.
IDENTITY="${SURF_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/')"
fi
if [ -z "$IDENTITY" ]; then
    cat >&2 <<'MSG'
error: no "Developer ID Application" certificate in the keychain.

Distributing outside the App Store needs one, and it needs a paid Apple
Developer Program membership. Xcode › Settings › Accounts › Manage
Certificates › + › Developer ID Application creates it.
MSG
    exit 1
fi
echo "Signing as: $IDENTITY"

# ---- The gates -------------------------------------------------------------
#
# A release is the worst possible moment to find out the JavaScript contract
# drifted, because the failure is silent and lands on someone else's Mac.
if [ "${SURF_SKIP_CHECKS:-}" != "1" ]; then
    echo "Running tests…"
    swift test --package-path "$ROOT" >/dev/null
    echo "Checking the injected contracts…"
    "$ROOT/scripts/check-js.sh" >/dev/null
fi

# ---- Build and sign --------------------------------------------------------
SURF_VERSION="$VERSION" SURF_BUILD="$BUILD" SURF_SIGN_IDENTITY="$IDENTITY" \
    "$ROOT/scripts/bundle.sh" release

# ---- Notarize the app itself ----------------------------------------------
#
# Before packaging, not after. The ticket has to be stapled into the .app that
# goes *into* the image, or the copy someone drags to /Applications carries no
# proof of its own: it passes today only because Gatekeeper is reading the
# image's ticket, and an app moved to a machine that is offline has nothing
# left to show.
if [ "${SURF_SKIP_NOTARIZE:-}" != "1" ]; then
    require_notary_profile
    APPZIP="$(mktemp -d)/Surf.zip"
    # ditto, not zip: it is the only one that preserves the bundle's symlinks
    # and extended attributes, and a mangled bundle fails notarization with an
    # error that says nothing about zip.
    ditto -c -k --keepParent "$APP" "$APPZIP"
    echo "Notarizing the app…"
    xcrun notarytool submit "$APPZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -rf "$(dirname "$APPZIP")"
fi

# ---- Package ---------------------------------------------------------------
#
# A folder with the app and a symlink to /Applications: the drag-to-install
# window everyone already knows how to use.
rm -rf "$DIST"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Surf.app"
ln -s /Applications "$STAGE/Applications"

echo "Building $DMG…"
hdiutil create -volname "Surf $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

# The disk image is signed too. An unsigned container around a signed app is a
# download that changes its mind about who it is halfway through opening.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# ---- Notarize --------------------------------------------------------------
if [ "${SURF_SKIP_NOTARIZE:-}" = "1" ]; then
    echo
    echo "Skipped notarization. $DMG will be refused on other Macs."
    exit 0
fi

require_notary_profile() {
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 && return 0
    cat >&2 <<MSG

error: no notary profile named "$PROFILE" in the keychain.

Create it once. It stores the credential in your keychain, and nothing else
here or in this repo ever reads it:

  xcrun notarytool store-credentials "$PROFILE" \\
      --apple-id "<your Apple ID>" \\
      --team-id "$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)/\1/')" \\
      --password "<an app-specific password>"

The password is not your Apple ID password. Make one at
appleid.apple.com › Sign-In and Security › App-Specific Passwords.

MSG
    exit 1
}

echo "Notarizing the image…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling writes the ticket into the image, so it validates with no network.
# Without it, someone opening the download offline is refused.
xcrun stapler staple "$DMG"
# ---- Prove it --------------------------------------------------------------
echo
echo "Verifying…"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# ---- The appcast -----------------------------------------------------------
#
# The file Sparkle actually asks for. Every entry is signed with the EdDSA key
# in the keychain — the private half of SUPublicEDKey in the bundle — so an
# update that has been tampered with in transit, or served by something that
# is not us, is refused by the copy already installed.
APPCAST="$ROOT/appcast.xml"
GENERATE="$(find "$ROOT/.build/artifacts" -maxdepth 6 -type f \
    -name generate_appcast 2>/dev/null | head -1)"
if [ -z "$GENERATE" ]; then
    echo "error: generate_appcast not found — run swift build first." >&2
    exit 1
fi

echo
echo "Generating the appcast…"
"$GENERATE" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    -o "$APPCAST" \
    "$DIST"

# generate_appcast in 2.9.6 writes the entry without an EdDSA signature even
# with the key sitting in the keychain where its own sign_update finds it. A
# feed whose enclosure carries no signature is one that every installed copy
# refuses, so the signature goes in here, produced by Sparkle's own signing
# tool, and the build stops if it still isn't there afterwards.
SIGNER="$(find "$ROOT/.build/artifacts" -maxdepth 6 -type f \
    -name sign_update ! -path "*old_dsa*" 2>/dev/null | head -1)"
if ! grep -q "sparkle:edSignature" "$APPCAST"; then
    ED="$("$SIGNER" "$DMG" | sed -E 's/.*(sparkle:edSignature="[^"]+").*/\1/')"
    if [ -z "$ED" ]; then
        echo "error: couldn't sign the update — is the EdDSA key in the keychain?" >&2
        exit 1
    fi
    sed -i '' "s|<enclosure url=\"\([^\"]*$(basename "$DMG")\)\"|<enclosure url=\"\1\" $ED|" "$APPCAST"
fi
if ! grep -q "sparkle:edSignature" "$APPCAST"; then
    echo "error: the appcast has no signature; every copy of Surf would refuse this update." >&2
    exit 1
fi

echo
echo "Ready: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "size:   $(du -h "$DMG" | cut -f1)"

if [ "$PUBLISH" != "1" ]; then
    cat <<MSG

Nothing has been published. To put this in front of people:

  scripts/release.sh $VERSION --publish

MSG
    exit 0
fi

# ---- Publish ---------------------------------------------------------------
echo
echo "Creating the GitHub release…"
gh release create "v$VERSION" "$DMG" --repo "$REPO" \
    --title "Surf $VERSION" \
    --notes "Open the .dmg and drag Surf to Applications. Requires macOS 26 or later."

# The appcast has to land on the branch the feed URL points at, or the release
# exists and nobody is told about it. Loud, because that failure is silent.
cat <<MSG

The release is up. One step left, and skipping it means nobody's copy of Surf
ever hears about this version:

  git add appcast.xml && git commit -m "Surf $VERSION" && git push origin main

Then confirm the feed is live:

  curl -s https://raw.githubusercontent.com/$REPO/main/appcast.xml | grep sparkle:version

MSG
