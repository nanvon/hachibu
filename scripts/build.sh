#!/bin/bash
#
# build.sh — 命令行构建 Hachibu 并打包成可分发的 DMG 和 zip。
#
# 免费 ad-hoc 分发，不需要 Apple Developer 证书和公证。Sparkle 的框架和安装助手逐层签名后，
# 再封装外层 App；Sparkle 的 EdDSA 更新包签名由 release workflow 完成，和 Apple 代码签名独立。
#
# 用法:
#   SPARKLE_PUBLIC_ED_KEY="公钥" scripts/build.sh
#                               # 产物输出到 ./dist/Hachibu.dmg 和 ./dist/Hachibu.app.zip
#   scripts/build.sh <输出目录>
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
OUT_DIR="${1:-$REPO_ROOT/dist}"
APP="$BUILD_DIR/Build/Products/Release/Hachibu.app"

# 正式分发必须包含更新验证公钥。仅有 UI、没有公钥的包不能发布。
: "${SPARKLE_PUBLIC_ED_KEY:?请先配置 SPARKLE_PUBLIC_ED_KEY；见 docs/打包发布.md}"
python3 -c 'import base64, os, sys
try:
    key = base64.b64decode(os.environ["SPARKLE_PUBLIC_ED_KEY"], validate=True)
except ValueError:
    sys.exit("SPARKLE_PUBLIC_ED_KEY 必须是有效的 base64 公钥")
if len(key) != 32:
    sys.exit("SPARKLE_PUBLIC_ED_KEY 必须是 32 字节 Ed25519 公钥")'

command -v xcodegen >/dev/null || { echo "❌ 未安装 XcodeGen：brew install xcodegen" >&2; exit 1; }
command -v dmgbuild >/dev/null || { echo "❌ 未安装 dmgbuild：见 packaging/dmg/README.md" >&2; exit 1; }

echo "==> [1/5] 生成 Xcode 工程"
xcodegen generate

echo "==> [2/5] 清理旧构建"
rm -rf "$BUILD_DIR"

echo "==> [3/5] 编译(Release,不签名 → 自动 ad-hoc)"
xcodebuild \
  -project Hachibu.xcodeproj \
  -scheme Hachibu \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  build

[[ -d "$APP" ]] || { echo "❌ 构建产物未找到: $APP" >&2; exit 1; }

echo "==> [4/5] 签名并校验"
xattr -cr "$APP"

# 不用 --deep 签名；嵌套组件需要各自的 entitlements，必须由内向外封装。
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "❌ Sparkle.framework 未嵌入 App" >&2; exit 1; }
SPARKLE_CONTENTS="$SPARKLE_FRAMEWORK/Versions/B"
[[ -x "$SPARKLE_CONTENTS/Autoupdate" && -d "$SPARKLE_CONTENTS/Updater.app" ]] || {
  echo "❌ Sparkle 安装助手缺失" >&2; exit 1;
}
for SERVICE in "$SPARKLE_CONTENTS"/XPCServices/*.xpc; do
  [[ -d "$SERVICE" ]] || continue
  codesign --force --sign - --options runtime --timestamp=none \
    --preserve-metadata=entitlements "$SERVICE"
done
codesign --force --sign - --options runtime --timestamp=none "$SPARKLE_CONTENTS/Autoupdate"
codesign --force --sign - --options runtime --timestamp=none "$SPARKLE_CONTENTS/Updater.app"
codesign --force --sign - --options runtime --timestamp=none "$SPARKLE_FRAMEWORK"

echo "   -> 对 Bundle 做最终签名(ad-hoc,封装资源)"
codesign --force --sign - \
  --entitlements "$REPO_ROOT/App/Hachibu.entitlements" \
  --options runtime --timestamp=none \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "   ✅ 签名校验通过"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Signature" || true

echo "==> [5/5] 打包 DMG 和 zip"
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/Hachibu.app.zip"
DMG="$OUT_DIR/Hachibu.dmg"
rm -f "$ZIP"
rm -f "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 无需 Finder 即可写入背景、卷图标、Applications 快捷方式及图标位置。
bash "$REPO_ROOT/scripts/package-dmg.sh" "$APP" "$DMG"

[[ -f "$ZIP" ]] || { echo "❌ ZIP 产物未找到: $ZIP" >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "❌ DMG 产物未找到: $DMG" >&2; exit 1; }

echo
echo "✅ 完成:"
echo "   - $DMG"
echo "   - $ZIP"
echo "   上传到 GitHub Release 即可。用户首次需按 README「安装」一节手动放行一次。"
