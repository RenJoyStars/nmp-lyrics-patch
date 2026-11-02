#!/bin/zsh
# 还原原版 Neural Mix Pro（把打补丁的 App 换成备份）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Neural Mix Pro.app"

if [ ! -d "$ROOT/backup/Neural Mix Pro-原版.app" ]; then
    echo "找不到备份：$ROOT/backup/Neural Mix Pro-原版.app" >&2
    exit 1
fi

rm -rf "$APP"
cp -R "$ROOT/backup/Neural Mix Pro-原版.app" "$APP"
echo "已还原为未修改的原版 App。"
