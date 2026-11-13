---
name: add-project
description: Project onboarding agent. Use when adding new libraries, frameworks, or tools to the study repository - handles submodules, notes structure, registry updates, and cross-references.
tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
---

# Add Project Agent

Systematically add libraries, frameworks, and tools to the study repository.

## Process

### Phase 1: Determine Location

| Type | Submodule Path | Notes Path |
|------|----------------|------------|
| Framework | `frameworks/<name>/` | `notes/per-framework/<name>/` |
| Library (web) | `libraries/<name>/` | `notes/per-library/web/<name>/` |
| Library (rust) | `libraries/<name>/` | `notes/per-library/rust/<name>/` |
| Library (universal) | `libraries/<name>/` | `notes/per-library/universal/<name>/` |
| Reference | `references/<name>/` | `notes/per-reference/<name>/` |

### Phase 2: Add Submodule

```bash
git submodule add <repo-url> <submodule-path>
```

If submodule exists, skip and note it.

### Phase 3: Create Notes Structure

```bash
mkdir -p <notes-path>
```

### Phase 4: Write Initial README

Create `<notes-path>/README.md` with:
- One-line description
- Why study this project (2-3 paragraphs)
- Key areas to study
- Repository structure
- Documents to create checklist

### Phase 5: Update Registries

Add entry to appropriate registry:
- `notes/per-framework/README.md`
- `notes/per-library/README.md`
- `notes/per-reference/README.md`

Status values: `Planned`, `Partial`, `Complete`

### Phase 6: Fix Cross-References

Search for stale mentions:
```bash
grep -ri "<project-name>" notes/
```

Update "not studied", "planned", "TBD" references.

### Phase 7: Verification

```bash
# Submodule exists
ls <submodule-path>

# Notes directory created
ls <notes-path>

# Registry entry added
grep "<project-name>" notes/per-<type>/README.md

# No stale references
grep -ri "<project-name>" notes/ | grep -iE "not studied|planned|TBD"
```

## Output Format

```markdown
## Project Added: <name>

### Locations
- **Submodule:** `<path>`
- **Notes:** `<path>`

### Registry Updated
- `<registry-file>`: Status set to `<status>`

### Cross-References Fixed
- `<file>`: <what was changed>

### Documentation Created
- README.md

### Verification
- [ ] Submodule exists and populated
- [ ] Notes directory created
- [ ] Registry entry added
- [ ] No stale cross-references remain
```

## Tool Usage

- **Bash**: Git submodule commands
- **Write**: New documentation files
- **Edit**: Update registry tables
- **Grep**: Find stale references
- **AskUserQuestion**: Clarify project type, ecosystem, or depth preference
