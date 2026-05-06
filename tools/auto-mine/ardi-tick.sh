#!/usr/bin/env bash
# ardi-tick.sh — Ardi mining tick dispatcher.
#
# Called every 60-90s by systemd timer (see systemd/ardi-mine.timer).
# Workflow:
#   1. Cheap precheck: is there anything actionable on chain or in local
#      pending state? If not, exit 0.
#   2. Pick the configured runtime (claude / hermes / openclaw-scripted).
#   3. Spawn the subagent with our shared prompt.
#   4. Subagent runs one mining tick and exits.
#
# Idempotent: skill-side state dedups commits + reveals.

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${ARDI_AGENT_RUNTIME:-claude}"   # claude | hermes | openclaw
PROMPT="$HERE/prompt/ardi-mine-tick.md"
ARDI_AGENT="${ARDI_AGENT_BIN:-ardi-agent}"
SERVER="${ARDI_SERVER:-}"
MIN_COMMIT_BUFFER="${ARDI_MIN_COMMIT_BUFFER:-120}"   # seconds; Claude takes ~150s for solve+commit. Skip spawn if window too short.

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "[$(ts)] tick: $*"; }

# ── Sanity checks ───────────────────────────────────────────────────
command -v "$ARDI_AGENT" >/dev/null || {
  log "FATAL: $ARDI_AGENT not on PATH"
  exit 64
}
[[ -r "$PROMPT" ]] || {
  log "FATAL: prompt missing at $PROMPT"
  exit 65
}

RUNTIME_SH="$HERE/runtime/${RUNTIME}.sh"
[[ -x "$RUNTIME_SH" ]] || {
  log "FATAL: unknown runtime '$RUNTIME' (expected: claude | hermes | openclaw-scripted)"
  exit 66
}

# jq is required for robust JSON parsing — fall back to grep/sed only if absent.
HAVE_JQ=0
command -v jq >/dev/null && HAVE_JQ=1

# ── Cheap precheck: is there anything to do? ────────────────────────
SERVER_ARG=()
[[ -n "$SERVER" ]] && SERVER_ARG+=(--server "$SERVER")
# Bash strict-mode workaround: ${arr[@]} on empty array errors under `set -u`
# in older bash. Use ${arr[@]+"${arr[@]}"} idiom for safe expansion.

need_to_run="no"
reason=""
now="$(date +%s)"

# (a) check current epoch — open commit window with enough buffer
if ctx="$($ARDI_AGENT ${SERVER_ARG[@]+"${SERVER_ARG[@]}"} context 2>/dev/null)"; then
  if [[ "$HAVE_JQ" -eq 1 ]]; then
    deadline="$(echo "$ctx" | jq -r '.data.commitDeadline // .commit_deadline // .data.commit_deadline // .epoch.commit_deadline // empty' 2>/dev/null || true)"
  else
    deadline="$(echo "$ctx" | sed -nE 's/.*"commit[Dd]eadline"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
  fi
  if [[ -n "${deadline:-}" && "$deadline" =~ ^[0-9]+$ ]]; then
    remaining=$((deadline - now))
    if (( remaining > MIN_COMMIT_BUFFER )); then
      need_to_run="yes"
      reason="commit window open (${remaining}s remaining)"
    elif (( remaining > 0 )); then
      log "commit window closing in ${remaining}s — under buffer (${MIN_COMMIT_BUFFER}s); skipping commit-side"
    fi
  fi
fi

# (b) check local pending commits — drives reveal / inscribe
if [[ "$need_to_run" == "no" ]]; then
  if commits="$($ARDI_AGENT ${SERVER_ARG[@]+"${SERVER_ARG[@]}"} commits 2>/dev/null)"; then
    if [[ "$HAVE_JQ" -eq 1 ]]; then
      # ardi-agent commits returns {data: {pending: [...]}}, not a flat array
      pending="$(echo "$commits" | jq '[(.data.pending // .)[] | select(.status=="committed" or .status=="revealed" or .status=="won")] | length' 2>/dev/null || echo 0)"
    else
      pending="$(echo "$commits" | grep -cE '"status"[[:space:]]*:[[:space:]]*"(committed|revealed|won)"' || true)"
    fi
    if [[ "${pending:-0}" -gt 0 ]]; then
      need_to_run="yes"
      reason="$pending pending entries to drive forward"
    fi
  fi
fi

if [[ "$need_to_run" == "no" ]]; then
  log "no work — skipping (no open commit window, no pending state)"
  exit 0
fi

# ── Spawn subagent ──────────────────────────────────────────────────
log "spawning $RUNTIME — $reason"
exec "$RUNTIME_SH" "$PROMPT"
