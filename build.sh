#!/bin/zsh
set -e

PROJECT="${0:A:h}/KeysMirror.xcodeproj"
SCHEME="KeysMirror"
CONFIG="${1:-Debug}"
DERIVED="/Users/chace/KeysMirror_build"
APP="$DERIVED/Build/Products/$CONFIG/KeysMirror.app"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ xcodebuild 不可用 —— xcode-select 当前指向 CommandLineTools 而非 Xcode。"
  echo "  改回来:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "  或临时:  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer $0 $CONFIG"
  exit 1
fi

echo "▶ Building ($CONFIG)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|CompileSwift" | grep -v "Stale" | grep -v "^$"

# 回归校验：macOS 26/27 闪退防线。详见 scripts/verify_crash_guard.sh 里的完整说明。
# 校验逻辑放在脚本里而不是内联在这，是为了让 CI 和 Release 流程能跑同一份——
# 过去这道防线只存在于本机，CI 上合进来的改动可以静默把闪退带回去。
"${0:A:h}/scripts/verify_crash_guard.sh" "$APP/Contents/MacOS/KeysMirror"

echo "▶ Stripping xattrs..."
xattr -cr "$APP"

echo "▶ Signing..."
/usr/bin/codesign --force --sign "KeysMirror Dev" --timestamp=none --generate-entitlement-der "$APP"

echo "▶ Launching..."
pkill -x KeysMirror 2>/dev/null || true
sleep 0.3
open "$APP"
echo "✓ Done"
