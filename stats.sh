#!/usr/bin/env bash
#
# stats.sh — summarize the fusion journal (which model wins, signal mix, reliability)
#
# Usage:
#   ./stats.sh                       # default journal (~/.local/share/tenet/fusion/journal.jsonl)
#   ./stats.sh /path/to/journal.jsonl
#   ./stats.sh --shuffled            # only per-judge-shuffle runs (records with an anon field)
#   ./stats.sh --legacy              # only pre-shuffle runs (records with no anon field)
#   FUSION_TAG=rfc ./stats.sh        # only runs tagged "rfc" (composes with --shuffled/--legacy)
#
# The --shuffled/--legacy split lets you diff a leg's win-share across the de-bias
# change — e.g. compare Opus's share under `./stats.sh --legacy` vs `./stats.sh --shuffled`.
#
set -uo pipefail
JOURNAL=""; FILTER_ANON=""
for a in "$@"; do
  case "$a" in
    --shuffled) FILTER_ANON=shuffled ;;
    --legacy)   FILTER_ANON=legacy ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    --*)        echo "stats: unknown flag: $a" >&2; exit 2 ;;
    *)          JOURNAL="$a" ;;
  esac
done
JOURNAL="${JOURNAL:-${FUSION_JOURNAL:-$HOME/.local/share/tenet/fusion/journal.jsonl}}"
[ -s "$JOURNAL" ] || { echo "stats: no journal at $JOURNAL (run a fusion first)" >&2; exit 1; }

FILTER_TAG="${FUSION_TAG:-}" FILTER_ANON="$FILTER_ANON" python3 - "$JOURNAL" <<'PY'
import json, os, sys
from collections import Counter, defaultdict
path = sys.argv[1]
ftag = os.environ.get('FILTER_TAG') or None
fanon = os.environ.get('FILTER_ANON') or None    # 'shuffled' | 'legacy' | None
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
    shuffled = bool(r.get("anon"))               # any anon scheme = a post-de-bias run
    if fanon == "shuffled" and not shuffled: continue
    if fanon == "legacy"   and shuffled:     continue
    runs += 1
    sig[r.get("signal") or "?"] += 1
    if r.get("wall_s") is not None: wall.append(r["wall_s"])
    w = r.get("winners", {})
    po, pg = w.get("opus_judge"), w.get("gpt_judge")
    if po: wins[po] += 1
    if pg: wins[pg] += 1
    # compare the de-anonymized winner labels, not raw pick #s — under per-judge
    # shuffle the integers live in different spaces; labels are the only comparable key
    if po and pg and po == pg: agree += 1
    for leg in r.get("legs", []):
        k = leg.get("model") or leg.get("label") or "?"
        s = rel[k]; s["runs"] += 1; s["bytes"] += leg.get("bytes") or 0
        if leg.get("timed_out"): s["timeout"] += 1
        elif leg.get("exit") == 0: s["ok"] += 1
        else: s["fail"] += 1

if runs == 0:
    print("stats: no matching fusion runs"); sys.exit(0)

def pct(x): return f"{100*x/runs:.0f}%"
filt = []
if ftag: filt.append(f"tag={ftag}")
if fanon: filt.append(fanon)
print(f"fusion journal — {path}")
print(f"runs: {runs}" + (f"   ({', '.join(filt)})" if filt else ""))
if wall: print(f"avg wall: {sum(wall)//len(wall)}s   (min {min(wall)}s / max {max(wall)}s)")
print(f"judges agreed on top pick: {agree}/{runs} ({pct(agree)})")

print("\nsignal mix:")
for k,v in sig.most_common(): print(f"  {k:<12} {v:>3}  {pct(v)}")

total_picks = sum(wins.values())
print(f"\njudge-preference wins  (top-pick count + share of {total_picks} attributed picks; 2 judges/run):")
for k,v in wins.most_common():
    share = f"{100*v/total_picks:.0f}%" if total_picks else "—"
    print(f"  {k:<10} {v:>3}  {share:>5}")

print("\nleg reliability:")
print(f"  {'model':<18} {'runs':>4} {'ok':>4} {'timeout':>7} {'fail':>4} {'avg_bytes':>9}")
for k,s in sorted(rel.items(), key=lambda kv:-kv[1]['runs']):
    ab = s['bytes']//s['runs'] if s['runs'] else 0
    print(f"  {k:<18} {s['runs']:>4} {s['ok']:>4} {s['timeout']:>7} {s['fail']:>4} {ab:>9}")
PY
