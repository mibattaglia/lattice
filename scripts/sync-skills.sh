#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SKILLS="$ROOT_DIR/skills"
CLAUDE_SKILLS="$ROOT_DIR/.claude/skills"
BASE_RULES="$BASE_SKILLS/skill-rules.json"
CLAUDE_RULES="$CLAUDE_SKILLS/skill-rules.json"

mkdir -p "$BASE_SKILLS" "$CLAUDE_SKILLS"

# Bidirectional sync using newer mtimes as the source of truth.
# Note: deletions are not propagated automatically. Remove manually on both sides when needed.
rsync -a -u "$BASE_SKILLS/" "$CLAUDE_SKILLS/"
rsync -a -u "$CLAUDE_SKILLS/" "$BASE_SKILLS/"

if [[ -f "$BASE_RULES" || -f "$CLAUDE_RULES" ]]; then
  if [[ -f "$BASE_RULES" ]]; then
    rsync -a -u "$BASE_RULES" "$CLAUDE_RULES"
  fi
  if [[ -f "$CLAUDE_RULES" ]]; then
    rsync -a -u "$CLAUDE_RULES" "$BASE_RULES"
  fi
fi

echo "Synced skills between $BASE_SKILLS and $CLAUDE_SKILLS"
