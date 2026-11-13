#!/bin/bash
# PreToolUse guard: refuse Write/Edit/NotebookEdit targets inside a submodule checkout.
# Files written there are untracked by this repo and get lost on `git clean`,
# re-clone, or a submodule update. Study output belongs in notes/, research/ or references/.
#
# Exit 2 = block the tool call; stderr is shown to Claude as the reason.

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$root" ] && [ -f "$root/.gitmodules" ] || exit 0

target=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -n "$target" ] || exit 0

# Make the path repo-relative (it may arrive absolute or relative).
case "$target" in
  "$root"/*) rel="${target#"$root"/}" ;;
  /*) exit 0 ;;  # outside the repo: not our concern
  *) rel="${target#./}" ;;
esac

while read -r _ sm; do
  case "$rel" in
    "$sm"/*)
      echo "Blocked: '$rel' is inside the submodule '$sm'. Files there are untracked by this repo and are lost on git clean, re-clone or submodule update. Write study output to research/, notes/ or references/ instead (e.g. research/<project>/...)." >&2
      exit 2 ;;
  esac
done < <(git -C "$root" config -f .gitmodules --get-regexp '\.path$')

exit 0
