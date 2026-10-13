#!/system/bin/sh
# start_mirakc.sh — start mirakc on SMB400 via chroot + Alpine ARM32 (glibc runtime bundled).
#
# Requires root (ADB shell is root by default on SMB400).
# Alpine rootfs must be set up first (see setup_proot.sh / make setup-runtime).
# mirakc binaries + config live in /data/local/tmp/mirakc/ (see config/config.yml).

ROOTFS=/data/local/tmp/mirakc-root
MIRAKC=/data/local/tmp/mirakc
LOG=/data/local/tmp/mirakc.log
PIDFILE=/data/local/tmp/mirakc-start.pid

# --- Preflight: start only if the mirakc setup is fully present. ---
# If anything required is missing we exit immediately WITHOUT stopping
# Android TV, so a not-yet-provisioned device is left completely untouched.
# (This runs before the singleton check / pidfile write on purpose.)
REQUIRED="
$ROOTFS/bin/sh
$MIRAKC/bin/mirakc
$MIRAKC/bin/mirakc-arib
$MIRAKC/bin/mirakc-arib-tlv
$MIRAKC/config.yml
$MIRAKC/strings.yml
/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
/data/local/tmp/smb400-tuner.sh
/data/local/tmp/tuner-stream-ng
/data/local/tmp/tuner-stream-bs-ng
/data/local/tmp/b21dec
/data/local/tmp/b61dec
"
missing=""
for f in $REQUIRED; do
    # Alpine's /bin/sh is a symlink; setup_proot.sh normalizes it to a relative
    # 'busybox' link, but older installs may still have the (Android-namespace)
    # dangling absolute link — accept symlinks too.
    { [ -e "$f" ] || [ -L "$f" ]; } || missing="$missing $f"
done
if [ -n "$missing" ]; then
    echo "[mirakc] not starting — missing file(s):$missing" >> "$LOG"
    exit 0
fi

# ACAS master key is optional for startup but required for descrambling.
if [ ! -s /data/local/tmp/.acas_key ]; then
    echo "[mirakc] warning: /data/local/tmp/.acas_key missing — streams will be scrambled." >> "$LOG"
fi

# Singleton: if another instance is already running, exit immediately.
if [ -f "$PIDFILE" ]; then
    existing=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
        echo "[mirakc] already running (pid=$existing), exiting." >> "$LOG"
        exit 0
    fi
fi
echo $$ > "$PIDFILE"

# Free memory by stopping unused Android TV components (display, audio, camera,
# DRM, OEM apps, etc.).  OEM tuner services are also stopped here so b61dec can
# claim the ACAS smartcard.  See stop_android_tv.sh for the full list.
export LOG
sh /data/local/tmp/stop_android_tv.sh

# Kill stale processes from a previous session.
# The mirakc pattern also matches its mirakc-arib / mirakc-arib-tlv children.
pkill -f "/data/local/tmp/mirakc/bin/mirakc" 2>/dev/null || true
pkill -f "tunertest_oem" 2>/dev/null || true
pkill -f "tunertest" 2>/dev/null || true
pkill -f "tuner-stream" 2>/dev/null || true
pkill -f "b61dec" 2>/dev/null || true
pkill -f "b21dec" 2>/dev/null || true

# --- Bind-mount host directories into the Alpine rootfs ---
mkdir -p "$ROOTFS/data/local/tmp" "$ROOTFS/system" "$ROOTFS/vendor"
mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev"

# Mount only if not already mounted (check by looking for a well-known file)
if ! test -f "$ROOTFS/data/local/tmp/mirakc/bin/mirakc"; then
    mount --bind /data/local/tmp "$ROOTFS/data/local/tmp" 2>/dev/null || true
fi
if ! test -d "$ROOTFS/system/bin"; then
    mount --bind /system "$ROOTFS/system" 2>/dev/null || true
fi
if ! test -d "$ROOTFS/vendor/lib"; then
    mount --bind /vendor "$ROOTFS/vendor" 2>/dev/null || true
fi

# glibc runtime loader symlink: the mirakc binaries are armv7 glibc (hard-float)
# with interpreter /lib/ld-linux-armhf.so.3, which Alpine (musl) does not have.
# Point it at the glibc runtime deployed under /data/local/tmp by setup_proot.sh.
# Alpine may ship /lib as a symlink -> /usr/lib, so resolve where to create it.
GLIBC_LD=/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
if [ -L "$ROOTFS/lib" ]; then
    LNK="$ROOTFS/usr/lib/ld-linux-armhf.so.3"
else
    LNK="$ROOTFS/lib/ld-linux-armhf.so.3"
fi
if [ ! -e "$LNK" ]; then
    mkdir -p "$(dirname "$LNK")" 2>/dev/null || true
    ln -sf "$GLIBC_LD" "$LNK"
fi

# Essential kernel filesystems inside chroot
mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
mount -t sysfs sysfs "$ROOTFS/sys" 2>/dev/null || true
mount -t tmpfs tmpfs "$ROOTFS/dev" 2>/dev/null || true
# Create minimal /dev nodes inside chroot
mknod -m 666 "$ROOTFS/dev/null" c 1 3 2>/dev/null || true
mknod -m 666 "$ROOTFS/dev/zero" c 1 5 2>/dev/null || true
mknod -m 666 "$ROOTFS/dev/urandom" c 1 9 2>/dev/null || true
mknod -m 666 "$ROOTFS/dev/random" c 1 8 2>/dev/null || true
mknod -m 666 "$ROOTFS/dev/tty" c 5 0 2>/dev/null || true

# Fix Alpine's /var/run symlink (→ /run which may not exist)
rm -f "$ROOTFS/var/run" 2>/dev/null
mkdir -p "$ROOTFS/var/run" "$ROOTFS/run"

# Create the mirakc EPG cache directory (config.yml: epg.cache-dir).
mkdir -p "$MIRAKC/epg"

# --- Launch the brick-prevention watchdog (independent of mirakc) ---
# crash_guard kills crash_dump32 fork-bombs and frees memory before OOM.
# Only start it if not already running.
GUARD=/data/local/tmp/crash_guard.sh
GUARD_PID=/data/local/tmp/crash_guard.pid
guard_running=0
if [ -f "$GUARD_PID" ]; then
    gp=$(cat "$GUARD_PID" 2>/dev/null)
    if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then
        guard_running=1
    fi
fi
if [ "$guard_running" = 0 ]; then
    setsid sh "$GUARD" >> /data/local/tmp/crash_guard.log 2>&1 &
    echo "[mirakc] crash_guard watchdog launched (pid=$!)" >> "$LOG"
else
    echo "[mirakc] crash_guard already running (pid=$gp)" >> "$LOG"
fi

echo "[mirakc] Starting mirakc via chroot + Alpine ARM32 (glibc runtime)..." >> "$LOG"

# Ensure the mirakc bind mount is present right before launch.
if ! test -f "$ROOTFS/data/local/tmp/mirakc/bin/mirakc"; then
    mount --bind /data/local/tmp "$ROOTFS/data/local/tmp" 2>/dev/null || true
fi

# Run mirakc ONCE — intentionally NO restart loop.
# On this device a crash-looping decoder can spawn a crash_dump32 fork-bomb
# and brick the box, so we never auto-restart.  If mirakc exits, we log and
# stop; recover with `make start` or a reboot.
# mirakc is a glibc binary (needs GLIBC_2.39 / GLIBCXX_3.4.32); the loader
# symlink above plus LD_LIBRARY_PATH make it run inside the musl chroot.
chroot "$ROOTFS" /bin/sh -l -c "
    export LD_LIBRARY_PATH=/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf
    # チャンネル/サービスは Mirakurun(.111)からインポート済みのため、
    # キャッシュが新鮮な間(30日)は起動時スキャンをスキップする。
    # 定期ジョブ(08:01/20:01)は通常どおり実行される。
    export MIRAKC_EPG_FRESH_PERIOD=30d
    cd /data/local/tmp/mirakc
    exec /data/local/tmp/mirakc/bin/mirakc -c /data/local/tmp/mirakc/config.yml
" >> "$LOG" 2>&1
code=$?

echo "[mirakc] process exited (code=$code) — not restarting (safe mode)." >> "$LOG"
rm -f "$PIDFILE" 2>/dev/null || true
exit 0
