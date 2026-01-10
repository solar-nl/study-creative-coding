# Adding a Library or Framework to Study

> Checklist for systematically adding new materials under study

---

## Before You Start

Determine the correct location:

| Type | Submodule Path | Notes Path |
|------|----------------|------------|
| Framework | `frameworks/<name>/` | `notes/per-framework/<name>/` |
| Web library | `libraries/<name>/` | `notes/per-library/web/<name>/` |
| Rust library | `libraries/<name>/` | `notes/per-library/rust/<name>/` |
| Universal library | `libraries/<name>/` | `notes/per-library/universal/<name>/` |
| Ecosystem library | `libraries/<name>/` | `notes/per-library/<ecosystem>/<name>/` |

---

## Checklist

### 1. Add Submodule

```bash
# For libraries
git submodule add <repo-url> libraries/<name>

# For frameworks
git submodule add <repo-url> frameworks/<name>

# Verify
ls libraries/<name>  # or frameworks/<name>
```

- [ ] Submodule added and cloned successfully
- [ ] `.gitmodules` updated

### 2. Create Notes Structure

Create the directory and initial README:

```bash
mkdir -p notes/per-library/<ecosystem>/<name>
# or
mkdir -p notes/per-framework/<name>
```

- [ ] Directory created in correct hierarchy
- [ ] `README.md` created with:
  - [ ] Why study this library (problem it solves)
  - [ ] Key areas to explore
  - [ ] Repository structure overview
  - [ ] Comparison with similar libraries

### 3. Update Registries

Update the status tables:

- [ ] **`notes/per-library/README.md`** or **`notes/per-framework/README.md`**
  - Add entry if missing
  - Update status: `Planned` → `Partial` → `Complete`
  - Update description if needed

### 4. Update Cross-References

Search for stale mentions:

```bash
# Search all notes for mentions of the library
grep -ri "<library-name>" notes/

# Common patterns to fix:
# - "not studied"
# - "not studied in depth"
# - "planned"
# - "TBD"
# - "(see X for alternatives)"
```

Files that commonly have cross-references:

- [ ] `notes/FRAMEWORK_COMPARISON.md`
- [ ] `notes/themes/**/*.md` (thematic analyses)
- [ ] Other library READMEs (comparison tables)
- [ ] `CLAUDE.md` (if mentioned as planned)

### 5. Write Documentation

Standard documentation set (follow [STYLE_GUIDE.md](./STYLE_GUIDE.md)):

- [ ] `README.md` — Overview and document index
- [ ] `architecture.md` — Package structure, entry points, module organization
- [ ] `rendering-pipeline.md` — Frame flow, draw calls, GPU command encoding
- [ ] `api-design.md` — API patterns worth extracting for Rust framework

Optional depending on library:

- [ ] `webgpu-*.md` — WebGPU-specific implementation
- [ ] `node-materials.md` — Visual shader system
- [ ] Feature-specific traces as needed

### 6. Verify

Run final checks:

```bash
# No stale references remaining
grep -ri "<library-name>" notes/ | grep -i "not studied\|planned\|TBD"

# Registry shows correct status
grep "<library-name>" notes/per-library/README.md
# or
grep "<library-name>" notes/per-framework/README.md

# Only one notes directory exists (no duplicates)
find notes -type d -name "<library-name>"
```

- [ ] No stale "not studied" or "planned" references
- [ ] Registry status is accurate
- [ ] Single canonical notes directory
- [ ] Documentation follows style guide

---

## Example: Adding Babylon.js

```bash
# 1. Add submodule
git submodule add https://github.com/BabylonJS/Babylon.js.git libraries/babylonjs

# 2. Create notes
mkdir -p notes/per-library/web/babylonjs

# 3. Update registry
# Edit notes/per-library/README.md:
# | [babylonjs](./web/babylonjs/) | Complete | Full-featured 3D game engine |

# 4. Fix cross-references
grep -ri "babylon" notes/
# Update: notes/FRAMEWORK_COMPARISON.md line 60

# 5. Write docs
# - README.md, architecture.md, rendering-pipeline.md, etc.

# 6. Verify
grep -ri "babylon" notes/ | grep -i "not studied"
# Should return nothing
```

---

## Status Definitions

| Status | Meaning |
|--------|---------|
| **Planned** | Submodule added, no documentation yet |
| **Partial** | README and some docs exist, exploration incomplete |
| **Complete** | Full documentation set with architecture traces |
