# Notes

Documentation and analysis for the creative coding frameworks study.

## Contents

| Folder | Description |
|--------|-------------|
| [per-framework/](./per-framework/) | Deep dives into each creative coding framework |
| [per-library/](./per-library/) | Analysis of reusable libraries |
| [per-example/](./per-example/) | Notes on example repositories |
| [themes/](./themes/) | Cross-cutting analysis by topic |

## Key Documents

- [FRAMEWORK_COMPARISON.md](./FRAMEWORK_COMPARISON.md) — High-level comparison matrix across all frameworks
- [READING_GUIDE.md](./READING_GUIDE.md) — How to effectively read this documentation (cognitive science-based)

## Documentation Structure

Each framework/library folder follows a consistent template:

```
{name}/
├── README.md              # Overview, key insights, entry points
├── architecture.md        # Module structure, dependencies
├── rendering-pipeline.md  # How drawing commands become pixels
├── api-design.md          # API patterns, ergonomics
└── code-traces/           # Annotated source walkthroughs (optional)
```

See [../templates/](../templates/) for the full documentation templates.
