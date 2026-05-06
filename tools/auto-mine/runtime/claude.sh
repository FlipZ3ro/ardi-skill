#!/usr/bin/env bash
# runtime/claude.sh — invoke Claude Code with the ardi mining tick prompt.
#
# Used by ardi-tick.sh when ARDI_AGENT_RUNTIME=claude (the default).
#
# Requires:
#   - claude binary on PATH (https://github.com/anthropics/claude-code)
#   - either ANTHROPIC_API_KEY in env, or `claude` already authed via OAuth
#
# Stdin: nothing.
# Stdout/stderr: passed through to journald via systemd.
# Exit: claude's exit code.

set -euo pipefail

PROMPT_FILE="${1:?usage: claude.sh <prompt-file>}"
[[ -r "$PROMPT_FILE" ]] || { echo "prompt not readable: $PROMPT_FILE" >&2; exit 2; }

command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 3; }

# --print: non-interactive one-shot
# --max-turns 30: hard cap on tool-use turns so a stuck loop can't burn
#   tokens forever (a healthy tick uses ~10 turns)
# Stream output so journald shows progress in real time.
mkdir -p "$HOME/.ardi-agent"

# Sonnet faster than Opus (~3-5x). For 90s commit window, we need speed.
# Override via env var if you want a different model:
#   export ARDI_CLAUDE_MODEL=claude-opus-4-7
MODEL="${ARDI_CLAUDE_MODEL:-claude-sonnet-4-6}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# Pipe stream-json through prettifier for human-readable log lines.
# Raw stream-json saved to .raw.log for debugging if needed.
RAW_LOG="$HOME/Library/Logs/ardi-mine.raw.log"

claude \
  --print \
  --max-turns 25 \
  --model "$MODEL" \
  --dangerously-skip-permissions \
  --add-dir "$HOME/.ardi-agent" \
  --output-format stream-json \
  --verbose \
  < "$PROMPT_FILE" \
  | tee -a "$RAW_LOG" \
  | python3 "$HERE/log-prettifier.py"
