#!/usr/bin/env bash
# Install this skill into the dsh skills directory (macOS / Linux / Git Bash).
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${DSH_SKILLS_DIR:-$HOME/.dsh/skills}/lan-forward"

mkdir -p "$DEST"
cp "$SRC/SKILL.md" "$DEST/"
rm -rf "$DEST/scripts"
cp -R "$SRC/scripts" "$DEST/"
rm -rf "$DEST/scripts/.run"

chmod +x "$DEST/scripts/"*.sh 2>/dev/null || true

echo "installed -> $DEST"
echo "scripts   : $DEST/scripts"
echo "next      : open a new dsh session; the 'lan-forward' skill appears in the catalog"
