#!/bin/sh
# decoder.sh — decode raw MPEG-TS / TLV from a tuner.
#
# The SMB400 tuner script (smb400-tuner.sh) now emits the RAW (scrambled)
# stream.  Run this where the TS/TLV is (remote host or the SMB400 itself):
#
#   tuner-stream ... | decoder.sh <channel> [--acas host:port]
#   cat scrambled.ts | decoder.sh BS15_0 --acas 192.168.1.133:40773
#
# Dispatch:
#   BS4K / BS8K (5-digit channel) -> b61dec  (ACAS B61, AES-128-CTR)
#   everything else               -> b25dec  (B-CAS / MULTI2, ARIB STD-B25)
#
# Environment:
#   BINDIR          directory containing the decoder binaries
#                   (default: the directory of this script)
#   ACAS_KEY        32-byte ACAS master key (64 hex chars) for b61dec
#   ACAS_KEY_FILE   file containing the key (default /data/local/tmp/.acas_key)
#   ACAS_PROXY      default --acas value, e.g. 192.168.1.133:40773
#   ACAS_TOKEN      default --acas-token value
#
# The proxy runs on the SMB400 (acas_proxy, default port 40773).

set -u

usage() {
    sed -n '2,24p' "$0" | sed 's/^# /# /'
    exit 2
}

CHANNEL=""
ACAS="${ACAS_PROXY:-}"
TOKEN="${ACAS_TOKEN:-}"
VERBOSE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --acas)
            [ "$#" -ge 2 ] || usage
            ACAS="$2"; shift 2 ;;
        --acas-token)
            [ "$#" -ge 2 ] || usage
            TOKEN="$2"; shift 2 ;;
        -v|--verbose)
            VERBOSE="-v"; shift ;;
        -h|--help)
            usage ;;
        -*)
            echo "decoder.sh: unknown option: $1" >&2
            usage ;;
        *)
            CHANNEL="$1"; shift ;;
    esac
done

[ -n "$CHANNEL" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${BINDIR:-}" ]; then
    if [ -d "$SCRIPT_DIR/../bin" ]; then
        BINDIR="$SCRIPT_DIR/../bin"
    else
        BINDIR="$SCRIPT_DIR"
    fi
fi

pick_bin() {
    # リモート用は bin/x86/ に出力される。無ければ通常の bin/ (または BINDIR) を使う。
    if [ -x "$BINDIR/x86/$1-remote" ]; then
        echo "$BINDIR/x86/$1-remote"
    elif [ -x "$BINDIR/$1-remote" ]; then
        echo "$BINDIR/$1-remote"
    else
        echo "$BINDIR/$1"
    fi
}

case "$CHANNEL" in
    4[0-9][0-9][0-9][0-9])
        # BS4K / BS8K (ISDB-S3): ACAS B61
        if [ -z "${ACAS_KEY:-}" ]; then
            KEYFILE="${ACAS_KEY_FILE:-/data/local/tmp/.acas_key}"
            if [ -s "$KEYFILE" ]; then
                ACAS_KEY=$(tr -d '[:space:]' < "$KEYFILE")
            fi
        fi
        if [ -z "${ACAS_KEY:-}" ]; then
            echo "decoder.sh: ACAS key required for BS4K (set ACAS_KEY or ACAS_KEY_FILE)" >&2
            exit 1
        fi
        BIN=$(pick_bin b61dec)
        set -- -key "$ACAS_KEY"
        [ -n "$ACAS" ]  && set -- "$@" -acas "$ACAS"
        [ -n "$TOKEN" ] && set -- "$@" -acas-token "$TOKEN"
        [ -n "$VERBOSE" ] && set -- "$@" -v
        [ -x "$BIN" ] || { echo "decoder.sh: $BIN not found" >&2; exit 1; }
        exec "$BIN" "$@"
        ;;
    *)
        # GR / BS / CS (2K): B-CAS / MULTI2 (ARIB STD-B25)
        BIN=$(pick_bin b25dec)
        set --
        [ -n "$ACAS" ]  && set -- "$@" -acas "$ACAS"
        [ -n "$TOKEN" ] && set -- "$@" -acas-token "$TOKEN"
        [ -n "$VERBOSE" ] && set -- "$@" -v
        [ -x "$BIN" ] || { echo "decoder.sh: $BIN not found" >&2; exit 1; }
        exec "$BIN" "$@"
        ;;
esac
