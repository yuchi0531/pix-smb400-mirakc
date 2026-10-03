# PIX-SMB400 BS4K — release build environment
FROM mcr.microsoft.com/devcontainers/base:trixie

# Build & deploy dependencies:
#   build-essential        : make + native gcc (Makefile targets)
#   gcc-arm-linux-gnueabi  : ARM32 cross-compiler for bin/ (tuner-stream-bs-ng, b61dec)
#                            Needs its Recommends libc6-dev-armel-cross for armel libc
#                            headers/crt: --no-install-recommends skips Recommends.
#   libssl-dev             : OpenSSL headers for b61dec
#   binwalk                : extract the initramfs cpio from kernel.img
#   cpio                   : unpack the firmware initramfs (build_initramfs.sh, host side)
#   adb                    : pull android-libs / push binaries & scripts to the device
#   python3-pycryptodome   : make_usb_boot.py (bootargs.bin / RSA key generation)
#   curl                   : make start / make test, setup_proot.sh downloads
#   git                    : clone mirakc / mirakc-arib(-tlv) / mirakc-webui sources
#   gcc-arm-linux-gnueabihf + g++-arm-linux-gnueabihf + libc6-dev-armhf-cross +
#   binutils-arm-linux-gnueabihf : ARMv7 (armhf) cross toolchain for mirakc
#                            (make build-mirakc-armv7 cross-builds the mirakc-BS4K fork)
#   cmake + ninja-build    : mirakc-arib build (part of make build-mirakc-armv7)
#
# Rust (rustup) and Node.js are provided by devcontainer features (see
# devcontainer.json): the Rust toolchain for mirakc, Node for mirakc-webui.
#
# mkimage/u-boot-tools are intentionally omitted: build_initramfs.sh builds the
# uImage inside a throwaway Docker container (docker-in-docker feature).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        gcc-arm-linux-gnueabi \
        libc6-dev-armel-cross \
        libssl-dev \
        binwalk \
        cpio \
        adb \
        python3-pycryptodome \
        curl \
        git \
        gcc-arm-linux-gnueabihf \
        g++-arm-linux-gnueabihf \
        libc6-dev-armhf-cross \
        binutils-arm-linux-gnueabihf \
        cmake \
        ninja-build \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
