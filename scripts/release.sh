#!/bin/bash
# Cut a release: bump the version, build and zip the app, publish a GitHub release,
# and point the Homebrew cask in vcspr/homebrew-tap at it.
#
#   scripts/release.sh 0.2.0
#
# Needs: a clean main branch, `gh` logged in with push access to vcspr/openPIP and vcspr/homebrew-tap.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3" >&2; exit 1; }
TAG="v$VERSION"
REPO=vcspr/openPIP
TAP=vcspr/homebrew-tap

[[ "$(git branch --show-current)" == main ]] || { echo "switch to main first" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit or stash your changes first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists" >&2; exit 1; }
# Every release must carry the same certificate, or users lose their Screen Recording permission.
IDENTITY="${OPENPIP_SIGN_IDENTITY:-OpenPiP Self-Signed}"
security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\"" \
    || { echo "no \"$IDENTITY\" certificate in the keychain; releases are never ad-hoc signed" >&2; exit 1; }

swift test

# Version in the app bundle. CFBundleVersion counts commits so every release goes up.
plutil -replace CFBundleShortVersionString -string "$VERSION" Support/Info.plist
plutil -replace CFBundleVersion -string "$(( $(git rev-list --count HEAD) + 1 ))" Support/Info.plist
if ! git diff --quiet Support/Info.plist; then
    git commit -q -m "Release $VERSION" Support/Info.plist
fi

scripts/build-app.sh
codesign -dr - build.noindex/OpenPiP.app 2>&1 | grep -q "certificate leaf" \
    || { echo "the build is not signed with \"$IDENTITY\"" >&2; exit 1; }
ZIP="build.noindex/OpenPiP-$VERSION.zip"
# The shell tools sit next to the app, not inside it: macOS kills anything run from inside a
# downloaded app it has not approved yet, and the cask links these onto PATH before first launch.
STAGE=build.noindex/stage
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE/bin"
ditto build.noindex/OpenPiP.app "$STAGE/OpenPiP.app"
install -m 755 bin/openpip-post bin/openpip-hook "$STAGE/bin/"
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$STAGE/OpenPiP.app" 2>/dev/null || true
rm -rf "$STAGE"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Zipped $ZIP ($(du -h "$ZIP" | cut -f1)), sha256 $SHA"

git tag -a "$TAG" -m "OpenPiP $VERSION"
git push origin main "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "OpenPiP $VERSION" --notes "$(cat <<EOF
Install with Homebrew:

\`\`\`bash
brew install --cask vcspr/tap/openpip
\`\`\`

Or download \`OpenPiP-$VERSION.zip\`, unzip, and move \`OpenPiP.app\` to Applications.

The app is signed with the OpenPiP project certificate (not a Developer ID) and not notarized. If macOS blocks it, open System Settings → Privacy & Security
and click **Open Anyway**, or run \`xattr -dr com.apple.quarantine /Applications/OpenPiP.app\`.

Requires macOS 14 or newer on Apple silicon. sha256: \`$SHA\`
EOF
)"

# Update the cask.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh repo clone "$TAP" "$TMP/tap" -- -q
mkdir -p "$TMP/tap/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/openpip.rb.in > "$TMP/tap/Casks/openpip.rb"
git -C "$TMP/tap" add Casks/openpip.rb
if git -C "$TMP/tap" diff --cached --quiet; then
    echo "Cask already up to date"
else
    git -C "$TMP/tap" commit -q -m "openpip $VERSION"
    git -C "$TMP/tap" push -q origin HEAD
fi
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
