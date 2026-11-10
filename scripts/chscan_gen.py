#!/usr/bin/env python3
"""chscan_gen.py — turn chscan manifest lines into mirakc config files.

Input (stdin file): TSV lines "TYPE<TAB>CHANNEL<TAB>JSON"
Output:
  config/config.yml     (channels: block replaced, rest preserved)
  config/channels.yml   (generated channels block, sample/reference)
  config/services.json  (mirakc EPG service cache)

With --sample-satellite, BS/CS/BS4K channels (and their service cache
entries) are carried over from the existing config/config.yml and
config/services.json, while GR is taken from the scan manifest.
"""

import json
import os
import sys

try:
    import yaml
except ImportError:
    yaml = None

TYPE_ORDER = {"GR": 0, "BS": 1, "CS": 2, "BS4K": 3, "CATV": 4}
SATELLITE_TYPES = ("BS", "CS", "BS4K")


def channel_sort_key(entry):
    t = entry["type"]
    ch = entry["channel"]
    order = TYPE_ORDER.get(t, 9)
    if t == "GR" or t == "CS" or t == "BS4K":
        try:
            return (order, int(ch), "")
        except ValueError:
            return (order, 0, ch)
    if t == "BS":
        try:
            body = ch[2:]
            tp, y = body.split("_")
            return (order, int(tp), int(y))
        except Exception:
            return (order, 0, ch)
    if t == "CATV":
        try:
            return (order, int(ch[1:]), ch[0])
        except Exception:
            return (order, 0, ch)
    return (order, 0, ch)


def load_manifest(path):
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t", 2)
            if len(parts) != 3:
                continue
            typ, ch, raw = parts
            try:
                services = json.loads(raw)
            except Exception:
                continue
            if not isinstance(services, list) or not services:
                continue
            sids = []
            for s in services:
                sid = s.get("sid")
                if isinstance(sid, int) and sid not in sids:
                    sids.append(sid)
            if not sids:
                continue
            name = services[0].get("name") or ch
            entries.append({
                "type": typ,
                "channel": ch,
                "name": name,
                "services": services,
                "sids": sids,
            })
    entries.sort(key=channel_sort_key)
    return entries


# ---------------------------------------------------------------- sample satellite

def _channels_block_range(lines):
    start = None
    for i, line in enumerate(lines):
        if line.rstrip() == "channels:":
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if not line or line.startswith((" ", "\t", "#")):
            continue
        if line.rstrip().endswith(":"):
            end = i
            break
    return start, end


def extract_sample_channels(path, types=SATELLITE_TYPES):
    """Return (raw YAML item lines, present types) for the requested sample types."""
    if not os.path.isfile(path):
        return [], set()
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    start, end = _channels_block_range(lines)
    if start is None:
        return [], set()

    items = []
    cur = None
    for line in lines[start + 1:end]:
        if line.startswith("  - "):
            if cur:
                items.append(cur)
            cur = [line]
        elif cur is not None:
            cur.append(line)
    if cur:
        items.append(cur)

    kept = []
    present = set()
    for item in items:
        typ = None
        if yaml is not None:
            try:
                doc = yaml.safe_load("\n".join(item))
                if isinstance(doc, list) and doc and isinstance(doc[0], dict):
                    typ = doc[0].get("type")
            except Exception:
                typ = None
        if typ is None:
            for line in item:
                stripped = line.strip()
                if stripped.startswith("type:"):
                    typ = stripped.split(":", 1)[1].strip().strip('"\'')
                    break
        if typ in types:
            kept.extend(item)
            present.add(typ)
    return kept, present


def load_sample_services(path, types=SATELLITE_TYPES):
    """Return [id, service] pairs for BS/CS/BS4K from the current services.json."""
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as f:
            pairs = json.load(f)
    except Exception:
        return []
    kept = []
    for pair in pairs:
        try:
            svc = pair[1]
            ch_type = svc.get("channel", {}).get("type")
        except Exception:
            continue
        if ch_type in types:
            kept.append(pair)
    return kept


# ---------------------------------------------------------------- output

def yaml_block(entries, sample_lines=None):
    lines = ["channels:", "  # generated by make chscan"]
    for e in entries:
        lines.append("  - name: %s" % json.dumps(e["name"], ensure_ascii=False))
        lines.append("    type: %s" % e["type"])
        lines.append("    channel: %s" % json.dumps(e["channel"], ensure_ascii=False))
        lines.append("    services: [%s]" % ", ".join(str(x) for x in e["sids"]))
    if sample_lines:
        lines.extend(sample_lines)
    return lines


def patch_config(entries, sample_lines, path):
    block = yaml_block(entries, sample_lines) + [""]
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    start, end = _channels_block_range(lines)
    if start is None:
        for i, line in enumerate(lines):
            if line.rstrip() == "tuners:":
                lines[i:i] = block
                break
        else:
            lines.extend(block)
    else:
        lines[start:end] = block

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_channels_yml(entries, sample_lines, path):
    header = [
        "# generated by make chscan",
        "# このファイルは参照用です。mirakc は config/config.yml の channels を読みます。",
        "",
    ]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(header + yaml_block(entries, sample_lines)) + "\n")


def write_services_json(entries, sample_pairs, path):
    by_id = {}
    for pair in sample_pairs:
        try:
            by_id[int(pair[0])] = pair[1]
        except Exception:
            continue

    for e in entries:
        ch_name = e["name"]
        ch_type = e["type"]
        ch_channel = e["channel"]
        sids = e["sids"]
        ch_obj = {
            "name": ch_name,
            "type": ch_type,
            "channel": ch_channel,
            "extra_args": "",
            "services": sids,
            "excluded_services": [],
        }
        for s in e["services"]:
            sid = s.get("sid")
            nid = s.get("nid")
            if not isinstance(sid, int) or not isinstance(nid, int):
                continue
            sid_value = nid * 100000 + sid
            svc = {
                "id": sid_value,
                "type": s.get("type", 1),
                "logoId": s.get("logoId", -1),
                "remoteControlKeyId": s.get("remoteControlKeyId", 0),
                "name": s.get("name", ch_name),
                "channel": ch_obj,
            }
            by_id[sid_value] = svc

    pairs = [[k, by_id[k]] for k in sorted(by_id)]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(pairs, f, ensure_ascii=False, separators=(",", ":"))


def main():
    args = [a for a in sys.argv[1:]
            if a not in ("--sample-satellite", "--sample-catv")]
    sample_satellite = "--sample-satellite" in sys.argv[1:]
    sample_catv = "--sample-catv" in sys.argv[1:]
    if len(args) != 2:
        print("usage: chscan_gen.py <manifest.tsv> <config-dir> "
              "[--sample-satellite] [--sample-catv]", file=sys.stderr)
        return 2
    manifest, config_dir = args[0], args[1]
    entries = load_manifest(manifest)
    config_path = os.path.join(config_dir, "config.yml")
    services_path = os.path.join(config_dir, "services.json")

    sample_lines = []
    sample_pairs = []
    if sample_satellite or sample_catv:
        sample_types = set()
        if sample_satellite:
            sample_types.update(SATELLITE_TYPES)
        if sample_catv:
            sample_types.add("CATV")
        sample_lines, present = extract_sample_channels(config_path, sample_types)
        sample_pairs = load_sample_services(services_path, present)

    if not entries and not sample_lines:
        print("chscan_gen: no scanned channels", file=sys.stderr)
        return 1

    patch_config(entries, sample_lines, config_path)
    write_channels_yml(entries, sample_lines, os.path.join(config_dir, "channels.yml"))
    write_services_json(entries, sample_pairs, services_path)

    counts = {}
    for e in entries:
        counts[e["type"]] = counts.get(e["type"], 0) + 1
    summary = ", ".join("%s=%d" % (t, counts.get(t, 0)) for t in TYPE_ORDER if counts.get(t))
    print("generated channels: " + (summary or "(none)"))
    if sample_satellite or sample_catv:
        print("sample channels: %d line(s), %d service(s)" %
              (len(sample_lines), len(sample_pairs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
