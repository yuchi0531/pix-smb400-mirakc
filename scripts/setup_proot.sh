#!/bin/bash
# setup_proot.sh — one-time setup of Alpine Linux ARM + glibc runtime on SMB400.
#
# Run from the development host (requires ADB connection to device):
#   make setup-runtime ADB_TARGET=<device-ip>:5555
#
# What this does:
#   1. Downloads the Alpine Linux ARM minimal rootfs
#   2. Pushes it to /data/local/tmp/ on the device and extracts it
#   3. Prepares the chroot skeleton (DNS, /var/run, /run)
#   4. Downloads the real glibc armhf runtime (libc6 / libgcc-s1 / libstdc++6)
#      from Ubuntu ports and deploys it to /data/local/tmp/glibc-armhf
#   5. Verifies the glibc loader and runs mirakc --version (best effort)
#
# Why glibc: mirakc / mirakc-arib / mirakc-arib-tlv are armv7 glibc (hard-float)
# binaries (GLIBC_2.39 / GLIBCXX_3.4.32) — Alpine's musl + gcompat cannot run
# them. They are launched via the loader bundled in /data/local/tmp/glibc-armhf
# (see start_mirakc.sh).
#
# The runtime (start_mirakc.sh) also uses chroot, so no proot is needed.

set -euo pipefail

ADB_TARGET="${1:-}"
if [ -n "$ADB_TARGET" ]; then
    ADB="adb -s $ADB_TARGET"
else
    ADB="adb"
fi

DEVICE_TMP=/data/local/tmp
ROOTFS_DIR="$DEVICE_TMP/mirakc-root"
GLIBC_DIR_DEVICE="$DEVICE_TMP/glibc-armhf"
GLIBC_LIB_DEVICE="$GLIBC_DIR_DEVICE/usr/lib/arm-linux-gnueabihf"
WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT

ALPINE_VERSION=3.20
ALPINE_ARCH=armhf
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"

# Idempotent: the Alpine minirootfs is immutable, so skip the download/extract
# when it is already provisioned. Re-extracting would also fail because Step 3
# replaces Alpine's /var/run symlink with a real directory (tar cannot remove a
# directory to recreate the symlink), so a presence check is required anyway.
alpine_present=$($ADB shell "[ -f '$ROOTFS_DIR/etc/alpine-release' ] && echo yes || echo no" | tr -d '\r\n')
case "$alpine_present" in
    *yes*)
        echo "=== Step 1-2: Alpine rootfs already on device — skipping download/extract. ==="
        ;;
    *)
        echo "=== Step 1: Download Alpine ${ALPINE_VERSION} (${ALPINE_ARCH}) ==="
        curl -L -o "$WORK_DIR/alpine-rootfs.tar.gz" "$ALPINE_URL"
        # Android's toybox tar cannot exec gunzip, so decompress on the host and push
        # an uncompressed .tar (extracted with `tar xf` on the device).
        gunzip "$WORK_DIR/alpine-rootfs.tar.gz"   # → $WORK_DIR/alpine-rootfs.tar

        echo "=== Step 2: Push and extract Alpine rootfs ==="
        $ADB shell mkdir -p "$ROOTFS_DIR"
        $ADB push "$WORK_DIR/alpine-rootfs.tar" "$DEVICE_TMP/alpine-rootfs.tar"
        $ADB shell "cd '$ROOTFS_DIR' && tar xf '$DEVICE_TMP/alpine-rootfs.tar'"
        $ADB shell "rm '$DEVICE_TMP/alpine-rootfs.tar'"
        ;;
esac

echo "=== Step 3: Configure Alpine DNS and runtime dirs ==="
$ADB shell "echo 'nameserver 8.8.8.8' > '$ROOTFS_DIR/etc/resolv.conf'"
# Alpine's /var/run is normally a symlink to /run; make both real directories
# so the init.pixboot.rc mkdir lines and mirakc never depend on a dangling link.
# -rf: on the second run /var/run is already a real directory (-f alone fails).
$ADB shell "rm -rf '$ROOTFS_DIR/var/run'; mkdir -p '$ROOTFS_DIR/var/run' '$ROOTFS_DIR/run'"

echo "=== Step 4: Deploy real glibc armhf runtime ==="
# Idempotent: skip the download/push only when the loader + libstdc++ + libgcc
# are all already on the device. If libstdc++.so.6 were missing, mirakc-arib
# would fail to start (GLIBCXX_3.4.32), so all three are checked.
# (Compare output because adb shell does not always propagate remote exit codes.)
glibc_present=$($ADB shell "[ -f '$GLIBC_LIB_DEVICE/ld-linux-armhf.so.3' ] && [ -f '$GLIBC_LIB_DEVICE/libstdc++.so.6' ] && [ -f '$GLIBC_LIB_DEVICE/libgcc_s.so.1' ] && echo yes || echo no" | tr -d '\r\n')
case "$glibc_present" in
    *yes*)
        echo "[=] glibc runtime already on device — skipping download/push."
        ;;
    *)
    GLIBC_DIR="$WORK_DIR/glibc-armhf"
    mkdir -p "$GLIBC_DIR"

    # Ubuntu ports suite used for the armhf libraries. mirakc needs GLIBC_2.39+
    # and mirakc-arib needs libstdc++ with GLIBCXX_3.4.32. On Ubuntu hosts use
    # the running release; otherwise (e.g. the Debian devcontainer) fall back to
    # an Ubuntu LTS suite that provides both. Override with UBUNTU_SUITE=<name>.
    UBUNTU_SUITE="${UBUNTU_SUITE:-}"
    if [ -z "$UBUNTU_SUITE" ]; then
        if command -v lsb_release >/dev/null 2>&1 && lsb_release -is 2>/dev/null | grep -qi ubuntu; then
            UBUNTU_SUITE=$(lsb_release -cs)
        else
            UBUNTU_SUITE=noble
        fi
    fi
    echo "[*] Ubuntu ports suite: $UBUNTU_SUITE"

    # Dedicated apt state under WORK_DIR so no root / global apt config is touched.
    # NOTE: the file must use the classic .list name — apt >= 3.x parses *.sources
    # as deb822 format and rejects the one-line `deb [...] ...` syntax.
    APT_OPTS="-o Dir::Etc::sourcelist=$WORK_DIR/armhf.list \
              -o Dir::Etc::sourceparts=/dev/null \
              -o Dir::State::Lists=$WORK_DIR/armhf-lists \
              -o Dir::Cache=$WORK_DIR/armhf-cache \
              -o Debug::NoLocking=1 \
              -o APT::Architecture=armhf -o APT::Architectures=armhf"
    mkdir -p "$WORK_DIR/armhf-lists/partial" "$WORK_DIR/armhf-cache/archives/partial"
    echo "deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports $UBUNTU_SUITE main" \
        > "$WORK_DIR/armhf.list"

    GLIBC_PKGS="libc6:armhf libgcc-s1:armhf libstdc++6:armhf"
    # libstdc++6 is required by mirakc-arib (GLIBCXX_3.4.32).
    # shellcheck disable=SC2086
    if ! apt-get $APT_OPTS update >/dev/null 2>&1; then
        # Most common cause on a non-Ubuntu host: the Ubuntu archive keyring is
        # not installed. Retry unauthenticated so the download still works.
        echo "[!] apt-get update failed — retrying with AllowInsecureRepositories"
        # shellcheck disable=SC2086
        APT_OPTS="$APT_OPTS -o Acquire::AllowInsecureRepositories=true \
                             -o APT::Get::AllowUnauthenticated=true"
        # shellcheck disable=SC2086
        apt-get $APT_OPTS update 2>&1 | tail -1
    fi
    # shellcheck disable=SC2086
    if ! (cd "$WORK_DIR" && apt-get $APT_OPTS download $GLIBC_PKGS 2>&1 | tail -2); then
        echo "[*] apt-get download failed — falling back to --print-uris + curl..."
        # Same three packages, but fetched directly from the ports mirror.
        # apt output: '<uri>' <filename> <size> [<hash>]
        # Extract uri/fname/hash (hash may be absent on older apt).
        # shellcheck disable=SC2086
        apt-get $APT_OPTS --print-uris download $GLIBC_PKGS 2>/dev/null \
            | sed -n "s/^'\(http[^']*\)'[[:space:]]\+\([^[:space:]]*\.deb\)\([[:space:]]\+[^[:space:]]*\)\{0,1\}\([[:space:]]\+[^[:space:]]*\)\{0,1\}$/\1 \2\4/p" \
            > "$WORK_DIR/glibc-uris.txt"
        while read -r uri fname hash; do
            echo "    curl $fname"
            curl -fL -o "$WORK_DIR/$fname" "$uri"
            case "$hash" in
                SHA256:*)
                    expected="${hash#SHA256:}"
                    actual=$(sha256sum "$WORK_DIR/$fname" | awk '{print $1}')
                    if [ "$actual" != "$expected" ]; then
                        echo "[!] SHA256 mismatch: $fname (expected $expected, got $actual)"
                        exit 1
                    fi
                    ;;
                *)
                    echo "[!] unverified: $fname (SHA256 hash unavailable from apt)"
                    ;;
            esac
        done < "$WORK_DIR/glibc-uris.txt"
    fi

    # Extract each package; fail loudly instead of passing a stray glob to dpkg.
    for pkg in libc6 libgcc-s1 libstdc++6; do
        deb=$(ls "$WORK_DIR"/${pkg}_*_armhf.deb 2>/dev/null | head -n 1 || true)
        if [ -z "$deb" ]; then
            echo "[!] download failed: ${pkg} (armhf) — see messages above"
            exit 1
        fi
        dpkg-deb -x "$deb" "$GLIBC_DIR"
    done

    echo "[*] Pushing glibc-armhf to device..."
    # Push the *contents* (trailing /.) into a pre-created target so a previous
    # partial deploy cannot end up nested as glibc-armhf/glibc-armhf.
    $ADB shell mkdir -p "$GLIBC_DIR_DEVICE"
    $ADB push "$GLIBC_DIR/." "$GLIBC_DIR_DEVICE/"
    ;;
esac

echo ""
echo "=== Setup complete ==="
echo "glibc runtime on device:"
$ADB shell "ls -l '$GLIBC_LIB_DEVICE/' | head"

echo "mirakc startup test (best effort — needs 'make deploy-mirakc' first):"
# /data/local/tmp is bind-mounted into the rootfs so the chroot sees the glibc
# runtime and the mirakc binaries. The explicit loader is used because the
# /lib/ld-linux-armhf.so.3 symlink is created by start_mirakc.sh at launch.
# `sh -l` (login shell) is required: adb shell exports Android's PATH, which
# has no coreutils, so a plain `sh -c` cannot find head/ls inside the chroot.
$ADB shell "mkdir -p '$ROOTFS_DIR/data/local/tmp'; \
    mount --bind '$DEVICE_TMP' '$ROOTFS_DIR/data/local/tmp' 2>/dev/null || true; \
    chroot '$ROOTFS_DIR' /bin/sh -l -c 'LD_LIBRARY_PATH=$GLIBC_LIB_DEVICE $GLIBC_LIB_DEVICE/ld-linux-armhf.so.3 --library-path $GLIBC_LIB_DEVICE $DEVICE_TMP/mirakc/bin/mirakc --version 2>&1 | head -2' || true; \
    chroot '$ROOTFS_DIR' /bin/sh -l -c 'LD_LIBRARY_PATH=$GLIBC_LIB_DEVICE $GLIBC_LIB_DEVICE/ld-linux-armhf.so.3 --library-path $GLIBC_LIB_DEVICE $DEVICE_TMP/mirakc/bin/mirakc-arib --version 2>&1 | head -2' || true; \
    chroot '$ROOTFS_DIR' /bin/sh -l -c 'LD_LIBRARY_PATH=$GLIBC_LIB_DEVICE $GLIBC_LIB_DEVICE/ld-linux-armhf.so.3 --library-path $GLIBC_LIB_DEVICE $DEVICE_TMP/mirakc/bin/mirakc-arib-tlv --version 2>&1 | head -2' || true; \
    umount '$ROOTFS_DIR/data/local/tmp' 2>/dev/null || true" || true
