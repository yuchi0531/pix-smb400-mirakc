#!/usr/bin/env bash
# build_mirakc_armv7.sh — mirakc / mirakc-arib / mirakc-arib-tlv を
# armv7-unknown-linux-gnueabihf (glibc) 向けにクロスビルドするスクリプト。
#
# 【通常は不要】 デプロイ用バイナリは GitHub Release (smb400-armv7-v1) から
# `make fetch-mirakc-armv7` で取得できます。
# バイナリを自分で生成したい場合のみ実行してください。
#
# 使い方 (リポジトリのルートで実行):
#   bash scripts/build_mirakc_armv7.sh   # = make build-mirakc-armv7
#
# 前提 (Linux x86_64 ホスト):
#   - rustup / cargo
#   - rustup target: armv7-unknown-linux-gnueabihf (無ければ rustup target add)
#   - ARMv7 クロスツールチェーン:
#       sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
#                        libc6-dev-armhf-cross binutils-arm-linux-gnueabihf
#   - cmake, ninja, git
#
# 成果物:
#   tmp/mirakc-armv7/mirakc
#   tmp/mirakc-armv7/mirakc-arib
#   tmp/mirakc-armv7/mirakc-arib-tlv
#   tmp/mirakc-armv7/SHA256SUMS (更新)
#
# ソースツリーは WORK_DIR (既定: tmp/mirakc-cross-build) に clone されます。
# clone 済みなら再利用するため再実行可能です。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/tmp/mirakc-cross-build}"
OUT_DIR="$REPO_ROOT/tmp/mirakc-armv7"
TARGET=armv7-unknown-linux-gnueabihf

MIRAKC_REPO="${MIRAKC_REPO:-https://github.com/yuchi0531/mirakc-BS4K.git}"
MIRAKC_REF="${MIRAKC_REF:-994b493cabb21c80a325a71973120549e98abc27}" # SIGTERM 対応コミット
MIRAKC_TLV_REPO="${MIRAKC_TLV_REPO:-https://github.com/yuchi0531/mirakc-arib-tlv.git}"
MIRAKC_TLV_REF="${MIRAKC_TLV_REF:-v0.1.0}"
MIRAKC_ARIB_REPO="${MIRAKC_ARIB_REPO:-https://github.com/mirakc/mirakc-arib.git}"
# mirakc-arib 上流 v0.24.37 (= 確認元: /mnt/dev/build/mirakc-arib-src)
MIRAKC_ARIB_REF="${MIRAKC_ARIB_REF:-6fef5309b9d93868cbfad37c8a0c4537742f6501}"

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

command -v cargo  >/dev/null 2>&1 || fail "cargo が見つかりません。rustup をインストールしてください (https://rustup.rs/)"
command -v rustup >/dev/null 2>&1 || fail "rustup が見つかりません。rustup をインストールしてください (https://rustup.rs/)"
command -v git    >/dev/null 2>&1 || fail "git が見つかりません"

# クロスツールチェーン (C / C++ / strip)
for tool in arm-linux-gnueabihf-gcc arm-linux-gnueabihf-g++ arm-linux-gnueabihf-strip; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool が見つかりません。
    sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \\
                     libc6-dev-armhf-cross binutils-arm-linux-gnueabihf"
done

# mirakc-arib のビルドに必要なツール
command -v cmake >/dev/null 2>&1 || fail "cmake が見つかりません (sudo apt install cmake)"
command -v ninja >/dev/null 2>&1 || fail "ninja が見つかりません (sudo apt install ninja-build)"

# rust target
if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    echo "[*] rustup target add $TARGET"
    rustup target add "$TARGET"
fi

mkdir -p "$OUT_DIR" "$WORK_DIR"

# mirakc / mirakc-arib-tlv は cargo のリンカ設定でクロス GCC を指定する。
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER="${CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER:-arm-linux-gnueabihf-gcc}"

# ------------------------------------------------------------------- mirakc
step "mirakc ($MIRAKC_REF)"

MIRAKC_SRC="$WORK_DIR/mirakc-BS4K"
if [ ! -d "$MIRAKC_SRC/.git" ]; then
    git clone "$MIRAKC_REPO" "$MIRAKC_SRC"
fi
git -C "$MIRAKC_SRC" fetch --tags origin
git -C "$MIRAKC_SRC" checkout --detach "$MIRAKC_REF"

# workspace 既定は lto=true。通常 LTO はメモリを大量消費するため thin LTO を使う。
# (CARGO_PROFILE_RELEASE_LTO=thin は環境変数で profile.release.lto を上書きする)
(
    cd "$MIRAKC_SRC"
    CARGO_PROFILE_RELEASE_LTO=thin \
        cargo build -p mirakc --release --target "$TARGET" -j2
)

# ------------------------------------------------------------- mirakc-arib-tlv
step "mirakc-arib-tlv ($MIRAKC_TLV_REF)"

TLV_SRC="$WORK_DIR/mirakc-arib-tlv"
if [ ! -d "$TLV_SRC/.git" ]; then
    git clone "$MIRAKC_TLV_REPO" "$TLV_SRC"
fi
git -C "$TLV_SRC" fetch --tags origin
git -C "$TLV_SRC" checkout --detach "$MIRAKC_TLV_REF"

(
    cd "$TLV_SRC"
    CARGO_PROFILE_RELEASE_LTO=thin \
        cargo build --release --locked --target "$TARGET"
)

# --------------------------------------------------------------- mirakc-arib
step "mirakc-arib ($MIRAKC_ARIB_REF)"

ARIB_SRC="$WORK_DIR/mirakc-arib"
if [ ! -d "$ARIB_SRC/.git" ]; then
    git clone "$MIRAKC_ARIB_REPO" "$ARIB_SRC"
fi
git -C "$ARIB_SRC" fetch --tags origin
git -C "$ARIB_SRC" checkout --detach "$MIRAKC_ARIB_REF"
git -C "$ARIB_SRC" submodule update --init --recursive

(
    cd "$ARIB_SRC"
    cmake -S . -B build -G Ninja \
        -D CMAKE_BUILD_TYPE=Release \
        -D MIRAKC_ARIB_TEST=OFF \
        -D CMAKE_TOOLCHAIN_FILE="$PWD/toolchain.cmake.d/debian-armhf.cmake"
    ninja -C build vendor
    ninja -C build
)

# -------------------------------------------------------------------- 配置
step "tmp/mirakc-armv7/ へコピー + strip + SHA256SUMS 更新"

cp "$MIRAKC_SRC/target/$TARGET/release/mirakc"                    "$OUT_DIR/mirakc"
cp "$TLV_SRC/target/$TARGET/release/mirakc-arib-tlv"              "$OUT_DIR/mirakc-arib-tlv"
cp "$ARIB_SRC/build/bin/mirakc-arib"                              "$OUT_DIR/mirakc-arib"

arm-linux-gnueabihf-strip "$OUT_DIR/mirakc" \
                          "$OUT_DIR/mirakc-arib" \
                          "$OUT_DIR/mirakc-arib-tlv"
chmod +x "$OUT_DIR/mirakc" "$OUT_DIR/mirakc-arib" "$OUT_DIR/mirakc-arib-tlv"

(
    cd "$OUT_DIR"
    sha256sum mirakc mirakc-arib mirakc-arib-tlv > SHA256SUMS
)

file "$OUT_DIR/mirakc" "$OUT_DIR/mirakc-arib" "$OUT_DIR/mirakc-arib-tlv"
cat "$OUT_DIR/SHA256SUMS"

echo ""
echo "[+] 完了: tmp/mirakc-armv7/ の3バイナリを更新しました。"
