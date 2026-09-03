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
# Ad-hoc ("-") so the app runs on any Mac without an Apple Developer ID.
# Swap in "Developer ID Application: Your Name (TEAMID)" once you have one,
# then notarize before zipping — see README.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
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
# Xcode signs the embedded Sparkle framework, its XPC services and Updater.app
# inside-out in the right order, which `codesign --deep` after the fact does not
# do correctly. So we let the build sign, and only pick the identity here.
xcodebuild \
    -project "$ROOT/Beacon.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build >/dev/null

APP_PATH="$BUILD_DIR/Build/Products/Release/Beacon.app"
[ -d "$APP_PATH" ] || { echo "Build produced no app at $APP_PATH" >&2; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

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
python3 - "$ROOT/appcast.xml" "$ITEM" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
marker = "<!-- RELEASES:"
with open(path) as f:
    text = f.read()
if marker not in text:
    sys.exit("appcast.xml is missing the RELEASES marker comment")
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
