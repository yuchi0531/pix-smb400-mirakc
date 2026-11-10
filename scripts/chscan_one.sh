#!/system/bin/sh
# chscan_one.sh — scan one channel on the SMB400 and print services as JSON.
#
# Usage: chscan_one.sh <channel> <ts|tlv> [timeout_seconds]
#
#   ts  : GR / BS / CS / CATV (MPEG-TS)  -> b25dec + mirakc-arib scan-services
#   tlv : BS4K / BS8K (TLV)               -> b61dec + mirakc-arib-tlv scan-services-tlv
#
# The ACAS chip is accessed through the local acas_proxy (127.0.0.1:40773).
# b61dec reads /data/local/tmp/.acas_key next to itself.

CH="$1"
MODE="$2"
SECS="${3:-20}"

BINDIR=/data/local/tmp
ROOTFS=/data/local/tmp/mirakc-root
GLIBC_LD=/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf
TUNER="$BINDIR/smb400-tuner.sh"

[ -n "$CH" ] && [ -n "$MODE" ] || { echo "usage: $0 <channel> <ts|tlv> [secs]" >&2; exit 2; }
[ -x "$TUNER" ] || { echo "chscan_one: missing $TUNER" >&2; exit 1; }
[ -d "$ROOTFS" ] || { echo "chscan_one: missing $ROOTFS (run make start first)" >&2; exit 1; }

if [ "$MODE" = "tlv" ]; then
    DEC="$BINDIR/b61dec --host 127.0.0.1:40773"
    SCAN="$BINDIR/mirakc/bin/mirakc-arib-tlv"
    SUB="scan-services-tlv"
else
    DEC="$BINDIR/b25dec --host 127.0.0.1:40773"
    SCAN="$BINDIR/mirakc/bin/mirakc-arib"
    SUB="scan-services"
fi

[ -x "$BINDIR/b25dec" ] || { echo "chscan_one: missing b25dec" >&2; exit 1; }
[ -x "$BINDIR/b61dec" ] || { echo "chscan_one: missing b61dec" >&2; exit 1; }
[ -x "$SCAN" ] || { echo "chscan_one: missing $SCAN" >&2; exit 1; }

"$TUNER" "$CH" 2>/dev/null \
    | $DEC 2>/dev/null \
    | timeout "$SECS" chroot "$ROOTFS" /bin/sh -l -c \
        "export LD_LIBRARY_PATH=$GLIBC_LD; exec $SCAN $SUB" 2>/dev/null
