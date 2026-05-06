#!/usr/bin/env python3
"""log-prettifier.py — convert claude stream-json (stdin) to MINIMAL readable log.

Only shows essential events:
- 🟢 epoch open / 🔴 epoch close
- 💬 brief decisions
- ▶ commit/reveal/inscribe attempts (with tx + status)
- 🏆 wins / 💀 losses
- 🏁 tick summary

Hides: thinking blocks, raw JSON dumps, intermediate file reads.
"""

import json
import re
import sys
from datetime import datetime


def ts():
    return datetime.now().strftime("%H:%M:%S")


def short(s, n=120):
    s = str(s).replace("\n", " ").strip()
    s = re.sub(r"\s+", " ", s)
    return s if len(s) <= n else s[: n - 1] + "…"


def emit(line):
    print(line, flush=True)


# Regex extractors for ardi-agent output
RE_COMMIT_TX = re.compile(r'tx confirmed (0x[a-f0-9]+)')
RE_COMMIT_HASH = re.compile(r'commit:\s*epoch=(\d+)\s+word=(\d+)\s+hash=0x[a-f0-9]+')
RE_REVEAL_TX = re.compile(r'reveal:\s*tx confirmed\s+(0x[a-f0-9]+)')
RE_INSCRIBE_TX = re.compile(r'inscribe:\s*tx confirmed\s+(0x[a-f0-9]+)|token_id[":\s]+(\d+)')
RE_WINNER = re.compile(r'winner is (0x[a-f0-9]+)')
RE_VRF_PENDING = re.compile(r'VRF pending')
RE_LUCK_NEXT = re.compile(r'Better luck next time')
RE_NO_OPEN = re.compile(r'NO_OPEN_EPOCH|commit window for this cycle has closed')
RE_INSUF_STAKE = re.compile(r'InsufficientStake|NOT_STAKED')
RE_ALREADY = re.compile(r'ALREADY_COMMITTED')

# Track last commit args (so we can pair tx result with answer)
last_commit_args = None  # (word_id, answer)
last_reveal_args = None
last_inscribe_args = None

RE_COMMIT_ARGS = re.compile(r'ardi-agent commit\s+(?:--epoch\s+(\d+)\s+)?--word-id\s+(\d+)\s+--answer\s+"?([^"\s]+)"?')
RE_REVEAL_ARGS = re.compile(r'ardi-agent reveal\s+--epoch\s+(\d+)\s+--word-id\s+(\d+)')
RE_INSCRIBE_ARGS = re.compile(r'ardi-agent inscribe\s+--epoch\s+(\d+)\s+--word-id\s+(\d+)')

# Skip these noisy patterns in 💬 text
SKIP_TEXT_PATTERNS = [
    r'^Let me',
    r'^Now ',
    r'^Looking at',
    r'^I need to',
    r'^Checking',
    r'^Reading',
]


def text_is_useful(text):
    """Filter out short/transitional text."""
    text = text.strip()
    if len(text) < 20:
        return False
    if any(re.match(p, text) for p in SKIP_TEXT_PATTERNS):
        # Allow if it contains specific keywords
        if not re.search(r'commit|reveal|epoch|skip|win|legendary|rare', text, re.I):
            return False
    return True


for raw_line in sys.stdin:
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    try:
        obj = json.loads(raw_line)
    except json.JSONDecodeError:
        # Pass through tick: ... lines from ardi-tick.sh
        if raw_line.startswith("[") and "tick:" in raw_line:
            # Reformat: "[2026-05-06T05:38:07Z] tick: spawning claude..."
            m = re.match(r'\[(\S+)\]\s+tick:\s+(.+)', raw_line)
            if m:
                msg = m.group(2)
                if "spawning claude" in msg:
                    rem = re.search(r'\((\d+)s remaining\)', msg)
                    rem_str = f" ({rem.group(1)}s left)" if rem else ""
                    emit(f"[{ts()}] 🟢 epoch open — spawning Claude{rem_str}")
                elif "no work" in msg:
                    pass  # silent — too noisy
                elif "FATAL" in msg:
                    emit(f"[{ts()}] 💥 {msg}")
                else:
                    emit(f"[{ts()}] · {msg}")
        continue

    if not isinstance(obj, dict):
        continue

    msg_type = obj.get("type")

    # System init
    if msg_type == "system" and obj.get("subtype") == "init":
        model = obj.get("model", "?")
        # Just confirm model on the same line as "epoch open"
        emit(f"           └─ model={model}")
        continue

    # Assistant blocks: tool_use + text
    if msg_type == "assistant":
        msg = obj.get("message", {})
        content = msg.get("content", [])
        if not isinstance(content, list):
            continue

        for block in content:
            if not isinstance(block, dict):
                continue
            t = block.get("type")

            # Thinking blocks: SKIP entirely
            if t == "thinking":
                continue

            # Text: only show if useful
            if t == "text":
                txt = block.get("text", "").strip()
                if txt and text_is_useful(txt):
                    emit(f"[{ts()}] 💬 {short(txt, 200)}")
                continue

            # Tool use: only show ardi-agent commands
            if t == "tool_use":
                name = block.get("name", "")
                inp = block.get("input", {})
                if name != "Bash":
                    continue
                cmd = inp.get("command", "")

                m = RE_COMMIT_ARGS.search(cmd)
                if m:
                    epoch_n = m.group(1) or "?"
                    word_id = m.group(2)
                    answer = m.group(3)
                    last_commit_args = (epoch_n, word_id, answer)
                    emit(f"[{ts()}] ▶ commit ep={epoch_n} word={word_id} → \"{answer}\"")
                    continue

                m = RE_REVEAL_ARGS.search(cmd)
                if m:
                    last_reveal_args = (m.group(1), m.group(2))
                    emit(f"[{ts()}] ▶ reveal ep={m.group(1)} word={m.group(2)}")
                    continue

                m = RE_INSCRIBE_ARGS.search(cmd)
                if m:
                    last_inscribe_args = (m.group(1), m.group(2))
                    emit(f"[{ts()}] ▶ inscribe ep={m.group(1)} word={m.group(2)}")
                    continue

                # Other ardi-agent commands: silent (context, commits, gas, etc.)
                continue
        continue

    # Tool results
    if msg_type == "user":
        msg = obj.get("message", {})
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_result":
                continue
            body = block.get("content", "")
            if isinstance(body, list):
                body = " ".join(b.get("text", "") for b in body if isinstance(b, dict))
            body = str(body)
            is_err = block.get("is_error", False)

            # Detect specific success patterns
            tx_match = RE_COMMIT_TX.search(body)
            winner_match = RE_WINNER.search(body)
            vrf_pending = RE_VRF_PENDING.search(body)
            luck_next = RE_LUCK_NEXT.search(body)
            no_open = RE_NO_OPEN.search(body)
            insuf_stake = RE_INSUF_STAKE.search(body)
            already = RE_ALREADY.search(body)

            if tx_match:
                tx = tx_match.group(1)
                tx_short = tx[:8] + "..." + tx[-6:]
                emit(f"[{ts()}]   ✅ tx {tx_short} confirmed")
            elif winner_match:
                emit(f"[{ts()}]   💀 LOST — winner: {winner_match.group(1)[:10]}...")
            elif vrf_pending:
                emit(f"[{ts()}]   ⏳ VRF pending — retry in 60s")
            elif luck_next:
                emit(f"[{ts()}]   💀 LOST VRF")
            elif no_open:
                emit(f"[{ts()}]   ❌ epoch closed mid-tx")
            elif insuf_stake:
                emit(f"[{ts()}]   💥 INSUFFICIENT STAKE — fix wallet")
            elif already:
                emit(f"[{ts()}]   ⚠️  already committed (skip)")
            elif is_err:
                # Show short error
                emit(f"[{ts()}]   ✗ {short(body, 150)}")
            elif 'token_id' in body and 'inscribed' in body.lower():
                # NFT mint!
                m = re.search(r'token_id["\s:]+(\d+)', body)
                if m:
                    emit(f"[{ts()}]   🏆 NFT MINTED! token_id={m.group(1)} 🎉🎉🎉")
            # else silent (don't show every cat/jq output)
        continue

    # Final result
    if msg_type == "result":
        cost = obj.get("total_cost_usd", 0)
        dur = obj.get("duration_ms", 0) / 1000
        is_err = obj.get("is_error", False)
        result = obj.get("result", "")

        marker = "❌" if is_err else "✅"
        emit(f"[{ts()}] 🏁{marker} tick done · ${cost:.2f} · {dur:.0f}s")

        # Summarize result line
        result_first = str(result).split('\n')[0].strip() if result else ""
        # Find the tick: ... line if present
        tick_summary = re.search(r'tick:\s*([^\n]+)', str(result))
        if tick_summary:
            summary = short(tick_summary.group(1), 200)
            emit(f"           {summary}")
        elif result_first:
            emit(f"           {short(result_first, 200)}")
        emit("")
        continue
