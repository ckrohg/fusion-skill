#!/usr/bin/env bash
#
# fusion.sh — subscription-backed model fusion (no API keys)
#
#   Phase 1  fan-out : panel of native subscription CLIs run in parallel (per-leg timeout)
#   Phase 2  judge   : TWO cross-vendor judges (Claude Opus + GPT/codex) each emit a
#                      PREFERRED pick + a CONVERGENT/DIVERGENT verdict on the panel
#   Phase 3  synth   : consensus-gated synthesis on Claude Opus
#                      (confident when judges agree; surfaces the split when they don't)
#
#   Auth, all subscription-backed:
#     claude -p  = Claude Max/Pro   |   codex exec = ChatGPT/Codex   |   gemini -p = Google
#
#   macOS system bash 3.2 safe: no associative arrays, no heredoc-in-$(), no eval-on-task.
#
# Usage:
#   ./fusion.sh "task..."          |  echo "task" | ./fusion.sh
#   KEEP=1 ./fusion.sh "..."       # keep run dir (panel + both judge files)
#   LEG_TIMEOUT=600 ./fusion.sh    # per-leg wall-clock cap (default 480s, sized for max effort)
#   FUSION_OPUS_EFFORT=xhigh ./fusion.sh        # Opus judge+synth effort (default max; floor xhigh)
#   FUSION_OPUS_LEG_EFFORT=xhigh ./fusion.sh    # claude leg effort only (default = FUSION_OPUS_EFFORT)
#   CODEX_REASONING_EFFORT=high ./fusion.sh     # GPT leg+judge effort (default ultra = gpt-5.6 ceiling)
#   CODEX_MODEL=gpt-5.5 ./fusion.sh             # pin the codex model (default gpt-5.6-sol)
#
set -uo pipefail

TASK="${1:-}"
[ -z "$TASK" ] && TASK="$(cat)"
[ -z "${TASK// }" ] && { echo "fusion: no task provided" >&2; exit 2; }

# ---- config ---------------------------------------------------------------
START_EPOCH="$(date +%s)"
# Caps are sized for MAX-effort Opus, which thinks substantially longer than the old
# default. The leg cap is the tightest pressure point (Opus is the sole timeout source —
# at max effort a hard task's leg has been observed near ~885s), so it gets the most room;
# judge/synth read the whole panel (a larger input than any one leg) and share an even
# larger cap. A cap is a kill-ceiling, not a wait: fast legs/judges still finish when done.
LEG_TIMEOUT="${LEG_TIMEOUT:-900}"
JUDGE_TIMEOUT="${JUDGE_TIMEOUT:-1080}"
FUSION_JOURNAL="${FUSION_JOURNAL:-$HOME/.local/share/tenet/fusion/journal.jsonl}"
FUSION_TAG="${FUSION_TAG:-}"        # optional task-class tag for worldengine analysis
# Effort is PINNED in-script (never inherited from ambient config) so fusion can't
# silently drift, and so these high-stakes calls run at full reasoning. Floor is xhigh.
#   Opus (claude): low|medium|high|xhigh|max            — ceiling = max
#   GPT  (codex):  minimal|low|medium|high|xhigh|max|ultra — ceiling = ultra (gpt-5.6)
# Both vendors default to their ceiling, keeping the panel balanced.
# Verified 2026-07-14 (codex CLI 0.144.4, live API probes): gpt-5.6-sol is the newest
# flagship reachable on ChatGPT-subscription auth — the BARE slug gpt-5.6 and gpt-5.5-pro
# are rejected ("not supported when using Codex with a ChatGPT account"), but the variant
# slugs gpt-5.6-{sol,luna,terra} all work, and sol accepts max AND ultra effort (docs:
# low→ultra; sol = "strongest capability for complex coding"). gpt-5.5's own ceiling
# remains xhigh, so if you override CODEX_MODEL back to gpt-5.5, drop the effort too.
# NOTE: the override vars are FUSION_*-prefixed on purpose — the Claude Code harness
# exports CLAUDE_EFFORT into subprocesses, so reading $CLAUDE_EFFORT here would silently
# inherit the parent session's effort (the very drift this pin exists to prevent).
OPUS_EFFORT="${FUSION_OPUS_EFFORT:-max}"                  # Opus judge + synthesizer effort
OPUS_LEG_EFFORT="${FUSION_OPUS_LEG_EFFORT:-$OPUS_EFFORT}" # claude panel legs; flex to xhigh if the leg times out
CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"             # the codex model for leg + judge
CODEX_EFFORT="${CODEX_REASONING_EFFORT:-ultra}"       # gpt-5.6 ceiling (gpt-5.5 caps at xhigh); balances Opus=max
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || echo '')"
maybe_timeout() {                 # maybe_timeout <secs> cmd... (no-op if no timeout bin)
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}

# ---- legs: "label kind model" (the editable panel) ------------------------
LEGS=(
  "fable  claude fable"
  "sonnet claude sonnet"
  "gpt    codex  -"
)
# Top Anthropic leg = Fable 5 while it's available (2026-07-14; Mythos-class, above
# Opus). `claude -p --model fable --effort max` verified live; if the alias ever stops
# resolving the leg just fails and the panel degrades to 3 — swap "fable" back to
# "opus" here to restore. Judges + synth stay on OPUS deliberately: the judge is the
# measuring instrument behind 143+ journaled runs, and swapping it mid-stream would
# confound the longitudinal win-share/convergence stats.
# Gemini = 3rd vendor (Google), now via the Antigravity CLI `agy` — the standalone
# `gemini` CLI was cut off for individuals 2026-06-19 ("migrate to Antigravity"). The
# model name carries spaces, so it can't ride the space-split LEGS array; it's passed via
# $AGY_MODEL and resolved in run_leg (placeholder "-" below, exactly like the codex leg).
# Default to Flash (High): quality dissent without burning the Antigravity Starter quota
# that Pro would. Override with AGY_MODEL="Gemini 3.1 Pro (High)" when you have Pro capacity.
AGY_MODEL="${AGY_MODEL:-Gemini 3.5 Flash (High)}"
command -v agy >/dev/null 2>&1 && LEGS+=("gemini agy -")

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fusion.XXXXXX")"
cleanup() { [ "${KEEP:-0}" = "1" ] || rm -rf "$RUN_DIR"; }
trap cleanup EXIT
echo "fusion: ${#LEGS[@]} legs -> 2 judges (opus@${OPUS_EFFORT} + ${CODEX_MODEL}@${CODEX_EFFORT}) -> synthesize@${OPUS_EFFORT}   ($RUN_DIR)" >&2

# ---- Phase 1: fan-out, parallel, per-leg timeout --------------------------
run_leg() {                       # $1=label $2=kind $3=model ; reads $TASK
  local label="$1" kind="$2" model="$3" rc=0
  local out="$RUN_DIR/$label.out" log="$RUN_DIR/$label.log"
  case "$kind" in
    claude) local t0=$SECONDS
            maybe_timeout "$LEG_TIMEOUT" claude -p --model "$model" --effort "$OPUS_LEG_EFFORT" "$TASK"  >"$out" 2>"$log"; rc=$?
            local elapsed=$((SECONDS - t0))
            # Fable availability guard: if the fable alias stops working on the Claude
            # subscription (e.g. moves to API-only billing), fall back to OPUS instead of
            # losing the top Anthropic leg. Gated on a genuinely FAST no-output failure —
            # elapsed <= FUSION_FABLE_FAST_WINDOW (default 90s; entitlement errors return in
            # seconds) and not a 124 timeout. A slow failure (model thought for minutes then
            # died) is NOT the cutoff signature, and an opus rerun there would double the
            # leg phase's wall clock. Journal records the real model used either way.
            if [ "$model" = "fable" ] && [ ! -s "$out" ]; then
              if [ "$rc" -ne 124 ] && [ "$elapsed" -le "${FUSION_FABLE_FAST_WINDOW:-90}" ]; then
                echo "[fusion] fable leg failed fast (rc=$rc, ${elapsed}s, no output) — falling back to opus" >>"$log"
                echo "opus" >"$RUN_DIR/$label.model"
                maybe_timeout "$LEG_TIMEOUT" claude -p --model opus --effort "$OPUS_LEG_EFFORT" "$TASK" >"$out" 2>>"$log"; rc=$?
              else
                echo "[fusion] fable leg produced no output (rc=$rc, ${elapsed}s) — slow failure/timeout, NOT falling back (panel degrades)" >>"$log"
              fi
            fi ;;
    # </dev/null on every codex call: with a held-open non-tty stdin codex exec blocks on
    # "Reading additional input from stdin...". Backgrounding usually implies </dev/null,
    # but that's an implicit-job-control subtlety — make it explicit, not inherited.
    codex)  maybe_timeout "$LEG_TIMEOUT" codex exec --skip-git-repo-check -s read-only -m "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" -o "$out" "$TASK" >"$log" 2>&1 </dev/null; rc=$? ;;
    agy)    maybe_timeout "$LEG_TIMEOUT" agy --model "$AGY_MODEL" -p "$TASK"                               >"$out" 2>"$log"; rc=$? ;;
    *)      echo "unknown leg kind: $kind" >"$log"; rc=1 ;;
  esac
  echo "$rc" >"$RUN_DIR/$label.exit"
}
PIDS=(); NAMES=()
for leg in "${LEGS[@]}"; do
  set -- $leg
  m="$3"; [ "$2" = "codex" ] && [ "$m" = "-" ] && m="$CODEX_MODEL"   # journal the real pinned model
  [ "$2" = "agy" ] && m="$AGY_MODEL"                                 # agy model carries spaces; journal it directly
  echo "$m" > "$RUN_DIR/$1.model"
  run_leg "$1" "$2" "$3" &
  PIDS+=("$!"); NAMES+=("$1")
done
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}"
  ec="$(cat "$RUN_DIR/${NAMES[$i]}.exit" 2>/dev/null || echo '?')"
  sz="$(wc -c <"$RUN_DIR/${NAMES[$i]}.out" 2>/dev/null | tr -d ' ')"
  if [ "$ec" = "124" ]; then
    echo "  leg ${NAMES[$i]}: TIMED OUT after ${LEG_TIMEOUT}s" >&2
  else
    echo "  leg ${NAMES[$i]}: exit=$ec bytes=${sz:-0}" >&2
  fi
done

# ---- per-judge anonymized panels (vendor-blind AND independently shuffled) --
# Each judge gets its OWN random response ordering, so position carries no vendor
# signal (Response 1 is no longer always Opus). This removes the position confound
# that an un-shuffled, identically-numbered panel bakes into both judges' picks.
# map_<judge>.txt line k = the leg behind that judge's "Response k" (used to
# de-anonymize the pick afterwards). Picks are NO LONGER comparable as raw integers
# across judges — only the mapped leg labels are.
OK_LABELS=()
for label in "${NAMES[@]}"; do
  [ -s "$RUN_DIR/$label.out" ] && OK_LABELS+=("$label")
done
n=${#OK_LABELS[@]}
[ "$n" -eq 0 ] && { echo "fusion: every leg failed — see $RUN_DIR/*.log" >&2; KEEP=1; exit 1; }
[ "$n" -lt 2 ] && echo "fusion: WARNING only $n leg(s) succeeded — no real ensemble" >&2

shuffle_to() {                    # $1=outfile, rest=items ; Fisher-Yates via $RANDOM (bash 3.2)
  local out="$1"; shift
  local arr=("$@") i j tmp
  for (( i=${#arr[@]}-1; i>0; i-- )); do
    j=$(( RANDOM % (i+1) ))
    tmp="${arr[i]}"; arr[i]="${arr[j]}"; arr[j]="$tmp"
  done
  printf '%s\n' "${arr[@]}" >"$out"
}
build_panel() {                   # $1=judge key -> panel_<key>.txt + map_<key>.txt
  local map="$RUN_DIR/map_$1.txt" panel="$RUN_DIR/panel_$1.txt" k=0 label
  shuffle_to "$map" "${OK_LABELS[@]}"      # independent shuffle per call (RANDOM advances globally)
  : >"$panel"
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    k=$((k+1))
    { echo "===== Response $k ====="; cat "$RUN_DIR/$label.out"; echo; } >>"$panel"
  done <"$map"
}
build_panel opus
build_panel gpt

# ---- Phase 2: two independent cross-vendor judges --------------------------
make_judge_prompt() {             # $1 = that judge's panel file -> prompt on stdout
cat <<EOF
You are one of two INDEPENDENT judges comparing $n anonymized responses to a task.
Be vendor-blind; assume no response is authoritative. The responses are in a RANDOM
order chosen independently for you — position carries no meaning, so do not infer
anything about a response from its number.

Your FIRST TWO lines MUST be exactly:
PREFERRED: Response <k>
CONVERGENCE: <CONVERGENT|DIVERGENT>
where <k> is a single integer 1..$n naming the single strongest response, and the
CONVERGENCE verdict is CONVERGENT if the responses substantively agree on the
bottom-line answer (ignore wording, style, and emphasis) or DIVERGENT if they reach
materially different conclusions.
Then a blank line, then:
## BOTTOM LINE — one sentence: the core answer the best response gives
## WHY         — one sentence: why your preferred response wins
## CONFLICTS   — where responses disagree; which is better supported and why
## GAPS        — important aspects no response covered
## RISKS        — likely errors / hallucinations / unsupported claims (cite Response #)

TASK:
$TASK

RESPONSES:
$(cat "$1")
EOF
}
JUDGE_OPUS="$RUN_DIR/judge_opus.txt"; JUDGE_GPT="$RUN_DIR/judge_gpt.txt"
JP_O="$(make_judge_prompt "$RUN_DIR/panel_opus.txt")"   # Opus judge sees its own shuffle
JP_G="$(make_judge_prompt "$RUN_DIR/panel_gpt.txt")"    # GPT  judge sees a different shuffle
( maybe_timeout "$JUDGE_TIMEOUT" claude -p --model opus --effort "$OPUS_EFFORT" "$JP_O" >"$JUDGE_OPUS" 2>"$RUN_DIR/judge_opus.log" ) & JPID_O=$!
( maybe_timeout "$JUDGE_TIMEOUT" codex exec --skip-git-repo-check -s read-only -m "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" -o "$JUDGE_GPT" "$JP_G" >"$RUN_DIR/judge_gpt.log" 2>&1 </dev/null ) & JPID_G=$!
wait "$JPID_O"; wait "$JPID_G"

parse_pick() { grep -m1 -oiE 'PREFERRED:[[:space:]]*Response[[:space:]]*[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1; }
parse_conv() { grep -m1 -iE 'CONVERGENCE:' "$1" 2>/dev/null | grep -oiE 'CONVERGENT|DIVERGENT' | head -1 | tr '[:lower:]' '[:upper:]'; }
PICK_O="$(parse_pick "$JUDGE_OPUS")"; CONV_O="$(parse_conv "$JUDGE_OPUS")"; [ -s "$JUDGE_OPUS" ] || { PICK_O=""; CONV_O=""; }
PICK_G="$(parse_pick "$JUDGE_GPT")";  CONV_G="$(parse_conv "$JUDGE_GPT")";  [ -s "$JUDGE_GPT" ]  || { PICK_G=""; CONV_G=""; }

# Map each judge's pick through ITS OWN shuffle to the real leg label. Because the two
# judges saw different orderings, PICK_O and PICK_G are integers in different spaces —
# only WIN_O/WIN_G (the de-anonymized leg labels) are comparable across judges.
WIN_O=""; [ -n "$PICK_O" ] && WIN_O="$(sed -n "${PICK_O}p" "$RUN_DIR/map_opus.txt" 2>/dev/null)"
WIN_G=""; [ -n "$PICK_G" ] && WIN_G="$(sed -n "${PICK_G}p" "$RUN_DIR/map_gpt.txt"  2>/dev/null)"
if [ -n "$WIN_O" ] && [ -n "$WIN_G" ]; then
  [ "$WIN_O" = "$WIN_G" ] && AGREE="SAME" || AGREE="DIFFERENT"
else
  AGREE="UNKNOWN"
fi

# Headline signal = do the two judges agree the PANEL converges on one bottom line?
# (conclusion-level, not preference-level — a single preferred pick is near-always split.)
if [ "$CONV_O" = "CONVERGENT" ] && [ "$CONV_G" = "CONVERGENT" ]; then
  SIGNAL="CONVERGENT — both judges agree the models reach the same bottom line (high confidence)"
elif [ "$CONV_O" = "DIVERGENT" ] && [ "$CONV_G" = "DIVERGENT" ]; then
  SIGNAL="DIVERGENT — both judges agree the models reach different conclusions (genuine disagreement)"
elif [ -n "$CONV_O$CONV_G" ]; then
  SIGNAL="MIXED — judges differ on whether the models converge (Opus=${CONV_O:-?}, GPT=${CONV_G:-?})"
else
  SIGNAL="UNDETERMINED — convergence verdict could not be parsed"
fi
PICKNOTE="picks: Opus->${WIN_O:-?}, GPT->${WIN_G:-?}  (judges preferred the $AGREE leg)"
echo "  judge signal: $SIGNAL" >&2
echo "    $PICKNOTE" >&2
[ -s "$JUDGE_OPUS" ] || echo "(Judge A / Opus unavailable — see judge_opus.log)" > "$JUDGE_OPUS"
[ -s "$JUDGE_GPT" ]  || echo "(Judge B / GPT ${CODEX_MODEL} unavailable — see judge_gpt.log)" > "$JUDGE_GPT"

# ---- Phase 3: consensus-gated synthesis -----------------------------------
# canonical panel for the synthesizer; its numbering is independent of either judge's
# private shuffle, so the synth must NOT cross-reference a judge's "Response k" to it.
PANEL_SYNTH="$RUN_DIR/panel_synth.txt"; : >"$PANEL_SYNTH"; k=0
for label in "${OK_LABELS[@]}"; do
  k=$((k+1)); { echo "===== Response $k ====="; cat "$RUN_DIR/$label.out"; echo; } >>"$PANEL_SYNTH"
done

# ---- Phase 2.5 (2026-07-02): DIVERGENT/MIXED tiebreak — one extra ADVERSARIAL codex pass.
# Runs only when the judges do NOT both see convergence: it tries to REFUTE each contested
# bottom line against the canonical panel and names the position that best survives, handed
# to the synthesizer as a REFEREE note (advisory — synthesis stays Opus). Fail-open: an
# empty/failed tiebreak leaves synthesis exactly as before. FUSION_TIEBREAK=0 disables;
# FUSION_FORCE_TIEBREAK=1 runs it regardless of signal (testing). Numbering note: the
# tiebreak reads panel_synth, so its "Response k" IS the synthesizer's numbering (unlike
# the judges' private shuffles).
TIEBREAK_FILE="$RUN_DIR/tiebreak.txt"; TB_RAN=0; TB_WIN=""
TB_WANT=0
case "$SIGNAL" in DIVERGENT*|MIXED*) TB_WANT=1 ;; esac
[ "${FUSION_FORCE_TIEBREAK:-0}" = "1" ] && TB_WANT=1
if [ "${FUSION_TIEBREAK:-1}" = "1" ] && [ "$TB_WANT" = "1" ] && [ "$n" -ge 2 ]; then
  TB_RAN=1; TB_T0="$(date +%s)"
  [ "${FUSION_FORCE_TIEBREAK:-0}" = "1" ] && tbwhy="forced (FUSION_FORCE_TIEBREAK=1)" || tbwhy="judges did not both see convergence"
  echo "  tiebreak: $tbwhy -> adversarial ${CODEX_MODEL} referee pass" >&2
  TB_PROMPT="You are a TIEBREAK REFEREE. Two independent judges disagreed on whether $n responses to a task converge (judge A verdict: ${CONV_O:-?}, judge B verdict: ${CONV_G:-?}). Be adversarial: identify each materially different bottom-line position among the responses, try hard to REFUTE each one, and name the position that best SURVIVES refutation. Do not reward confidence or length.
Your FIRST line MUST be exactly: TIEBREAK: Response <k>   (k = 1..$n from the RESPONSES below)
Second line: SURVIVES: <one sentence — why this position survives refutation best>
Then at most 250 words of refutation analysis.

TASK:
$TASK

JUDGE A ANALYSIS:
$(cat "$JUDGE_OPUS")

JUDGE B ANALYSIS:
$(cat "$JUDGE_GPT")

RESPONSES:
$(cat "$PANEL_SYNTH")"
  # </dev/null: with a non-tty stdin held open, codex exec blocks on stdin until the timeout
  maybe_timeout "$JUDGE_TIMEOUT" codex exec --skip-git-repo-check -s read-only -m "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" -o "$TIEBREAK_FILE" "$TB_PROMPT" >"$RUN_DIR/tiebreak.log" 2>&1 </dev/null
  TB_PICK="$(grep -m1 -oiE '^TIEBREAK:[[:space:]]*Response[[:space:]]*[0-9]+' "$TIEBREAK_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  if [ -n "$TB_PICK" ] && [ "$TB_PICK" -ge 1 ] 2>/dev/null && [ "$TB_PICK" -le "$n" ] 2>/dev/null; then
    TB_WIN="${OK_LABELS[$((TB_PICK-1))]}"
    echo "    tiebreak referee: Response $TB_PICK -> $TB_WIN" >&2
  else
    echo "    tiebreak referee: unparseable/empty — synthesis proceeds without it (see tiebreak.log)" >&2
  fi
  if [ -f "$HOME/.local/lib/codex-metrics.sh" ]; then
    . "$HOME/.local/lib/codex-metrics.sh" 2>/dev/null
    command -v cxm >/dev/null 2>&1 && cxm fusion-tiebreak tiebreak signal="${SIGNAL%% *}" winner="${TB_WIN:-unparsed}" secs=$(( $(date +%s) - TB_T0 )) tokens="$(cxm_tokens "$RUN_DIR/tiebreak.log" 2>/dev/null || echo 0)"
  fi
fi

cat > "$RUN_DIR/synth_prompt.txt" <<EOF
You are a synthesizer. Two independent judges (A = Claude Opus, B = GPT/codex) each
analyzed $n anonymized responses and named a preferred one.

JUDGE SIGNAL: $SIGNAL
(The two judges preferred the $AGREE underlying response. Each judge saw the responses
in its own private random order, so a judge's "Response k" does NOT correspond to the
other judge's numbering or to the RAW RESPONSES below — identify responses by content,
not by number.)
- If CONVERGENT, write a confident single best answer.
- If DIVERGENT or MIXED, weigh both judges' reasoning, take the best-supported position,
  and surface the key disagreement in ONE short clause so the reader sees where the
  models diverged.
- If a TIEBREAK REFEREE section is present below, it is a third, adversarial pass that
  refuted the contested positions against each other; its "Response k" numbering DOES
  match the RAW RESPONSES below. Treat refutation-survival as strong (not absolute)
  evidence when choosing the position to build on.

Merge the strongest elements across responses, resolve conflicts toward the better-
supported claim, fill gaps where you can, and silently drop anything a judge flagged as
a likely error. Output ONLY the final answer — no meta-commentary and no mention of
"responses" or "judges" except the single disagreement clause if DIVERGENT.

TASK:
$TASK

JUDGE A (Opus):
$(cat "$JUDGE_OPUS")

JUDGE B (GPT):
$(cat "$JUDGE_GPT")

$( [ "$TB_RAN" = "1" ] && [ -s "$TIEBREAK_FILE" ] && { echo "TIEBREAK REFEREE (${CODEX_MODEL}, adversarial — ran because the judges did not both see convergence):"; cat "$TIEBREAK_FILE"; echo; } )
RAW RESPONSES:
$(cat "$PANEL_SYNTH")
EOF
maybe_timeout "$JUDGE_TIMEOUT" claude -p --model opus --effort "$OPUS_EFFORT" "$(cat "$RUN_DIR/synth_prompt.txt")" 2>"$RUN_DIR/synth.log"

# ---- Journal the run (machine-global, append-only JSONL) -------------------
# Records WHICH MODEL each judge preferred + the convergence signal per run — the
# reference data worldengine wants ("which vendor wins which task-class"). The panel
# is anonymized, so we map each judge's Response-# pick back to the real leg/model.
# Best-effort: a journaling failure never affects the run (explicit exit 0 below).
if [ "${FUSION_NO_JOURNAL:-0}" != "1" ]; then
  : > "$RUN_DIR/legs.tsv"
  for label in "${NAMES[@]}"; do
    ex="$(cat "$RUN_DIR/$label.exit" 2>/dev/null || echo '?')"
    by="$(wc -c <"$RUN_DIR/$label.out" 2>/dev/null | tr -d ' ')"
    md="$(cat "$RUN_DIR/$label.model" 2>/dev/null)"
    rno="$(grep -nxF "$label" "$RUN_DIR/map_opus.txt" 2>/dev/null | head -1 | cut -d: -f1)"
    rng="$(grep -nxF "$label" "$RUN_DIR/map_gpt.txt"  2>/dev/null | head -1 | cut -d: -f1)"
    to=false; [ "$ex" = "124" ] && to=true
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$md" "$ex" "${by:-0}" "$to" "${rno:-}" "${rng:-}" >> "$RUN_DIR/legs.tsv"
  done
  mkdir -p "$(dirname "$FUSION_JOURNAL")" 2>/dev/null
  FJ_TASK="$TASK" FJ_LEGS="$RUN_DIR/legs.tsv" \
  FJ_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" FJ_RUNID="$(basename "$RUN_DIR")" FJ_CWD="$PWD" \
  FJ_TAG="$FUSION_TAG" FJ_SIGNAL="${SIGNAL%% *}" FJ_N="$n" \
  FJ_PICK_O="${PICK_O:-}" FJ_PICK_G="${PICK_G:-}" FJ_CONV_O="${CONV_O:-}" FJ_CONV_G="${CONV_G:-}" \
  FJ_WIN_O="$WIN_O" FJ_WIN_G="$WIN_G" FJ_WALL="$(( $(date +%s) - START_EPOCH ))" \
  FJ_TB_RAN="$TB_RAN" FJ_TB_WIN="$TB_WIN" \
  FJ_CODEX_MODEL="$CODEX_MODEL" FJ_CODEX_EFFORT="$CODEX_EFFORT" \
  FJ_OPUS_EFFORT="$OPUS_EFFORT" FJ_OPUS_LEG_EFFORT="$OPUS_LEG_EFFORT" \
  python3 - "$FUSION_JOURNAL" >>"$RUN_DIR/journal.log" 2>&1 <<'PY'
import json, os, sys
def env(k):
    v = os.environ.get(k, ''); return v if v != '' else None
def i(v):
    return int(v) if (v is not None and str(v).isdigit()) else None
legs = []
try:
    with open(os.environ['FJ_LEGS']) as f:
        for line in f:
            p = line.rstrip('\n').split('\t')
            if len(p) < 7: continue
            label, model, ex, by, to, rno, rng = p[:7]
            legs.append({"label": label, "model": model or None,
                         "exit": i(ex) if str(ex).isdigit() else ex,
                         "bytes": i(by) or 0, "timed_out": to == "true",
                         "response_n_opus": i(rno), "response_n_gpt": i(rng)})
except Exception:
    pass
task = os.environ.get('FJ_TASK', '')
rec = {"ts": env('FJ_TS'), "kind": "fusion", "run_id": env('FJ_RUNID'), "cwd": env('FJ_CWD'),
       "anon": "per_judge_shuffle_v1",
       "codex": {"model": env('FJ_CODEX_MODEL'), "effort": env('FJ_CODEX_EFFORT')},
       "opus_effort": {"judge_synth": env('FJ_OPUS_EFFORT'), "leg": env('FJ_OPUS_LEG_EFFORT')},
       "tag": env('FJ_TAG'), "task_preview": task[:240], "task_chars": len(task),
       "n_legs": i(env('FJ_N')), "signal": env('FJ_SIGNAL'),
       "judges": {"opus": {"pick": i(env('FJ_PICK_O')), "convergence": env('FJ_CONV_O')},
                  "gpt":  {"pick": i(env('FJ_PICK_G')), "convergence": env('FJ_CONV_G')}},
       "winners": {"opus_judge": env('FJ_WIN_O'), "gpt_judge": env('FJ_WIN_G')},
       "tiebreak": {"ran": env('FJ_TB_RAN') == '1', "winner": env('FJ_TB_WIN')},
       "legs": legs, "wall_s": i(env('FJ_WALL')) or 0}
with open(sys.argv[1], "a") as out:
    out.write(json.dumps(rec) + "\n")
PY
  echo "  journaled -> $FUSION_JOURNAL" >&2
fi

if [ "${KEEP:-0}" = "1" ]; then
  echo >&2; echo "fusion: artifacts in $RUN_DIR (panel_opus.txt, panel_gpt.txt, map_opus.txt, map_gpt.txt, judge_opus.txt, judge_gpt.txt, panel_synth.txt)" >&2
fi
exit 0   # success — don't let a falsy final test leak a nonzero status
