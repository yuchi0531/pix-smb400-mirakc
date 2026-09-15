#!/usr/bin/env bash
# fetch_webui.sh — mirakc 用 WebUI (mirakc-webui, 静的 SPA) のビルド済み dist を
# GitHub Release から取得するスクリプト。
#
# 通常は Makefile 経由で使います:
#   make fetch-webui
#
# mirakc-webui をビルドし直す場合は https://github.com/yuchi0531/mirakc-webui を
# clone して `npm ci && npm run build` を実行し、生成された dist/ の中身
# (index.html / favicon.svg / assets/ ...) を tmp/mirakc-webui/ に置いてください。
# 本スクリプトは Release に配置済みの dist を取得するだけです。
#
# 取得先:
#   https://github.com/yuchi0531/mirakc-webui/releases/tag/smb400-webui-v1
# 出力先:
#   tmp/mirakc-webui/ (index.html / favicon.svg / assets/ ...)
#
# 冪等: index.html が存在し、展開時に生成した SHA256SUMS の検証に合格していれば
#       スキップします。FORCE=1 を付けると強制再取得します。

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/tmp/mirakc-webui"
BASE_URL="https://github.com/yuchi0531/mirakc-webui/releases/download/smb400-webui-v1"

ASSET="mirakc-webui-dist.tar.gz"
CHECKSUM="$ASSET.sha256"

fail() {
    echo "[!] $*" >&2
    echo "    Release から取得できません。ネットワークを確認するか、" >&2
    echo "    https://github.com/yuchi0531/mirakc-webui を clone して" >&2
    echo "    npm ci && npm run build し、dist/ の中身を tmp/mirakc-webui/ に置いてください。" >&2
    exit 1
}

# 展開済み dist が揃い、SHA256SUMS の検証に合格すれば 0 を返す
verify() {
    [ -f "$OUT_DIR/index.html" ] || return 1
    [ -f "$OUT_DIR/SHA256SUMS" ] || return 1
    (cd "$OUT_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
}

if [ "${FORCE:-0}" != "1" ] && verify; then
    echo "[*] mirakc-webui: already up to date (SHA256 OK) — skipping download."
else
    command -v curl >/dev/null 2>&1 || fail "curl が見つかりません"

    # Release のアセットをアセット名のまま保存し、検証してから展開する。
    DL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mirakc-webui-fetch.XXXXXX")"
    trap 'rm -rf "$DL_DIR"' EXIT INT TERM

    echo "[*] Downloading mirakc-webui dist from smb400-webui-v1 release..."
    for asset in "$ASSET" "$CHECKSUM"; do
        echo "    fetching $asset"
        curl -fL --retry 3 --connect-timeout 20 -o "$DL_DIR/$asset" "$BASE_URL/$asset" \
            || fail "$asset のダウンロードに失敗しました"
    done

    echo "[*] Verifying $ASSET SHA256..."
    (cd "$DL_DIR" && sha256sum -c "$CHECKSUM") \
        || fail "$ASSET の SHA256 検証に失敗しました（部分ダウンロードの可能性）"

    # tar 直下が dist の中身 (index.html / favicon.svg / assets/) なので
    # そのまま展開する。古いバージョンの残骸を残さないよう、
    # ステージングへ展開してから tmp/mirakc-webui/ を入れ替える。
    STAGE_DIR="$DL_DIR/dist"
    mkdir -p "$STAGE_DIR"
    tar xzf "$DL_DIR/$ASSET" -C "$STAGE_DIR"
    [ -f "$STAGE_DIR/index.html" ] || fail "展開後に index.html が見つかりません"

    rm -rf "$OUT_DIR"
    mv "$STAGE_DIR" "$OUT_DIR"

    # 以後のスキップ判定用に、展開済み dist の SHA256SUMS を作る
    # （SHA256SUMS 自身はリダイレクトで先に作られるため除外する）
    (cd "$OUT_DIR" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + > SHA256SUMS)

    verify || fail "展開後の SHA256 検証に失敗しました"
fi

echo "[+] mirakc-webui ready: tmp/mirakc-webui/"
