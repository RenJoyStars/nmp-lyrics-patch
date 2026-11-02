#!/bin/zsh
# Neural Mix Pro · 中文歌词补丁 —— staging 构建（不碰 /Applications）
#
# 为什么有这套：直接改 /Applications 里的正式安装版，既不可逆又容易被沙箱拦。
# 这里把正式版复制一份到 build/staging/，在副本上编译、注入、签名、运行，
# 验证通过后由安装包在生产机上执行同样的动作。
#
# 使用：
#   zsh build-staging.sh          # 编译 + 生成打好的副本
#   zsh build-staging.sh run      # 同上，然后启动副本
#   open "build/staging/Neural Mix Pro.app"

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="/Applications/Neural Mix Pro.app"
OUT="$ROOT/build"
STAGE="$OUT/staging"
APP="$STAGE/Neural Mix Pro.app"

[ -d "$SRC_APP" ] || { echo "找不到 $SRC_APP"; exit 1; }

echo "== 1/5 编译 libNMPLyrics.dylib =="
mkdir -p "$OUT"
xcrun clang \
    -arch arm64 -arch x86_64 \
    -dynamiclib \
    -fobjc-arc \
    -mmacosx-version-min=11.0 \
    -framework AppKit -framework ApplicationServices -framework AVFoundation \
    -Wno-deprecated-declarations \
    -install_name "@rpath/libNMPLyrics.dylib" \
    -o "$OUT/libNMPLyrics.dylib" \
    "$ROOT/src/main.m"
echo "  $(du -h "$OUT/libNMPLyrics.dylib" | cut -f1)"

echo "== 2/5 复制正式版到 staging =="
rm -rf "$STAGE"
mkdir -p "$STAGE"
# 用 ditto 保签名/权限/扩展属性
ditto "$SRC_APP" "$APP"
echo "  $(du -sh "$APP" | cut -f1)"

echo "== 3/5 放入动态库与中文本地化 =="
cp "$OUT/libNMPLyrics.dylib" "$APP/Contents/Frameworks/libNMPLyrics.dylib"
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
iconv -f UTF-8 -t UTF-16 "$ROOT/l10n/Localizable.strings" \
    > "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
echo "  ok"

echo "== 4/5 注入 LC_LOAD_DYLIB =="
python3 "$ROOT/Tools/inject.py" "$APP/Contents/MacOS/Neural Mix Pro"

echo "== 5/5 重新签名 =="
ENT="$OUT/entitlements.plist"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$ENT" || true
if [ -s "$ENT" ]; then
    codesign --force --deep --sign - --entitlements "$ENT" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
codesign -v "$APP" && echo "  签名有效"

echo ""
echo "✅ staging 就绪：$APP"
if [ "${1:-}" = "run" ]; then
    pkill -x "Neural Mix Pro" 2>/dev/null || true
    sleep 1
    open "$APP"
    echo "   已启动副本"
fi
