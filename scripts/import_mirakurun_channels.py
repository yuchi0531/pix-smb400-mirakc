#!/usr/bin/env python3
"""Mirakurun (192.168.100.111) の /api/channels から mirakc の channels 設定と
services.json (EPG キャッシュ) を生成する。

- config.yml は `channels:` セクションのみをテキストブロック置換で差し替える。
  (PyYAML で全体を dump するとコメントが消えるため)
- services.json は mirakc のキャッシュ形式 `[[service_id, EpgService], ...]`。
  channel オブジェクトは config.yml のチャンネル定義と完全一致させる
  (mirakc は不一致のサービスを起動時に破棄する)。

チャンネル値の変換:
  GR   : そのまま (物理チャンネル番号)
  BS   : BSxx_y のまま。scripts/smb400-tuner.sh の TSID 表にあるものだけ採用。
         表に無い (= 本機で受信できない) ものは除外。
  CS   : CSn → NDnn (偶数スロットのみ)
  BS4K : 5桁 StreamID のまま
  BS8K : .111 に無いため base-config の 45280 エントリを引き継ぐ (services.json には入れない)

Usage:
  python3 scripts/import_mirakurun_channels.py \\
      --api          tmp/channels-111/api-channels.json \\
      --base-config  config/config.yml \\
      --out-config   config/config.yml \\
      --out-services config/services.json
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
BS8K_CHANNEL = "45280"
GROUP_ORDER = ["GR", "BS", "CS", "BS4K"]
GROUP_TITLES = {
    "GR": "--- GR (ISDB-T 地上波) ---",
    "BS": "--- BS (ISDB-S, 従来2K衛星) ---",
    "CS": "--- CS (110度CS) ---",
    "BS4K": "--- BS4K / BS8K (ISDB-S3) ---",
}
GROUP_NOTES = {
    "GR": "channel = 物理チャンネル番号 (13-62)。services は .111 の実測 SDT 由来。",
    "BS": "channel = BSxx_y (xx=トランスポンダ番号, y=相対TS)。smb400-tuner.sh の TSID 表にあるもののみ。",
    "CS": "channel = NDxx (xx=偶数トランスポンダ番号)。",
    "BS4K": "channel = 5桁 StreamID。BS8K (45280) は .111 に無いため現行 config から引き継ぎ。",
}


def parse_bs_tsid_channels(tuner_script):
    """smb400-tuner.sh の BS TSID 表に載っている BSxx_y の集合を返す。"""
    pattern = re.compile(r"(BS\d{2}_\d)\)\s+TSID=\d+")
    return set(pattern.findall(tuner_script.read_text(encoding="utf-8")))


def cs_to_nd(channel):
    """'CS2' -> 'ND02'。奇数スロットや形式違いは None。"""
    m = re.fullmatch(r"CS(\d+)", str(channel))
    if not m:
        return None
    n = int(m.group(1))
    if n % 2 != 0:
        return None
    return f"ND{n:02d}"


def channel_sort_key(channel):
    if channel["type"] == "GR":
        return int(channel["channel"])
    if channel["type"] == "BS":
        m = re.fullmatch(r"BS(\d+)_(\d+)", channel["channel"])
        if m:
            return (int(m.group(1)), int(m.group(2)))
        return (999, 999)
    if channel["type"] == "CS":
        return int(channel["channel"][2:])
    return int(channel["channel"])


def load_channel_names(channels_yml):
    """.111 原本 channels.yml から (type, channel) -> 代表名 (先頭エントリ) を作る。"""
    if channels_yml is None:
        return {}
    entries = yaml.safe_load(channels_yml.read_text(encoding="utf-8")) or []
    names = {}
    for entry in entries:
        key = (entry["type"], str(entry["channel"]))
        names.setdefault(key, entry["name"])
    return names


def build_channels(api_entries, bs_allowed, channel_names):
    """API エントリを mirakc チャンネル定義へ変換し、除外一覧も返す。"""
    channels = []
    excluded = []
    for entry in api_entries:
        ctype = entry["type"]
        src = str(entry["channel"])

        if ctype == "GR":
            channel = src
        elif ctype == "BS":
            if src not in bs_allowed:
                excluded.append((ctype, src, "smb400-tuner.sh の BS TSID 表に無い"))
                continue
            channel = src
        elif ctype == "CS":
            channel = cs_to_nd(src)
            if channel is None:
                excluded.append((ctype, src, "偶数スロットの CSn ではない"))
                continue
        elif ctype == "BS4K":
            channel = src
        else:
            excluded.append((ctype, src, "未対応の type"))
            continue

        # serviceId 重複除去 (同一チャンネル内) + ソート
        services = {}
        for svc in entry.get("services", []):
            sid = int(svc["serviceId"])
            services[sid] = {
                "sid": sid,
                "nid": int(svc["networkId"]),
                "name": svc["name"],
            }
        service_list = [services[sid] for sid in sorted(services)]

        # Mirakurun は serviceId 付きチャンネルの name を "TYPE:channel" に上書き
        # する。日本語の代表名は原本 channels.yml (無ければ先頭サービス名) から取る。
        name = channel_names.get((ctype, src)) or (
            service_list[0]["name"] if service_list else entry["name"]
        )

        channels.append(
            {
                "name": name,
                "type": ctype,
                "channel": channel,
                "services": service_list,
            }
        )
    return channels, excluded


def append_bs8k(channels, base_config):
    """base-config の 45280 エントリを引き継ぐ (存在し、未生成の場合のみ)。"""
    if any(c["channel"] == BS8K_CHANNEL for c in channels):
        return channels
    for c in base_config.get("channels") or []:
        if str(c.get("channel")) == BS8K_CHANNEL:
            channels.append(
                {
                    "name": c["name"],
                    "type": c["type"],
                    "channel": BS8K_CHANNEL,
                    "services": [
                        {"sid": int(sid), "nid": None, "name": ""}
                        for sid in c.get("services") or []
                    ],
                }
            )
            break
    else:
        print(
            f"[!] base-config に BS8K ({BS8K_CHANNEL}) のエントリが無いため引き継ぎません",
            file=sys.stderr,
        )
    return channels


def sort_channels(channels):
    ordered = []
    for group in GROUP_ORDER:
        group_channels = [c for c in channels if c["type"] == group]
        ordered.extend(sorted(group_channels, key=channel_sort_key))
    return ordered


def yaml_str(value):
    # JSON 文字列は YAML の二重引用符スカラーとしてそのまま使える。
    return json.dumps(value, ensure_ascii=False)


def render_channels_block(channels):
    lines = [
        "channels:\n",
        "  # Mirakurun (192.168.100.111) の channels.yml から変換\n",
        "  #   scripts/import_mirakurun_channels.py / 元データ: tmp/channels-111/api-channels.json\n",
        "  # channel 値の解釈は smb400-tuner.sh が行う。復号はすべて同スクリプト内で完了する。\n",
    ]
    for group in GROUP_ORDER:
        group_channels = [c for c in channels if c["type"] == group]
        if not group_channels:
            continue
        lines.append(f"  # {GROUP_TITLES[group]}\n")
        lines.append(f"  # {GROUP_NOTES[group]}\n")
        for c in group_channels:
            if c["channel"] == BS8K_CHANNEL:
                lines.append(
                    "  # BS8K NHK (左旋)。NID 不明のため services.json には未収録 (初回スキャンで取得)。\n"
                )
            lines.append(f"  - name: {yaml_str(c['name'])}\n")
            lines.append(f"    type: {c['type']}\n")
            lines.append(f"    channel: {yaml_str(c['channel'])}\n")
            if c["services"]:
                sids = ", ".join(str(s["sid"]) for s in c["services"])
                lines.append(f"    services: [{sids}]\n")
    lines.append("\n")  # 次セクションとの空行
    return "".join(lines)


def replace_channels_section(text, new_block):
    """`channels:` 行から次のトップレベルキー直前までを new_block で置換する。"""
    lines = text.splitlines(keepends=True)
    start = None
    for i, line in enumerate(lines):
        if line.rstrip("\n") == "channels:":
            start = i
            break
    if start is None:
        raise SystemExit("error: config.yml に channels: セクションが見つかりません")

    end = start + 1
    while end < len(lines) and (
        lines[end][:1] in (" ", "\t") or not lines[end].strip()
    ):
        end += 1
    return "".join(lines[:start]) + new_block + "".join(lines[end:])


def build_services_json(channels):
    """mirakc キャッシュ形式 [[service_id, EpgService], ...] を組み立てる。"""
    entries = []
    for c in channels:
        if c["channel"] == BS8K_CHANNEL:
            continue  # NID 不明のため後でスキャン取得
        # EpgChannel (mirakc-core/src/epg/mod.rs) は snake_case でシリアライズされる
        channel_obj = {
            "name": c["name"],
            "type": c["type"],
            "channel": c["channel"],
            "extra_args": "",
            "services": [s["sid"] for s in c["services"]],
            "excluded_services": [],
        }
        for s in c["services"]:
            if s["nid"] is None:
                continue
            service_id = s["nid"] * 100000 + s["sid"]
            entries.append(
                [
                    service_id,
                    {
                        "id": service_id,
                        "type": 1,
                        "logoId": -1,
                        "remoteControlKeyId": 0,
                        "name": s["name"] or c["name"],
                        "channel": channel_obj,
                    },
                ]
            )
    return entries


def main():
    parser = argparse.ArgumentParser(
        description="Mirakurun の channels から mirakc の channels / services.json を生成"
    )
    parser.add_argument(
        "--api",
        type=Path,
        default=REPO_ROOT / "tmp/channels-111/api-channels.json",
        help="Mirakurun /api/channels の JSON",
    )
    parser.add_argument(
        "--base-config",
        type=Path,
        default=REPO_ROOT / "config/config.yml",
        help="channels 以外を引き継ぐ mirakc 設定",
    )
    parser.add_argument(
        "--out-config",
        type=Path,
        default=REPO_ROOT / "config/config.yml",
        help="出力先 config.yml (channels セクションのみ置換)",
    )
    parser.add_argument(
        "--out-services",
        type=Path,
        default=REPO_ROOT / "config/services.json",
        help="出力先 services.json",
    )
    parser.add_argument(
        "--tuner-script",
        type=Path,
        default=REPO_ROOT / "scripts/smb400-tuner.sh",
        help="BS TSID 表の参照元",
    )
    parser.add_argument(
        "--channels-yml",
        type=Path,
        default=REPO_ROOT / "tmp/channels-111/channels.yml",
        help=".111 原本の channels.yml (日本語の代表名の取得元)",
    )
    args = parser.parse_args()

    api_entries = json.loads(args.api.read_text(encoding="utf-8"))
    bs_allowed = parse_bs_tsid_channels(args.tuner_script)
    if not bs_allowed:
        raise SystemExit(f"error: {args.tuner_script} から BS TSID 表を読めません")

    base_text = args.base_config.read_text(encoding="utf-8")
    base_config = yaml.safe_load(base_text)
    channel_names = load_channel_names(
        args.channels_yml if args.channels_yml.exists() else None
    )

    channels, excluded = build_channels(api_entries, bs_allowed, channel_names)
    channels = append_bs8k(channels, base_config)
    channels = sort_channels(channels)

    args.out_config.parent.mkdir(parents=True, exist_ok=True)
    args.out_config.write_text(
        replace_channels_section(base_text, render_channels_block(channels)),
        encoding="utf-8",
    )

    services = build_services_json(channels)
    args.out_services.parent.mkdir(parents=True, exist_ok=True)
    args.out_services.write_text(
        json.dumps(services, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    counts = {g: sum(1 for c in channels if c["type"] == g) for g in GROUP_ORDER}
    print(f"[+] channels: {len(channels)} ({', '.join(f'{g}={n}' for g, n in counts.items())})")
    print(f"[+] services.json: {len(services)} entries")
    print(f"[+] excluded: {len(excluded)}")
    for ctype, channel, reason in excluded:
        print(f"    - {ctype} {channel}: {reason}")


if __name__ == "__main__":
    main()
