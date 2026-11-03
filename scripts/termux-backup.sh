#!/usr/bin/env bash
# termux-backup.sh — snapshot OpenClaw config BEFORE any change.
#
# Default: config + .env + recovery artefacts + a manifest with checksums.
#   --full   additionally tar.gz the whole ~/.OpenClaw (excluding logs), which
#            preserves agents/sessions/workspaces config state. Check the size
#            warning first — on a phone this can be large.
#
# Usage:  bash termux-backup.sh [--full]
# Backups land in ~/OpenClaw-backups/<timestamp>/  (dir 700, files 600)
# Then download a copy off-device via Remote Desktop Commander / adb / scp.

set -eu
set +x
umask 077

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

TS="$(date +%Y%m%d-%H%M%S)"
DEST="$HOME/OpenClaw-backups/$TS"

# Resolve the config the gateway actually reads — not a guess.
CFG=""
if command -v OpenClaw >/dev/null 2>&1; then
  CFG="$(timeout 30 OpenClaw config file 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true)"
fi
[ -z "$CFG" ] && [ -f "$HOME/.OpenClaw/OpenClaw.json" ] && CFG="$HOME/.OpenClaw/OpenClaw.json"
[ -z "$CFG" ] && [ -f /root/.OpenClaw/OpenClaw.json ] && CFG="/root/.OpenClaw/OpenClaw.json"

if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
  echo "ERROR: could not locate OpenClaw.json in this shell." >&2
  echo "Run this inside the SAME environment that runs OpenClaw (proot vs native matters)." >&2
  exit 1
fi

STATE_DIR="$(dirname "$CFG")"
mkdir -p "$DEST"
chmod 700 "$DEST" "$HOME/OpenClaw-backups" 2>/dev/null || true
[ ! -e "$DEST/MANIFEST.txt" ] || { echo "ERROR: $DEST already has a backup; refusing to overwrite." >&2; exit 1; }

echo "Backing up config: $CFG"
cp -p "$CFG" "$DEST/OpenClaw.json"

# OpenClaw's own recovery artefacts are cheap insurance; copy them too.
for f in "$CFG".bak* "$CFG".last-good* "$STATE_DIR/.env"; do
  [ -f "$f" ] && cp -p "$f" "$DEST/$(basename "$f")" && echo "  + $(basename "$f")"
done

{
  echo "backup-created: $(date -Iseconds 2>/dev/null || date)"
  echo "source-config:  $CFG"
  echo "source-statedir:$STATE_DIR"
  echo "host: $(hostname 2>/dev/null || echo android)  user: $(whoami)"
  command -v OpenClaw >/dev/null 2>&1 && echo "openclaw: $(timeout 30 OpenClaw --version 2>/dev/null | head -n1)"
  echo "files:"
  ls -l "$DEST"
} > "$DEST/MANIFEST.txt"

if [ "$FULL" = 1 ]; then
  echo "Full mode: archiving $STATE_DIR (excluding logs)…"
  du -sh "$STATE_DIR" 2>/dev/null || true
  tar -czf "$DEST/openclaw-state.tar.gz" --exclude='*.log' --exclude='logs' -C "$(dirname "$STATE_DIR")" "$(basename "$STATE_DIR")" \
    && echo "  + openclaw-state.tar.gz ($(wc -c < "$DEST/openclaw-state.tar.gz" | tr -d ' ') bytes)" \
    || echo "  ! full tar failed (config backup above is still valid)" >&2
fi

cat > "$DEST/RESTORE.md" <<EOF
# Restore (only if a repair makes things worse)

1. Stop the gateway (in its tmux session: Ctrl-C; or \`OpenClaw gateway stop\` if you use that flow).
2. Save the broken file for forensics:  \`cp "$CFG" "$CFG.broken-\$(date +%Y%m%d-%H%M%S)"\`
3. Restore:  \`cp "$DEST/OpenClaw.json" "$CFG"\`  (and \`.env\` likewise if you changed it)
4. \`OpenClaw config validate\`  -> must pass before starting the gateway.
5. Start the gateway the normal way (tmux foreground on Termux) and verify.

Verify this backup at any time:  \`cd "$DEST" && sha256sum -c SHA256SUMS\`
EOF

# Lock down EVERYTHING including dotfiles (.env), then checksum last so the
# sums cover the final file set.
find "$DEST" -type f -exec chmod 600 {} + 2>/dev/null || true
( cd "$DEST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -exec sha256sum {} + > SHA256SUMS 2>/dev/null \
  && chmod 600 SHA256SUMS ) || true

echo
echo "Backup complete: $DEST"
( cd "$DEST" && sha256sum -c SHA256SUMS 2>/dev/null ) || echo "(verify later: cd $DEST && sha256sum -c SHA256SUMS)"
echo "NEXT: copy this folder OFF the phone (Remote Desktop Commander download / adb pull / scp)."
echo "Do not make config changes until the checksums say OK."
