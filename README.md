# PIX-SMB400 mirakc

PIX-SMB400（HiSilicon Hi3798CV200 搭載 Android TV）上で [mirakc](https://github.com/mirakc/mirakc)（Rust 製 Mirakurun 互換 PVR バックエンド）を実行し、地上波（ISDB-T）・BS（ISDB-S）・BS4K / BS8K（ISDB-S3）を受信するためのプロジェクトです。

本リポジトリは BS4K / BS8K の **TLV passthrough 対応** を追加した [yuchi0531/mirakc-BS4K](https://github.com/yuchi0531/mirakc-BS4K) フォークを使用します。ARMv7 (glibc) 版の mirakc バイナリは [smb400-armv7-v1 リリース](https://github.com/yuchi0531/mirakc-BS4K/releases/tag/smb400-armv7-v1) から `make fetch-mirakc-armv7` で取得するため、クロスビルド環境なしでもデプロイできます（リポジトリにはバイナリを含みません）。自分でビルドする場合は `make build-mirakc-armv7`。

Web UI は任意で [yuchi0531/mirakc-webui](https://github.com/yuchi0531/mirakc-webui) を導入できます（[Web UI (mirakc-webui)](#web-ui-mirakc-webui) 参照）。

> 以前は Mirakurun（Node.js）を Alpine + chroot で動かす構成でしたが、現在は mirakc（Rust, glibc ARMv7）に移行しています。

<img width="1052" height="822" alt="image" src="https://github.com/user-attachments/assets/fd564f7a-a7b6-4b5c-941d-a226162a170c" />

## 免責事項

本プロジェクトのファイル・スクリプト・ドキュメントは、技術的な調査・学習を目的としています。
利用はすべて**自己責任**で行ってください。

- 本手順はメーカー非公式・非サポートの改造であり、実行した時点でメーカー保証は失われます。
- ブートローダや init への介入を伴うため、**デバイスが文鎮化（起動不能）する可能性**があります。
  実際に過去、特定の操作でデバイスが起動不能になった事例があります。
- 作者は、本プロジェクトの利用によって生じた**いかなる損害（デバイスの故障・データ消失・経済的損失・第三者への損害等を含むがこれに限らない）についても、  一切の責任を負いません。**
- 放送の受信・録画・復号は、利用者自身が正規に契約・受信権を持つ範囲で、私的利用の目的に限り行ってください。
  関係する法令・契約・利用規約は各自の責任で遵守してください。

---

## 全体の流れ

```
Part 1: USB ブートで root を取る
  Step 1  ブートファイルをビルドして USB メモリを準備する
  Step 2  PIX-SMB400 を USB ブートで起動する
  Step 3  ADB で接続確認する

Part 2: mirakc のセットアップ
  Step 4  チューナーバイナリをビルドする（make build-bins）
  Step 5  mirakc バイナリを用意する（Release から fetch・再ビルドは任意）
  Step 6  Alpine Linux + glibc ランタイムをセットアップする（make setup-runtime）
  Step 7  mirakc をデプロイする（make deploy-mirakc）
  Step 8  ACAS マスターキーを設定する

Part 3: 起動・確認
  Step 9  mirakc を起動する（make start）
  Step 10 ストリームを確認する（make test / make test-cs）
  Step 11 自動起動を有効にする（initramfs 再ビルド）
```

---

## 必要なもの

| 項目 | 内容 |
|------|------|
| 作業コピー | 本リポジトリ（`git clone https://github.com/yuchi0531/pix-smb400-mirakc`）。以降のコマンドは clone したディレクトリのルートで実行 |
| PIX-SMB400 本体 | USB ブートピンにアクセスできる状態 |
| USB メモリ | FAT32 フォーマット、1 GB 以上 |
| ビルド環境 | `python3` + `pycryptodome`（ブートファイル用）、`mkimage` (u-boot-tools) または Docker（uimg 用）、`binwalk`（`kernel.img` 展開用）、`gcc-arm-linux-gnueabi` + `libc6-dev-armel-cross` + `libssl-dev`（チューナーバイナリのビルド用）。mirakc 本体はリリースから取得するためクロスビルド環境は不要 |
| ADB | デバイスへの接続（`adb connect` / `adb devices` で認識済みであること）。全デプロイ系コマンドで必要 |
| ネットワーク | mirakc バイナリ取得（`make fetch-mirakc-armv7`）に必要（`curl` を使用） |
| ACAS マスターキー | 64 文字の hex |

---

## 開発環境（Dev Container）

本リポジトリには [Dev Container](https://containers.dev/) 設定（[.devcontainer/](.devcontainer/)）が含まれています。
ビルドに必要なツールチェーンを一括で用意できるため、**ローカルへ個別にパッケージをインストールせずに済みます**。

VS Code の **Dev Containers** 拡張、または GitHub Codespaces で「Reopen in Container」すると、
[.devcontainer/Dockerfile](.devcontainer/Dockerfile) からビルド環境が構築されます。主な内容:

- `gcc-arm-linux-gnueabi` + `libc6-dev-armel-cross` + `libssl-dev` — `make build-bins`（ARM32 チューナーバイナリのクロスコンパイル）
- `binwalk` + `cpio` — `kernel.img` から initramfs cpio を展開（[Step 0](#step-0-kernelimg-を入手して展開する)）
- `adb` — デバイスとのバイナリ転送・android-libs 取得
- `python3-pycryptodome` — `make_usb_boot.py`（`bootargs.bin` / RSA 鍵生成）
- `git` / `curl` — mirakc バイナリ（GitHub Release）の取得や、任意の再ビルド時のクローン
- **docker-in-docker** feature — `build_initramfs.sh` / `make_usb_boot.py` がコンテナ内で `docker run` を使う場合のため有効化済み（`mkimage` が使える環境では docker なしでもビルド可能）

> 以降の手順に出てくる `sudo apt install ...`（`gcc-arm-linux-gnueabi`・`libc6-dev-armel-cross`・`libssl-dev`・`binwalk` 等）は、
> Dev Container を使う場合はインストール済みのためスキップできます。
> ただし USB メモリのフォーマット・マウント（[Step 1](#step-1-ブートファイルをビルドして-usb-メモリを準備する)）や
> デバイスへの物理アクセスを伴う操作は、ホスト側で実施してください。

---

## ディレクトリ構成

```
.                                    （リポジトリのルート）
├── README.md                        このファイル
├── BOOT.md                          USB ブートイメージの仕組みと再ビルド手順
├── Makefile                         デプロイ・運用コマンド集
├── .devcontainer/                   Dev Container 設定（ビルド環境一式）
│   ├── devcontainer.json            Dev Container 定義（docker-in-docker feature 等）
│   └── Dockerfile                   ビルド依存パッケージのインストール
├── boot/                            USB ブート用ファイル（ビルド手順は BOOT.md）
│   ├── make_usb_boot.py             bootargs.bin / root_rsa_pub_crc.bin 生成スクリプト
│   ├── patch_init.py                init バイナリパッチスクリプト（SELinux bypass 等）
│   ├── build_initramfs.sh           initramfs_patched.uimg ビルドスクリプト
│   ├── usb_boot_files/              生成物: bootargs.bin / root_rsa_pub_crc.bin / rsa_key.pem（gitignore 対象）
│   └── initramfs_overlay/           initramfs オーバーレイファイル
│       └── start_mirakc.sh          mirakc 自動起動スクリプト（電源 ON 時に実行される版）
├── bin/                             ビルドしたチューナーバイナリの出力先（make build-bins で生成）
├── tmp/mirakc-armv7/                mirakc 本体 ARMv7 (glibc) バイナリの取得先（gitignore 対象・コミットされない）
│   ├── mirakc                       mirakc 本体（yuchi0531/mirakc-BS4K fork）
│   ├── mirakc-arib                  GR / BS / CS(2K) 用フィルタ・ジョブ
│   ├── mirakc-arib-tlv              BS4K / BS8K (TLV) 用ジョブ
│   └── SHA256SUMS                   上記バイナリのチェックサム
├── include/openssl/                 b61dec ビルド用 OpenSSL 設定ヘッダ
├── scripts/
│   ├── smb400-tuner.sh              mirakc チューナーコマンドラッパー
│   ├── start_mirakc.sh              mirakc 起動スクリプト（chroot + glibc ランタイム）
│   ├── stop_android_tv.sh           Android TV 不要プロセス停止
│   ├── crash_guard.sh               クラッシュ監視ウォッチドッグ
│   ├── write_usb_boot.sh            USBメモリへブートファイル3点を書き込む（要 sudo）
│   ├── setup_proot.sh               Alpine rootfs + glibc-armhf 初回セットアップ
│   ├── fetch_mirakc_armv7.sh        mirakc バイナリを GitHub Release から取得（通常はこちら）
│   └── build_mirakc_armv7.sh        mirakc バイナリ再ビルドスクリプト（任意・上級者向け）
├── config/
│   ├── config.yml                   mirakc 設定（server / channels / tuners / filters / jobs）
│   ├── services.json                サービス定義（mirakc の EPG キャッシュ services.json として配置）
│   └── strings.yml                  mirakc 日本語文字列定義
└── src/                             バイナリの C ソースコード（make build-bins でビルド）
    ├── b61dec.c                     ACAS BS4K / BS8K デスクランブラー（ARIB STD-B61 / AES）
    ├── b21dec.c                     地上波 / BS / CS MULTI2 デスクランブラー（ACAS 経由 / ARIB STD-B25）
    ├── tuner-stream-ng.c            地上波（ISDB-T, MPEG-TS）チューナー
    ├── tuner-stream-bs-ng.c         BS4K / BS8K / BS / CS（ISDB-S/S3）チューナー
    ├── tuner-stream-bs.c            BS（ISDB-S, MPEG-TS）チューナー（mode=1）
    └── startup.c                    Android PIE 用 _start エントリポイント
```

### デバイス上のレイアウト

| パス | 内容 |
|------|------|
| `/data/local/tmp/mirakc/bin/` | mirakc / mirakc-arib / mirakc-arib-tlv |
| `/data/local/tmp/mirakc/` | `config.yml` / `strings.yml` |
| `/data/local/tmp/mirakc/epg/` | EPG キャッシュ（`services.json` など） |
| `/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf/` | glibc ランタイム（`make setup-runtime` で配備） |
| `/data/local/tmp/mirakc-root/` | Alpine rootfs |
| `/data/local/tmp/mirakc.log` | ログ |
| `/data/local/tmp/mirakc-start.pid` | pidfile |
| `/data/local/tmp/start_mirakc.sh` | 起動スクリプト（`make start` から実行） |

---

## Part 1: USB ブートでルートを取る

> **仕組みの詳細・各ファイルのビルド方法は [BOOT.md](BOOT.md) を参照してください。**

### Step 0: kernel.img を入手して展開する

ブートファイル（`initramfs_patched.uimg`）のビルドには PIX-SMB400 のカーネルイメージ `kernel.img` が必要です。
これはメーカー公式の配布ファームウェアから取得します。

**0-1. kernel.img を展開して initramfs を取り出す**

`kernel.img` を binwalk で展開すると、内部に格納された initramfs（cpio アーカイブ）が取り出せます。
取り出した cpio ファイルが、次の Step でブートイメージ（`initramfs_patched.uimg`）をビルドする元になります。

```sh
# 要件: binwalk
binwalk -e kernel.img
# → _kernel.img.extracted/988000 が initramfs の cpio アーカイブ
```

> `988000` は kernel.img 内での initramfs のオフセット（16 進）に由来するファイル名です。
> binwalk のバージョンによって抽出先ディレクトリ名やファイル名が変わることがあります。
> その場合は `_kernel.img.extracted/` 内で `file` コマンドが `ASCII cpio archive` と判定するファイルを使用してください。

---

### Step 1: ブートファイルをビルドして USB メモリを準備する

**1-1. ブートファイルをビルドする**

USB メモリに必要な 3 ファイル（`bootargs.bin` / `root_rsa_pub_crc.bin` / `initramfs_patched.uimg`）を `boot/` のスクリプトで生成します。
`initramfs_patched.uimg` のビルドには、[Step 0](#step-0-kernelimg-を入手して展開する) で取り出した initramfs cpio を使用します。

```sh
# 1) bootargs.bin / root_rsa_pub_crc.bin を生成（Docker 不要）
#    要件: python3 + pycryptodome
python3 boot/make_usb_boot.py
# → boot/usb_boot_files/ に bootargs.bin / root_rsa_pub_crc.bin / rsa_key.pem が生成される

# 2) Step 0 で取り出した initramfs cpio から initramfs_patched.uimg をビルド
#    要件: mkimage (u-boot-tools) または Docker
bash boot/build_initramfs.sh _kernel.img.extracted/988000
```

> `mkimage` が無い場合（root 権限なしで u-boot-tools を入手する例）:
> ```sh
> mkdir -p /tmp/u-boot-tools && cd /tmp
> URL=$(apt-get download --print-uris u-boot-tools | sed -n "s/^'\(http[^']*\)'.*/\1/p" | head -1)
> curl -fL -o u-boot-tools.deb "$URL"
> dpkg-deb -x u-boot-tools.deb /tmp/u-boot-tools
> cd - && PATH=/tmp/u-boot-tools/usr/bin:$PATH bash boot/build_initramfs.sh _kernel.img.extracted/988000
> ```

**1-2. FAT32 でフォーマットする**

```sh
sudo mkfs.fat -F 32 -n PIXBOOT /dev/sdX1
```

**1-3. ブートファイルを USB メモリにコピーする**

`scripts/write_usb_boot.sh` がマウント・コピー・md5 検証・アンマウントまで行います:

```sh
sudo bash scripts/write_usb_boot.sh /dev/sdX1
```

手動でコピーする場合:

```sh
sudo mkdir -p /mnt/PIXBOOT
sudo mount -o uid=$(id -u),gid=$(id -g) /dev/sdX1 /mnt/PIXBOOT
sudo chown $USER:$USER /mnt/PIXBOOT

cp boot/usb_boot_files/bootargs.bin         /mnt/PIXBOOT/
cp boot/usb_boot_files/root_rsa_pub_crc.bin /mnt/PIXBOOT/
cp boot/initramfs_patched.uimg              /mnt/PIXBOOT/

sudo umount /mnt/PIXBOOT
```

USB メモリのルートに以下の 3 ファイルが置かれていれば OK です:

```
PIXBOOT/
├── bootargs.bin
├── root_rsa_pub_crc.bin
└── initramfs_patched.uimg
```

---

### Step 2: PIX-SMB400 を USB ブートで起動する

**2-1. 事前準備**

- PIX-SMB400 の電源を切る
- USB Boot ピン（基板上）にアクセスできる状態にする
- USB メモリを PIX-SMB400 の USB ポートに挿入する
- LAN ケーブルを接続する

**2-2. USB ブートピンをショートしながら電源を投入する**

1. USB Boot ピンをショートした状態を維持しながら電源を入れる
   <img width="1575" height="1181" alt="image" src="https://github.com/user-attachments/assets/09c1fc0b-332a-4d23-bf2b-5097678871e6" />

3. BootROM が USB メモリを検出し、外部 RSA 鍵で検証を行う
4. カスタム initramfs でシステムが起動する

---

### Step 3: ADB で接続確認する

起動後 30 秒ほど待ってから接続します。

**3-1. デバイスの IP アドレスを確認する**

デバイスが DHCP で取得した IP アドレスをシリアルコンソールまたは arp-scan 等で確認します。
シリアルコンソールで確認する場合、 `init_pix_netdbg.sh` が `PIXDBG: *** ADB: adb connect <デバイスのIPアドレス>:5555 ***` をカーネルログに出力しています。

**3-2. ADB 接続**

```sh
adb connect <デバイスのIPアドレス>:5555
adb -s <デバイスのIPアドレス>:5555 shell id
# → uid=0(root) gid=0(root) groups=0(root),1004(input),1007(log),1011(adb),1015(sdcard_rw),1028(sdcard_r),3001(net_bt_admin),3002(net_bt),3003(inet),3006(net_bw_stats),3009(readproc) context=u:r:su:s0
```

`uid=2000(shell)` と表示された場合は eMMC から通常ブートしています（USB ブートを再確認）。

---

## Part 2: mirakc のセットアップ

> セットアップ以降は USB メモリを挿入して電源を入れるだけで、`mirakc_proxy` サービスが起動時に mirakc を自動起動します（`make start` は不要）。
> ただし、安全のためクラッシュ時の自動再起動はしません。
> 停止した場合は `make start` か再起動で復帰してください。

---

### Step 4: チューナーバイナリをビルドする

`src/` の C ソースからチューナー/デスクランブラバイナリ（`tuner-stream-ng` / `tuner-stream-bs-ng` / `b61dec` / `tuner-stream-bs` / `b21dec`）をビルドします。
リンクには実機の Android システムライブラリが必要なため、`make build-bins` が ADB 経由で自動取得します（デバイスが USB ブート中であること）。

```sh
# 要件: sudo apt install gcc-arm-linux-gnueabi libc6-dev-armel-cross libssl-dev
make build-bins ADB_TARGET=<デバイスのIPアドレス>:5555
```

> mirakc 本体（`mirakc` / `mirakc-arib` / `mirakc-arib-tlv`）はこのターゲットではビルドされません。
> GitHub Release から取得します（Step 5）。

---

### Step 5: mirakc バイナリを用意する（通常は何もしなくてよい）

ARMv7 (glibc) 版の mirakc 3バイナリはリポジトリに含まれません。デプロイ時に `make fetch-mirakc-armv7` が GitHub Release（[smb400-armv7-v1](https://github.com/yuchi0531/mirakc-BS4K/releases/tag/smb400-armv7-v1)）から `tmp/mirakc-armv7/` へ自動取得し、SHA256 を検証します（**クロスビルド環境は不要**）。手動で先に取得する場合:

```sh
make fetch-mirakc-armv7
```

- 取得済みで SHA256 が一致していれば再ダウンロードはスキップされます（強制再取得は `FORCE=1 make fetch-mirakc-armv7`）。
- 通信できない環境では、自分でバイナリをビルドできます（任意・上級者向け）:

```sh
# 前提: rustup/cargo + armv7-unknown-linux-gnueabihf target、
#       gcc-arm-linux-gnueabihf / g++-arm-linux-gnueabihf、cmake、ninja、git
make build-mirakc-armv7       # = bash scripts/build_mirakc_armv7.sh
```

スクリプトは [yuchi0531/mirakc-BS4K](https://github.com/yuchi0531/mirakc-BS4K)（SIGTERM 対応コミット固定）、[yuchi0531/mirakc-arib-tlv](https://github.com/yuchi0531/mirakc-arib-tlv)（v0.1.0）、[mirakc/mirakc-arib](https://github.com/mirakc/mirakc-arib)（v0.24.37 相当）を `tmp/mirakc-cross-build/` に clone してクロスビルドし、`tmp/mirakc-armv7/` を更新します。

---

### Step 6: Alpine Linux + glibc ランタイムをセットアップする

デバイスにインターネット接続が必要です。コマンドはリポジトリのルートで実行します。

```sh
make setup-runtime ADB_TARGET=<デバイスのIPアドレス>:5555
```

Alpine ARM32 minirootfs のダウンロードと、mirakc が要求する **glibc (armhf) ランタイム**（`/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf/`）の配備を自動で行います。
完了まで 3〜5 分かかります。**Node.js は不要になりました**（mirakc は静的リンクに近い Rust バイナリで、Alpine の musl ではなく同梱の glibc ランタイムを `LD_LIBRARY_PATH` 経由で使います）。

展開後は `mirakc-root/bin/busybox` が armhf（ELF32 ARM）であること、`mirakc-root/bin/sh -> busybox`（相対リンク）であることを検証し、chroot 内で `/bin/sh` が動作することを確認します。壊れていれば Alpine minirootfs から自動修復するため、**手動での busybox 差し替えやシンボリックリンク修正は不要**です（[トラブルシューティング](#alpine-の-binsh-や-binbusybox-が壊れたアーキテクチャが違うと言われた)参照）。

完了確認（rootfs が展開されていること）:

```sh
adb -s <デバイスのIPアドレス>:5555 shell \
  "ls -l /data/local/tmp/mirakc-root/bin/sh /data/local/tmp/mirakc-root/bin/busybox /data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3"
# → すべてのパスが表示されること（bin/sh は -> busybox の相対リンク）
```

---

### Step 7: mirakc をデプロイする

PC 側の `tmp/mirakc-armv7/` にある mirakc バイナリ（`make fetch-mirakc-armv7` で取得。`make deploy-mirakc` 実行時には自動取得）と設定ファイルをデバイスへ転送します。

```sh
make deploy-mirakc ADB_TARGET=<デバイスのIPアドレス>:5555
```

以下がデバイスにコピーされます:

- `tmp/mirakc-armv7/mirakc` / `mirakc-arib` / `mirakc-arib-tlv` → `/data/local/tmp/mirakc/bin/`
- `config/config.yml` → `/data/local/tmp/mirakc/config.yml`
- `config/strings.yml` → `/data/local/tmp/mirakc/strings.yml`
- `config/services.json` → `/data/local/tmp/mirakc/epg/services.json`（起動時スキャンの省略に使用）

mirakc の設定は `config/config.yml` です（`server.addrs` は `0.0.0.0:40772`、EPG キャッシュは `/data/local/tmp/mirakc/epg`）。`config/strings.yml` は `config.yml` の `resource.strings-yaml` から参照されます。

> 設定やスクリプトを更新した場合は `make push-all` だけ再実行します（チューナーバイナリ + mirakc バイナリ + スクリプト + 設定を一括更新）。

> **注意（initramfs 再ビルドが必要なケース）**
> `scripts/` 内のファイル（`smb400-tuner.sh`, `start_mirakc.sh`, `crash_guard.sh`, `stop_android_tv.sh`）を変更した場合、**起動のたびに initramfs 内の版が `/data/local/tmp/` へ上書きコピーされる**ため、`make push-scripts` の変更は再起動で元に戻ってしまいます。
> 恒久的に反映するには `boot/initramfs_overlay/` へ同期して `bash boot/build_initramfs.sh <cpio>` で initramfs を再ビルドし、USB メモリを更新してください（[BOOT.md](BOOT.md) 参照）。

---

### Step 8: ACAS マスターキーを設定する

BS4K デスクランブルには ACAS マスターキー（64 文字 hex）が必要です。

```sh
# デバイスのシェルで実行（64HEX_KEY を実際のキーに置き換える）
adb -s <デバイスのIPアドレス>:5555 shell

echo '64HEX_KEY' > /data/local/tmp/.acas_key
chmod 600 /data/local/tmp/.acas_key

# 確認（65 = 64 文字 + 改行）
wc -c /data/local/tmp/.acas_key
```

---

## Part 3: 起動・確認

### Step 9: mirakc を起動する

```sh
make start ADB_TARGET=<デバイスのIPアドレス>:5555
```

正常起動時（`/api/version` の応答）:

```
{"current":"4.0.0-dev.0","latest":"4.0.0-dev.0"}
```

> `make start` は `/data/local/tmp/start_mirakc.sh` を `setsid` で起動し、`/api/version` を ~60 秒ポーリングします。
> mirakc は `server.addrs` の `0.0.0.0:40772` で待ち受けます。

---

### Step 10: ストリームを確認する

**BS4K:**

```sh
make test ADB_TARGET=<デバイスのIPアドレス>:5555
```

出力例（正常）:

```
Streaming BS4K 45168 for 5s...
0000000 7f 02 00 60 60 00 00 00 ...
```

- `7f 02 ...` または `7f 03 ...` → **正常**（IPv4 / IPv6 TLV コンテンツ）
- `7f ff 00 00 ...` → 未復号（b61dec の ACAS 認証失敗）→ Step 8 を確認
- 出力なし → チューナーが応答していない → `make log` でログを確認

**CS (2K):**

```sh
make test-cs ADB_TARGET=<デバイスのIPアドレス>:5555
```

- 先頭が `47`（TS 同期バイト）なら受信成功。復号可否は ACAS 契約・EMM 状態に依存します。

---

### Step 11: 自動起動を有効にする（initramfs 再ビルド）

USB メモリを挿入して電源 ON するだけで `mirakc_proxy` サービスが mirakc を自動起動するようにするには、initramfs を再ビルドして USB メモリの `initramfs_patched.uimg` を更新します。

```sh
bash boot/build_initramfs.sh /path/to/_kernel.img.extracted/988000
```

- `boot/initramfs_overlay/start_mirakc.sh` が `/data/local/tmp/start_mirakc.sh` として配備され、起動時に実行されます。
- **rootfs 名が `mirakurun-root` → `mirakc-root` に変わったため、既存環境は要再セットアップ**です（`make setup-runtime` → `make deploy-mirakc` を再実行してください）。
  - 旧環境の掃除: `adb shell rm -rf /data/local/tmp/mirakurun-root /data/local/tmp/mirakurun`（ディスク節約。旧ファイルはもう使われません）
  - 自動起動も `mirakurun_proxy` → `mirakc_proxy` に切り替えるため、initramfs の再ビルドが必要です
  - 注: `/data/local/tmp` を**丸ごと** `rm` してはいけません（チューナーバイナリや ACAS キーが消えます）
- 詳細は [BOOT.md](BOOT.md) を参照。

---

## API

mirakc は Mirakurun 互換の REST API を提供します（`/api/version`・`/api/channels`・`/api/services` 等）。

```sh
# バージョン確認
curl -s http://<デバイスのIPアドレス>:40772/api/version
```

EPGStation をセットアップする際の `mirakurunPath` は `http://<デバイスのIPアドレス>:40772/` を指定してください。

### BS8Kの受信について

BS8K（左旋・ISDB-S3）にも対応しています。`config/config.yml` には次のエントリが含まれています。

| name | type | channel | serviceId |
|------|------|---------|-----------|
| BS8K NHK | BS4K | 45280 | 102 |

- BS8K は右旋ではなく**左旋**で送出されるため、`smb400-tuner.sh` が channel `45280`（実 tlvStreamId）を IF `2472MHz` にマップして受信します。
  `type` は BS4K と同じ ISDB-S3 経路のため `BS4K` のままです。
- 復号経路は BS4K と共通で、`b61dec` による ACAS デスクランブルで復号されます。
- ストリーム確認:

```sh
curl -s --max-time 8 "http://<デバイスのIPアドレス>:40772/api/channels/BS4K/45280/stream" \
  | od -v -t x1 | head -4
# 先頭が 7f 02 / 7f 03 なら正常（復号済み TLV）。サービス名は「ＮＨＫ　ＢＳ８Ｋ」(serviceId 102)
```

- 視聴も BS4K と同じく mmt/tlv 対応 FFmpeg で行えます:

```sh
ffplay http://<デバイスのIPアドレス>:40772/api/channels/BS4K/45280/stream
```

> BS8K は 7680×4320 / HEVC 10bit のため、再生・録画には相応の処理能力を持つ視聴環境が必要です。

### 地上波（ISDB-T / GR）の受信について

地上波デジタル（ISDB-T）にも対応しています。
地デジも BS と同じ **MULTI2**（B-CAS 方式, CA_system_id 0x0005）でスクランブルされているため、`smb400-tuner.sh` 内の **`b21dec`** がオンデバイス ACAS チップ経由でそのまま解除します（B-CAS カード不要）。
チューナーは `tuner-stream-ng`（DMX 直接キャプチャ）を使い、`tuner-stream-ng | b21dec` を chroot 配下で実行して平文 MPEG-TS を出力します（mirakc の `service-filter` / `program-filter`（mirakc-arib）で処理）。

`config/config.yml` の GR 一覧は **Mirakurun サーバ（192.168.100.111）からインポートした関東（東京）の値**です。
物理チャンネル割り当ては地域で異なるため、お住まいの地域に合わせて `channel`（13〜62）を変更してください。
`services` は .111 の実測 SDT 由来のサービスIDが明示されており、起動時スキャンなしで登録されます。

| name | type | channel(物理) | services |
|------|------|---------------|----------|
| Ｊ：ＣＯＭテレビ | GR | 13 | 23656, 23657 |
| ＴＯＫＹＯ　ＭＸ | GR | 16 | 23608-23610, 23992, 23993 |
| Ｊ：ＣＯＭチャンネル | GR | 18 | 27768-27770 |
| フジテレビ | GR | 21 | 1056-1058, 1440 |
| ＴＢＳ | GR | 22 | 1048, 1049, 1183, 1432 |
| テレビ東京 | GR | 23 | 1072-1074, 1456 |
| テレビ朝日 | GR | 24 | 1064-1066, 1448 |
| 日テレ | GR | 25 | 1040, 1041, 1424 |
| ＮＨＫＥテレ・東京 | GR | 26 | 1032-1034, 1416 |
| ＮＨＫ総合・東京 | GR | 27 | 1024, 1025, 1408 |
| チバテレ | GR | 30 | 27704-27706, 28088 |
| テレ玉 | GR | 32 | 29752-29754, 30136 |

```sh
# 物理チャンネル 27（関東 NHK総合）を受信して先頭を確認
curl -s --max-time 8 "http://<デバイスのIPアドレス>:40772/api/channels/GR/27/stream?decode=0" \
  -o gr27.ts
ffprobe gr27.ts        # mpeg2video が見えれば復号成功
```


### BS（ISDB-S）の受信について

NHK BS などの**BS（ISDB-S, MPEG-TS）**にも対応しています。
2K BS は ARIB STD-B25 系の **MULTI2**（B-CAS 方式, CA_system_id 0x0005）でスクランブルされており、`smb400-tuner.sh` 内の **`b21dec`** がオンデバイスの **ACAS チップ**経由で解除します（B-CAS カード不要）。
BS4K の `b61dec`（ACAS-RMP / AES）とは別系統で、ACAS チップの**従来 CAS 機能**（APDU を ACAS モード P2=0x02 で送出）を使い、ECM から MULTI2 スクランブル鍵を取得します。

`config/config.yml` には例として NHK BS（BS15 / IF 1318000kHz / tsId 16625）が含まれます。

| name | type | channel | serviceId |
|------|------|---------|-----------|
| NHK BS       | BS | BS15_0 | 101 |
| NHK BS (102) | BS | BS15_0 | 102 |
| NHK BS (103) | BS | BS15_0 | 103 |

- channel は `BSxx_y`（xx=トランスポンダ番号, y=ストリーム）形式で、`smb400-tuner.sh` が IF = `1049480 + (xx-1)/2 × 38360` kHz を算出して `tuner-stream-bs-ng`（mode=1）でロックします（旧 `tuner-stream-bs` バイナリは現在未使用・フォールバック保持）。
- `b21dec` は **ACAS マスターキー不要**です（放送局のワークキー Kw は、過去の実放送受信時に EMM 経由でチップへ書き込まれた契約情報を利用するため）。
  逆に、当該局の契約・受信履歴が無いチップでは ECM 応答が「視聴不可」となり復号できません。
- 出力は平文 MPEG-TS なので mirakc の `service-filter` / `program-filter`（mirakc-arib）で処理されます。
- ストリーム確認・視聴:

```sh
curl -s --max-time 8 "http://<デバイスのIPアドレス>:40772/api/services/<serviceId>/stream" -o nhkbs.ts
ffprobe nhkbs.ts          # mpeg2video 1440x1080 + aac が見えれば復号成功
ffplay  "http://<デバイスのIPアドレス>:40772/api/services/<serviceId>/stream"
```

110 度 CS（ISDB-S 2K 相当）も BS と同じ経路（`tuner-stream-bs-ng` mode=1 → `b21dec`）で受信します。`config/config.yml` には .111 からインポートした CS チャンネル（ND02〜ND24、実測 services 付き）が含まれます（`make test-cs` が CS/ND02 を叩きます）。

| name | type | channel |
|------|------|---------|
| CS ND02 | CS | ND02 |

> 2K BS は受信できるトランスポンダ・サービスが地域/契約により異なります。
> `config/config.yml` の `tuners[].types` で `BS` タイプが有効になっている必要があります（本リポジトリでは有効化済み）。

### ffplay でリアルタイム視聴

再生にはmmt/tlvに対応した [FFmpeg](https://github.com/superfashi/FFmpeg) が必要です。

```sh
ffplay http://<デバイスのIPアドレス>:40772/api/channels/BS4K/45168/stream
```

### EPGStation で録画・視聴

BS4K に対応した EPGStation フォークを使うと、Web UI から録画予約・視聴が行えます。

- リポジトリ: [tsuyopon123/EPGStation](https://github.com/tsuyopon123/EPGStation)

EPGStation をセットアップする際に `mirakurunPath` を `http://<デバイスのIPアドレス>:40772/` に設定してください。

---

## Web UI (mirakc-webui)

mirakc 自体は Web UI を持ちません。任意で静的 SPA の
[yuchi0531/mirakc-webui](https://github.com/yuchi0531/mirakc-webui) を導入できます。
本リポジトリの標準デプロイには含まれません（使う場合のみ以下を実施）。

### セットアップ手順

1. Web UI をビルドする（要 Node.js 18+ / npm）:
   ```sh
   git clone https://github.com/yuchi0531/mirakc-webui
   cd mirakc-webui
   npm ci
   npm run build
   ```
   成果物は `dist/`（index.html ほか）。

2. デバイスへ配置:
   ```sh
   adb shell mkdir -p /data/local/tmp/mirakc/www
   adb push dist/. /data/local/tmp/mirakc/www/
   ```

3. `config/config.yml` の `server:` に `mounts` を追加（既存の `addrs` はそのまま）:
   ```yaml
   server:
     mounts:
       /www:
         path: /data/local/tmp/mirakc/www
         index: index.html
   ```
   ⚠️ mirakc は `mounts.<path>` が存在しないと起動に失敗します。手順 2 の配置を先に行ってください。

4. 設定を反映して再起動:
   ```sh
   make push-config
   make restart
   ```

5. ブラウザで開く: `http://<デバイスのIPアドレス>:40772/www`
   - **末尾にスラッシュを付けない**（`/www/` は 404。mounts 仕様）
   - same-origin 配信のみ対応（API `/api/...` と SSE `/events` がオリジンルート絶対のため、リバースプロキシのサブパス配下では動きません）

機能: ステータス（バージョン・サービスグリッド・チューナー）、イベント（SSE、最大200件）、接続ガイド。

---

## サービス登録と EPG について

チャンネル・サービスは Mirakurun サーバ（`192.168.100.111`）からインポート済みです。`config/config.yml` の `channels` と、`make deploy-mirakc` で `/data/local/tmp/mirakc/epg/services.json` に配置されるサービス定義（`config/services.json`）により、**初回からサービスが登録された状態**で起動します。

```sh
# 登録されたサービスを確認
curl -s http://<デバイスのIPアドレス>:40772/api/services | python3 -m json.tool
```

- 起動スクリプト（`start_mirakc.sh`）は `MIRAKC_EPG_FRESH_PERIOD=30d` を設定します。EPG キャッシュ（`services.json` 等）の mtime が 30 日以内なら、**起動時のサービススキャンをスキップ**します（`scan-services` の初回実行が走らない）。
- 定期ジョブは通常どおり動きます（`scan-services`: 08:01 / 20:01、`sync-clocks`: 08:11 / 20:11、`update-schedules`: 08:21 / 20:21）。
- 新しいチャンネルを追加した場合など、明示的にスキャンさせたいときは古い `services.json` を削除するか、mtime を更新してください（次回起動時にスキャンします）。
- トランスポンダの初回チューニング時、ウォームアップで稀にサービスを取り逃すことがあります（ストリーム先頭の `7f ff`）。
  その場合は `make start` で再起動すれば取得されます。

> **再起動について**: 再起動はホストから `make restart` を使ってください。
> `make stop` は mirakc に SIGTERM を送り、mirakc は猶予 2 秒でチューナー子プロセス（`smb400-tuner.sh` / `tuner-stream-*` / `b21dec` / `b61dec`）を掃除してから終了します。

---

## mirakc の制約・注意

- **BS4K / BS8K は passthrough（ストリーム中継）のみ**です。program-level stream（`/api/programs/<id>/stream` 等）・録画・タイムシフトには対応しません。BS4K の視聴・録画は EPGStation 等のクライアント側で行ってください。
- GR / BS / CS(2K) は `mirakc-arib` のフィルタ（`filter-service` / `filter-program`）で処理します。BS4K / BS8K 用のジョブ（`scan-services-tlv` / `collect-mh-eits`）は `mirakc-arib-tlv` が担当します。
- チューナーは実質 1 台です。視聴と EPG ジョブ（`update-schedules` 等）はチューナーを奪い合うため、時間帯によってはストリーム開始が待たされたり、EPG 取得が失敗することがあります。
- EPG ジョブは `config.yml` の既定スケジュール（08:01 / 20:01 等）で動きます。録画予約の更新タイミングに注意してください。
- ACAS 契約が必要なチャンネルは、契約・EMM 状態がチップに無いと復号できません（`make test` で `7f ff` になる場合は Step 8 と契約を確認）。
- mirakc は停止時に SIGTERM → 猶予 2 秒 → SIGKILL の順でチューナー子プロセスを終了させます（`smb400-tuner.sh` の trap がチューナーを解放します）。`make stop` はこの猶予を待ってから後続処理を行います。

---

## コマンド

```sh
make build-bins          # チューナー/デコーダバイナリをビルド
make fetch-mirakc-armv7  # mirakc 3バイナリを GitHub Release から取得（通常はこちら）
make build-mirakc-armv7  # mirakc 3バイナリを ARMv7 向けに再ビルド（任意）
make deploy-mirakc       # mirakc 本体・設定をデプロイ
make setup-runtime       # Alpine rootfs + glibc ランタイムを構築
make push-all            # チューナーバイナリ・mirakc バイナリ・スクリプト・設定を更新
make start               # mirakc 起動
make stop                # 停止（チューナー・デスクランブラーも含む）
make restart             # 再起動
make log                 # ログ確認（最新 50 行）
make test                # BS4K 疎通テスト
make test-cs             # CS ND02 疎通テスト

# デバイスの IP アドレスを指定する場合
make start ADB_TARGET=192.168.1.100:5555
```

---

## 注意事項

### OEM サービスと ACAS 競合

OEM チューナーサービス（`pix_airtuner`）が起動中は ACAS を占有するため、
`b61dec` が失敗します（`GetCkc failed: -4`）。

`start_mirakc.sh` は起動時に自動で停止します。
再起動後に OEM サービスが復帰した場合は手動で停止:

```sh
adb -s <デバイスのIPアドレス>:5555 shell "stop pix_airtuner; stop airtuner; stop airtuner_4k"
```

### メモリ管理（crash_guard）

`crash_guard.sh` が自動起動し以下を監視します:

- `crash_dump32` フォーク爆弾（Android 8 のクラッシュダンプ暴走）
- MemAvailable < 600 MB → `stop_android_tv.sh` で Android TV アプリを回収（2 分クールダウン）
- MemAvailable < 350 MB → mirakc を強制終了（最終手段）

### USB Boot ファイルのビルド

`bootargs.bin` / `root_rsa_pub_crc.bin` / `initramfs_patched.uimg` のビルド手順・
オーバーレイのカスタマイズ方法は [BOOT.md](BOOT.md) を参照してください。

---

## トラブルシューティング

```sh
# ログ確認（mirakc.log）
make log ADB_TARGET=<デバイスのIPアドレス>:5555

# crash_guard ログ
adb -s <デバイスのIPアドレス>:5555 shell "tail -20 /data/local/tmp/crash_guard.log"

# メモリ確認
adb -s <デバイスのIPアドレス>:5555 shell "grep MemAvailable /proc/meminfo"
```

### mirakc バイナリの取得に失敗する（fetch）

`make fetch-mirakc-armv7` が失敗する場合:

- **ネットワーク / GitHub に到達できない**: `curl -fL https://github.com/yuchi0531/mirakc-BS4K/releases/download/smb400-armv7-v1/SHA256SUMS` で疎通確認してください。プロキシ環境では `https_proxy` 等を設定します。
- **SHA256 不一致**: ダウンロードが壊れている可能性があります。`FORCE=1 make fetch-mirakc-armv7` で再取得してください。
- どうしても取得できない場合は、ソースからビルドできます（クロスビルド環境が必要）:

```sh
make build-mirakc-armv7
```

### mirakc が起動しない

`start_mirakc.sh` は事前チェック（preflight）で必要なファイルが揃っていない場合は**何も起動せずに終了**します。ログに以下が出ていないか確認してください:

```sh
make log ADB_TARGET=<デバイスのIPアドレス>:5555
# [mirakc] not starting — missing file(s): ...
```

不足しているファイルに応じて `make deploy-mirakc`（mirakc バイナリ・設定）や `make push-scripts`（スクリプト）を再実行してください。

### glibc ローダーが見つからない

mirakc / mirakc-arib / mirakc-arib-tlv は glibc (armhf) に動的リンクされています。以下のようなエラーが出る場合:

```
cannot execute: required file not found
/.../mirakc: error while loading shared libraries: ld-linux-armhf.so.3: cannot open shared object file
```

glibc ランタイムが未配備です。`make setup-runtime` を実行してください。配備先は `/data/local/tmp/glibc-armhf/usr/lib/arm-linux-gnueabihf/` で、`start_mirakc.sh` が chroot 内で `LD_LIBRARY_PATH` を設定します。

### Alpine の /bin/sh や /bin/busybox が壊れた（アーキテクチャが違うと言われた）

> **先に確認**: `ls /data/local/tmp/mirakc-root/bin/sh` で `No such file or directory` が出ても、**機能上の異常ではありません**。Alpine の `/bin/sh` は絶対リンク `-> /bin/busybox` で、chroot 外（Android 名前空間）から見ると `/bin/busybox` が存在しないためリンク切れに見えるだけです。chroot 内では正しく解決します（`ls -l` でリンク実体を確認できます）。最新の `setup_proot.sh` は Step 2.5 で自動的に相対リンク `-> busybox` に正規化するため、このエラー自体が出なくなります。

`chroot: /bin/sh: No such file or directory` や、`ls` では存在するのに chroot 内で何も実行できない場合は、`mirakc-root` の展開が不完全か、`bin/busybox` が armhf 以外（aarch64 など）になっています。

```sh
adb -s <デバイスのIPアドレス>:5555 shell \
  "ls -la /data/local/tmp/mirakc-root/bin/sh /data/local/tmp/mirakc-root/bin/busybox; \
   od -An -tx1 -N20 /data/local/tmp/mirakc-root/bin/busybox"
# → bin/sh -> busybox（相対）または -> /bin/busybox で、busybox の先頭が
#    7f 45 4c 46 01 01 (ELF32 LE) / 機械種別 2800 (ARM) なら正常
```

`make setup-runtime` は毎回この検証を行い、壊れていれば minirootfs から `bin/busybox` を再配置し、`bin/sh -> busybox`（相対リンク）を張り直します。既存インストールでも再実行すれば修復されます。**手動で busybox をダウンロードして差し替える必要はありません**（armhf 版 Alpine minirootfs の busybox がそのまま正解です）。

- `bin/sh` は `-> busybox`（相対）または `-> /bin/busybox`（絶対）のシンボリックリンクです。リンクに見えても壊れてはいません。
- `ls /data/local/tmp/mirakc-root/bin/sh`（`-l` なし）が `No such file or directory` になっても、chroot 内で動いていれば問題ありません。確認は `ls -l` を使ってください。
- `make setup-runtime` の Step 2.5（busybox / sh 検証・正規化）は、rootfs が既に展開済みでダウンロードをスキップした場合でも実行されます。
- chroot 内で `/bin/sh` が起動できないほど rootfs が壊れている場合は、`make setup-runtime` がエラーで停止します。その場合は作り直してください:
  ```sh
  adb -s <デバイスのIPアドレス>:5555 shell "rm -rf /data/local/tmp/mirakc-root"
  make setup-runtime ADB_TARGET=<デバイスのIPアドレス>:5555
  ```

### BS4K が無映像・無出力

- `make test` の先頭が `7f ff ...` → 未復号。ACAS マスターキー（Step 8）と契約を確認。
- OEM チューナーサービスが ACAS を占有している → 上記「OEM サービスと ACAS 競合」を参照。
- 出力なし → チューナーが応答していない。`make log` を確認し、`make restart` を試す。
- BS4K/BS8K は passthrough のみのため、クライアント側も mmt/tlv 対応 FFmpeg や BS4K 対応 EPGStation が必要です。

### TVTest 等の外部クライアントで視聴できない（信号が流れてこない）

`make test` / `make test-cs` でストリームの先頭が復号済み（`7f ff` 以外）なのに、TVTest 側で映像が出ない場合はクライアント側の BonDriver 設定を確認してください。

- **mirakc 用の BonDriver を使う**: [stuayu/BonDriver_mirakc](https://github.com/stuayu/BonDriver_mirakc) を使い、mirakc の API（`http://<デバイスのIPアドレス>:40772`）へ接続します。Mirakurun 用 BonDriver は mirakc では動作しないことがあります。
- **BS4K / BS8K は専用 BonDriver が必要**: mirakc は BS4K / BS8K を TLV のまま passthrough するため、dantto4k 等の ISDB-S3 対応 BonDriver を経由してください（例: `BonDriver_mirakc` → `BonDriver_dantto4k` の構成でリアルタイム視聴可）。
- **PC 側の破損も疑う**: TVTest / BonDriver / その依存ライブラリがクラッシュや破損を起こすと、実機は正常でも「API は応答するが映像が出ない」状態になります。BonDriver を差し替え・再配置するか、クライアント PC を再起動して切り分けてください。
- ホスト側から見た切り分け:
  ```sh
  # チューナー〜mirakc まで問題ないか（期待値: 先頭が 7f ff 以外 = 復号済み）
  make test ADB_TARGET=<デバイスのIPアドレス>:5555
  # mirakc → クライアントへ配信中のストリームを直接確認（同じ URL を VLC 等で開いても可）
  curl -s --max-time 8 http://<デバイスのIPアドレス>:40772/api/channels/GR/27/stream | od -v -t x1 | head -4
  ```

### その他（USB ブート・ADB）

- ログ確認: `make log ADB_TARGET=<デバイスのIPアドレス>:5555`
- crash_guard ログ: `adb -s <デバイスのIPアドレス>:5555 shell "tail -20 /data/local/tmp/crash_guard.log"`
- メモリ確認: `adb -s <デバイスのIPアドレス>:5555 shell "grep MemAvailable /proc/meminfo"`
- ADB で `uid=2000(shell)` と表示される場合は eMMC 通常ブートです（USB ブートを再確認）。詳細は [BOOT.md](BOOT.md) を参照。
