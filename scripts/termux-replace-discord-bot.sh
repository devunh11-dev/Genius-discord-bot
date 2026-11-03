#!/usr/bin/env bash
# termux-replace-discord-bot.sh — safely install a NEW Discord bot token
# (or a whole replacement bot) into an existing OpenClaw account slot on Termux.
#
# WHAT THIS DOES
#   1. Preflight: OpenClaw present, config resolves and ALREADY validates
#      (fix config errors first; this is not a config-repair tool).
#   2. Takes a verified backup (scripts/termux-backup.sh if present, else an
#      inline equivalent). Aborts if the backup fails.
#   3. Prompts for the new token with echo OFF (twice). The token is never
#      printed, never passed as a command-line argument, never written to any
#      file except ~/.OpenClaw/.env (mode 600). Only its SHA-256 fingerprint
#      (10 hex chars) is ever shown.
#   4. LIVE-CHECKS the token against Discord (GET /users/@me + /applications/@me)
#      BEFORE changing anything. HTTP 401 -> abort, nothing modified.
#   5. Guards: same-as-current token -> abort; token already used by the OTHER
#      bot (duplicate fingerprint in .env) -> abort; applicationId mismatch
#      for this account slot -> abort unless you pass --new-bot.
#   6. Writes the token into ~/.OpenClaw/.env under a per-account env var and
#      points the config at it with an env SecretRef via
#      `OpenClaw config patch --dry-run` (shown for approval) then for real.
#      The token VALUE never enters OpenClaw.json.
#   7. Re-validates config and confirms agents.defaults.model is unchanged
#      (Gemini-primary preservation). On any failure: auto-rollback of
#      config + .env from the step-2 backup.
#   8. Does NOT restart the gateway (on Termux you own the tmux foreground
#      process) — it prints the exact next steps, incl. re-invite/intents
#      checklist when --new-bot is used.
#
# YOU must create the token yourself in the Discord Developer Portal
# (Bot -> Reset Token, or a New Application for a replacement bot).
# Resetting a token kills the old one IMMEDIATELY — do the portal reset and
# this script in one sitting. Never paste the token into chat.
#
# USAGE
#   Token-only (normal 401 fix):
#     bash termux-replace-discord-bot.sh --account default
#     bash termux-replace-discord-bot.sh --account automation
#   Whole new bot in the same account slot (keeps agent binding/routing):
#     bash termux-replace-discord-bot.sh --account default --new-bot
#   Options:
#     --env-var NAME     env var to store token in (default: DISCORD_BOT_TOKEN
#                        for account "default", else DISCORD_<ACCOUNT>_TOKEN)
#     --yes              skip the final approval prompt (backup still mandatory)
#   Env knobs (testing only):
#     REPLACE_NO_NETWORK=1    skip live Discord check (LOUD warning; the 401
#                             protection is then OFF — do not use on the phone)

set -u
set +x
umask 077

ACCOUNT="default"
ENV_VAR=""
NEW_BOT=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --account) ACCOUNT="${2:?--account needs a value}"; shift 2 ;;
    --env-var) ENV_VAR="${2:?--env-var needs a value}"; shift 2 ;;
    --new-bot) NEW_BOT=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

case "$ACCOUNT" in *[!A-Za-z0-9_-]*|"") echo "ERROR: account id must be [A-Za-z0-9_-]+" >&2; exit 2 ;; esac
if [ -z "$ENV_VAR" ]; then
  if [ "$ACCOUNT" = "default" ]; then ENV_VAR="DISCORD_BOT_TOKEN"
  else
    up="$(printf %s "$ACCOUNT" | tr '[:lower:]-' '[:upper:]_')"
    ENV_VAR="DISCORD_${up}_TOKEN"
  fi
fi
case "$ENV_VAR" in *[!A-Za-z0-9_]*|"") echo "ERROR: bad env var name: $ENV_VAR" >&2; exit 2 ;; esac

die() { echo "ABORT: $*" >&2; cleanup_secrets; exit 1; }
cleanup_secrets() { unset NEW_TOKEN NEW_TOKEN2 2>/dev/null || true; }
have() { command -v "$1" >/dev/null 2>&1; }
fp10() { printf %s "$1" | (sha256sum 2>/dev/null || python3 -c 'import sys,hashlib;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') | cut -c1-10; }

echo "== OpenClaw Discord bot/token replacement =="
echo "Account slot : $ACCOUNT   (agent binding for this slot is preserved)"
echo "Token stored : ~/.OpenClaw/.env var $ENV_VAR (config gets a SecretRef, not the value)"
[ "$NEW_BOT" = 1 ] && echo "Mode         : NEW BOT (new application allowed; you must re-invite it)" \
                   || echo "Mode         : token-only (same bot application expected)"
echo

# ---------- 1. Preflight ----------
have OpenClaw || die "OpenClaw CLI not in PATH in this shell. Run inside the environment that runs OpenClaw (proot vs native Termux)."
have python3  || die "python3 not found (needed for token handling without shell exposure)."
CFG="$(timeout 30 OpenClaw config file 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
[ -n "$CFG" ] && [ -f "$CFG" ] || CFG="$HOME/.OpenClaw/OpenClaw.json"
[ -f "$CFG" ] || die "config file not found (tried CLI resolution and $HOME/.OpenClaw/OpenClaw.json)"
StateDir="$(dirname "$CFG")"
ENV_FILE="$StateDir/.env"
echo "Config: $CFG"
timeout 60 OpenClaw config validate >/dev/null 2>&1 \
  || die "current config does NOT validate. Fix config errors first (run termux-diagnose.sh) — token replacement on a broken config is the wrong order."
MODEL_BEFORE="$(timeout 30 OpenClaw config get agents.defaults.model 2>/dev/null | head -c 400)"
echo "Model routing before: ${MODEL_BEFORE:-<unreadable>}"

# Where does this account live in config? (top-level for single/default bot,
# accounts.<id> for multi-bot) + its configured applicationId, if any.
read -r TARGET EXISTING_APP_ID <<EOF
$(CFG="$CFG" ACCOUNT="$ACCOUNT" python3 - <<'PY'
import json, os, re
raw = open(os.environ["CFG"], encoding="utf-8", errors="replace").read()
try: cfg = json.loads(raw)
except Exception:
    t = re.sub(r"//[^\n]*", "", raw); t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r",(\s*[}\]])", r"\1", t)
    try: cfg = json.loads(t)
    except Exception: cfg = {}
disc = ((cfg.get("channels") or {}).get("discord") or {})
acct = os.environ["ACCOUNT"]
accts = disc.get("accounts") or {}
if isinstance(accts, dict) and acct in accts:
    print("accounts", accts.get(acct, {}).get("applicationId") or disc.get("applicationId") or "-")
elif acct in ("default",):
    print("top", disc.get("applicationId") or "-")
else:
    print("accounts-new", "-")
PY
)
EOF
[ "$TARGET" = "accounts-new" ] && [ "$NEW_BOT" != 1 ] \
  && die "account '$ACCOUNT' does not exist in config. Creating a brand-new account slot also needs an agent binding — that is new setup, not replacement. Re-run with --new-bot only if you understand you must add routing afterwards (see runbook), or check the account id spelling with: OpenClaw channels list"
echo "Config target: $TARGET   configured applicationId: ${EXISTING_APP_ID}"

# ---------- 2. Backup (mandatory gate) ----------
echo
echo "-- Backup first (nothing proceeds without it) --"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
BACKUP_DIR=""
if [ -f "$SCRIPT_DIR/termux-backup.sh" ]; then
  bout="$(bash "$SCRIPT_DIR/termux-backup.sh" 2>&1)" || die "backup script failed. Output:\n$bout"
  BACKUP_DIR="$(printf %s "$bout" | sed -n 's/^Backup complete: //p' | tail -n 1)"
fi
if [ -z "$BACKUP_DIR" ] || [ ! -f "$BACKUP_DIR/OpenClaw.json" ]; then
  BACKUP_DIR="$HOME/OpenClaw-backups/pre-token-replace-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || die "cannot create backup dir"
  cp -p "$CFG" "$BACKUP_DIR/OpenClaw.json" || die "inline backup copy failed"
  [ -f "$ENV_FILE" ] && cp -p "$ENV_FILE" "$BACKUP_DIR/.env"
  chmod 600 "$BACKUP_DIR"/* "$BACKUP_DIR"/.env 2>/dev/null || true
fi
echo "Backup: $BACKUP_DIR"

rollback() {
  echo "ROLLBACK: restoring config + .env from $BACKUP_DIR" >&2
  cp -p "$BACKUP_DIR/OpenClaw.json" "$CFG" 2>/dev/null || echo "  ! config restore failed — restore manually from backup" >&2
  if [ -f "$BACKUP_DIR/.env" ]; then cp -p "$BACKUP_DIR/.env" "$ENV_FILE" 2>/dev/null; else rm -f "$ENV_FILE" 2>/dev/null; fi
  timeout 60 OpenClaw config validate >/dev/null 2>&1 && echo "  rollback config validates." >&2 \
    || echo "  ! rollback config still invalid — use $BACKUP_DIR/RESTORE.md if present" >&2
}

# ---------- 3. Hidden token prompt ----------
echo
echo "Paste the NEW bot token at the hidden prompt (input will not echo;"
echo "it is stored only in $ENV_FILE). Paste ONLY the token, no quotes."
[ -t 0 ] || echo "WARNING: stdin is not a terminal — prefer running interactively so the paste cannot be captured by whatever feeds stdin."
printf "New token: " >&2; IFS= read -r -s NEW_TOKEN; echo >&2
printf "Again    : " >&2; IFS= read -r -s NEW_TOKEN2; echo >&2
[ "$NEW_TOKEN" = "$NEW_TOKEN2" ] || die "the two pastes differ. Nothing was changed."
NEW_TOKEN2=""
# Normalise the classic paste accidents (these CAUSE 401s when stored raw).
NEW_TOKEN="$(printf %s "$NEW_TOKEN" | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//; s/^Bot[[:space:]]+//')"
[ -n "$NEW_TOKEN" ] || die "empty token."
case "$NEW_TOKEN" in *"***"*|*" "...*) die "that looks like a placeholder, not a token." ;; esac
NEW_FP="$(fp10 "$NEW_TOKEN")"
echo "Token received: len=${#NEW_TOKEN} sha256-fingerprint=$NEW_FP segments=$(printf %s "$NEW_TOKEN" | awk -F. '{print NF}')"
if [ "${#NEW_TOKEN}" -lt 50 ]; then echo "WARNING: unusually short for a Discord bot token — did you paste the Client Secret or a truncated value? The live check decides."; fi

# ---------- 4. Guards: duplicate / already-current ----------
if [ -f "$ENV_FILE" ]; then
  dup_label="$(ENV_FILE="$ENV_FILE" NEW_FP="$NEW_FP" SELF_VAR="$ENV_VAR" python3 - <<'PY'
import hashlib, os
target = os.environ["NEW_FP"]; self_var = os.environ["SELF_VAR"]
same_self = ""
for line in open(os.environ["ENV_FILE"], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line: continue
    k, v = line.split("=", 1); v = v.strip().strip('"').strip("'")
    if hashlib.sha256(v.encode()).hexdigest()[:10] != target: continue
    if k.strip() == self_var: same_self = "SELF"
    elif "DISCORD" in k and "TOKEN" in k: print(k.strip()); break
else:
    if same_self: print("SELF")
PY
)"
  [ "$dup_label" = "SELF" ] && die "this exact token is already stored in $ENV_VAR (same fingerprint). Nothing to replace — your 401 is elsewhere (wrong environment/account, or gateway not restarted since). Run termux-diagnose.sh."
  [ -n "$dup_label" ] && die "this token is already used by $dup_label in .env. Installing it here would duplicate one bot into two slots (OpenClaw then runs only one monitor). You probably copied the OTHER bot's token. Nothing changed."
fi

# ---------- 5. Live Discord verification BEFORE any write ----------
echo
APP_ID=""; BOT_DESC=""
if [ "${REPLACE_NO_NETWORK:-0}" = "1" ]; then
  echo "WARNING: REPLACE_NO_NETWORK=1 — live Discord verification SKIPPED."
  echo "         A bad token will only be discovered after gateway restart."
else
  echo "-- Live-checking token against Discord (no change made yet) --"
  live="$(TOKEN_IN="$NEW_TOKEN" python3 - <<'PY'
import json, os, urllib.request, urllib.error
tok = os.environ["TOKEN_IN"]
def get(path):
    req = urllib.request.Request("https://discord.com/api/v10" + path,
        headers={"Authorization": f"Bot {tok}", "User-Agent": "DiscordBot (OpenClaw-replace, 1.0)"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, json.loads(r.read().decode("utf-8", "replace"))
try:
    s, me = get("/users/@me")
    print("HTTP=200")
    print(f"BOT_ID={me.get('id','')}")
    print(f"BOT_NAME={me.get('username','')}")
    try:
        _, app = get("/applications/@me")
        print(f"APP_ID={app.get('id','')}")
        print(f"APP_NAME={app.get('name','')}")
    except Exception:
        print("APP_ID=")
except urllib.error.HTTPError as e:
    try: d = json.loads(e.read().decode("utf-8", "replace"))
    except Exception: d = {}
    print(f"HTTP={e.code}"); print(f"ERR={d.get('message','')}")
except Exception as ex:
    print("HTTP=NETERR"); print(f"ERR={type(ex).__name__}: {ex}")
PY
)"
  http="$(printf %s "$live" | sed -n 's/^HTTP=//p')"
  case "$http" in
    200)
      bot_id="$(printf %s "$live" | sed -n 's/^BOT_ID=//p')"
      bot_name="$(printf %s "$live" | sed -n 's/^BOT_NAME=//p')"
      APP_ID="$(printf %s "$live" | sed -n 's/^APP_ID=//p')"
      app_name="$(printf %s "$live" | sed -n 's/^APP_NAME=//p')"
      BOT_DESC="$bot_name (bot user id $bot_id, application '$app_name' $APP_ID)"
      echo "Discord ACCEPTED this token -> $BOT_DESC"
      ;;
    401) die "Discord returned 401 for the token you pasted — it is wrong, revoked, or a Client Secret instead of the Bot Token. NOTHING was modified. In the Developer Portal: correct application -> Bot -> Reset Token -> copy the BOT token, then re-run." ;;
    *)   die "live check did not confirm the token (HTTP=$http $(printf %s "$live" | sed -n 's/^ERR=//p')). Nothing modified. Check the phone's network/Discord reachability and re-run." ;;
  esac
  # Wrong-bot guard: token's application vs this slot's configured application.
  if [ -n "$APP_ID" ] && [ "$EXISTING_APP_ID" != "-" ] && [ -n "$EXISTING_APP_ID" ] && [ "$APP_ID" != "$EXISTING_APP_ID" ]; then
    [ "$NEW_BOT" = 1 ] || die "application mismatch: slot '$ACCOUNT' is configured for application $EXISTING_APP_ID but this token belongs to application $APP_ID. Refusing to install (likely the other bot's token, or a new bot). For a deliberate new bot re-run with --new-bot. Nothing modified."
    echo "Note: application changes $EXISTING_APP_ID -> $APP_ID (--new-bot acknowledged)."
  fi
fi

# ---------- 6. Build config patch (contains NO secret) + dry-run ----------
PATCH_FILE="$(mktemp "${TMPDIR:-/tmp}/oc-discord-patch.XXXXXX.json")" || die "mktemp failed"
chmod 600 "$PATCH_FILE" 2>/dev/null || true
PATCH_FILE="$PATCH_FILE" ACCOUNT="$ACCOUNT" ENV_VAR="$ENV_VAR" TARGET="$TARGET" APP_ID="$APP_ID" python3 - <<'PY'
import json, os
ref = {"source": "env", "provider": "default", "id": os.environ["ENV_VAR"]}
app = os.environ.get("APP_ID") or ""
if os.environ["TARGET"] == "top":
    node = {"enabled": True, "token": ref}
    if app: node["applicationId"] = app
    patch = {"channels": {"discord": node}}
else:
    node = {"token": ref}
    if app: node["applicationId"] = app
    patch = {"channels": {"discord": {"enabled": True,
             "accounts": {os.environ["ACCOUNT"]: node}}}}
open(os.environ["PATCH_FILE"], "w").write(json.dumps(patch, indent=2))
PY
echo
echo "-- Config patch (SecretRef only — safe to look at) --"
cat "$PATCH_FILE"
echo "-- Dry run --"
timeout 60 OpenClaw config patch --file "$PATCH_FILE" --dry-run || { rm -f "$PATCH_FILE"; die "dry-run patch rejected by OpenClaw (see message above). Nothing modified."; }

if [ "$ASSUME_YES" != 1 ]; then
  printf "Apply backup-covered change to .env + config now? [y/N] " >&2
  IFS= read -r ans; case "$ans" in y|Y|yes|YES) ;; *) rm -f "$PATCH_FILE"; die "declined at approval gate. Nothing modified (backup kept at $BACKUP_DIR)." ;; esac
fi

# ---------- 7. Write .env, then patch config (rollback on any failure) ----------
ENV_FILE="$ENV_FILE" ENV_VAR="$ENV_VAR" TOKEN_IN="$NEW_TOKEN" python3 - <<'PY'
import os
path, key, val = os.environ["ENV_FILE"], os.environ["ENV_VAR"], os.environ["TOKEN_IN"]
lines = []
if os.path.exists(path):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
out, done = [], False
for ln in lines:
    if ln.split("=", 1)[0].strip() == key and "=" in ln:
        out.append(f"{key}={val}"); done = True
    else:
        out.append(ln)
if not done: out.append(f"{key}={val}")
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f: f.write("\n".join(out) + "\n")
os.replace(tmp, path); os.chmod(path, 0o600)
PY
cleanup_secrets
echo ".env updated: $ENV_VAR -> fingerprint $NEW_FP (value not shown)"

if ! timeout 60 OpenClaw config patch --file "$PATCH_FILE" >/dev/null; then
  rm -f "$PATCH_FILE"; rollback; die "config patch failed — rolled back. See backup: $BACKUP_DIR"
fi
rm -f "$PATCH_FILE"

if ! timeout 60 OpenClaw config validate >/dev/null 2>&1; then
  rollback; die "config invalid after patch — rolled back. Re-run termux-diagnose.sh and share its output."
fi
MODEL_AFTER="$(timeout 30 OpenClaw config get agents.defaults.model 2>/dev/null | head -c 400)"
if [ -n "$MODEL_BEFORE" ] && [ "$MODEL_AFTER" != "$MODEL_BEFORE" ]; then
  rollback; die "model routing changed unexpectedly ($MODEL_BEFORE -> $MODEL_AFTER) — rolled back to protect Gemini-primary routing."
fi

# ---------- 8. Report (claims nothing about end-to-end health) ----------
echo
if [ "${REPLACE_NO_NETWORK:-0}" = "1" ]; then
  echo "== Installed (OFFLINE MODE: identity was NOT live-checked with Discord) =="
else
  echo "== Installed (bot identity verified with Discord before the write) =="
fi
echo "Account slot : $ACCOUNT  ->  ${BOT_DESC:-identity not live-checked (offline mode)}"
echo "Token        : stored as $ENV_VAR in $ENV_FILE, fingerprint $NEW_FP"
echo "Config       : SecretRef applied and validated; model routing unchanged (${MODEL_AFTER:-unreadable})"
echo "Backup/undo  : $BACKUP_DIR  (restore its OpenClaw.json + .env to undo)"
echo
echo "NOT done yet — the running gateway still uses the OLD token until restarted:"
echo "  1. Restart the gateway your normal Termux way (In its tmux session: Ctrl-C, then re-run your usual 'OpenClaw gateway' command; Proot: same inside Ubuntu)."
echo "  2. bash termux-verify.sh"
echo "  3. Send the bot a real Discord DM and confirm a reply (runbook gates M1-M5)."
if [ "$NEW_BOT" = 1 ]; then
  echo
  echo "NEW-BOT checklist (a new application starts with nothing):"
  echo "  * Developer Portal -> your application -> Bot: enable MESSAGE CONTENT INTENT"
  echo "    (and SERVER MEMBERS INTENT if you use member allowlists)."
  echo "  * OAuth2 -> URL Generator: scopes 'bot' + 'applications.commands'; bot permissions"
  echo "    at minimum View Channel, Send Messages (+ in Threads), Read Message History,"
  echo "    Embed Links, Attach Files, Add Reactions. Open the generated URL and invite"
  echo "    the bot to EVERY server the old bot served; recreate its roles if it had any."
  echo "  * The OpenClaw account slot, agent binding, guild/channel allowlists were kept;"
  echo "    only the Discord-side identity changed."
fi
echo
echo "Clear your clipboard now (it still holds the token), and never paste it into chat/logs."
