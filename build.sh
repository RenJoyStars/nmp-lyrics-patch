#!/bin/zsh
# Neural Mix Pro · 中文歌词补丁一键构建
#
# 做四件事：
#   1. 编译歌词动态库（universal: arm64 + x86_64）
#   2. 放入 zh-Hans.lproj 汉化资源
#   3. 向主二进制注入 LC_LOAD_DYLIB（两个 slice）
#   4. 整个 bundle 重新 ad-hoc 签名
#
# 使用：zsh build.sh          # 在 NMP-歌词补丁/ 目录下执行
# 还原：zsh restore.sh        # 恢复备份的原版 App

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Neural Mix Pro.app"
OUT="$ROOT/build"
FW="$APP/Contents/Frameworks"
RES="$APP/Contents/Resources"

echo "== 1/4 编译 libNMPLyrics.dylib =="
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
cp "$OUT/libNMPLyrics.dylib" "$FW/"
echo "  已放入 $FW/"

echo "== 2/4 安装中文本地化 =="
mkdir -p "$RES/zh-Hans.lproj"
# 与 en.lproj 一致的 UTF-16 编码（macOS .strings 标准）
iconv -f UTF-8 -t UTF-16 "$ROOT/l10n/Localizable.strings" > "$RES/zh-Hans.lproj/Localizable.strings"
echo "  已写入 $RES/zh-Hans.lproj/"

echo "== 3/4 注入 LC_LOAD_DYLIB =="
python3 "$ROOT/Tools/inject.py" "$APP/Contents/MacOS/Neural Mix Pro"

echo "== 4/4 重新签名 =="
# 保留原有 entitlements（若有）
ENT="$OUT/entitlements.plist"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$ENT" || true
if [ -s "$ENT" ]; then
    codesign --force --deep --sign - --entitlements "$ENT" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

echo ""
echo "✅ 完成。现在双击 Neural Mix Pro 就能用："
echo "   · 界面已是中文（系统语言为简体中文时自动生效）"
echo "   · 歌词窗：标题栏气泡按钮 或 ⌘L"
