#!/usr/bin/env bash
#
# stats.sh — summarize the fusion journal (which model wins, signal mix, reliability)
#
# Usage:
#   ./stats.sh                       # default journal (~/.local/share/tenet/fusion/journal.jsonl)
#   ./stats.sh /path/to/journal.jsonl
#   FUSION_TAG=rfc ./stats.sh        # only runs tagged "rfc"
#
set -uo pipefail
JOURNAL="${1:-${FUSION_JOURNAL:-$HOME/.local/share/tenet/fusion/journal.jsonl}}"
[ -s "$JOURNAL" ] || { echo "stats: no journal at $JOURNAL (run a fusion first)" >&2; exit 1; }

FILTER_TAG="${FUSION_TAG:-}" python3 - "$JOURNAL" <<'PY'
import json, os, sys
from collections import Counter, defaultdict
path = sys.argv[1]
ftag = os.environ.get('FILTER_TAG') or None
runs = 0
sig = Counter()
wins = Counter()                 # judge top-pick wins, by leg label (both judges)
agree = 0                        # both judges picked the same response
rel = defaultdict(lambda: {"runs":0,"ok":0,"timeout":0,"fail":0,"bytes":0})
wall = []
for line in open(path):
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except: continue
    if r.get("kind") != "fusion": continue
    if ftag and r.get("tag") != ftag: continue
    runs += 1
    sig[r.get("signal") or "?"] += 1
    if r.get("wall_s") is not None: wall.append(r["wall_s"])
    w = r.get("winners", {})
    po, pg = w.get("opus_judge"), w.get("gpt_judge")
    if po: wins[po] += 1
    if pg: wins[pg] += 1
    jo = (r.get("judges",{}).get("opus",{}) or {}).get("pick")
    jg = (r.get("judges",{}).get("gpt",{})  or {}).get("pick")
    if jo is not None and jo == jg: agree += 1
    for leg in r.get("legs", []):
        k = leg.get("model") or leg.get("label") or "?"
        s = rel[k]; s["runs"] += 1; s["bytes"] += leg.get("bytes") or 0
        if leg.get("timed_out"): s["timeout"] += 1
        elif leg.get("exit") == 0: s["ok"] += 1
        else: s["fail"] += 1

if runs == 0:
    print("stats: no matching fusion runs"); sys.exit(0)

def pct(x): return f"{100*x/runs:.0f}%"
print(f"fusion journal — {path}")
print(f"runs: {runs}" + (f"   (tag={ftag})" if ftag else ""))
if wall: print(f"avg wall: {sum(wall)//len(wall)}s   (min {min(wall)}s / max {max(wall)}s)")
print(f"judges agreed on top pick: {agree}/{runs} ({pct(agree)})")

print("\nsignal mix:")
for k,v in sig.most_common(): print(f"  {k:<12} {v:>3}  {pct(v)}")

print("\njudge-preference wins  (times a judge's top pick was that model; 2 judges/run):")
for k,v in wins.most_common(): print(f"  {k:<10} {v:>3}")

print("\nleg reliability:")
print(f"  {'model':<18} {'runs':>4} {'ok':>4} {'timeout':>7} {'fail':>4} {'avg_bytes':>9}")
for k,s in sorted(rel.items(), key=lambda kv:-kv[1]['runs']):
    ab = s['bytes']//s['runs'] if s['runs'] else 0
    print(f"  {k:<18} {s['runs']:>4} {s['ok']:>4} {s['timeout']:>7} {s['fail']:>4} {ab:>9}")
PY
