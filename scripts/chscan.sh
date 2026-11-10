#!/usr/bin/env bash
# chscan.sh — scan SMB400 channels (GR / BS / CS / BS4K) and generate config.
#
# Usage:
#   scripts/chscan.sh [<adb-target>] [options]
#   make chscan ADB_TARGET=<device-ip>:5555
#   make chscan ADB_TARGET=<device-ip>:5555 CATV=1
#
# Options:
#   --catv          also scan CATV (ISDB-C): C13-C63 and U13-U62
#   --quick         only scan the common Kanto/BS/BS4K channels (for testing)
#   --timeout <s>   per-channel scan timeout (default: 12s GR/CS, 20s BS, 25s BS4K)
#   --key <file>    64-hex ACAS master key file
#   --force         run even if a tuner user (recording/viewing) is active
#   --config-dir <dir>  output directory (default: config/)
#
# The script:
#   1. pushes .acas_key to /data/local/tmp/.acas_key (if a local key is found)
#   2. starts acas_proxy if it is not running
#   3. scans each channel via chscan_one.sh (b25dec/b61dec + mirakc-arib[-tlv])
#   4. regenerates config/config.yml, config/channels.yml and config/services.json
#
# Run this while no recording/viewing is using the tuner.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB_BIN="${ADB:-adb}"

TARGET=""
CATV=0
QUICK=0
FORCE=0
TIMEOUT=""
KEYFILE=""
CONFIG_DIR="$REPO_ROOT/config"

usage() {
    sed -n '2,30p' "$0" | sed 's/^# /# /'
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --catv) CATV=1; shift ;;
        --quick) QUICK=1; shift ;;
        --force) FORCE=1; shift ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --key) KEYFILE="${2:-}"; shift 2 ;;
        --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        --*) echo "chscan.sh: unknown option: $1" >&2; usage ;;
        *) TARGET="$1"; shift ;;
    esac
done

# ---------------------------------------------------------------- ADB target
if [ -z "$TARGET" ]; then
    TARGET=$("$ADB_BIN" devices 2>/dev/null | awk '/\tdevice$/{print $1; exit}')
fi
[ -n "$TARGET" ] || { echo "no ADB device; pass an IP or set ADB_TARGET" >&2; exit 1; }
case "$TARGET" in
    *:*) ;;
    *) TARGET="$TARGET:5555" ;;
esac
DEVICE_IP="${TARGET%%:*}"
ADB_CMD=( "$ADB_BIN" -s "$TARGET" )

"$ADB_BIN" connect "$TARGET" >/dev/null 2>&1 || true
if [ "$("${ADB_CMD[@]}" get-state 2>/dev/null | tr -d '\r')" != "device" ]; then
    echo "chscan.sh: device $TARGET is not online" >&2
    exit 1
fi

echo "=== SMB400 channel scan: $TARGET ==="

# ---------------------------------------------------------------- preconditions
"${ADB_CMD[@]}" shell 'test -x /data/local/tmp/mirakc-root/bin/sh' >/dev/null 2>&1 \
    || { echo "mirakc-root is not set up (run make start / make setup-runtime)" >&2; exit 1; }
"${ADB_CMD[@]}" shell 'test -x /data/local/tmp/b25dec -a -x /data/local/tmp/b61dec -a -x /data/local/tmp/acas_proxy' >/dev/null 2>&1 \
    || { echo "missing decoder/acas_proxy binaries (run make build-bins && make push-bins)" >&2; exit 1; }

# chscan_one.sh (device-side helper)
"$ADB_BIN" -s "$TARGET" push "$REPO_ROOT/scripts/chscan_one.sh" /data/local/tmp/chscan_one.sh >/dev/null \
    || { echo "failed to push chscan_one.sh" >&2; exit 1; }
"${ADB_CMD[@]}" shell chmod 755 /data/local/tmp/chscan_one.sh

# mirakc-arib-tlv is needed for BS4K; push it if missing and available locally.
if ! "${ADB_CMD[@]}" shell 'test -x /data/local/tmp/mirakc/bin/mirakc-arib-tlv' >/dev/null 2>&1; then
    if [ -x "$REPO_ROOT/tmp/mirakc-armv7/mirakc-arib-tlv" ]; then
        echo "[scan] pushing mirakc-arib-tlv"
        "$ADB_BIN" -s "$TARGET" push "$REPO_ROOT/tmp/mirakc-armv7/mirakc-arib-tlv" \
            /data/local/tmp/mirakc/bin/mirakc-arib-tlv >/dev/null
        "${ADB_CMD[@]}" shell chmod 755 /data/local/tmp/mirakc/bin/mirakc-arib-tlv
    else
        echo "warning: mirakc-arib-tlv missing; BS4K scan may fail" >&2
    fi
fi

# acas_proxy must be running (all decoders use --host 127.0.0.1:40773).
if ! "${ADB_CMD[@]}" shell 'pgrep -f /data/local/tmp/acas_proxy >/dev/null' >/dev/null 2>&1; then
    echo "[scan] starting acas_proxy"
    "${ADB_CMD[@]}" shell 'setsid /data/local/tmp/acas_proxy -p 40773 >> /data/local/tmp/acas_proxy.log 2>&1 &'
    sleep 1
    "${ADB_CMD[@]}" shell 'pgrep -f /data/local/tmp/acas_proxy >/dev/null' >/dev/null 2>&1 \
        || { echo "failed to start acas_proxy (see /data/local/tmp/acas_proxy.log)" >&2; exit 1; }
fi

# ---------------------------------------------------------------- tuner busy check
if [ "$FORCE" -eq 0 ]; then
    users=$(curl -s --max-time 3 "http://$DEVICE_IP:40772/api/tuners" 2>/dev/null \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(len(t.get("users",[])) for t in d))' 2>/dev/null)
    if [ -n "$users" ] && [ "$users" != "0" ]; then
        echo "chscan.sh: tuner is in use ($users user(s)); use --force to scan anyway" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------- ACAS key
KEY_SRC=""
for f in "$KEYFILE" "${ACAS_KEY_FILE:-}" \
         "$REPO_ROOT/acas_key" "$REPO_ROOT/.acas_key" \
         "$REPO_ROOT/config/acas_key" "$REPO_ROOT/config/.acas_key"; do
    if [ -n "$f" ] && [ -s "$f" ]; then KEY_SRC="$f"; break; fi
done

if [ -n "$KEY_SRC" ]; then
    key=$(tr -d '[:space:]' < "$KEY_SRC")
    if printf '%s' "$key" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        echo "[scan] using ACAS key: $KEY_SRC"
        "$ADB_BIN" -s "$TARGET" push "$KEY_SRC" /data/local/tmp/.acas_key >/dev/null
        "${ADB_CMD[@]}" shell chmod 600 /data/local/tmp/.acas_key
    else
        echo "warning: $KEY_SRC is not 64 hex chars; BS4K scan may fail" >&2
    fi
elif "${ADB_CMD[@]}" shell 'test -s /data/local/tmp/.acas_key' >/dev/null 2>&1; then
    echo "[scan] using existing /data/local/tmp/.acas_key"
else
    echo "warning: no .acas_key found; BS4K scan will fail" >&2
fi

# ---------------------------------------------------------------- channel lists
if [ "$QUICK" -eq 1 ]; then
    GR_CHANNELS="13 16 18 21 22 23 24 25 26 27 30 32"
    BS_CHANNELS="BS15_0 BS15_1 BS01_0 BS03_0 BS13_0"
    CS_CHANNELS="CS2"
    BS4K_CHANNELS="45168 45232 45280"
    CATV_CHANNELS="U38 U39 U45 U47 U50"
else
    GR_CHANNELS=$(seq 13 62)
    BS_CHANNELS=$(grep -o 'BS[0-9][0-9]_[0-9]' "$REPO_ROOT/scripts/smb400-tuner.sh" | sort -u)
    CS_CHANNELS=$(for n in $(seq 2 2 24); do echo "CS$n"; done)
    BS4K_CHANNELS="45168 45169 45170 45232 45234 45328 45329 45330 45280"
    CATV_CHANNELS="$(seq 13 63 | sed 's/^/C/') $(seq 13 62 | sed 's/^/U/')"
fi

# Test/debug helper: CHSCAN_ONLY="GR:27,BS:BS15_0,BS4K:45168"
if [ -n "${CHSCAN_ONLY:-}" ]; then
    GR_CHANNELS=""; BS_CHANNELS=""; CS_CHANNELS=""; BS4K_CHANNELS=""; CATV_CHANNELS=""
    oldifs=$IFS; IFS=','
    for item in $CHSCAN_ONLY; do
        t=${item%%:*}; ch=${item#*:}
        case "$t" in
            GR) GR_CHANNELS="$GR_CHANNELS $ch" ;;
            BS) BS_CHANNELS="$BS_CHANNELS $ch" ;;
            CS) CS_CHANNELS="$CS_CHANNELS $ch" ;;
            BS4K) BS4K_CHANNELS="$BS4K_CHANNELS $ch" ;;
            CATV) CATV_CHANNELS="$CATV_CHANNELS $ch" ;;
        esac
    done
    IFS=$oldifs
fi

secs_gr="${TIMEOUT:-12}"
secs_bs="${TIMEOUT:-20}"
secs_cs="${TIMEOUT:-12}"
secs_bs4k="${TIMEOUT:-25}"
secs_catv="${TIMEOUT:-12}"

mkdir -p "${CHSCAN_TMP:-$REPO_ROOT/tmp}"
MANIFEST=$(mktemp "${CHSCAN_TMP:-$REPO_ROOT/tmp}/chscan.XXXXXX")

cleanup_scan() {
    "${ADB_CMD[@]}" shell \
        'pkill -9 -f "[t]uner-stream" 2>/dev/null; \
         pkill -9 -f "[b]25dec" 2>/dev/null; \
         pkill -9 -f "[b]61dec" 2>/dev/null; \
         pkill -9 -f "[t]unertest" 2>/dev/null; true' >/dev/null 2>&1
}
trap 'cleanup_scan' INT TERM

ok=0
skip=0

scan() {
    local type=$1 ch=$2 mode=$3 secs=$4 out
    printf '[scan] %-4s %-8s ' "$type" "$ch"
    out=$("${ADB_CMD[@]}" shell \
        "timeout $((secs + 10)) /data/local/tmp/chscan_one.sh '$ch' '$mode' '$secs'" \
        2>/dev/null | tr -d '\r\n')
    # Kill any tuner/decoder that outlived the scan (single-tuner device).
    cleanup_scan
    case "$out" in
        \[*\])
            printf '%s\t%s\t%s\n' "$type" "$ch" "$out" >> "$MANIFEST"
            printf 'OK\n'
            ok=$((ok + 1))
            ;;
        *)
            printf 'skip\n'
            skip=$((skip + 1))
            ;;
    esac
}

echo "[scan] GR (ISDB-T)"
for ch in $GR_CHANNELS; do scan GR "$ch" ts "$secs_gr"; done

echo "[scan] BS (ISDB-S)"
for ch in $BS_CHANNELS; do scan BS "$ch" ts "$secs_bs"; done

echo "[scan] CS (ISDB-S)"
for ch in $CS_CHANNELS; do scan CS "$ch" ts "$secs_cs"; done

echo "[scan] BS4K / BS8K (ISDB-S3)"
for ch in $BS4K_CHANNELS; do scan BS4K "$ch" tlv "$secs_bs4k"; done

if [ "$CATV" -eq 1 ]; then
    echo "[scan] CATV (ISDB-C)"
    for ch in $CATV_CHANNELS; do scan CATV "$ch" ts "$secs_catv"; done
fi

echo "[scan] done: $ok channel(s) with services, $skip skipped"

if [ "$ok" -eq 0 ]; then
    echo "chscan.sh: no services found; config not updated" >&2
    cleanup_scan
    rm -f "$MANIFEST"
    exit 1
fi

# ---------------------------------------------------------------- generate config
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.yml" ]; then
    cp "$REPO_ROOT/config/config.yml" "$CONFIG_DIR/config.yml"
fi
python3 "$REPO_ROOT/scripts/chscan_gen.py" "$MANIFEST" "$CONFIG_DIR" \
    || { echo "chscan.sh: config generation failed" >&2; exit 1; }
cleanup_scan
rm -f "$MANIFEST"

cat <<EOF
=== scan complete ===
generated:
  $CONFIG_DIR/config.yml
  $CONFIG_DIR/channels.yml
  $CONFIG_DIR/services.json

apply to the device:
  make push-config ADB_TARGET=$TARGET
  adb -s $TARGET push config/services.json /data/local/tmp/mirakc/epg/services.json
  make restart ADB_TARGET=$TARGET
EOF
