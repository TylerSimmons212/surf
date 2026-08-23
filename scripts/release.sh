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

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
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

The signed but un-notarized image is at:
  $DMG
MSG
    exit 1
fi

echo "Submitting to Apple. This usually takes a few minutes…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling writes the ticket into the image, so it validates with no network.
# Without it, someone opening the download offline is refused.
xcrun stapler staple "$DMG"
# And onto the app itself, by the same ticket, so a copy dragged out of the
# image and moved to another machine still carries its own proof.
xcrun stapler staple "$APP" || \
    echo "note: couldn't staple the .app; the image is stapled and is what ships."

# ---- Prove it --------------------------------------------------------------
echo
echo "Verifying…"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo
echo "Ready: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "size:   $(du -h "$DMG" | cut -f1)"
