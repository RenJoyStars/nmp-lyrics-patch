#!/bin/zsh
# 把已经打好补丁的 /Applications/Neural Mix Pro.app 打成可分发安装包
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Neural Mix Pro.app"
WORK="$ROOT/build/pkg"
DIST="$ROOT/dist"
NAME="Neural Mix Pro 歌词版 1.0.pkg"

[ -d "$APP" ] || { echo "找不到 $APP"; exit 1; }

echo "== 1/4 准备 payload =="
rm -rf "$WORK"
mkdir -p "$WORK/root/Applications"
# --noextattr --noqtn：连隔离属性一起清掉，别把本机状态带给别人
ditto --norsrc --noextattr --noqtn "$APP" "$WORK/root/Applications/Neural Mix Pro.app"
du -sh "$WORK/root/Applications/Neural Mix Pro.app"

echo "== 2/4 打组件包 =="
pkgbuild --root "$WORK/root" \
         --scripts "$ROOT/Tools/pkg/scripts" \
         --identifier "cn.renqiaoyi.nmplyrics" \
         --version "1.0" \
         --install-location "/" \
         --ownership recommended \
         "$WORK/NeuralMixProLyrics.pkg"

echo "== 3/4 合成带说明的安装包 =="
mkdir -p "$DIST"
rm -f "$DIST/$NAME"
productbuild --distribution "$ROOT/Tools/pkg/distribution.xml" \
             --resources "$ROOT/Tools/pkg/res" \
             --package-path "$WORK" \
             "$DIST/$NAME"

echo "== 4/4 校验 =="
ls -lh "$DIST/$NAME"
pkgutil --check-signature "$DIST/$NAME" 2>&1 | head -3 || true
echo "✅ 完成：$DIST/$NAME"
