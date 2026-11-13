---
name: update-submodules
description: Safely update the studied framework/library submodules to upstream - checks for study work stranded inside submodules, snapshots the studied-at commits, updates, and reports drift and notes affected.
disable-model-invocation: true
argument-hint: "[--check | path...]"
---

# Update Submodules

Run the repo's update script, then interpret the result for the user.

1. Run `scripts/update_submodules.sh $ARGUMENTS` from the repo root. With no arguments it updates every submodule except the frozen list at the top of the script. Large repos (filament, wgpu, threejs, babylonjs) take minutes, so run it in the background.
2. **If it refuses** because of untracked files inside a submodule, that is usually study work saved in the wrong place. Show the user the files and offer to move them into `research/<project>/` (scripts, extracted data) or `references/<project>/` (papers, datasets), then rewrite any note paths that pointed at the old location and verify the new paths exist. Never delete these files.
3. **After a successful update**, report the per-submodule commit counts. For each submodule that moved, count the notes that cite it:
   `grep -rlE '<submodule-path>/[^ ]+:[0-9]+' notes insights | wc -l`
   Point out that those `file:line` references may now be off and are resolvable via the dated snapshot in `notes/SUBMODULE-PINS.md`. Do not re-verify line numbers unless asked.
4. Leave the result unstaged and uncommitted (this repo denies `git commit`). Summarise what changed for the user to review.

If an upstream has gone dormant or should stay pinned to the studied release, suggest adding it to `FROZEN` in the script.
