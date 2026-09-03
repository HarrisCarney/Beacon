#!/bin/bash
# Cuts a Beacon release: builds, zips, signs with Sparkle's EdDSA key,
# inserts the <item> into appcast.xml, and optionally publishes to GitHub.
#
#   ./release.sh 1.1 3            # build, sign, update appcast.xml
#   ./release.sh 1.1 3 --publish  # ...and create the GitHub release via gh
#
#   1.1 = marketing version (CFBundleShortVersionString)
#   3   = build number      (CFBundleVersion) — must increase every release,
#         this is the number Sparkle actually compares.

set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"
PUBLISH="${3:-}"

REPO_SLUG="HarrisCarney/Beacon"
# Signing identity. Defaults to your Developer ID if it's in the Keychain, so
# releases are notarizable and open with no Gatekeeper prompt. Falls back to
# ad-hoc ("-") on a machine without the cert — those builds still auto-update
# fine, they just show the "Apple could not verify" dialog on first launch.
# Override with:  SIGN_IDENTITY="..." ./release.sh 1.2 3
DEFAULT_IDENTITY="Developer ID Application: Harris carney (RRH87BJ2KY)"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEFAULT_IDENTITY"; then
        SIGN_IDENTITY="$DEFAULT_IDENTITY"
    else
        SIGN_IDENTITY="-"
    fi
fi
# Keychain profile created by: xcrun notarytool store-credentials notary
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SCHEME="Beacon"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SPARKLE_BIN="$ROOT/Tools/bin"
DIST="$ROOT/dist"
# The build must happen OUTSIDE the repo. This project lives in ~/Documents,
# which iCloud Drive syncs, and the file provider stamps com.apple.FinderInfo
# on every bundle it touches — codesign rejects that with "resource fork, Finder
# information, or similar detritus not allowed". Building in a temp dir avoids it.
BUILD_DIR="${TMPDIR:-/tmp}/beacon-release-build"

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    echo "Usage: $0 <version> <build> [--publish]" >&2
    exit 1
fi

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "Missing $SPARKLE_BIN/sign_update." >&2
    echo "Re-download it with:" >&2
    echo "  curl -sSL -o /tmp/sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz" >&2
    echo "  tar -xJf /tmp/sparkle.tar.xz -C '$ROOT' bin && mv '$ROOT/bin' '$SPARKLE_BIN'" >&2
    exit 1
fi

ZIP_NAME="Beacon-${VERSION}.zip"
ZIP_PATH="$DIST/$ZIP_NAME"
DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/${ZIP_NAME}"

rm -rf "$DIST" "$BUILD_DIR"
mkdir -p "$DIST"

echo "==> Building Beacon $VERSION ($BUILD)"
# Build unsigned, then sign inside-out below. Letting Xcode sign doesn't work for
# notarization: it leaves Sparkle's prebuilt Updater.app with its original
# signature, omits the secure timestamp, and injects the debug-only
# com.apple.security.get-task-allow entitlement. All three are hard notarization
# failures.
xcodebuild \
    -project "$ROOT/Beacon.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build >/dev/null

APP_PATH="$BUILD_DIR/Build/Products/Release/Beacon.app"
[ -d "$APP_PATH" ] || { echo "Build produced no app at $APP_PATH" >&2; exit 1; }

# Sign deepest-first: a bundle's seal covers everything nested inside it, so any
# inner component signed afterwards invalidates the outer signature.
echo "==> Signing inside-out ($SIGN_IDENTITY)"
FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
# Ad-hoc signatures can't carry a secure timestamp; Developer ID must.
[ "$SIGN_IDENTITY" = "-" ] || SIGN_FLAGS+=(--timestamp)

for TARGET in \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/Autoupdate" \
    "$FW/Versions/B/Updater.app" \
    "$FW/Versions/B" \
    "$APP_PATH"
do
    echo "    $(basename "$TARGET")"
    codesign "${SIGN_FLAGS[@]}" "$TARGET"
done

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP_PATH"

# Notarization, when we have a real identity. Order matters and is easy to get
# wrong: you cannot staple a zip, so the app must be notarized, THEN stapled,
# THEN re-zipped. The EdDSA signature below must be computed over that final
# stapled zip — signing an earlier zip ships a hash Sparkle will reject.
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> Skipping notarization (ad-hoc build; expect a Gatekeeper prompt)"
else
    echo "==> Notarizing — takes a few minutes, Apple's service is the slow part"
    NOTARIZE_ZIP="$DIST/notarize-$ZIP_NAME"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    # `notarytool submit --wait` exits 0 even when the verdict is Invalid, so the
    # status has to be read out of the output rather than trusted to $?.
    NOTARY_OUT="$(xcrun notarytool submit "$NOTARIZE_ZIP" \
                  --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
    echo "$NOTARY_OUT"
    SUB_ID="$(echo "$NOTARY_OUT" | awk '/id: /{print $2; exit}')"
    if ! echo "$NOTARY_OUT" | grep -q "status: Accepted"; then
        echo "" >&2
        echo "Notarization did NOT succeed. Apple's log:" >&2
        [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" \
            --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
    rm -f "$NOTARIZE_ZIP"

    echo "==> Stapling the ticket to the app"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"

    echo "==> Gatekeeper check"
    spctl -a -vv "$APP_PATH"
fi

echo "==> Zipping -> $ZIP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Signing update with Sparkle EdDSA key"
# Prints e.g.  sparkle:edSignature="..." length="123456"
SIGNATURE_LINE="$("$SPARKLE_BIN/sign_update" "$ZIP_PATH")"

ITEM=$(cat <<ITEMEOF
    <item>
        <title>Version ${VERSION}</title>
        <sparkle:version>${BUILD}</sparkle:version>
        <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <pubDate>$(date -R)</pubDate>
        <enclosure
            url="${DOWNLOAD_URL}"
            ${SIGNATURE_LINE}
            type="application/octet-stream" />
    </item>
ITEMEOF
)

echo "==> Inserting item into appcast.xml"
python3 - "$ROOT/appcast.xml" "$ITEM" "$BUILD" <<'PY'
import re
import sys
path, item, build = sys.argv[1], sys.argv[2], sys.argv[3]
marker = "<!-- RELEASES:"
with open(path) as f:
    text = f.read()
if marker not in text:
    sys.exit("appcast.xml is missing the RELEASES marker comment")

# Drop any existing entry for this build number before inserting. Re-running a
# release (after a failed notarization, say) produces a different zip and so a
# different EdDSA signature — leaving the stale item behind would put a
# signature in the feed that can never match the uploaded asset.
existing = re.findall(r"[ \t]*<item>.*?</item>\n?", text, re.S)
for block in existing:
    if re.search(r"<sparkle:version>%s</sparkle:version>" % re.escape(build), block):
        text = text.replace(block, "", 1)
        print("    replaced existing entry for build %s" % build)

line_end = text.index("\n", text.index(marker))
with open(path, "w") as f:
    f.write(text[:line_end + 1] + item + "\n" + text[line_end + 1:])
PY

echo ""
echo "Done. $ZIP_PATH is ready and appcast.xml now lists v${VERSION}."

if [ "$PUBLISH" = "--publish" ]; then
    echo "==> Publishing GitHub release v${VERSION}"
    gh release create "v${VERSION}" "$ZIP_PATH" \
        --repo "$REPO_SLUG" \
        --title "Beacon ${VERSION}" \
        --notes "Beacon ${VERSION} (build ${BUILD})"
    git add appcast.xml
    git commit -m "Release ${VERSION} (build ${BUILD})"
    git push
    echo "Published. Sparkle clients will pick it up on their next check."
else
    echo ""
    echo "Next steps:"
    echo "  1. gh release create v${VERSION} '$ZIP_PATH' --repo ${REPO_SLUG} --title 'Beacon ${VERSION}'"
    echo "  2. git add appcast.xml && git commit -m 'Release ${VERSION}' && git push"
    echo "  (or re-run with --publish to do both automatically)"
fi
