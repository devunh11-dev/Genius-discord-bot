# Genius-discord-bot

Repair workspace for an existing **OpenClaw** installation on **Android Termux**
(gateway stopped, two Discord bots — primary + automation — hitting HTTP 401,
config-loading problems), driven remotely via **Remote Desktop Commander**.

Approach: evidence-first, incremental, no reinstall, back up before every
change, secrets never leave the phone, and success means *both Discord bots
actually reply* — not merely a running process.

## Start here

1. Read the status board in [`docs/REPAIR_RUNBOOK.md`](docs/REPAIR_RUNBOOK.md).
2. **Phase 1 (only current action):** run the read-only collector on the phone,
   in the same environment that runs OpenClaw (native Termux *or* inside
   `proot-distro login ubuntu`):
   ```bash
   bash scripts/termux-diagnose.sh
   ```
   Send back the generated `~/OpenClaw-diag-*.txt` (secrets are never printed;
   tokens appear only as length/shape + 10-char fingerprint — leak-tested).
3. Only after classification: `scripts/termux-backup.sh` (backup gate), one
   targeted fix at a time, then `scripts/termux-verify.sh` plus real Discord
   message tests against both bots.

## Scripts

| Script | Purpose | Changes anything? |
|---|---|---|
| `scripts/termux-diagnose.sh` | Read-only evidence: env identity, config resolution, validation, per-bot Discord auth verdicts, gateway/process/port, redacted logs | No |
| `scripts/termux-backup.sh` | Timestamped config (+ optional full state) backup with checksums and restore instructions | Creates `~/OpenClaw-backups/<ts>/` only |
| `scripts/termux-verify.sh` | Post-repair gates: config valid, Gemini-primary preserved, gateway listening, channels; plus manual real-message checklist | No |
| `scripts/termux-replace-discord-bot.sh` | Install a new Discord bot token (or a whole replacement bot, `--new-bot`) into an account slot: mandatory backup → hidden prompt → live Discord identity check → secret written only to `.env`, config gets a SecretRef → validate, auto-rollback on failure. Token is never displayed or sent to chat | Yes — backup-gated |

### Replacing a Discord bot / token

Only the account owner can create/reset a token (Discord Developer Portal →
Bot → **Reset Token**); resetting kills the old token instantly, so do the
reset and the install in one sitting. Most 401s need a **token only**, not a
new bot — a new bot must be re-invited to every server and needs its intents
(Message Content) re-enabled. Then, on the phone:

```bash
bash scripts/termux-replace-discord-bot.sh --account default       # primary
bash scripts/termux-replace-discord-bot.sh --account automation    # automation bot
bash scripts/termux-replace-discord-bot.sh --account default --new-bot   # whole new bot, same slot/binding
```

Restart the gateway in tmux afterwards and verify with a real Discord DM.
Never paste a token into chat, logs, or git.

Constraints honoured throughout: existing agents/config/Gemini-primary routing
preserved · no Docker/systemd/paid services/OpenRouter · no reinstall unless
proven necessary.

**Current status:** awaiting Phase 1 diagnostic output from the device (this
repo's CI/sandbox is not the phone — see runbook finding F0).
