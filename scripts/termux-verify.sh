#!/usr/bin/env bash
# termux-verify.sh — post-repair verification for OpenClaw on Termux.
#
# Automated gates (PASS/FAIL) + an explicit MANUAL section for real Discord
# message tests. This script never claims end-to-end success by itself:
# a listening port is not a working bot. Only a Discord reply is.
#
# Usage:  bash termux-verify.sh
# Exit code = number of failed AUTOMATED gates (0 = all automated gates pass).

set -u
set +x
umask 077

FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
note() { echo "NOTE  $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# CLI output is echoed for evidence; run it through the same redaction as the
# diagnostic collector so this output stays shareable.
redact() {
  sed -E \
    -e 's/(Authorization:[[:space:]]*(Bot|Bearer))[[:space:]]+[^[:space:]"]+/\1 [REDACTED]/gI' \
    -e 's/([Tt]oken|[Ss]ecret|[Pp]assword|[Aa]pi[_-]?[Kk]ey)(["'"'"' ]*[:=]["'"'"' ]*)[^",} ]+/\1\2[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]+)[A-Za-z0-9_.-]{12,}/\1[REDACTED]/g' \
    -e 's/AIza[0-9A-Za-z_-]{10,}/[REDACTED-GOOGLE-KEY]/g' \
    -e 's/sk-(ant-)?[A-Za-z0-9_-]{10,}/[REDACTED-KEY]/g' \
    -e 's/[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{16,}/[REDACTED-DOTTED-TOKEN]/g' \
    -e 's/\b[0-9a-f]{48,}\b/[REDACTED-LONG-HEX]/g'
}

echo "OpenClaw post-repair verification — $(date)"
echo

# --- Gate 1: CLI present + config valid -----------------------------------
if have OpenClaw; then
  pass "OpenClaw CLI available: $(command -v OpenClaw)"
else
  fail "OpenClaw CLI not in PATH in this shell (wrong environment? proot vs native)"
  echo; echo "Automated gates failed: $FAILS"; exit "$FAILS"
fi

if timeout 60 OpenClaw config validate >/tmp/.oc-validate.$$ 2>&1; then
  pass "config validate"
else
  fail "config validate — output:"; redact < /tmp/.oc-validate.$$ | sed 's/^/      /' | head -n 30
fi
rm -f /tmp/.oc-validate.$$

# --- Gate 2: Gemini-primary routing preserved (model names are not secrets) -
MODEL="$(timeout 30 OpenClaw config get agents.defaults.model 2>/dev/null | head -c 400)"
echo "      agents.defaults.model = ${MODEL:-<unreadable>}"
case "$MODEL" in
  *gemini*|*google*) pass "primary model still Gemini/Google routing" ;;
  *) fail "primary model does NOT look Gemini-primary — compare against your pre-repair backup manifest" ;;
esac

# --- Gate 3: agents preserved ----------------------------------------------
AGENTS="$(timeout 30 OpenClaw config get agents.entries 2>/dev/null | head -c 2000)"
if [ -n "$AGENTS" ] && [ "$AGENTS" != "{}" ]; then
  note "agent entries readable — diff the ID list against your backup to prove preservation:"
  printf '%s' "$AGENTS" | grep -oE '"[A-Za-z0-9_-]+"[[:space:]]*:' | head -n 20 | sed 's/^/      /' || true
else
  note "agents.entries unreadable via CLI here (older schema may use agents.list) — confirm in config diff."
fi

# --- Gate 4: gateway process + port + HTTP probe ----------------------------
PORT="$(timeout 30 OpenClaw config get gateway.port 2>/dev/null | tr -dc '0-9')"; PORT="${PORT:-18789}"
if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -qE ":$PORT\b"; then
  pass "something is listening on port $PORT"
else
  fail "nothing listening on port $PORT — gateway not running (start it in tmux, keep wake-lock)"
fi
if have curl; then
  CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
  case "$CODE" in
    200|301|302|401|403) pass "gateway HTTP responds on 127.0.0.1:$PORT (code $CODE; 401 here can be NORMAL auth)" ;;
    *) fail "gateway HTTP probe code=${CODE:-none}" ;;
  esac
fi
timeout 60 OpenClaw gateway status 2>&1 | redact | sed 's/^/      /' | head -n 25

# --- Gate 5: channels (both Discord bots) ------------------------------------
echo
note "Channel report (look for BOTH Discord accounts connected, distinct bot users):"
timeout 90 OpenClaw channels status 2>&1 | redact | sed 's/^/      /' | head -n 60
note "If your version lacks 'channels status', use 'OpenClaw channels list' + startup logs."

# --- Gate 6: doctor (read-only) ----------------------------------------------
echo
if timeout 120 OpenClaw doctor >/tmp/.oc-doctor.$$ 2>&1; then
  pass "doctor completed without fatal complaint (read its warnings below)"
else
  note "doctor exited non-zero — read output; warnings are not automatically failures:"
fi
redact < /tmp/.oc-doctor.$$ | sed 's/^/      /' | tail -n 40
rm -f /tmp/.oc-doctor.$$

echo
echo "Automated gates failed: $FAILS"
echo
cat <<'EOF'
===== MANUAL GATES — nothing above substitutes for these =====
M1. DM the PRIMARY bot in Discord:  "ping — reply with the word ok"
    [ ] visible reply received   time: ______   latency: ______
M2. In your test server channel, @-mention the PRIMARY bot with a question.
    [ ] reply received in-channel   time: ______
M3. Repeat M1/M2 for the AUTOMATION bot (its own account/agent).
    [ ] reply received   time: ______   correct agent/persona? ______
M4. While sending M1–M3, watch live logs (tmux session or `OpenClaw logs --follow`
    if your build supports it): each message should produce inbound + model +
    outbound lines, with NO 401s. Note the timestamp correlation.
M5. Soak: lock the phone screen, wait 15 minutes, repeat M1. This catches
    Android battery/phantom-process kills that a 2-minute test misses.

Only when M1–M5 pass is the repair "verified". Until then it is "gateway up".
EOF
exit "$FAILS"
