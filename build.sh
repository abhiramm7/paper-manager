#!/bin/bash
# Build Sift.app from the SPM target.
#
# Usage:
#   ./build.sh            # release build, writes ./Sift.app
#   ./build.sh debug      # debug build (faster compile, slower runtime)
#   ./build.sh run        # build release then launch
#   ./build.sh dmg        # build release + package as Sift-<ver>.dmg
#
set -euo pipefail
cd "$(dirname "$0")"

ACTION="${1:-release}"
RUN_AFTER=0
MAKE_DMG=0
case "$ACTION" in
    run)   MODE="release"; RUN_AFTER=1 ;;
    dmg)   MODE="release"; MAKE_DMG=1 ;;
    debug) MODE="debug" ;;
    *)     MODE="$ACTION" ;;
esac

CONFIG_FLAG="-c $MODE"
APP_NAME="Sift"
EXE_NAME="SiftApp"
APP_DIR="$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 0.1.0)"

echo "==> swift build $CONFIG_FLAG"
swift build $CONFIG_FLAG

BIN_PATH="$(swift build $CONFIG_FLAG --show-bin-path)/$EXE_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "build produced no executable at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXE_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Sign with a stable identity when one exists. macOS keys folder-access
# grants (Downloads, Documents, iCloud Drive, …) to the app's code signature,
# and an ad-hoc signature changes with every build — so each rebuild would
# re-trigger every permission prompt. Override with SIFT_SIGN_ID if needed.
SIGN_ID="${SIFT_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="-"
    echo "warn: no signing identity found — signing ad-hoc (folder permission prompts will repeat after every rebuild)" >&2
fi
echo "==> codesign --force --sign \"$SIGN_ID\""
codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" >/dev/null

echo "==> done: $APP_DIR"

if [[ "$RUN_AFTER" -eq 1 ]]; then
    echo "==> open $APP_DIR"
    open "$APP_DIR"
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
    STAGING="$(mktemp -d)/dmg_stage"
    mkdir -p "$STAGING"
    cp -R "$APP_DIR" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"

    cat > "$STAGING/README.txt" <<EOF
Sift $VERSION

To install:
  1. Drag Sift.app into the Applications folder (shown next to it).
  2. The first time you launch it, macOS Gatekeeper will block it because
     this build isn't notarized by Apple.
     To open it anyway:
        Right-click Sift.app → Open → Open
     You'll only need to do this once.

What it does:
  - Sifts through research papers and books — collect, tag, rate, recall.
  - Stores everything as plain files in a folder you choose (recommended:
    inside iCloud Drive, so it syncs across your devices).
  - Opens PDFs in a built-in reader: highlight text, search the PDF, and
    ask questions about it. Preview is still one right-click away.

First-run setup:
  On first launch you'll be asked where to keep your library. The default is
  inside iCloud Drive so it syncs to your other Apple devices. You can choose
  any other folder too — it just won't sync.
EOF

    rm -f "$DMG_NAME"
    echo "==> hdiutil create $DMG_NAME"
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG_NAME" >/dev/null
    rm -rf "$STAGING"
    echo "==> done: $DMG_NAME"
fi
