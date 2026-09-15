#!/usr/bin/env bash
# write_usb_boot.sh — PIX-SMB400 USBブートスティックへ起動ファイルを書き込むスクリプト。
#
# USBメモリを FAT32 でフォーマットし、PIXBOOT というラベルを付けてから実行してください:
#   sudo mkfs.fat -F 32 -n PIXBOOT /dev/sdX1
#
# 使い方:
#   sudo bash scripts/write_usb_boot.sh /dev/sdX1
#
# 書き込むファイル（FAT32 パーティションのルート）:
#   boot/usb_boot_files/bootargs.bin
#   boot/usb_boot_files/root_rsa_pub_crc.bin
#   boot/initramfs_patched.uimg
#
# 事前に以下を実行してファイルを生成しておいてください:
#   python3 boot/make_usb_boot.py
#   PATH=/path/to/u-boot-tools/usr/bin:$PATH bash boot/build_initramfs.sh <firmware_cpio>
#
# オプション:
#   --force   ラベルが PIXBOOT でなくても、またはファイルシステムが vfat でなくても続行
#   --yes     確認プロンプトをスキップ（非対話実行向け）
#
# 詳細は BOOT.md を参照。

set -euo pipefail

usage() {
    echo "使い方: sudo bash $(basename "$0") [--force] [--yes] <デバイス>"
    echo "  例: sudo bash $(basename "$0") /dev/sdc1"
    echo ""
    echo "  --force  ラベル PIXBOOT / FAT32 以外でも続行"
    echo "  --yes    確認プロンプトをスキップ"
    exit 1
}

FORCE=0
ASSUME_YES=0
DEV=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage ;;
        -*)
            echo "[!] 不明なオプション: $arg" >&2
            usage
            ;;
        *)
            if [ -n "$DEV" ]; then
                echo "[!] デバイス引数が複数指定されました: $DEV, $arg" >&2
                usage
            fi
            DEV="$arg"
            ;;
    esac
done

# --- 0. 引数チェック ---
if [ -z "$DEV" ]; then
    usage
fi

# --- 1. root チェック ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] root 権限が必要です。sudo で実行してください:" >&2
    echo "    sudo bash scripts/write_usb_boot.sh $DEV" >&2
    exit 1
fi

# --- 2. デバイスチェック ---
if [ ! -e "$DEV" ]; then
    echo "[!] デバイスが見つかりません: $DEV" >&2
    echo "    lsblk で接続状態を確認してください。" >&2
    exit 1
fi

if [ ! -b "$DEV" ]; then
    echo "[!] ブロックデバイスではありません: $DEV" >&2
    exit 1
fi

FSTYPE="$(lsblk -no FSTYPE "$DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"
LABEL="$(lsblk -no LABEL "$DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"
SIZE="$(lsblk -no SIZE "$DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"

echo "[*] デバイス: $DEV ($SIZE)"
echo "[*] ファイルシステム: ${FSTYPE:-不明}  ラベル: ${LABEL:-なし}"
echo ""

if [ "$FSTYPE" != "vfat" ]; then
    if [ "$FORCE" != "1" ]; then
        echo "[!] FAT32 (vfat) ではありません: ${FSTYPE:-不明}" >&2
        echo "    FAT32 でフォーマットしてください:" >&2
        echo "      sudo mkfs.fat -F 32 -n PIXBOOT $DEV" >&2
        echo "    (意図的に続行する場合は --force を付けてください)" >&2
        exit 1
    fi
    echo "[!] FAT32 ではありませんが --force により続行します: ${FSTYPE:-不明}"
fi

if [ "$LABEL" != "PIXBOOT" ]; then
    echo "[!] ラベルが PIXBOOT ではありません: ${LABEL:-なし}"
    if [ "$FORCE" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
        if [ -t 0 ]; then
            printf "本当に続行しますか? [y/N] "
            read -r answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *) echo "[*] 中止しました。" ; exit 1 ;;
            esac
        else
            echo "[!] 非対話実行では --force を付けてください。" >&2
            exit 1
        fi
    fi
    echo "[*] (ラベル ${LABEL:-なし} ですが続行します)"
fi

# --- 3. 書き込むファイルの存在チェック ---
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES=(
    "$REPO_ROOT/boot/usb_boot_files/bootargs.bin"
    "$REPO_ROOT/boot/usb_boot_files/root_rsa_pub_crc.bin"
    "$REPO_ROOT/boot/initramfs_patched.uimg"
)

for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "[!] 必要なファイルがありません: $f" >&2
        echo "    先に boot/make_usb_boot.py と boot/build_initramfs.sh を実行してください。" >&2
        exit 1
    fi
done

echo "[*] 書き込むファイル:"
for f in "${FILES[@]}"; do
    printf '    %s (%s bytes)\n' "$(basename "$f")" "$(wc -c < "$f")"
done
echo ""

# --- 3. マウント ---
MOUNT_DIR="$(mktemp -d)"
cleanup() {
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount "$MOUNT_DIR" 2>/dev/null || true
    fi
    rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "[*] マウント中: $DEV -> $MOUNT_DIR"
if ! mount "$DEV" "$MOUNT_DIR"; then
    echo "[!] マウントに失敗しました: $DEV" >&2
    exit 1
fi

# --- 4. コピー ---
echo "[*] コピー中..."
for f in "${FILES[@]}"; do
    cp -f "$f" "$MOUNT_DIR/$(basename "$f")"
done
sync
echo "[+] コピー完了"

# --- 5. md5 検証 ---
echo "[*] md5 を検証中..."
FAILED=0
for f in "${FILES[@]}"; do
    base="$(basename "$f")"
    src_md5="$(md5sum "$f" | awk '{print $1}')"
    dst_md5="$(md5sum "$MOUNT_DIR/$base" | awk '{print $1}')"
    if [ "$src_md5" = "$dst_md5" ]; then
        echo "    [OK] $base ($src_md5)"
    else
        echo "    [NG] $base" >&2
        echo "         host: $src_md5" >&2
        echo "         usb:  $dst_md5" >&2
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "[!] 検証に失敗しました。書き込みをやり直してください。" >&2
    exit 1
fi

# --- 6. アンマウント ---
echo "[*] アンマウント中..."
umount "$MOUNT_DIR"
trap - EXIT
rmdir "$MOUNT_DIR" 2>/dev/null || true

echo ""
echo "[+] USBブートスティックの準備が完了しました: $DEV"
echo "    USBメモリを取り外してください。"
echo "    デバイスに挿し、USBブートピンをショートした状態で電源を入れてください。"
