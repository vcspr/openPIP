#!/bin/bash
# Build OpenPiP.app with SwiftPM and sign it. No Xcode project, no Developer ID.
#
#   scripts/build-app.sh            -> build.noindex/OpenPiP.app
#                                      (Spotlight skips .noindex folders, so macOS never lists this
#                                      copy as a second OpenPiP)
#   scripts/build-app.sh --install  -> also copy to ~/Applications/OpenPiP.app
#                                      and install openpip-post / openpip-hook to ~/.openpip/bin
#
# Signing: with the "OpenPiP Self-Signed" certificate in the login keychain (make it once with
# scripts/make-signing-cert.sh, or name another with OPENPIP_SIGN_IDENTITY), every build has the same
# identity and keeps its Screen Recording permission. Without it the app is ad-hoc signed: each build
# is a new app to macOS and Screen Recording must be allowed again.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/OpenPiP"

APP=build.noindex/OpenPiP.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenPiP"
cp Support/Info.plist "$APP/Contents/Info.plist"
IDENTITY="${OPENPIP_SIGN_IDENTITY:-OpenPiP Self-Signed}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier app.hemii.openpip "$APP"
else
    echo "No \"$IDENTITY\" certificate: signing ad-hoc (run scripts/make-signing-cert.sh to keep permissions across builds)"
    codesign --force --sign - --identifier app.hemii.openpip "$APP"
fi
codesign --verify --strict "$APP"
# Keep this build copy off macOS's app list. Two registered copies with one bundle id can tie the
# Screen Recording switch to the wrong copy, and then macOS keeps asking.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/OpenPiP.app"
    mkdir -p "$HOME/Applications"
    pkill -x OpenPiP 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    mkdir -p "$HOME/.openpip/bin"
    chmod 700 "$HOME/.openpip"
    install -m 755 bin/openpip-post bin/openpip-hook "$HOME/.openpip/bin/"
    echo "Installed $DEST"
    echo "Installed ~/.openpip/bin/openpip-post and openpip-hook"
fi
