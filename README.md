# fusion — subscription-backed multi-model fusion

A Claude Code skill that fans a high-stakes question out to several **native,
subscription-authenticated** model CLIs in parallel, has **two cross-vendor judges**
(Claude Opus + GPT-5.5) each pick a preferred answer and rule the panel
`CONVERGENT`/`DIVERGENT`, then synthesizes one best answer on Claude Opus.

No API keys — every leg runs through a subscription CLI (`claude -p`, `codex exec`,
`gemini -p`). Mirrors the 3-phase structure of opencode-fusion and OpenRouter Fusion's
judge taxonomy, run entirely locally.

## Contents

| File | What it is |
|------|------------|
| `SKILL.md`  | The Claude Code skill definition (when/how to use, options, reading the result) |
| `fusion.sh` | The fan-out → dual-judge → synthesize engine (bash 3.2 safe) |
| `stats.sh`  | Reads the append-only journal: win-rates, signal mix, leg reliability |

## Install

This repo *is* the skill folder. Drop it into your Claude Code skills dir:

```bash
git clone git@github.com:ckrohg/fusion-skill.git ~/.claude/skills/fusion
chmod +x ~/.claude/skills/fusion/*.sh
```

Then invoke with `/fusion <task>` in Claude Code, or run the engine directly:

```bash
~/.claude/skills/fusion/fusion.sh "<the full, self-contained task>"
```

The legs run **headless and read-only with only the task string** — no repo, file, or
conversation access — so embed every piece of context the models need directly into the
task. See `SKILL.md` for the full contract, options (`KEEP`, `LEG_TIMEOUT`,
`FUSION_TAG`, `GEMINI_MODEL`, …), and how to read the `CONVERGENT`/`DIVERGENT` signal.

## Panel

| Leg | Model | Subscription |
|-----|-------|--------------|
| opus   | claude-opus-4-8     | Claude Max/Pro |
| sonnet | claude-sonnet-4-6   | Claude Max/Pro |
| gpt    | gpt-5.5 (codex)     | ChatGPT/Codex  |
| gemini | gemini-2.5-flash    | Google         |

Judges: Opus + GPT-5.5. Edit the `LEGS=` array in `fusion.sh` to change the panel.
The `gemini` leg is auto-detected on `PATH`; if absent the panel drops to 3 legs.

## Journal

Every run appends one JSON line to `~/.local/share/tenet/fusion/journal.jsonl`
(machine-global, append-only) recording which model each judge preferred, the
convergence signal, the tag, and per-leg reliability. `stats.sh` summarizes it.

## Source of truth & keeping this repo in sync

This repo is a **manual mirror**. The canonical files live elsewhere:

- `fusion.sh`, `stats.sh` → `tenet-master/fusion/` (the live tenet project; the
  `~/.claude/skills/fusion/` skill dir only *symlinks* to these, so editing tenet
  updates the live `/fusion` skill automatically)
- `SKILL.md` → `~/.claude/skills/fusion/` (a real file; `tenet/fusion` has none)

Edits to those sources do **not** auto-propagate here. Run [`sync.sh`](sync.sh) to pull
them in, review the diff, and commit + push in one step:

```bash
./sync.sh             # pull canonical files, show diff, commit + push
./sync.sh --check     # dry run: report drift only (exit 1 if out of sync) — verify anytime
./sync.sh --no-push   # commit locally, don't push
```

Source dirs are overridable on other machines via `FUSION_TENET_DIR` /
`FUSION_SKILL_DIR`.
