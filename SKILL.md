---
name: fusion
description: Subscription-backed multi-model fusion — fan out a high-stakes question to several models in parallel, judge their answers with two cross-vendor judges, and synthesize one best answer. Use for RFC/design reviews, architecture calls, risk/security audits, and correctness decisions where one model's blind spot is costly. NOT for routine Q&A (each run is ~7 subscription calls, ~2-3 min).
disable-model-invocation: true
triggers:
  - /fusion
  - fusion run
  - fuse the models
  - multi-model
  - cross-check this with multiple models
  - run this through fusion
  - get a consensus answer
---

# /fusion — subscription-backed model fusion

Replicates OpenRouter-Fusion / opencode-fusion locally, but **every leg is a native
subscription-authenticated CLI** — no API keys. Runs the panel in parallel, has two
**cross-vendor judges** (Claude Opus + GPT-5.5) each pick a preferred answer and rule
the panel CONVERGENT or DIVERGENT, then synthesizes one answer on Claude Opus.

Script (symlinked to the source of truth in `tenet-master/fusion/`):
`~/.claude/skills/fusion/fusion.sh`

## When to use it

High-stakes, judgment-heavy questions only:
- RFC / design-doc critique, architecture decisions, tradeoff calls
- Risk, security, or correctness audits of a plan or diff
- Anything where a single model being confidently wrong would be expensive

**Do not** use it for routine lookups, quick edits, or anything you'd trust one model
on. Each run is ~7 subscription calls across Claude, Codex, and Gemini and ~2-3
minutes, and it multiplies subscription rate-limit usage N×.

## How to run it

```bash
~/.claude/skills/fusion/fusion.sh "<the full self-contained task>"
```

**The single most important rule: the legs run headless and read-only with ONLY the
task string.** They have no access to this conversation, the repo, or any files. So
**you must embed every piece of context the models need directly into the task** —
paste the relevant file excerpt, the RFC text, the diff, the constraints, the exact
question, and the desired output shape. A bare "review my design" will produce vague
answers; an embedded design + a pointed question produces the value.

- If invoked as `/fusion <task>`, use that text — but still enrich it with the
  necessary context from the conversation/repo before passing it to the script.
- If no task is given, ask what to fuse (one sentence), then assemble the task.
- Frame the question to demand a committed answer (e.g. "name the single biggest risk
  and one fix", "pick exactly one and justify") — fusion is sharpest when there's a
  decision to converge or diverge on.
- Keep the output budget generous enough to preserve breadth. If you want the full
  ensemble's coverage, ask for "the top 3 risks ranked", not "the single biggest" —
  a tight "single answer" cap discards the divergent findings fusion paid to generate.

## Reading the result

- **stdout** = the synthesized final answer. Relay it to the user.
- **stderr** = run telemetry. Always report the **judge signal**:
  - `CONVERGENT` — both judges agree the models reached the same bottom line → high
    confidence; present the answer plainly.
  - `DIVERGENT` — the models reached materially different conclusions → genuine
    disagreement; the synthesis surfaces it in one clause. **Flag this to the user**
    as lower-confidence / a real judgment call, not a settled answer.
  - `MIXED` / `PARTIAL` / `UNDETERMINED` — degraded signal; mention it.
- If any leg shows `TIMED OUT` or `exit=<nonzero>`, say so — the ensemble was smaller
  than intended, which weakens the result.

## Options

- `KEEP=1 ~/.claude/skills/fusion/fusion.sh "..."` — keep the run dir (printed on
  stderr) so you can read `panel.txt`, `judge_opus.txt`, `judge_gpt.txt` to show the
  user exactly where the models diverged and why.
- `LEG_TIMEOUT=180 ...` — per-leg wall-clock cap (default 240s).
- Pipe the task via stdin instead of an argument: `echo "task" | fusion.sh`.
- `FUSION_TAG=rfc ...` — tag the run with a short task-class (`rfc`, `bug`, `security`,
  `design`, …). **When you invoke /fusion, set FUSION_TAG to a one-word class for the
  task** — it makes the which-model-wins data sliceable and far more useful.
- `FUSION_NO_JOURNAL=1 ...` — skip journaling for this run.

## Journaling & stats

Every run appends one JSON line to `~/.local/share/tenet/fusion/journal.jsonl`
(machine-global, append-only — the worldengine reference-class philosophy). Each record
captures **which model each judge preferred** (the anonymized Response-# pick mapped
back to the real leg/model), the CONVERGENT/DIVERGENT signal, the tag, per-leg
reliability (exit / bytes / timed-out), and wall time. Journaling is best-effort — a
failure never affects the run.

Read it back with the companion reader (symlinked into the skill dir):
```
~/.claude/skills/fusion/stats.sh                  # win-rates, signal mix, leg reliability
FUSION_TAG=rfc ~/.claude/skills/fusion/stats.sh   # slice to one task-class
```
This is the "which vendor wins which task-class" signal for worldengine calibration; the
reliability table also surfaces a leg that's quietly failing (e.g. Gemini timing out on
capacity).

## Current panel (edit the `LEGS=` array in fusion.sh to change)

| Leg | Model | Subscription |
|-----|-------|--------------|
| opus | claude-opus-4-8 | Claude Max/Pro |
| sonnet | claude-sonnet-4-6 | Claude Max/Pro |
| gpt | gpt-5.5 (codex) | ChatGPT/Codex |
| gemini | gemini-2.5-flash | Google |

Judges: Opus + GPT-5.5. **3 vendors live** (Anthropic ×2, OpenAI, Google).

### Gemini capacity note
`gemini-2.5-pro` is frequently capacity-exhausted on the free/AI tier — the CLI then
retries with long backoffs and the leg hangs until `LEG_TIMEOUT`. The Gemini leg
therefore defaults to `gemini-2.5-flash` (high quota, still genuine Google-vendor
diversity). To use pro when you have capacity:
```
GEMINI_MODEL=gemini-2.5-pro ~/.claude/skills/fusion/fusion.sh "..."
```
The script auto-detects `gemini` on PATH; if it's ever uninstalled the panel silently
drops to 3 legs.

## Notes

- All auth is subscription-based; no API keys are read or required.
- Mirrors opencode-fusion's 3-phase structure and OpenRouter Fusion's judge taxonomy.
  Difference vs OpenRouter: the panel here has **no web access** (legs run read-only),
  so for current-facts questions, supply the facts in the task.
- macOS system-bash (3.2) safe; uses `timeout`/`gtimeout` if present.
