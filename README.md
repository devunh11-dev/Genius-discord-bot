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

Constraints honoured throughout: existing agents/config/Gemini-primary routing
preserved · no Docker/systemd/paid services/OpenRouter · no reinstall unless
proven necessary.

**Current status:** awaiting Phase 1 diagnostic output from the device (this
repo's CI/sandbox is not the phone — see runbook finding F0).
