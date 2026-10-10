#!/system/bin/sh
# heartbeat.sh — low-cost forensic logger for the SMB400 mirakc box.
#
# WHY: this device leaves NO kernel log on a hang (pstore/ramoops are
# disabled and logd is stopped), so every freeze is a black box and the
# only way to recover is a physical power cycle.  This script records the
# last minutes before a freeze so the cause can be identified afterwards.
#
# It does NOT touch mirakc, the tuner, or any hardware.  It only reads
# /proc and /sys and appends one line per interval.
#
# Output: /data/local/tmp/heartbeat.log (rotated to the last ROTATE lines).
# On a NEW boot (boot_id change) a header line is written, so the file
# shows "last line before boot N" = the moment the device froze/died.

INTERVAL=30                       # seconds between samples
OUT=/data/local/tmp/heartbeat.log
BOOT=/data/local/tmp/heartbeat.boot_id
PENDING=/data/local/tmp/heartbeat.pending
LASTSEEN=/data/local/tmp/heartbeat.lastseen
ROTATE=2000                       # keep at most this many lines
LOG=/data/local/tmp/heartbeat.log

# Keep CPU priority low so we never affect mirakc.
renice -n 19 $$ 2>/dev/null || true

# Ignore SIGTERM so an accidental kill does not stop the recorder.
trap '' TERM INT

# Singleton: if another heartbeat is already running, exit immediately.
if [ -f /data/local/tmp/heartbeat.pid ]; then
    _p=$(cat /data/local/tmp/heartbeat.pid 2>/dev/null)
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
        exit 0
    fi
fi

sample() {
    now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    mem=$(grep MemAvailable /proc/meminfo 2>/dev/null | tr -dc '0-9')
    free=$(grep MemFree /proc/meminfo 2>/dev/null | tr -dc '0-9')
    # tuner / decoder child processes (the EPG-hardware chain)
    tun=$(pgrep -f 'tuner-stream|b21dec|b61dec|tunertest' 2>/dev/null | wc -l)
    # mirakc / guard presence
    mir=$(pgrep -f '/data/local/tmp/mirakc/bin/mirakc' 2>/dev/null | wc -l)
    grd=$(pgrep -f 'crash_guard' 2>/dev/null | wc -l)
    # D-state (uninterruptible) process count — early hang indicator
    d=$(ps -A -o STAT 2>/dev/null | grep -c '^D')
    # top-3 memory consumers (name:rss kB)
    top=$(ps -A -o RSS,NAME 2>/dev/null | sort -rn | sed -n '1,3p' | tr '\n' ';')
    echo "$now up=${up}s load=$load memAvail=${mem}kB memFree=${free}kB tuner=$tun mirakc=$mir guard=$grd D=$d top=[$top]" >> "$OUT"
}

rotate() {
    n=$(wc -l < "$OUT" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" -gt "$ROTATE" ]; then
        tail -n "$ROTATE" "$OUT" > "$OUT.tmp" 2>/dev/null && mv "$OUT.tmp" "$OUT"
    fi
}

# --- boot detection: header on every new boot ---
cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
prev_boot=$(cat "$BOOT" 2>/dev/null)
if [ "$cur_boot" != "$prev_boot" ]; then
    echo "$cur_boot" > "$BOOT"
    echo "==== BOOT $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) boot_id=$cur_boot (prev=$prev_boot) ====" >> "$OUT"
fi

# Record our PID so a singleton check can be done.
echo $$ > /data/local/tmp/heartbeat.pid

i=0
while true; do
    sample
    i=$((i + 1))
    # rotate roughly every ROTATE samples (cheap)
    [ $((i % 100)) -eq 0 ] && rotate
    sleep "$INTERVAL"
done
