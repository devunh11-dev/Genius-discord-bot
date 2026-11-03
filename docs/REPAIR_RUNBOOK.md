# OpenClaw on Android Termux — Repair Runbook

**Patient:** existing OpenClaw install on Android Termux; gateway stopped; two Discord
bots (primary + automation) failing; Discord HTTP 401s; config-loading problems.
**Hard constraints (from owner):** preserve all agents/config/projects and
Gemini-primary routing · no reinstall unless proven necessary · back up before
*every* config change · never expose API keys or bot tokens · no Docker, no
systemd, no paid services, no OpenRouter · verify with real Discord messages,
not with "process started".

**Control channel:** Remote Desktop Commander (RDC) — a hosted remote-MCP relay
to a device agent started with `npx @wonderwhy-er/desktop-commander@latest remote`
(Node 18+; the machine is reachable only while that agent runs).

---

## Status board (updated as evidence arrives)

| Phase | State |
|---|---|
| 0. Confirm where the work is happening | ✅ Done — see finding F0 below |
| 1. Read-only diagnosis on the phone | ⏳ **Awaiting `OpenClaw-diag-*.txt` from the device** |
| 2. Classification (root-cause per symptom) | Blocked on Phase 1 |
| 3. Backup gate | Script ready (`scripts/termux-backup.sh`) |
| 4. Targeted repair (one change at a time) | Blocked on Phases 2–3 |
| 5. Gemini/agents preservation diff | Blocked on Phase 4 |
| 6. Real Discord verification (both bots) | Blocked on Phase 4 — script + manual gates ready |

### Finding F0 (evidence, 2026-11-03)

The Arena coding workspace for this session is a Debian x86_64 sandbox
containing an empty `Genius-discord-bot` repo. It has **no Termux**
(`/data/data/com.termux` absent), **no OpenClaw** (`~/.OpenClaw`, CLI absent),
and **no RDC connector attached to this conversation**. Therefore no on-device
command has been run yet, and *nothing on the phone has been diagnosed or
fixed*. Anyone claiming otherwise from this workspace would be fabricating.
The repair proceeds by (a) running the collectors in `scripts/` on the phone
via RDC and returning their output, or (b) attaching RDC so commands can be
issued directly — see "Getting the tools onto the phone".

---

## Ground rules

1. **Read-only until classified.** Phase 1 changes nothing. `OpenClaw doctor --fix`,
   `config set/patch`, gateway restarts and token resets are all Phase 4 actions.
2. **Backup before every change, checksums verified, copy taken off-device.**
   No backup ⇒ no change. (`scripts/termux-backup.sh`, `--full` for state.)
3. **Secrets never transit chat, logs, git, or screenshots.** Tokens are handled
   only on-device. The scripts report presence/length/shape and a 10-char
   SHA-256 fingerprint — never the value. This was leak-tested locally with fake
   credentials (see "Local test evidence").
4. **One change → validate → observe.** After any config edit:
   `OpenClaw config validate`, structural diff vs backup (agents list, bindings,
   `agents.defaults.model` must still be Gemini-primary), then start/observe.
5. **Stop conditions:** config checksum changes unexpectedly; token fingerprints
   change without a deliberate rotation; agent IDs disappear in a diff; anything
   suggests the config on disk is not the config we think is on disk. Stop and
   re-collect evidence instead of stacking fixes.
6. **No reinstall.** Only justified if the binary itself is proven corrupt
   (e.g. `OpenClaw --version` crashes after env issues are excluded) — and even
   then state/config survive a package reinstall because they live in
   `~/.OpenClaw/`, not in the package.

---

## Getting the tools onto the phone (pick the row that matches your RDC setup)

Run every script **in the environment where OpenClaw actually runs** — if you
normally `proot-distro login ubuntu` first, do that, then run scripts inside.

| Your RDC layout | How scripts reach the phone |
|---|---|
| RDC device agent running *inside Termux* (native or proot) | In that shell: `cd ~ && git clone <this repo>` (or fetch the three script files), then run them. Keep the agent terminal open. |
| RDC agent on a **PC/Mac**, phone attached by USB/adb | `adb push scripts/termux-diagnose.sh /sdcard/Download/` then in Termux: `cp ~/storage/downloads/termux-diagnose.sh ~` (needs `termux-setup-storage`). Or `adb shell` can't run Termux apps directly — prefer the copy + run in Termux. |
| RDC agent on a **PC/Mac**, phone reachable over LAN | In Termux: `pkg install openssh && sshd` (Termux sshd listens on port **8022**, auth by key). From PC: `scp -P 8022 scripts/*.sh <phone-ip>:~` and run via `ssh -p 8022 <phone-ip>`. Never send passwords/tokens through chat to set this up. |

Return channel for Phase 1 output: the script writes `~/OpenClaw-diag-<ts>.txt`
(mode 600). Download it via RDC / `adb pull` / `scp` and attach it to the chat.
It is designed to be safe to share — still skim it first.

---

## Phase 1 — Read-only diagnosis (the only step to run right now)

```bash
bash termux-diagnose.sh            # ~1–2 min; add DIAG_TEST_GEMINI=1 to also probe the Gemini key
```

What it collects: environment identity (native Termux vs proot — configs live in
different HOMEs), versions, the config path the CLI *actually* resolves plus all
candidate paths, `.bak/.clobbered/.rejected` artefacts, `config validate --json`,
`doctor` (**without** `--fix`), a secrets-safe structural summary (gateway
mode/port/auth shape, `agents.defaults.model`, agent IDs, Discord bindings,
per-account token *sources* + fingerprints, duplicate-token detection), live
Discord auth verdicts per token (`GET /users/@me` → HTTP code + public bot
identity, token used in memory only), gateway process/port/HTTP probe, channel
status, and the newest log's error lines (redacted).

Also report back (none are secrets): install flavour; the two Discord
`accountId`s and bot usernames; **when each bot token was last Reset in the
Discord Developer Portal**; what changed just before it broke.

---

## Phase 2 — Classification tables

### 2a. Which "401" is it? (three different diseases, one symptom word)

| Signature in evidence | System speaking | Meaning | First-line cause |
|---|---|---|---|
| Discord API `401` / `{"message":"401: Unauthorized","code":0}` from `discord.com`, **and** diagnose §5b also gets 401 | Discord | The *credential itself* is rejected — independent of OpenClaw | Token was reset in the Developer Portal (old one dies instantly); copied **Client Secret** instead of **Bot Token**; quotes/whitespace/newline pasted in; spurious `Bot ` prefix stored in the value; token belongs to a different application than `applicationId`; config value clobbered to a placeholder like `***` |
| Gateway logs 401 but diagnose §5b gets **200** for the same fingerprint | Discord ← OpenClaw glue | Token is fine; the *running gateway* resolves something else | Gateway process env ≠ shell env (SecretRef env var exported in one shell, gateway started in tmux/proot without it; `.env` not at `~/.OpenClaw/.env` for the env that runs the gateway); `DISCORD_BOT_TOKEN` fallback only ever applies to the **default** account, so the automation account silently gets nothing/wrong value; both accounts resolve to the same token → OpenClaw starts only one monitor and reports the duplicate as disabled |
| WebSocket `1008 unauthorized: gateway token missing/mismatch`, Control UI 401 | OpenClaw gateway | Gateway's *own* auth — nothing to do with Discord | Legacy `gateway.token` vs current `gateway.auth.token` drift; stale `OPENCLAW_GATEWAY_TOKEN` env overriding the file; token regenerated but not propagated to clients/UI |
| `400/401 API_KEY_INVALID` from `generativelanguage.googleapis.com`, bot is online but "thinking" fails | Google (Gemini) | Model key rejected — bots will look broken in Discord while Discord auth is healthy | Key deleted/restricted in Google Cloud, wrong key in auth profile, key in env of wrong environment |

**Non-401 look-alikes to not misdiagnose:** missing **Message Content Intent**
(bot logs in, sees empty message text), `dmPolicy: pairing`/guild allowlists
(bot online, deliberately silent), `requireMention` (bot ignores un-@'d guild
messages). These produce *silence*, never HTTP 401.

### 2b. Config-loading failures

| Signature | Meaning | Repair shape (Phase 4) |
|---|---|---|
| `Invalid config at …` at startup; gateway exits immediately | Startup validation failed; OpenClaw **fails closed** and leaves the file untouched | Fix exactly the paths `config validate` names — via `OpenClaw config set/patch` (schema-checked), not by rewriting the whole file |
| `config reload skipped (invalid config)` while running | A hand edit was invalid; the *old* runtime config is still live — "my edit did nothing" | Correct the edit; validate; the reload then applies |
| `*.clobbered.*` beside the config | `doctor --fix` (or startup repair) preserved a broken edit and restored last-known-good | Diff clobbered vs active; re-apply only intended keys with `config patch --dry-run` first |
| `*.rejected.*` / "Config write rejected" (`size-drop-vs-last-good` etc.) | An OpenClaw-owned write tried to shrink/drop required shape and was refused | Never paste a partial config over the full file; merge only the intended keys |
| CLI reads config A (`OpenClaw config file`), user edits config B | **Split-brain** across native-Termux HOME vs proot `/root`, or `OPENCLAW_CONFIG_PATH/STATE_DIR` overrides | Standardise on the CLI-reported path in the environment that runs the gateway; remove confusion by documenting the one true path (diagnose §3 settles this) |
| Token values show flags `PLACEHOLDER/CLOBBERED-SUSPECT` in diagnose §5 | A UI round-trip saved `***` over real tokens | Re-supply tokens via env SecretRef (below), not by un-redacting from a UI |

### 2c. Gateway stopped (Termux-specific, ranked)

1. **Android killed it** — battery optimisation / Android 12+ phantom-process
   killer; log ends mid-idle with no error. Mitigate with `termux-wake-lock`,
   battery-unrestricted for Termux, and a tmux session; verify with the 15-min
   screen-off soak (M5).
2. **Invalid config** → §2b (exits at start; log says so).
3. **Port 18789 already bound** by a zombie gateway (`EADDRINUSE`; diagnose §7
   shows listener + process). Kill only the identified PID after confirming it
   is the stale gateway.
4. **TMPDIR** wrong on native Termux (expects `$PREFIX/tmp`, not `/tmp`) —
   crashes around temp/log files.
5. **Node too old** for the installed OpenClaw (newer releases need Node 22.19+)
   or the shell is simply the wrong one (OpenClaw missing in PATH here, fine in proot).

Expected noise on Termux: "systemd not found" style errors. The gateway is run
in the **foreground inside tmux**; there is no service manager to install.

---

## Phase 3 — Backup gate (before *every* Phase 4 change, repeat per change)

```bash
bash termux-backup.sh            # config + .env + artefacts + manifest + checksums
bash termux-backup.sh --full     # first time, and before any doctor --fix: + state archive
cd ~/OpenClaw-backups/<newest> && sha256sum -c SHA256SUMS   # must be all OK
# then copy the folder OFF the phone via RDC/adb/scp
```

Record in the status board: backup path, config sha256[0:16], the intended change.

## Phase 4 — Targeted repairs (menu; only the classified items, one at a time)

* **Schema/legacy repair:** `OpenClaw doctor --fix` is the sanctioned tool for
  legacy-key migration and last-known-good restoration — it *rewrites* config,
  so it runs only behind a verified `--full` backup, followed by a structural
  diff (agents, bindings, `agents.defaults.model`, Discord accounts, provider
  names) before the gateway is started.
* **Surgical config edits:** `OpenClaw config patch --file fix.json5 --dry-run`,
  review, then without `--dry-run`; `OpenClaw config validate` after. Never
  hand-overwrite the entire JSON.
* **Discord token correction/rotation (per bot, independently):**
  Developer Portal → *that bot's application* → Bot → **Reset Token** → on the
  phone set a **distinct** env var per bot (`DISCORD_BOT_TOKEN` for default,
  e.g. `DISCORD_AUTOMATION_TOKEN` for automation) in `~/.OpenClaw/.env`
  (mode 600) of the environment that runs the gateway, with config holding an
  env SecretRef (`{source:"env",provider:"default",id:"…"}`) — official
  pattern; `DISCORD_BOT_TOKEN` alone only feeds the default account. Set each
  account's `applicationId` to *its own* application. Re-run diagnose §5b:
  both must return 200 with **different** bot user IDs.
  **Use `scripts/termux-replace-discord-bot.sh` for this step** — it enforces
  the backup, hidden prompt, live Discord identity check (a token Discord
  rejects with 401 is refused *before* any file changes), wrong-bot and
  duplicate-token guards, SecretRef-only config patching with dry-run,
  model-preservation check, and auto-rollback. Its `--new-bot` mode covers a
  whole replacement application in the same account slot (binding/routing and
  allowlists preserved; Discord-side invite + Message Content Intent must be
  redone — the script prints that checklist). Only the owner can create/reset
  tokens in the Developer Portal; no token ever passes through chat.
* **Env split-brain:** make the launch path load the same `.env` every time
  (start gateway from the documented shell; don't rely on one-off `export`s).
* **Termux runtime:** `export TMPDIR="$PREFIX/tmp"` (+`TMP`,`TEMP`) in
  `~/.bashrc` for native installs; `mkdir -p "$TMPDIR/OpenClaw"`;
  `termux-wake-lock`; start with `tmux new -s OpenClaw` → `OpenClaw gateway`;
  detach with Ctrl-b d. Proot installs: same, inside `proot-distro login ubuntu`,
  wake-lock taken in the outer Termux first.

## Phase 5 — Preservation diff (must be empty except intended keys)

Compare pre-repair backup vs live config structurally (agent IDs, workspaces,
bindings incl. `accountId`s, `agents.defaults.model.primary` = Gemini,
provider names, Discord guild/channel allowlists). Use diagnose §5 output from
before/after — fingerprints prove tokens changed *only* where rotated.

## Phase 6 — Verification (script + human gates; no shortcuts)

```bash
bash termux-verify.sh   # automated: validate, Gemini-primary, port/HTTP, channels, doctor
```

Then the manual gates in that script: DM + guild-mention tests against the
**primary** bot, the same against the **automation** bot (confirm the correct
agent answers), logs watched during the tests with no 401s, and a 15-minute
screen-off soak. **"Gateway listening" is not success; two Discord replies are.**

### Rollback (any phase, any doubt)

Stop gateway → `cp` the broken config aside with a timestamp → restore the
Phase 3 backup per its `RESTORE.md` → `OpenClaw config validate` → start →
re-verify. Rollback is a normal outcome, not a failure of process.

---

## Local test evidence for the scripts (this sandbox, fake credentials only)

* `bash -n` clean for all three scripts.
* Diagnose run against a fixture `OpenClaw.json` (two agents, two Discord
  accounts incl. env SecretRef, Gemini-primary model, stub CLI): correctly
  reported model routing, agent IDs, bindings, token sources/fingerprints, and
  the duplicate-token warning when both accounts shared one fake token.
* **Leak test:** after two found-and-fixed redactor bugs, all fake secret
  strings (both fake bot tokens, fake Gemini key, fake gateway token) occur
  **0 times** in diagnose/verify output; output file mode is 600.
* Backup: produces config+`.env`+manifest+`RESTORE.md` at mode 600 with
  `sha256sum -c` all-OK. Verify: correctly **FAILs** (exit 2) when no gateway
  listens — it does not rubber-stamp.
* Live Discord/Gemini probes were *not* exercised here (sandbox has no route
  to discord.com and no real tokens — by design). First live run is on-device.

## References (official docs)

* Discord setup & multi-bot accounts/SecretRefs — docs.openclaw.ai/channels/discord/setup
* Config CLI, validation & write-safety — docs.openclaw.ai/cli/config
* Config rejection/clobber semantics — docs.openclaw.ai/gateway/troubleshooting/config-validation-and-probes
* Multi-agent routing/bindings — docs.openclaw.ai/concepts/multi-agent
* Termux notes (native & proot flavours) — ClawPhone; mithun50/openclaw-termux
* Remote Desktop Commander — github.com/desktop-commander/remote-desktop-commander
