#!/bin/bash
# Ask the study repo's `consult` agent a question from another project.
#
#   scripts/consult.sh "How do openrndr and nannou structure their draw context?"
#   scripts/consult.sh --resume <session_id> "Follow-up question"
#
# Runs a headless, read-only Claude session inside this repo (so it loads this repo's
# CLAUDE.md, agents and hooks). Prints the answer, then a final line
# `consult-session: <id>` that can be passed to --resume for a follow-up.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

resume=()
if [ "${1:-}" = "--resume" ]; then resume=(--resume "$2"); shift 2; fi
[ $# -ge 1 ] || { echo "usage: $0 [--resume <session_id>] \"question\"" >&2; exit 2; }

cd "$REPO"
out=$(claude -p "$*" ${resume[@]+"${resume[@]}"} \
  --agent consult \
  --allowedTools "Read,Grep,Glob,Bash(gh search:*),Bash(gh issue view:*),Bash(gh issue list:*),Bash(gh pr view:*)" \
  --output-format json)

echo "$out" | jq -r '.result'
echo
echo "consult-session: $(echo "$out" | jq -r '.session_id')"
