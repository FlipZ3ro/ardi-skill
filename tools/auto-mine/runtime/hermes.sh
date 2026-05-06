#!/usr/bin/env bash
# runtime/hermes.sh — invoke Hermes (NousResearch) with the ardi tick prompt.
#
# Hermes auto-loads any skill placed under ~/.hermes/skills/ — so as long
# as the user has installed ardi-skill there (the install.sh script links
# it), the agent can call `ardi-agent` directly via its terminal toolset.
#
# Requires:
#   - hermes binary on PATH
#   - ardi skill linked at ~/.hermes/skills/ardi/SKILL.md
#   - LLM API key configured in hermes config (provider-agnostic)

set -euo pipefail

PROMPT_FILE="${1:?usage: hermes.sh <prompt-file>}"
[[ -r "$PROMPT_FILE" ]] || { echo "prompt not readable: $PROMPT_FILE" >&2; exit 2; }

command -v hermes >/dev/null || { echo "hermes not on PATH" >&2; exit 3; }

# `chat -Q -q`: programmatic mode + one-shot query
# -s ardi: preload the ardi skill (auto-discovered from ~/.hermes/skills/ardi)
# --toolsets terminal,skills,web: terminal so it can run ardi-agent + curl,
#   skills so it can call sub-skills, web so the LLM can hit dictionary APIs
#   (dictionaryapi.dev / wiktionary) for word validation. Validation is the
#   single biggest accuracy lever for riddle solving — without it the agent
#   commits hallucinated words.
# Higher max-turns: solving 3 riddles with CoT + validation easily uses
#   20–30 tool calls. The old 30-turn cap (claude.sh) cut solves short.
PROMPT="$(cat "$PROMPT_FILE")"
exec hermes chat -Q -q "$PROMPT" \
  -s ardi \
  --toolsets terminal,skills,web \
  --max-turns 60
