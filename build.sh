#!/bin/zsh
set -e

PROJECT="/Users/chace/Documents/KeysMirror/KeysMirror.xcodeproj"
SCHEME="KeysMirror"
CONFIG="${1:-Debug}"
DERIVED="/Users/chace/KeysMirror_build"
APP="$DERIVED/Build/Products/$CONFIG/KeysMirror.app"

echo "▶ Building ($CONFIG)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|CompileSwift" | grep -v "Stale" | grep -v "^$"

echo "▶ Stripping xattrs..."
xattr -cr "$APP"

echo "▶ Signing..."
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP"

echo "▶ Launching..."
pkill -x KeysMirror 2>/dev/null || true
sleep 0.3
open "$APP"
echo "✓ Done"
