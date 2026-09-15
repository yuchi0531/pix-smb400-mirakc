#!/usr/bin/env bash
# fetch_mirakc_armv7.sh — mirakc / mirakc-arib / mirakc-arib-tlv の
# ARMv7 (glibc) プリビルドバイナリを GitHub Release から取得するスクリプト。
#
# 通常は Makefile 経由で使います:
#   make fetch-mirakc-armv7
#
# mirakc 本体をソースからビルドする場合は scripts/build_mirakc_armv7.sh
# (make build-mirakc-armv7) を使ってください（クロスビルド環境が必要です）。
#
# 取得先:
#   https://github.com/yuchi0531/mirakc-BS4K/releases/tag/smb400-armv7-v1
# 出力先:
#   tmp/mirakc-armv7/{mirakc,mirakc-arib,mirakc-arib-tlv,SHA256SUMS}
#
# 冪等: 3バイナリ + SHA256SUMS が揃い SHA256 検証に合格していればスキップします。
#       FORCE=1 を付けると強制再取得します。

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/tmp/mirakc-armv7"
BASE_URL="https://github.com/yuchi0531/mirakc-BS4K/releases/download/smb400-armv7-v1"

# リポジトリ内の最終ファイル名（デプロイ時のデバイス配置名と一致）
FILES="mirakc mirakc-arib mirakc-arib-tlv"

fail() {
    echo "[!] $*" >&2
    echo "    Release から取得できません。ネットワークを確認するか、" >&2
    echo "    mirakc 本体は scripts/build_mirakc_armv7.sh でソースからビルドしてください。" >&2
    echo "    (make build-mirakc-armv7)" >&2
    exit 1
}

# 3バイナリ + SHA256SUMS が揃い、検証に合格すれば 0 を返す
verify() {
    [ -f "$OUT_DIR/SHA256SUMS" ] || return 1
    for f in $FILES; do
        [ -f "$OUT_DIR/$f" ] || return 1
    done
    (cd "$OUT_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
}

show_files() {
    for f in $FILES; do
        printf '    %s (%s bytes)\n' "$OUT_DIR/$f" "$(wc -c < "$OUT_DIR/$f")"
    done
}

if [ "${FORCE:-0}" != "1" ] && verify; then
    echo "[*] mirakc binaries: already up to date (SHA256 OK) — skipping download."
else
    command -v curl >/dev/null 2>&1 || fail "curl が見つかりません"

    # Release のアセットをアセット名のまま保存し、検証してから最終名へ rename する。
    DL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mirakc-fetch.XXXXXX")"
    trap 'rm -rf "$DL_DIR"' EXIT INT TERM

    fetch_asset() {
        echo "    fetching $1"
        curl -fL --retry 3 --connect-timeout 20 -o "$DL_DIR/$1" "$BASE_URL/$1" \
            || fail "$1 のダウンロードに失敗しました"
    }

    echo "[*] Downloading mirakc ARMv7 binaries from smb400-armv7-v1 release..."
    for asset in mirakc-armv7 mirakc-arib-armv7 mirakc-arib-tlv-armv7 SHA256SUMS; do
        fetch_asset "$asset"
    done

    echo "[*] Verifying SHA256..."
    (cd "$DL_DIR" && sha256sum -c SHA256SUMS) \
        || fail "SHA256 検証に失敗しました（部分ダウンロードの可能性）"

    # 検証合格後に最終名で配置
    mkdir -p "$OUT_DIR"
    mv "$DL_DIR/mirakc-armv7"           "$OUT_DIR/mirakc"
    mv "$DL_DIR/mirakc-arib-armv7"      "$OUT_DIR/mirakc-arib"
    mv "$DL_DIR/mirakc-arib-tlv-armv7"  "$OUT_DIR/mirakc-arib-tlv"
    chmod +x "$OUT_DIR/mirakc" "$OUT_DIR/mirakc-arib" "$OUT_DIR/mirakc-arib-tlv"

    # 以後のスキップ判定用に、最終名で SHA256SUMS を作り直す
    # （中身は Release のアセットと同一。ファイル名のみ変換）
    (cd "$OUT_DIR" && sha256sum $FILES > SHA256SUMS)

    verify || fail "配置後の SHA256 検証に失敗しました"
fi

echo "[+] mirakc binaries ready: tmp/mirakc-armv7/"
show_files
