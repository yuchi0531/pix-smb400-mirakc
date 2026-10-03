#!/usr/bin/env bash
# build_webui.sh — mirakc 用 WebUI (mirakc-webui, 静的 SPA) をソースからビルドし、
#                  生成された dist/ の中身を tmp/mirakc-webui/ に配置するスクリプト。
#
# 通常は Makefile 経由で使います:
#   make build-webui
#
# Release のプリビルド dist には依存せず、毎回ソースを取得してビルドします。
#
# 前提 (Linux / macOS ホスト):
#   - Node.js 18+ / npm
#   - git
#
# ソース:
#   https://github.com/yuchi0531/mirakc-webui (既定ブランチ: main)
#   MIRAKC_WEBUI_REF でコミット / タグ / ブランチを固定できます。
# ソースツリーは WORK_DIR (既定: tmp/mirakc-webui-src) に clone され、
# 再実行時は再利用して最新に fetch してからビルドします。
#
# 成果物:
#   tmp/mirakc-webui/ (index.html / favicon.svg / assets/ ...)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/tmp/mirakc-webui-src}"
OUT_DIR="$REPO_ROOT/tmp/mirakc-webui"

MIRAKC_WEBUI_REPO="${MIRAKC_WEBUI_REPO:-https://github.com/yuchi0531/mirakc-webui.git}"
MIRAKC_WEBUI_REF="${MIRAKC_WEBUI_REF:-main}"

fail() {
    echo "[!] $*" >&2
    exit 1
}

step() {
    echo ""
    echo "=== $* ==="
}

# ---------------------------------------------------------------- 前提チェック
step "前提チェック"
command -v git >/dev/null 2>&1 || fail "git が見つかりません"
command -v node >/dev/null 2>&1 || fail "node が見つかりません (Node.js 18+ が必要)"
command -v npm >/dev/null 2>&1 || fail "npm が見つかりません"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || fail "Node.js 18+ が必要です (現在: $(node -v))"

# ---------------------------------------------------------------- ソース取得
step "mirakc-webui ($MIRAKC_WEBUI_REF) を取得"
mkdir -p "$REPO_ROOT/tmp"
if [ ! -d "$WORK_DIR/.git" ]; then
    git clone "$MIRAKC_WEBUI_REPO" "$WORK_DIR"
fi
git -C "$WORK_DIR" fetch --tags --prune origin
# ブランチ (origin/<ref>) を優先し、無ければタグ / コミットとして解決する。
git -C "$WORK_DIR" checkout --detach "origin/$MIRAKC_WEBUI_REF" 2>/dev/null \
    || git -C "$WORK_DIR" checkout --detach "$MIRAKC_WEBUI_REF"
git -C "$WORK_DIR" reset --hard -q
git -C "$WORK_DIR" -c advice.detachedHead=false log -1 --format='    %h %s (%ci)'

# ---------------------------------------------------------------- ビルド
step "npm ci"
(cd "$WORK_DIR" && npm ci)

step "npm run typecheck"
(cd "$WORK_DIR" && npm run typecheck)

step "npm run build"
(cd "$WORK_DIR" && npm run build)

[ -f "$WORK_DIR/dist/index.html" ] || fail "ビルド後の dist/index.html が見つかりません"

# ---------------------------------------------------------------- 配置
step "tmp/mirakc-webui/ へ配置"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -a "$WORK_DIR/dist/." "$OUT_DIR/"

echo ""
echo "[+] 完了: tmp/mirakc-webui/ の Web UI を更新しました。"
find "$OUT_DIR" -type f | sort
