#!/system/bin/sh
# smb400-tuner.sh — tuner command wrapper for mirakc on SMB400.
#
# Usage (invoked by mirakc via config/config.yml tuners.command):
#   smb400-tuner.sh <channel>
#
# Channel format determines operating mode:
#   GR:   integer 13-62    → tuner-stream-ng  (raw MPEG-TS, ISDB-T)
#   BS:   BSxx_y           → tuner-stream-bs-ng (raw MPEG-TS, ISDB-S)
#   CS:   CSn / NDxx       → tuner-stream-bs-ng (raw MPEG-TS, 110度CS)
#   BS4K: integer ≥40000   → tuner-stream-bs-ng (raw TLV, ISDB-S3)
#
# Decoding is NOT done here.  This script only tunes and emits the raw
# (scrambled) MPEG-TS / TLV.  The decoder (b21dec / b61dec, locally or on a
# remote host via decoder.sh) and the ACAS proxy handle ECM/Ks/AES.
#   - GR / BS / CS(2K): MULTI2 (ARIB STD-B25)  → b21dec
#   - BS4K / BS8K:      ACAS-RMP (ARIB STD-B61) → b61dec
#
# tuner-stream-* run via chroot /proc/1/root to access the Android linker
# paths required by libhi_msp.

CHANNEL=$1
if [ -z "$CHANNEL" ]; then
    echo "smb400-tuner.sh: missing channel argument" >&2
    exit 1
fi

BINDIR=/data/local/tmp

case "$CHANNEL" in
    BS[0-9][0-9]_[0-9])
        # BS (ISDB-S, 従来2K): BSxx_y。xx=トランスポンダ番号で IF を算出。
        TPSTR=${CHANNEL#BS}       # "BS15_0" → "15_0"
        TPSTR=${TPSTR%_*}         # "15_0"   → "15"
        TP=$((TPSTR + 0))         # strip leading zero
        IF_KHZ=$((1049480 + (TP - 1) / 2 * 38360))
        # 1 トランスポンダに複数の相対 TS が多重されており、tunertest(mode=1) は
        # _y(相対インデックス)ではなく実 MPEG TS-ID で TS を選択する。全国共通の
        # BS TS-ID 表（実機 NIT から導出, 2026-06-21）で BSxx_y → TS-ID を引く。
        # TSID は recpt1/recisdb の実測値 (Qiita: yuriyuriyuriyuri「Mirakurunのチャンネル手動設定」)。
        # BSxx_y の y はトランスポンダ内の並び順ラベルに過ぎず、実体はこの TSID で決まる。
        # 別名チャンネル (サブ) はサービスが同じ TS なので親と同一 TSID にする。
        case "$CHANNEL" in
            BS01_0) TSID=16400 ;;  BS01_1) TSID=16401 ;;  BS01_2) TSID=16402 ;;  BS01_3) TSID=16400 ;;
            BS03_0) TSID=16432 ;;  BS03_1) TSID=17969 ;;  BS03_2) TSID=17970 ;;  BS03_3) TSID=16432 ;;
            BS05_0) TSID=17488 ;;  BS05_1) TSID=17489 ;;  BS05_2) TSID=17488 ;;  BS05_3) TSID=17488 ;;
            BS09_0) TSID=16528 ;;  BS09_1) TSID=16530 ;;  BS09_2) TSID=16528 ;;  BS09_3) TSID=16528 ;;
            BS13_0) TSID=16592 ;;  BS13_1) TSID=16593 ;;  BS13_2) TSID=18130 ;;  BS13_3) TSID=16592 ;;
            BS15_0) TSID=16625 ;;  BS15_1) TSID=16626 ;;  BS15_2) TSID=18675 ;;
            BS19_0) TSID=18224 ;;  BS19_1) TSID=18225 ;;  BS19_2) TSID=18226 ;;  BS19_3) TSID=18227 ;;
            BS21_0) TSID=18256 ;;  BS21_1) TSID=18257 ;;  BS21_2) TSID=18258 ;;  BS21_3) TSID=18256 ;;
            BS23_0) TSID=18288 ;;  BS23_1) TSID=18801 ;;  BS23_2) TSID=18803 ;;  BS23_3) TSID=18288 ;;
            *)      TSID= ;;       # 未知: TSID テーブルに載っていない = 存在しないチャンネル
        esac
        # TSID 未定義 (偶数 TP や TS インデックス超過など) は即終了。
        # TSID=0 を tuner-stream-bs-ng に渡すと先頭 TS を返すため、
        # 存在しないチャンネルでも別 TP のサービスがヒットしてしまう。
        if [ -z "$TSID" ]; then
            echo "smb400-tuner.sh: unknown BS channel '$CHANNEL' (not in TSID table)" >&2
            exit 1
        fi
        # 2K BS is MULTI2-scrambled (NHK / 有料局). The raw TS is left scrambled
        # here; b21dec (= the B25 decoder) decrypts it locally or remotely.
        # NOTE: 2K BS (mode=1) も tuner-stream-bs-ng (pipe + 64-bit limit) を使用。
        # 旧 tuner-stream-bs (mkfifo + 2GB limit + 18分毎再起動) は不使用。
        chroot /proc/1/root /system/bin/sh -c \
            "$BINDIR/tuner-stream-bs-ng 0 1 $IF_KHZ $TSID" &
        CHROOT_PID=$!
        trap "pkill -f 'tuner-stream-bs-ng 0 1 $IF_KHZ' 2>/dev/null; \
              sleep 1; \
              kill -9 $CHROOT_PID 2>/dev/null; \
              pkill -9 -f 'tuner-stream-bs-ng 0 1 $IF_KHZ' 2>/dev/null; \
              pkill -9 tunertest 2>/dev/null; exit 0" TERM INT
        wait $CHROOT_PID
        pkill -9 -f "tuner-stream-bs-ng 0 1 $IF_KHZ" 2>/dev/null || true
        pkill -9 tunertest 2>/dev/null || true
        ;;
    CS[0-9]|CS1[0-9]|CS2[0-4]|ND[0-9][0-9])
        # CS (110度CS, ISDB-S 2K相当)。チャンネル名は recpt1 互換の CSn
        # (n=偶数トランスポンダ番号 2-24)。後方互換のため旧 NDxx も受理する。
        # IF = 1613000 + (n-2)/2 * 40000 kHz。1トランスポンダ=単一TSで
        # 複数サービスが通常のMPTSとして多重されているため、BSのようなTSID対応表は不要。
        # streamId=0(auto)で受かる。生TSを出力し、b21dec が復号する。
        case "$CHANNEL" in
            CS*) NSTR=${CHANNEL#CS} ;;
            ND*) NSTR=${CHANNEL#ND} ;;
        esac
        case "$NSTR" in
            2|4|6|8|10|12|14|16|18|20|22|24) ;;
            02|04|06|08|10|12|14|16|18|20|22|24) ;;
            *)
                echo "smb400-tuner.sh: unknown CS channel '$CHANNEL' (expected CS2-CS24 even)" >&2
                exit 1
                ;;
        esac
        ND=$((10#$NSTR)) # strip leading zero, force base10
        IF_KHZ=$((1613000 + (ND - 2) / 2 * 40000))
        chroot /proc/1/root /system/bin/sh -c \
            "$BINDIR/tuner-stream-bs-ng 0 1 $IF_KHZ 0" &
        CHROOT_PID=$!
        trap "pkill -f 'tuner-stream-bs-ng 0 1 $IF_KHZ' 2>/dev/null; \
              sleep 1; \
              kill -9 $CHROOT_PID 2>/dev/null; \
              pkill -9 -f 'tuner-stream-bs-ng 0 1 $IF_KHZ' 2>/dev/null; \
              pkill -9 tunertest 2>/dev/null; exit 0" TERM INT
        wait $CHROOT_PID
        pkill -9 -f "tuner-stream-bs-ng 0 1 $IF_KHZ" 2>/dev/null || true
        pkill -9 tunertest 2>/dev/null || true
        ;;
    4[0-9][0-9][0-9][0-9])
        # BS4K (ISDB-S3): 5-digit stream ID — static IF frequency lookup
        case "$CHANNEL" in
            45168|45169|45170) IF_KHZ=1164560 ;;  # BS7  transponder (右旋)
            45232|45234)       IF_KHZ=1241280 ;;  # BS11 transponder (右旋)
            45328|45329|45330) IF_KHZ=1356360 ;;  # BS17 transponder (右旋)
            45280)             IF_KHZ=2472000 ;;  # BS8K (NHK BS8K, 左旋 11.97682GHz / IF 2472MHz, serviceId 102)
            *) echo "smb400-tuner.sh: unknown BS4K channel '$CHANNEL'" >&2; exit 1 ;;
        esac
        # Raw (scrambled) TLV passthrough.  b61dec (local or remote via
        # decoder.sh + ACAS proxy) performs ECM/AES-128-CTR descrambling.
        chroot /proc/1/root /system/bin/sh -c \
            "$BINDIR/tuner-stream-bs-ng 0 2 $IF_KHZ $CHANNEL" &
        CHROOT_PID=$!
        trap "pkill -f 'tuner-stream-bs-ng 0 2 $IF_KHZ' 2>/dev/null; \
              sleep 1; \
              kill -9 $CHROOT_PID 2>/dev/null; \
              pkill -9 -f 'tuner-stream-bs-ng 0 2 $IF_KHZ' 2>/dev/null; \
              pkill -9 tunertest 2>/dev/null; exit 0" TERM INT
        wait $CHROOT_PID
        # tuner-stream-bs-ng spawns tunertest as a child but does not kill it on exit
        pkill -9 -f "tuner-stream-bs-ng 0 2 $IF_KHZ" 2>/dev/null || true
        pkill -9 tunertest 2>/dev/null || true
        ;;
    [0-9]*)
        # GR (ISDB-T 地上波): 物理チャンネル 13-62。ifKHz = 473143 + (ch-13)*6000。
        IF_KHZ=$((473143 + (CHANNEL - 13) * 6000))
        # 生TSを出力し、b21dec が MULTI2 (B-CAS, CA_system_id 0x0005) を復号する。
        # tuner-stream-ng は libhi_msp(DMX) を dlopen し tunertest_oem を fork するため、
        # Android linker/vendor lib を要する → chroot /proc/1/root 配下で実行。
        # ※ 地デジのワークキー Kw はチップが地上波 EMM 受信時に取得する。地上波を
        #   一度も受信していないチップでは ECM が視聴不可(rc≠0x0800)になり得る。
        chroot /proc/1/root /system/bin/sh -c \
            "$BINDIR/tuner-stream-ng 0 0 32 $IF_KHZ 6000" &
        CHROOT_PID=$!
        # SIGTERM first so tuner-stream-ng can call dmx_deinit() — SIGKILL skips it and
        # leaves a stale DMX channel that blocks the next run.
        trap "pkill -f 'tuner-stream-ng 0 0 32 $IF_KHZ' 2>/dev/null; \
              sleep 1; \
              kill -9 $CHROOT_PID 2>/dev/null; \
              pkill -9 -f 'tuner-stream-ng 0 0 32 $IF_KHZ' 2>/dev/null; \
              pkill -9 tunertest 2>/dev/null; exit 0" TERM INT
        wait $CHROOT_PID
        pkill -9 -f "tuner-stream-ng 0 0 32 $IF_KHZ" 2>/dev/null || true
        pkill -9 tunertest 2>/dev/null || true
        ;;
    *)
        echo "smb400-tuner.sh: unknown channel format '$CHANNEL'" >&2
        exit 1
        ;;
esac
