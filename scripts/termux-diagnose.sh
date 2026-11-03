#!/usr/bin/env bash
# termux-diagnose.sh — READ-ONLY OpenClaw diagnostic collector for Android Termux.
#
# Safety contract:
#   * Never modifies config, never starts/stops/kills anything, never runs --fix.
#   * Never prints a secret value. Tokens/keys are reported ONLY as:
#     presence, length, shape flags, and a 10-hex-char SHA-256 fingerprint
#     (enough to detect "both bots accidentally share one token", not enough
#     to recover the token).
#   * The whole output stream additionally passes through a redaction filter
#     as defence-in-depth against secrets echoed by other tools' output.
#   * Optional live Discord auth test (GET /users/@me) uses tokens in memory
#     only; it prints the HTTP status and, on 200, the bot's PUBLIC
#     username/id. Disable with DIAG_NO_NETWORK=1.
#
# Usage (on the phone, inside the SAME environment that runs OpenClaw —
# native Termux shell OR inside `proot-distro login ubuntu`, wherever
# `OpenClaw` normally runs):
#   bash termux-diagnose.sh
# Output is tee'd to ~/OpenClaw-diag-<timestamp>.txt — share that file.
#
# Env knobs:
#   DIAG_NO_NETWORK=1   skip live Discord/Gemini HTTP probes
#   DIAG_TEST_GEMINI=1  also probe Gemini API key (models list, no generation)
#   DIAG_OUT=/path      override output file

set -u
set +x
umask 077

TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
OUT="${DIAG_OUT:-$HOME/OpenClaw-diag-$TS.txt}"

# ---------- redaction filter (defence in depth; primary safety is by design) ----------
redact_stream() {
  sed -E \
    -e 's/(Authorization:[[:space:]]*(Bot|Bearer))[[:space:]]+[^[:space:]"]+/\1 [REDACTED]/gI' \
    -e 's/([Tt]oken|[Ss]ecret|[Pp]assword|[Aa]pi[_-]?[Kk]ey)(["'"'"' ]*[:=]["'"'"' ]*)[^",} ]+/\1\2[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]+)[A-Za-z0-9_.-]{12,}/\1[REDACTED]/g' \
    -e 's/AIza[0-9A-Za-z_-]{10,}/[REDACTED-GOOGLE-KEY]/g' \
    -e 's/sk-(ant-)?[A-Za-z0-9_-]{10,}/[REDACTED-KEY]/g' \
    -e 's/(ghp_|github_pat_|xox[bap]-)[A-Za-z0-9_-]{8,}/[REDACTED-KEY]/g' \
    -e 's/[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{16,}/[REDACTED-DOTTED-TOKEN]/g' \
    -e 's/\b[0-9a-f]{48,}\b/[REDACTED-LONG-HEX]/g'
}

have() { command -v "$1" >/dev/null 2>&1; }

run() { # run a diagnostic command, show exit code, never abort the script
  echo "+ $*"
  "$@" 2>&1
  echo "  [exit=$?]"
}

run_t() { # same, with timeout if available: run_t SECONDS cmd...
  local t="$1"; shift
  if have timeout; then
    echo "+ timeout ${t}s $*"
    timeout "$t" "$@" 2>&1
    echo "  [exit=$?]"
  else
    run "$@"
  fi
}

fp10() { # fingerprint of stdin value (no trailing newline added by caller)
  if have sha256sum; then printf %s "$1" | sha256sum | cut -c1-10
  elif have python3; then printf %s "$1" | python3 -c 'import sys,hashlib;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:10])'
  else echo "fp-unavailable"; fi
}

section() { echo; echo "===== $* ====="; }

main() {
  echo "OpenClaw Termux diagnosis (READ-ONLY)  $TS"
  echo "Output file: $OUT"
  echo "This file is designed to be shareable: secrets are never printed."
  echo "Still eyeball it before posting publicly."

  section "1. Platform — which world am I in? (native Termux vs proot Ubuntu)"
  echo "user=$(whoami 2>/dev/null)  HOME=$HOME  PWD=$PWD"
  echo "PREFIX=${PREFIX:-<unset>}  TERMUX_VERSION=${TERMUX_VERSION:-<unset>}"
  echo "TMPDIR=${TMPDIR:-<unset>}  SHELL=${SHELL:-<unset>}"
  uname -a 2>/dev/null || echo "uname: unavailable"
  [ -f /etc/os-release ] && head -n 4 /etc/os-release
  if [ -n "${PREFIX:-}" ] && [ -d /data/data/com.termux ] && [ ! -f /etc/debian_version.dpkg-orig ] && ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    echo "DETECTED: likely NATIVE Termux shell."
  elif grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null && [ -d /data/data/com.termux ]; then
    echo "DETECTED: likely proot-distro Linux INSIDE Termux (config usually /root/.OpenClaw/)."
  else
    echo "DETECTED: neither marker is conclusive — note where you normally run 'OpenClaw' from."
  fi
  df -h "$HOME" 2>/dev/null | tail -n 2 || true
  date

  section "2. Runtime versions"
  if have node; then echo "node: $(node -v 2>&1)"; else echo "node: NOT FOUND in PATH"; fi
  if have npm;  then echo "npm:  $(npm -v 2>&1 | head -n1)"; else echo "npm: NOT FOUND in PATH"; fi
  if have python3; then echo "python3: $(python3 --version 2>&1)"; else echo "python3: NOT FOUND (config-structure section will be limited)"; fi
  if have tmux; then echo "tmux: present"; run tmux ls; else echo "tmux: NOT FOUND"; fi
  if have OpenClaw; then
    echo "OpenClaw binary: $(command -v OpenClaw)"
    run_t 30 OpenClaw --version
  else
    echo "OpenClaw: NOT FOUND in PATH in THIS shell."
    echo "  -> Classic split-brain: installed in the other environment"
    echo "     (e.g. inside proot Ubuntu) or PATH missing npm global bin."
    echo "  -> npm global root candidates:"
    have npm && npm root -g 2>/dev/null
    ls -ld "$HOME/.npm-global/bin" /usr/local/bin/OpenClaw /root/.npm-global/bin 2>&1 | head -n 5
  fi

  section "3. Config path resolution (CLI is authoritative)"
  CFG=""
  if have OpenClaw; then
    CFG="$(timeout 30 OpenClaw config file 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    echo "openclaw config file -> ${CFG:-<no output>}"
  fi
  echo "OPENCLAW_CONFIG_PATH=${OPENCLAW_CONFIG_PATH:-<unset>}"
  echo "OPENCLAW_STATE_DIR=${OPENCLAW_STATE_DIR:-<unset>}"
  echo "OPENCLAW_HOME=${OPENCLAW_HOME:-<unset>}"
  echo "Candidate config locations (existence only):"
  for c in "$HOME/.OpenClaw/OpenClaw.json" "/root/.OpenClaw/OpenClaw.json" \
           "/data/data/com.termux/files/home/.OpenClaw/OpenClaw.json" \
           "${OPENCLAW_CONFIG_PATH:-/nonexistent}"; do
    if [ -f "$c" ]; then
      # size + mtime + short checksum help spot 'editing one file, gateway reads another'
      sz="$(wc -c < "$c" 2>/dev/null | tr -d ' ')"
      sum="<n/a>"; have sha256sum && sum="$(sha256sum "$c" 2>/dev/null | cut -c1-16)"
      echo "  EXISTS  $c  bytes=${sz:-?}  sha256[0:16]=$sum  mtime=$(ls -l "$c" 2>/dev/null | awk '{print $6,$7,$8}')"
    else
      echo "  absent  $c"
    fi
  done
  [ -z "$CFG" ] && [ -f "$HOME/.OpenClaw/OpenClaw.json" ] && CFG="$HOME/.OpenClaw/OpenClaw.json"
  [ -z "$CFG" ] && [ -f /root/.OpenClaw/OpenClaw.json ] && CFG="/root/.OpenClaw/OpenClaw.json"
  echo "Config used for structure inspection below: ${CFG:-<none found>}"
  if [ -n "$CFG" ] && [ -f "$CFG" ]; then
    echo "Sibling backup/recovery artefacts (names+sizes only):"
    ls -lt "$CFG".bak* "$CFG".clobbered.* "$CFG".rejected.* "$CFG".last-good* 2>/dev/null | head -n 20 \
      || echo "  (none of .bak/.clobbered/.rejected/.last-good found)"
    echo "Permissions: $(ls -l "$CFG" 2>/dev/null | awk '{print $1, $3, $4, $9}')"
  fi

  section "4. Config validation + doctor (NO --fix: nothing is modified)"
  if have OpenClaw; then
    run_t 60 OpenClaw config validate --json
    echo "--- doctor (read-only; --fix would rewrite config and is gated on a backup) ---"
    run_t 120 OpenClaw doctor
  else
    echo "Skipped: OpenClaw CLI not available in this shell."
  fi

  section "5. Config structure (secrets summarised, never printed)"
  if [ -n "$CFG" ] && [ -f "$CFG" ] && have python3; then
    CFG="$CFG" DIAG_NO_NETWORK="${DIAG_NO_NETWORK:-0}" DIAG_TEST_GEMINI="${DIAG_TEST_GEMINI:-0}" python3 - <<'PY'
import json, os, re, sys, hashlib

cfg_path = os.environ["CFG"]
raw = open(cfg_path, "r", encoding="utf-8", errors="replace").read()

def try_parse(text):
    try:
        return json.loads(text), "strict-json"
    except Exception:
        pass
    # OpenClaw config is JSON5: tolerate comments / trailing commas for a
    # STRUCTURE-ONLY summary. `OpenClaw config validate` remains authoritative.
    t = re.sub(r"//[^\n]*", "", text)
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r",(\s*[}\]])", r"\1", t)
    try:
        return json.loads(t), "json5-approx"
    except Exception as e:
        return None, f"parse-failed: {type(e).__name__}: {e}"

cfg, how = try_parse(raw)
print(f"config parse method: {how}")
print(f"config bytes: {len(raw)}")
if cfg is None:
    print("Could not parse config as JSON/approx-JSON5 in python.")
    print("=> Treat `OpenClaw config validate` output above as the verdict.")
    print("=> If validate also fails, geometry/syntax corruption is your config-loading bug.")
    sys.exit(0)

def fp(v): return hashlib.sha256(v.encode()).hexdigest()[:10]
candidates = []  # (label, token) for live test; never printed

def describe_token(label, val):
    # NOTE: use " -> " not ":" after the label, so the shell redaction filter
    # does not mistake our (already-safe) summary for a token assignment.
    if val is None:
        print(f"  {label} -> MISSING")
        return
    if isinstance(val, dict):  # SecretRef
        src, prov, ident = val.get("source"), val.get("provider"), val.get("id")
        print(f"  {label} -> SecretRef source={src} provider={prov} id={ident}")
        if src == "env" and ident:
            env_v = os.environ.get(str(ident))
            if env_v:
                print(f"    -> env {ident} is SET in this shell (len={len(env_v)}, fp={fp(env_v)})")
                candidates.append((f"{label} via env:{ident}", env_v))
            else:
                print(f"    -> env {ident} is NOT SET in this shell "
                      f"(gateway may still resolve it via ~/.OpenClaw/.env — see section 6)")
        return
    if not isinstance(val, str):
        print(f"  {label} -> unexpected type {type(val).__name__}")
        return
    m = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", val.strip())
    if m:
        name = m.group(1); env_v = os.environ.get(name)
        print(f"  {label} -> env-interpolation ${{{name}}} -> "
              + (f"SET (len={len(env_v)}, fp={fp(env_v)})" if env_v else "NOT SET in this shell"))
        if env_v: candidates.append((f"{label} via env:{name}", env_v))
        return
    flags = []
    if val.strip() in {"***", "...", "REDACTED", "YOUR_TOKEN", "YOUR_BOT_TOKEN", ""} or "*" in val:
        flags.append("PLACEHOLDER/CLOBBERED-SUSPECT")
    if val != val.strip(): flags.append("LEADING/TRAILING-WHITESPACE")
    if val.startswith("Bot "): flags.append("HAS-'Bot '-PREFIX")
    if '"' in val or "'" in val: flags.append("CONTAINS-QUOTES")
    if "\n" in val: flags.append("CONTAINS-NEWLINE")
    print(f"  {label} -> plaintext len={len(val)} fp={fp(val)} segments={val.count('.')+1} "
          f"flags={','.join(flags) if flags else 'none'}")
    if "PLACEHOLDER/CLOBBERED-SUSPECT" not in flags:
        candidates.append((label, val))

gw = cfg.get("gateway") or {}
auth = gw.get("auth") or {}
print(f"gateway.mode={gw.get('mode')}  gateway.port={gw.get('port')}  gateway.bind={gw.get('bind')}")
print(f"gateway.auth.mode={auth.get('mode')}  has gateway.auth.token={bool(auth.get('token'))}  "
      f"has LEGACY gateway.token={bool(gw.get('token'))}")
print(f"gateway token present in env OPENCLAW_GATEWAY_TOKEN={bool(os.environ.get('OPENCLAW_GATEWAY_TOKEN'))}"
      "  (if True and stale, it overrides the file — a known 401/1008 trap)")

agents = cfg.get("agents") or {}
defaults = agents.get("defaults") or {}
model = defaults.get("model")
print(f"agents.defaults.model={json.dumps(model) if not isinstance(model,(dict,list)) else json.dumps({k:v for k,v in model.items() if k in ('primary','fallbacks')}) if isinstance(model,dict) else model}")
entries = agents.get("entries") or agents.get("list") or {}
if isinstance(entries, dict):
    print(f"agent entries: {sorted(entries.keys())}")
    for aid, a in entries.items():
        if isinstance(a, dict) and a.get("model"):
            print(f"  agent {aid} model override: {a.get('model')}")
elif isinstance(entries, list):
    print(f"agent entries: {[e.get('id') for e in entries if isinstance(e,dict)]}")
binds = cfg.get("bindings") or []
for b in binds:
    if isinstance(b, dict):
        m = b.get("match") or {}
        print(f"binding: agentId={b.get('agentId')} channel={m.get('channel')} accountId={m.get('accountId')}")

provs = ((cfg.get("models") or {}).get("providers") or {})
print(f"model providers configured (names only): {sorted(provs.keys()) if isinstance(provs, dict) else provs}")

disc = ((cfg.get("channels") or {}).get("discord") or {})
print(f"channels.discord.enabled={disc.get('enabled')}  defaultAccount={disc.get('defaultAccount')}  "
      f"top-level applicationId={'SET' if disc.get('applicationId') else 'unset'}")
print("Discord token sources:")
describe_token("channels.discord.token (default account)", disc.get("token"))
accts = disc.get("accounts") or {}
if isinstance(accts, dict):
    for aid in sorted(accts.keys()):
        a = accts.get(aid) or {}
        print(f" account '{aid}': enabled={a.get('enabled')} applicationId={'SET' if a.get('applicationId') else 'unset'}")
        describe_token(f"channels.discord.accounts.{aid}.token", a.get("token"))
else:
    print("  accounts: (not a map — unexpected shape)")

# duplicate-token detection across candidates (by fingerprint only)
seen = {}
for label, tok in candidates:
    seen.setdefault(fp(tok), []).append(label)
dups = {k: v for k, v in seen.items() if len(v) > 1}
if dups:
    print("DUPLICATE TOKEN WARNING (same fingerprint under multiple labels):")
    for k, v in dups.items():
        print(f"  fp={k} <- {v}  (OpenClaw starts only ONE monitor per token; second bot looks 'disabled')")
else:
    print("No duplicate Discord token fingerprints among resolvable candidates.")

# also consider bare env vars as candidates (default-account fallback etc.)
for name in sorted(os.environ):
    if "DISCORD" in name and "TOKEN" in name:
        v = os.environ[name]
        if all(v != t for _, t in candidates):
            candidates.append((f"env:{name}", v))
            print(f"  env:{name}: SET (len={len(v)}, fp={fp(v)}) [env-only candidate]")

print()
print("--- 5b. Live Discord auth test: GET https://discord.com/api/v10/users/@me ---")
if os.environ.get("DIAG_NO_NETWORK") == "1":
    print("Skipped (DIAG_NO_NETWORK=1).")
elif not candidates:
    print("No resolvable Discord token candidates found in this shell/config — cannot live-test.")
    print("This itself is evidence: token missing, in unloaded .env, or in the OTHER environment.")
else:
    import urllib.request, urllib.error
    for label, tok in candidates:
        t = tok.strip()
        if t.startswith("Bot "): t = t[4:]
        req = urllib.request.Request(
            "https://discord.com/api/v10/users/@me",
            headers={"Authorization": f"Bot {t}",
                     "User-Agent": "DiscordBot (OpenClaw-diag, 1.0)"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                body = json.loads(r.read().decode("utf-8", "replace"))
            print(f"  [{label}] HTTP 200 -> VALID bot token. "
                  f"bot user: {body.get('username')}#{body.get('discriminator')} id={body.get('id')}")
        except urllib.error.HTTPError as e:
            try: detail = json.loads(e.read().decode("utf-8", "replace"))
            except Exception: detail = {}
            print(f"  [{label}] HTTP {e.code} -> Discord REJECTED this token. "
                  f"code={detail.get('code')} message={detail.get('message')}")
            if e.code == 401:
                print("      401 here proves the credential itself is wrong/revoked/mistyped,")
                print("      independent of OpenClaw. Fix is token rotation/correction, not reinstall.")
        except Exception as e:
            print(f"  [{label}] network error (not an auth verdict): {type(e).__name__}: {e}")

if os.environ.get("DIAG_TEST_GEMINI") == "1" and os.environ.get("DIAG_NO_NETWORK") != "1":
    print()
    print("--- 5c. Optional Gemini key probe (list models; no generation, no content sent) ---")
    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or os.environ.get("GOOGLE_GENERATIVE_AI_API_KEY")
    if not key:
        print("No GEMINI_API_KEY/GOOGLE_API_KEY in this shell env "
              "(key may live in auth profiles / .env — absence here is not proof of absence).")
    else:
        import urllib.request, urllib.error
        req = urllib.request.Request(
            "https://generativelanguage.googleapis.com/v1beta/models",
            headers={"x-goog-api-key": key})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                n = len(json.loads(r.read().decode()).get("models", []))
            print(f"  HTTP 200 -> Gemini key accepted ({n} models visible). fp={fp(key)} len={len(key)}")
        except urllib.error.HTTPError as e:
            print(f"  HTTP {e.code} -> Gemini rejected key in env (fp={fp(key)} len={len(key)}). "
                  "Note: a Google 401/400 is a DIFFERENT failure from a Discord 401.")
        except Exception as e:
            print(f"  network error: {type(e).__name__}: {e}")
PY
  else
    echo "Skipped: config file or python3 unavailable."
  fi

  section "6. Environment + ~/.OpenClaw/.env (names, lengths, fingerprints ONLY)"
  echo "Relevant env vars SET in this shell:"
  found=0
  while IFS='=' read -r name _; do
    case "$name" in
      *DISCORD*|*GEMINI*|*GOOGLE*KEY*|*OPENCLAW*)
        eval "val=\${$name:-}"
        echo "  $name: SET len=${#val} fp=$(fp10 "$val")"
        found=1 ;;
    esac
  done <<EOF
$(env)
EOF
  [ "$found" = 0 ] && echo "  (none — if the gateway is started from a different shell/service, it may see a different env)"
  for envf in "$HOME/.OpenClaw/.env" "/root/.OpenClaw/.env"; do
    if [ -f "$envf" ]; then
      echo ".env file EXISTS: $envf  (keys only; values as len/fp)"
      while IFS= read -r line; do
        case "$line" in ''|'#'*) continue;; esac
        k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        echo "    $k len=${#v} fp=$(fp10 "$v")"
      done < "$envf"
    else
      echo ".env absent: $envf"
    fi
  done

  section "7. Gateway process, port, and CLI status"
  PORT="18789"
  if have OpenClaw; then
    gp="$(timeout 30 OpenClaw config get gateway.port 2>/dev/null | tr -dc '0-9')"
    [ -n "$gp" ] && PORT="$gp"
    run_t 60 OpenClaw gateway status
    run_t 60 OpenClaw gateway status --deep
  fi
  echo "Processes matching OpenClaw/node (command lines can contain paths, not tokens):"
  (ps aux 2>/dev/null || ps -ef 2>/dev/null) | grep -iE 'OpenClaw|node' | grep -v grep | head -n 20 \
    || echo "  (ps unavailable or no match)"
  echo "Listeners on port $PORT:"
  (ss -tlnp 2>/dev/null | grep -E ":$PORT\b") || (netstat -tlnp 2>/dev/null | grep -E ":$PORT\b") \
    || echo "  (no listener found / ss+netstat unavailable — consistent with gateway stopped)"
  if have curl; then
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
    echo "HTTP probe http://127.0.0.1:$PORT/ -> ${code:-curl-failed} (000/failed = nothing listening)"
  fi

  section "8. Channel status (both Discord bots)"
  if have OpenClaw; then
    run_t 60 OpenClaw channels list
    run_t 90 OpenClaw channels status
  else
    echo "Skipped: OpenClaw CLI not available."
  fi

  section "9. Recent log evidence (filtered, redacted)"
  echo "Log directories:"
  for d in "$HOME/.OpenClaw/logs" /root/.OpenClaw/logs "${TMPDIR:-/tmp}/OpenClaw" "/tmp/OpenClaw" \
           "/data/data/com.termux/files/usr/tmp/OpenClaw"; do
    [ -d "$d" ] && { echo "  $d:"; ls -lt "$d" 2>/dev/null | head -n 6; }
  done
  LATEST=""
  for d in "$HOME/.OpenClaw/logs" /root/.OpenClaw/logs "${TMPDIR:-/tmp}/OpenClaw" "/tmp/OpenClaw" \
           "/data/data/com.termux/files/usr/tmp/OpenClaw"; do
    f="$(ls -t "$d"/*.log 2>/dev/null | head -n 1)"
    [ -n "$f" ] && LATEST="$f"
  done
  if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
    echo "--- newest log: $LATEST ---"
    echo "--- last 120 lines matching error/auth/discord/config signals ---"
    tail -n 3000 "$LATEST" 2>/dev/null \
      | grep -aiE '401|unauthor|1008|invalid config|config reload skipped|discord|EADDRINUSE|gateway.*(error|fail|stop|exit)|token' \
      | tail -n 120
    echo "--- raw tail (last 40 lines) ---"
    tail -n 40 "$LATEST" 2>/dev/null
  else
    echo "No *.log found in the usual locations. Note where your gateway logs go"
    echo "(foreground tmux scrollback counts — 'tmux capture-pane -p -S -300' retrieves it)."
  fi

  section "10. Termux survival facts (why gateways 'mysteriously stop')"
  have termux-wake-lock && echo "termux-wake-lock: command present (run it; also exempt Termux from battery optimisation)" \
    || echo "termux-wake-lock: not in PATH (native Termux: pkg install termux-api; or this is proot, lock must be taken OUTSIDE proot)"
  echo "TMPDIR for native Termux should be \$PREFIX/tmp; current: ${TMPDIR:-<unset>}"
  echo "Android 12+ phantom-process killer + battery optimisation can kill long-lived"
  echo "gateways with NO error in OpenClaw logs. A clean log ending mid-idle supports this."

  section "SUMMARY — send this whole file back"
  echo "File: $OUT"
  echo "Nothing was modified. Next step is classification, THEN a backup, THEN one fix at a time."
  echo "Also report (none of these are secrets):"
  echo "  * Install flavour: native Termux / proot Ubuntu / OpenClaw-termux app?"
  echo "  * Your two Discord accountIds (e.g. default + automation) and bot usernames"
  echo "  * When was each bot token last Reset in the Discord Developer Portal?"
  echo "  * What changed right before it broke? (update, config edit, token reset, reboot)"
}

main 2>&1 | redact_stream | tee "$OUT"
echo
echo "Saved: $OUT (mode 600). Review, then share it."
