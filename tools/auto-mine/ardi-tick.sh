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
MIN_COMMIT_BUFFER="${ARDI_MIN_COMMIT_BUFFER:-30}"   # seconds; need ≥30s to commit safely

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
[[ -n "$SERVER" ]] && SERVER_ARG=(--server "$SERVER")

need_to_run="no"
reason=""
now="$(date +%s)"

# (a) check current epoch — open commit window with enough buffer
if ctx="$($ARDI_AGENT "${SERVER_ARG[@]}" context 2>/dev/null)"; then
  if [[ "$HAVE_JQ" -eq 1 ]]; then
    deadline="$(echo "$ctx" | jq -r '.commit_deadline // .epoch.commit_deadline // empty' 2>/dev/null || true)"
  else
    deadline="$(echo "$ctx" | sed -nE 's/.*"commit_deadline"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
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
  if commits="$($ARDI_AGENT "${SERVER_ARG[@]}" commits 2>/dev/null)"; then
    if [[ "$HAVE_JQ" -eq 1 ]]; then
      pending="$(echo "$commits" | jq '[.[] | select(.status=="committed" or .status=="revealed" or .status=="won")] | length' 2>/dev/null || echo 0)"
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
