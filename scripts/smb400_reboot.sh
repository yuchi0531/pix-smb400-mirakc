#!/usr/bin/env bash
# smb400_reboot.sh — SMB400 をリモートから再起動し、復帰まで待つ。
#
# 前提:
#   - USB Boot ピンを常時ショート（ジャンパ）しておくこと。
#     warm reboot でも USB ブートのカスタム initramfs に戻り、mirakc_proxy が
#     自動起動する。ジャンパが無い場合、再起動後は eMMC の Android TV になり
#     mirakc は起動しない（このスクリプトは完了を検出できない）。
#   - このデバイスは ro.adb.secure=0 のため、adb のペアリングなしで LAN 内から
#     実行できる。録画・視聴の有無は判定しない（呼び出し側のタイミング責任）。
#
# 使い方:
#   scripts/smb400_reboot.sh [<device-ip>:5555]
#   ADB_TARGET=<device-ip>:5555 scripts/smb400_reboot.sh
#
# 流れ:
#   host  : 再起動要求を送信
#   device: REBOOT_ACCEPTED / REBOOT_STARTING を返す
#   device: 再起動（ADB 切断）
#   host  : 再接続を待つ
#   device: 起動後に boot_id と /api/version を返す
#   host  : REBOOT_COMPLETE を受信して終了
#
# 注意: 完了メッセージは再起動で ADB 接続が切れるため、再接続後にホストが
#       デバイスから boot_id / /api/version を読んで確定する。

set -uo pipefail

TARGET="${1:-${ADB_TARGET:-}}"
ADB_BIN="${ADB:-adb}"

OFFLINE_TIMEOUT=60     # 再起動要求後、切断を待つ秒数
RECONNECT_TIMEOUT=240  # デバイス復帰（adb）を待つ秒数
MIRAKC_TIMEOUT=180     # mirakc (/api/version) 復帰を待つ秒数

fail() {
    echo "[host] REBOOT_FAILED $*" >&2
    exit 1
}

adb_cmd() {
    if [ -n "$TARGET" ]; then
        "$ADB_BIN" -s "$TARGET" "$@"
    else
        "$ADB_BIN" "$@"
    fi
}

state() {
    adb_cmd get-state 2>/dev/null | tr -d '\r'
}

# ---------------------------------------------------------------- 接続確認
echo "[host] reboot request -> ${TARGET:-<adb 自動選択>}"
if [ -n "$TARGET" ]; then
    "$ADB_BIN" connect "$TARGET" >/dev/null 2>&1 || true
fi
[ "$(state)" = "device" ] || fail "device is not online (adb get-state != device)"

old_boot_id=$(adb_cmd shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r')
echo "[host] current boot_id=${old_boot_id:-unknown}"

# ---------------------------------------------------------------- 再起動要求
# 1) 受理/開始メッセージを先に受け取る（再起動で接続が切れる前に確実に）
adb_cmd shell 'echo REBOOT_ACCEPTED; echo REBOOT_STARTING' 2>/dev/null \
    | while IFS= read -r line; do
        echo "[device] $line"
    done

# 2) 再起動を実行（sync してから）
adb_cmd shell 'sync; sleep 1; reboot' >/dev/null 2>&1 || true
echo "[host] reboot request sent"

# ---------------------------------------------------------------- 切断待ち
echo "[host] waiting for device to go offline..."
went_offline=0
i=0
while [ "$i" -lt "$OFFLINE_TIMEOUT" ]; do
    if [ "$(state)" != "device" ]; then
        went_offline=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ "$went_offline" -eq 0 ]; then
    echo "[host] warning: device did not go offline within ${OFFLINE_TIMEOUT}s (continuing)"
fi

# ---------------------------------------------------------------- 再接続待ち
echo "[host] waiting for device to come back..."
reconnected=0
i=0
while [ "$i" -lt "$RECONNECT_TIMEOUT" ]; do
    if [ -n "$TARGET" ]; then
        "$ADB_BIN" connect "$TARGET" >/dev/null 2>&1 || true
    fi
    if [ "$(state)" = "device" ]; then
        reconnected=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
[ "$reconnected" -eq 1 ] || fail "device did not reconnect within ${RECONNECT_TIMEOUT}s"

echo "[host] device is back — waiting for mirakc..."
# ---------------------------------------------------------------- mirakc 復帰待ち
api_version=""
i=0
while [ "$i" -lt "$MIRAKC_TIMEOUT" ]; do
    api_version=$(adb_cmd shell \
        'curl -s --max-time 5 http://127.0.0.1:40772/api/version' \
        2>/dev/null | tr -d '\r')
    [ -n "$api_version" ] && break
    sleep 2
    i=$((i + 2))
done
[ -n "$api_version" ] || fail "mirakc did not respond within ${MIRAKC_TIMEOUT}s after reboot"

# ---------------------------------------------------------------- 完了判定
new_boot_id=$(adb_cmd shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r')
if [ -n "$old_boot_id" ] && [ "$new_boot_id" = "$old_boot_id" ]; then
    fail "boot_id unchanged ($new_boot_id) — device may not have rebooted"
fi

echo "[device] REBOOT_COMPLETE boot_id=${new_boot_id:-unknown} version=${api_version}"
echo "[host] reboot completed"
exit 0
