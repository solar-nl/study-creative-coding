# Architecture Decisions

Architecture Decision Records (ADRs) for your Rust framework.

## Template

```markdown
## ADR-XXX: Title

**Status**: Proposed | Accepted | Deprecated | Superseded

**Context**: What is the issue?

**Decision**: What is the change?

**Consequences**: What are the results?
```

---

## ADR-001: Workspace Organization

**Status**: Proposed

**Context**:
Framework code needs to be modular for:
- Different feature sets (2D only, 3D, audio)
- Cross-platform targets
- Optional dependencies

**Decision**:
Organize as a Cargo workspace with separate crates:
- `framework_core` — No-std compatible core (math, color, geom)
- `framework_graphics` — 2D/3D drawing (requires wgpu)
- `framework_audio` — Audio processing
- `framework` — Main crate that re-exports

**Consequences**:
- Clear separation of concerns
- Users can depend on only what they need
- Follows nannou's proven pattern

---

## ADR-002: Graphics Backend

**Status**: Proposed

**Context**:
Need cross-platform graphics for desktop, mobile, web.

**Decision**:
Use wgpu as the graphics backend.

**Consequences**:
- Native performance via Vulkan/Metal/DX12
- Web support via WebGPU
- Well-maintained Rust ecosystem
- Learning curve for contributors

---

## ADR-003: Drawing API Paradigm

**Status**: Proposed

**Context**:
Creative coding benefits from immediate-mode drawing, but GPUs work best with retained-mode batching.

**Decision**:
Provide immediate-mode API that internally batches to wgpu.

**Consequences**:
- Simple user code (`draw.ellipse()`)
- Internal complexity to batch efficiently
- Balance between convenience and performance

---

*Add more ADRs as decisions are made.*
