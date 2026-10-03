# SMB400 mirakc — デプロイ & 運用 Makefile
#
# 前提: デバイスが USB ブートで起動し ADB ルート取得済みであること。
# 初回のみ: Alpine + glibc ランタイムセットアップ (setup-runtime) と
#            mirakc デプロイ (deploy-mirakc) が必要。
#
# mirakc 本体 (yuchi0531/mirakc-BS4K fork) と Web UI (mirakc-webui) は
# 常にソースからビルドする。デプロイ時に make build-mirakc-armv7 /
# make build-webui が自動実行される（クロスビルド / Node.js が必要）。
#   mirakc 3バイナリ → tmp/mirakc-armv7/
#   Web UI dist      → tmp/mirakc-webui/  (server.mounts で /www 配信)
#
# 設定: config/config.yml, config/strings.yml
# API : http://<device>:40772 (Mirakurun 互換)
#
# 典型的な操作:
#   make push-all           バイナリ・スクリプト・設定・Web UI を一括更新
#   make start              mirakc 起動
#   make stop               停止
#   make log                ログ確認
#   make test               BS4K ストリーム疎通確認
#   ※ 初回: make build-bins → setup-runtime → deploy-mirakc の順に実行

# ---------- 変更可能な設定 ----------
# ADB_TARGET 未指定時は adb devices から自動検出
# 複数台接続時は明示指定: make <target> ADB_TARGET=192.168.1.126:5555
# ADB を使わないターゲット (help, build-mirakc-armv7, build-webui) は ADB なしでも実行できる。
ifndef ADB_TARGET
  ifeq ($(filter help build-mirakc-armv7 build-webui,$(MAKECMDGOALS)),)
    _DETECTED := $(shell adb devices 2>/dev/null | awk '/\tdevice$$/{print $$1}')
    ifeq ($(words $(_DETECTED)),0)
      $(error No ADB device connected. Run: adb connect <ip>:<port>)
    else ifneq ($(words $(_DETECTED)),1)
      $(error Multiple ADB devices detected: $(_DETECTED) — set ADB_TARGET=<device>)
    else
      ADB_TARGET := $(_DETECTED)
    endif
  endif
endif
ADB        := adb -s $(ADB_TARGET)
DEVICE_IP  := $(firstword $(subst :, ,$(ADB_TARGET)))
DEVICE_TMP := /data/local/tmp
MIRAKC_DIR := $(DEVICE_TMP)/mirakc

# mirakc 3バイナリの取得先 (make build-mirakc-armv7 が出力)
MIRAKC_ARM_DIR := tmp/mirakc-armv7

# mirakc Web UI (mirakc-webui) dist の出力先 (make build-webui が出力)
MIRAKC_WEBUI_DIR := tmp/mirakc-webui

# バイナリビルド設定
# 要件: gcc-arm-linux-gnueabi（sudo apt install gcc-arm-linux-gnueabi）
#       libssl-dev（b61dec の OpenSSL ヘッダ用）
CC_ARM       ?= arm-linux-gnueabi-gcc
ANDROID_LIBS := android-libs
# _TIME_BITS=32 / _FILE_OFFSET_BITS=32: 新しい Debian/Ubuntu のクロスツールチェーンは
# 64-bit time_t がデフォルトで __gettimeofday64 等を要求するが、Android bionic の
# libc.so は 32-bit time_t のシンボル (gettimeofday 等) しか持たないため明示的に 32-bit へ。
CFLAGS_ARM   := -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3 \
                -pie -fPIE -fno-stack-protector -nostartfiles \
                -D_TIME_BITS=32 -D_FILE_OFFSET_BITS=32 \
                -Wl,-dynamic-linker,/system/bin/linker \
                -L$(ANDROID_LIBS) -Wl,-rpath-link,$(ANDROID_LIBS)
# ------------------------------------

.PHONY: build-bins build-mirakc-armv7 build-webui android-libs \
        check-tuner-bins push-all push-bins push-scripts push-config push-webui \
        deploy-mirakc setup-runtime \
        start stop restart log test test-cs help

# ---- ビルド (src/ → bin/) ----

# デバイスから Android システムライブラリを取得（初回のみ。ADB 接続が必要）
# bionic libc/libssl 等にリンクするため実機の .so を使用する。
android-libs:
	@mkdir -p $(ANDROID_LIBS)
	@for lib in libc.so libdl.so ld-android.so libssl.so libcrypto.so libm.so; do \
	    if [ ! -f $(ANDROID_LIBS)/$$lib ]; then \
	        echo "[*] pull /system/lib/$$lib"; \
	        $(ADB) pull /system/lib/$$lib $(ANDROID_LIBS)/$$lib; \
	    fi; \
	done

# src/ から bin/ のバイナリ（tuner-stream-ng, tuner-stream-bs-ng, b61dec, tuner-stream-bs, b21dec）をビルド
# mirakc 本体 (mirakc / mirakc-arib / mirakc-arib-tlv) はここではビルドしない:
# ソースからクロスビルドする（build-mirakc-armv7）。
build-bins: android-libs
	@mkdir -p bin
	@echo "[*] Building tuner-stream-ng (GR/ISDB-T)..."
	$(CC_ARM) $(CFLAGS_ARM) \
	    src/startup.c src/tuner-stream-ng.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/tuner-stream-ng
	@echo "[*] Building tuner-stream-bs-ng..."
	$(CC_ARM) $(CFLAGS_ARM) \
	    src/startup.c src/tuner-stream-bs-ng.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/tuner-stream-bs-ng
	@echo "[*] Building b61dec..."
	$(CC_ARM) $(CFLAGS_ARM) -Wl,--no-as-needed \
	    -isystem /usr/include -isystem include \
	    src/startup.c src/b61dec.c \
	    $(ANDROID_LIBS)/libssl.so $(ANDROID_LIBS)/libcrypto.so \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so \
	    $(ANDROID_LIBS)/libm.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/b61dec
	@echo "[*] Building tuner-stream-bs (ISDB-S mode=1)..."
	$(CC_ARM) $(CFLAGS_ARM) \
	    src/startup.c src/tuner-stream-bs.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/tuner-stream-bs
	@echo "[*] Building b21dec (従来2K BS MULTI2 descrambler)..."
	$(CC_ARM) $(CFLAGS_ARM) -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -Wl,--no-as-needed \
	    src/startup.c src/b21dec.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/b21dec
	@echo "[+] Built bin/tuner-stream-ng, tuner-stream-bs-ng, b61dec, tuner-stream-bs, b21dec"

# mirakc / mirakc-arib / mirakc-arib-tlv (yuchi0531/mirakc-BS4K fork) を
# ARMv7 (glibc) 向けにソースからクロスビルドする。
# Linux x86_64 ホストに rustup + arm-linux-gnueabihf クロスツールチェーン等が必要
# （詳細は scripts/build_mirakc_armv7.sh の冒頭コメント）。
# デプロイ (push-bins / deploy-mirakc) から常に自動実行される。
build-mirakc-armv7:
	bash scripts/build_mirakc_armv7.sh

# mirakc 用 WebUI (mirakc-webui, 静的 SPA) をソースからビルドし、
# tmp/mirakc-webui/ へ dist を配置する。
# デプロイ (push-webui / deploy-mirakc) から常に自動実行される。
build-webui:
	bash scripts/build_webui.sh

# ---- デプロイ ----

# 初回は bin/ が未生成のため、先に存在チェックして案内を出す
# （make build-bins がクロスツールチェーンで生成する）。
check-tuner-bins:
	@missing=""; for f in bin/tuner-stream-ng bin/tuner-stream-bs-ng bin/b61dec bin/tuner-stream-bs bin/b21dec; do \
	    [ -f "$$f" ] || missing="$$missing $$f"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "[!] チューナーバイナリが未ビルドです:$$missing"; \
	    echo "    先に 'make build-bins' を実行してください (arm-linux-gnueabi-gcc が必要)。"; \
	    exit 1; \
	fi

# チューナー/デコーダバイナリを $(DEVICE_TMP)/ へ、
# mirakc 3バイナリを $(MIRAKC_DIR)/bin/ へ push
# mirakc バイナリは $(MIRAKC_ARM_DIR)/ から（常にソースから再ビルド）
push-bins: check-tuner-bins build-mirakc-armv7
	@echo "[*] Pushing tuner/decoder binaries..."
	$(ADB) push bin/tuner-stream-ng    $(DEVICE_TMP)/tuner-stream-ng
	$(ADB) push bin/tuner-stream-bs-ng $(DEVICE_TMP)/tuner-stream-bs-ng
	$(ADB) push bin/b61dec             $(DEVICE_TMP)/b61dec
	$(ADB) push bin/tuner-stream-bs    $(DEVICE_TMP)/tuner-stream-bs
	$(ADB) push bin/b21dec             $(DEVICE_TMP)/b21dec
	@echo "[*] Pushing mirakc binaries..."
	$(ADB) shell mkdir -p $(MIRAKC_DIR)/bin
	$(ADB) push $(MIRAKC_ARM_DIR)/mirakc          $(MIRAKC_DIR)/bin/mirakc
	$(ADB) push $(MIRAKC_ARM_DIR)/mirakc-arib     $(MIRAKC_DIR)/bin/mirakc-arib
	$(ADB) push $(MIRAKC_ARM_DIR)/mirakc-arib-tlv $(MIRAKC_DIR)/bin/mirakc-arib-tlv
	$(ADB) shell chmod +x \
	    $(DEVICE_TMP)/tuner-stream-ng \
	    $(DEVICE_TMP)/tuner-stream-bs-ng \
	    $(DEVICE_TMP)/b61dec \
	    $(DEVICE_TMP)/tuner-stream-bs \
	    $(DEVICE_TMP)/b21dec \
	    $(MIRAKC_DIR)/bin/mirakc \
	    $(MIRAKC_DIR)/bin/mirakc-arib \
	    $(MIRAKC_DIR)/bin/mirakc-arib-tlv

push-scripts:
	@echo "[*] Pushing scripts..."
	$(ADB) push scripts/smb400-tuner.sh    $(DEVICE_TMP)/smb400-tuner.sh
	$(ADB) push scripts/start_mirakc.sh    $(DEVICE_TMP)/start_mirakc.sh
	$(ADB) push scripts/stop_android_tv.sh $(DEVICE_TMP)/stop_android_tv.sh
	$(ADB) push scripts/crash_guard.sh     $(DEVICE_TMP)/crash_guard.sh
	$(ADB) shell chmod +x \
	    $(DEVICE_TMP)/smb400-tuner.sh \
	    $(DEVICE_TMP)/start_mirakc.sh \
	    $(DEVICE_TMP)/stop_android_tv.sh \
	    $(DEVICE_TMP)/crash_guard.sh

push-config:
	@echo "[*] Pushing config..."
	$(ADB) shell mkdir -p $(MIRAKC_DIR)/epg
	$(ADB) push config/config.yml  $(MIRAKC_DIR)/config.yml
	$(ADB) push config/strings.yml $(MIRAKC_DIR)/strings.yml

# Web UI (mirakc-webui) をソースからビルドしてデバイスへ push
# （config.yml の server.mounts で /www として配信される）
# 古いハッシュ付きアセットが残らないよう、配置前に www を空にする。
push-webui: build-webui
	@echo "[*] Pushing mirakc Web UI..."
	$(ADB) shell mkdir -p $(MIRAKC_DIR)/www
	$(ADB) shell "rm -rf $(MIRAKC_DIR)/www/*"
	$(ADB) push $(MIRAKC_WEBUI_DIR)/. $(MIRAKC_DIR)/www/

push-all: push-bins push-scripts push-config push-webui
	@echo "[+] Done. Run 'make start' to launch mirakc."

# 初回のみ: mirakc 本体・設定・Web UI をデバイスへデプロイ。
# バイナリと Web UI は $(MIRAKC_ARM_DIR)/ $(MIRAKC_WEBUI_DIR)/ へ
# ソースからビルドしてから配置される。
deploy-mirakc: build-mirakc-armv7 build-webui
	@echo "[*] Deploying mirakc to device..."
	$(ADB) shell mkdir -p $(MIRAKC_DIR)/bin $(MIRAKC_DIR)/epg $(MIRAKC_DIR)/www
	$(ADB) push config/config.yml  $(MIRAKC_DIR)/config.yml
	$(ADB) push config/strings.yml $(MIRAKC_DIR)/strings.yml
	$(ADB) push config/services.json $(MIRAKC_DIR)/epg/services.json
	$(ADB) push $(MIRAKC_ARM_DIR)/mirakc          $(MIRAKC_DIR)/bin/mirakc
	$(ADB) push $(MIRAKC_ARM_DIR)/mirakc-arib     $(MIRAKC_DIR)/bin/mirakc-arib
	$(ADB) push $(MIRAKC_ARM_DIR)/mirakc-arib-tlv $(MIRAKC_DIR)/bin/mirakc-arib-tlv
	$(ADB) shell chmod +x \
	    $(MIRAKC_DIR)/bin/mirakc \
	    $(MIRAKC_DIR)/bin/mirakc-arib \
	    $(MIRAKC_DIR)/bin/mirakc-arib-tlv
	@echo "[*] Pushing mirakc Web UI..."
	$(ADB) shell "rm -rf $(MIRAKC_DIR)/www/*"
	$(ADB) push $(MIRAKC_WEBUI_DIR)/. $(MIRAKC_DIR)/www/
	@echo "[+] mirakc deployed."

# 初回のみ: Alpine rootfs + glibc (armhf) ランタイムをデバイスに構築（インターネット接続必要）
setup-runtime:
	bash scripts/setup_proot.sh $(ADB_TARGET)

# ---- 起動・停止 ----

start:
	@echo "[*] Stopping any existing session..."
	-$(ADB) shell "pkill -TERM mirakc 2>/dev/null; \
	    sleep 3; \
	    pkill -9 mirakc 2>/dev/null; \
	    kill -9 \$$(pgrep -f 'start_mirakc[.]sh' 2>/dev/null) 2>/dev/null; \
	    pkill -9 b61dec 2>/dev/null; pkill -9 b21dec 2>/dev/null; \
	    pkill -9 tunertest 2>/dev/null; \
	    pkill -9 -f tuner-stream 2>/dev/null; true"
	@sleep 1
	@echo "[*] Starting mirakc..."
	$(ADB) shell "setsid sh $(DEVICE_TMP)/start_mirakc.sh \
	    >> $(DEVICE_TMP)/mirakc.log 2>&1 &"
	@echo "[*] 起動を待っています（最大 ~60 秒）..."
	@ok=0; for i in $$(seq 1 30); do \
	    if curl -s --max-time 5 http://$(DEVICE_IP):40772/api/version >/dev/null 2>&1; then ok=1; break; fi; \
	    sleep 2; \
	done; \
	if [ $$ok = 1 ]; then \
	    printf "[+] mirakc is up: "; curl -s --max-time 5 http://$(DEVICE_IP):40772/api/version; echo; \
	else \
	    echo "(まだ応答がありません — 'make log' で確認してください)"; \
	fi

stop:
	-$(ADB) shell "pkill -TERM mirakc 2>/dev/null; \
	    sleep 3; \
	    pkill -9 mirakc 2>/dev/null; \
	    kill -9 \$$(pgrep -f 'start_mirakc[.]sh' 2>/dev/null) 2>/dev/null; \
	    pkill -9 b61dec 2>/dev/null; \
	    pkill -9 b21dec 2>/dev/null; \
	    pkill -9 tunertest 2>/dev/null; \
	    pkill -9 -f tuner-stream 2>/dev/null; \
	    pkill -9 -f crash_guard.sh 2>/dev/null; \
	    rm -f $(DEVICE_TMP)/crash_guard.pid; \
	    sleep 1; true"
	-$(ADB) shell " \
	    grep mirakc-root /proc/mounts | while read d mp r; do echo \"\$$mp\"; done | sort -r | \
	    while read mp; do umount \"\$$mp\" 2>/dev/null || true; done; true"
	@echo "Stopped."

restart: stop start

# ---- 確認 ----

log:
	$(ADB) shell "tail -50 $(DEVICE_TMP)/mirakc.log"

# BS4K 45168 から 5 秒受信して先頭バイトを表示
# 正常: 7f 02 ... または 7f 03 ... (IPv4/IPv6 TLV コンテンツ)
# 異常: 7f ff ... (Null TLV = 未復号) またはデータなし
test:
	@echo "Streaming BS4K 45168 for 5s..."
	@curl -s --max-time 8 http://$(DEVICE_IP):40772/api/channels/BS4K/45168/stream \
	    | od -v -t x1 2>/dev/null | head -4

# CS ND02 から 5 秒受信して MPEG-TS の先頭バイトを表示
# 正常: 47 (TS同期バイト)。復号可否はACAS契約・EMM状態に依存する。
test-cs:
	@echo "Streaming CS ND02 for 5s..."
	@curl -s --max-time 8 http://$(DEVICE_IP):40772/api/channels/CS/ND02/stream \
	    | od -v -t x1 2>/dev/null | head -4

# ---- ヘルプ ----

help:
	@echo ""
	@echo "SMB400 mirakc デプロイ Makefile"
	@echo ""
	@echo "  make build-bins          src/ からチューナー/デコーダバイナリをビルド (初回のみ)"
	@echo "  make android-libs        デバイスから Android システムライブラリを取得"
	@echo "  make build-mirakc-armv7  mirakc 3バイナリ (mirakc-BS4K fork) をソースからビルド"
	@echo "  make build-webui         mirakc WebUI (mirakc-webui) をソースからビルド"
	@echo "  make push-all            バイナリ・スクリプト・設定・Web UI を一括デプロイ"
	@echo "  make push-bins           バイナリのみ (チューナー5種 + mirakc 3種)"
	@echo "  make push-scripts        スクリプトのみ (smb400-tuner.sh 等)"
	@echo "  make push-config         設定のみ (config.yml / strings.yml)"
	@echo "  make push-webui          WebUI のみ配備"
	@echo "  make deploy-mirakc       mirakc 本体・設定・Web UI をデプロイ (初回のみ)"
	@echo "  make setup-runtime       Alpine rootfs + glibc ランタイムを構築 (初回のみ)"
	@echo "  make start               mirakc 起動"
	@echo "  make stop                mirakc 停止"
	@echo "  make restart             再起動"
	@echo "  make log                 ログ確認 (tail -50)"
	@echo "  make test                BS4K ストリーム疎通テスト"
	@echo "  make test-cs             CS ND02 ストリーム疎通テスト (実機・契約依存)"
	@echo ""
	@echo "デフォルト接続先: $(if $(ADB_TARGET),$(ADB_TARGET),(未検出 — ADB 接続が必要))"
	@echo "変更: make start ADB_TARGET=192.168.1.100:5555"
	@echo ""
