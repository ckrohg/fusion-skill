#!/usr/bin/env bash
#
# sync.sh — mirror the canonical fusion-skill files into this repo, then commit + push.
#
# This repo is a manual MIRROR. The canonical sources live elsewhere:
#   fusion.sh, stats.sh : tenet-master/fusion/   (the source of truth; the ~/.claude
#                         skill dir only symlinks to these)
#   SKILL.md            : ~/.claude/skills/fusion/   (real file; tenet/fusion has none)
#
# Usage:
#   ./sync.sh                 # pull canonical files, show diff, commit + push
#   ./sync.sh "commit msg"    # ...with a custom commit message
#   ./sync.sh --check         # dry run: report drift only, write/commit nothing (exit 1 if out of sync)
#   ./sync.sh --no-push       # commit locally but don't push
#
# Source dirs are overridable for other machines:
#   FUSION_TENET_DIR=/path/to/tenet-master/fusion  FUSION_SKILL_DIR=/path/to/.claude/skills/fusion
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TENET="${FUSION_TENET_DIR:-$HOME/Documents/Claude/tenet-master/fusion}"
SKILLDIR="${FUSION_SKILL_DIR:-$HOME/.claude/skills/fusion}"

# target-in-repo | canonical source
PAIRS=(
  "fusion.sh|$TENET/fusion.sh"
  "stats.sh|$TENET/stats.sh"
  "SKILL.md|$SKILLDIR/SKILL.md"
)

MODE=sync; NOPUSH=0; MSG=""
for a in "$@"; do
  case "$a" in
    --check|-n|--dry-run) MODE=check ;;
    --no-push)            NOPUSH=1 ;;
    -h|--help)            sed -n '2,20p' "$0"; exit 0 ;;
    *)                    MSG="$a" ;;
  esac
done

# verify every source exists before touching anything
missing=0
for p in "${PAIRS[@]}"; do
  src="${p#*|}"; [ -f "$src" ] || { echo "sync: missing canonical source: $src" >&2; missing=1; }
done
[ "$missing" = 0 ] || { echo "sync: aborting — fix source paths (FUSION_TENET_DIR / FUSION_SKILL_DIR)" >&2; exit 3; }

# ---- check mode: compare in place, no writes -------------------------------
if [ "$MODE" = check ]; then
  drift=0
  for p in "${PAIRS[@]}"; do
    tgt="${p%%|*}"; src="${p#*|}"
    if cmp -s "$src" "$REPO/$tgt"; then
      echo "  in sync : $tgt"
    else
      echo "  DRIFT   : $tgt  (repo differs from $src)"
      diff -u "$REPO/$tgt" "$src" || true
      drift=1
    fi
  done
  [ "$drift" = 0 ] && echo "✓ repo matches all canonical sources" || echo "✗ repo is OUT OF SYNC — run ./sync.sh to update"
  exit "$drift"
fi

# ---- sync mode: copy, stage, diff, commit, push ----------------------------
cd "$REPO"
for p in "${PAIRS[@]}"; do
  tgt="${p%%|*}"; src="${p#*|}"
  cp -L "$src" "$REPO/$tgt"
  case "$tgt" in *.sh) chmod +x "$REPO/$tgt" ;; esac
  git add -- "$tgt"
done

changed="$(git diff --cached --name-only | tr '\n' ' ')"
if [ -z "${changed// }" ]; then
  echo "✓ already in sync — nothing to commit or push"
  exit 0
fi

echo "=== changes to sync ==="
git --no-pager diff --cached --stat
echo
git --no-pager diff --cached
echo

MSG="${MSG:-sync canonical fusion files: ${changed% }}"
git commit -q -m "$MSG"
echo "committed: $(git rev-parse --short HEAD)  ($MSG)"

if [ "$NOPUSH" = 1 ]; then
  echo "push skipped (--no-push); to push later: git -C \"$REPO\" push"
  exit 0
fi
if git push; then
  echo "✓ pushed to $(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo origin)"
else
  echo "sync: push failed — commit is saved locally; retry with: git -C \"$REPO\" push" >&2
  exit 4
fi
