#!/bin/bash
# Update submodules to their upstream default branch, safely.
#
#   scripts/update_submodules.sh            # check + snapshot + update all non-frozen
#   scripts/update_submodules.sh --check    # only report untracked files and drift; change nothing
#   scripts/update_submodules.sh PATH...    # update only these submodules
#
# Steps:
#   1. Refuse if any submodule holds untracked files that aren't build output or .DS_Store
#      (that is usually study work saved in the wrong place; move it to research/ first).
#   2. Prepend a dated "studied-at" snapshot to notes/SUBMODULE-PINS.md so the
#      file:line references in notes stay traceable to the commit they were written against.
#   3. `git submodule update --remote --checkout` (follows each remote's default branch).
#   4. Print how many commits each submodule moved.
#
# Nothing is staged or committed: review with `git status` and commit yourself.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

# Upstreams that are dormant or deliberately pinned to the studied release.
# (Not frozen but worth knowing: frameworks/p5js tracks `branch = v1` in .gitmodules because
#  the notes describe p5.js 1.x; upstream main became 2.x in 2026. Don't "fix" it back to main.)
FROZEN="demoscene/apex-public demoscene/fr_public frameworks/harfang3d libraries/ltc_code libraries/rend3
libraries/processing-ecosystem/controlp5 libraries/processing-ecosystem/toxiclibs
libraries/universal/mixbox"

# Untracked paths inside submodules that are safe to ignore.
NOISE='(^|/)(\.DS_Store|obj/|__pycache__/|node_modules/|target/|build/)$'

# Many clones are shallow, where `rev-list A..B` counts the whole history behind the
# shallow boundary (tens of thousands). Count commits on B newer than A by date instead.
approx_count() {  # <path> <from-commit> <to-ref>
  git -C "$1" rev-list --count --since="$(git -C "$1" log -1 --format=%cI "$2")" "$3" 2>/dev/null || echo "?"
}

PINS=notes/SUBMODULE-PINS.md
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && { CHECK_ONLY=1; shift; }

ALL=$(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}' | sort)
if [ $# -gt 0 ]; then
  TARGETS="$*"
else
  TARGETS=$(for p in $ALL; do echo "$FROZEN" | tr ' ' '\n' | grep -qx "$p" || echo "$p"; done)
fi

# 1. Untracked-work check
echo "== Untracked files inside submodules =="
blocked=0
for p in $ALL; do
  stray=$(git -C "$p" status --porcelain --untracked-files=normal 2>/dev/null | grep '^??' | cut -c4- | grep -vE "$NOISE")
  if [ -n "$stray" ]; then
    blocked=1
    echo "  $p:"; echo "$stray" | sed 's/^/      /' | head -10
  fi
done
[ $blocked -eq 0 ] && echo "  none"
if [ $blocked -eq 1 ]; then
  echo "Refusing to update: move the files above into research/ or references/ first." >&2
  exit 1
fi

if [ $CHECK_ONLY -eq 1 ]; then
  echo "== Drift (fetching; this may take a while) =="
  for p in $TARGETS; do
    git -C "$p" fetch --quiet origin 2>/dev/null
    br=$(git config -f .gitmodules "submodule.$p.branch" || echo HEAD)  # e.g. p5js tracks v1
    printf "  %-44s %6s commits behind origin/%s\n" "$p" "~$(approx_count "$p" HEAD "origin/$br")" "$br"
  done
  exit 0
fi

# 2. Snapshot
today=$(date +%Y-%m-%d)
snap=$(mktemp)
{
  echo "## Snapshot $today (before update)"
  echo
  echo "| Path | Commit | Commit date | Branch / tag |"
  echo "|------|--------|-------------|--------------|"
  for p in $ALL; do
    echo "| \`$p\` | \`$(git -C "$p" rev-parse --short=12 HEAD)\` | $(git -C "$p" log -1 --format=%cs) | $(git -C "$p" describe --all --always 2>/dev/null | sed 's#heads/##') |"
  done
  echo
} > "$snap"
# Insert the new snapshot right after the file's intro (everything before the first "## ").
awk -v snapfile="$snap" '
  /^## / && !done { while ((getline l < snapfile) > 0) print l; done=1 }
  { print }
  END { if (!done) while ((getline l < snapfile) > 0) print l }
' "$PINS" > "$PINS.tmp" && mv "$PINS.tmp" "$PINS"

# 3. Update
before=$(mktemp)
for p in $TARGETS; do echo "$p $(git -C "$p" rev-parse HEAD)"; done > "$before"
echo "== Updating $(echo $TARGETS | wc -w | tr -d ' ') submodules =="
git submodule update --remote --checkout --jobs 6 $TARGETS 2>&1 \
  | grep -vE '^(remote:|Receiving|Resolving|Unpacking|Updating files)'

# 4. Report
echo "== Result =="
while read -r p old; do
  new=$(git -C "$p" rev-parse HEAD)
  printf "  %-44s %6s commits  now %s\n" "$p" "~$(approx_count "$p" "$old" "$new")" "$(git -C "$p" log -1 --format='%h %cs')"
done < "$before"
rm -f "$snap" "$before"
echo "Snapshot written to $PINS. Review with 'git status' and commit when ready."
