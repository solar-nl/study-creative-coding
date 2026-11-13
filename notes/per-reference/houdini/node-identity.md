# Node Identity in Houdini: The Path Is the Name Is the Identity

> *A follow-up to [Node Instance Identity](../../../insights/node-instance-identity.md): Houdini is the largest production system whose node identity is a name path, the scheme closest to Flux's.*

---

## The Problem

A Houdini scene can hold thousands of nodes wired together and cross-referenced by expressions: a copy's radius follows a sphere's radius, an Object Merge pulls geometry from another network, a shader reads a parameter three levels up. Artists rename and reorganise constantly. If identity is the name, how does any of that keep working?

## Mental Model: A Filesystem With a Smart `mv`

Houdini's own documentation reaches for the filesystem analogy: paths are "very similar to a UNIX file system", with `.` for here and `..` for up one level ([network/paths](https://www.sidefx.com/docs/houdini/network/paths.html)). A node's identity is its path, `/obj/geo1/sphere1`, the same way a file's identity is its path.

The difference is the `mv` command. Renaming a file breaks every script that hard-coded its path. Renaming a Houdini node runs a smarter `mv` that also rewrites every reference Houdini knows about. Everything depends on what "knows about" covers.

---

## What Identifies a Node

**The path, and nothing persistent beside it.** "Every node and parameter has a unique pathname you can use to refer to it" ([network/paths](https://www.sidefx.com/docs/houdini/network/paths.html)); `hou.Node.path()` returns "the full path ... of this node in the network" ([hom/hou/Node](https://www.sidefx.com/docs/houdini/hom/hou/Node.html)).

Houdini does have a numeric id, but it is session-scoped. `sessionId()` "uniquely identifies this item in a given Houdini session" and is "only guaranteed to be unique in a single Houdini process" ([hom/hou/NetworkMovableItem](https://www.sidefx.com/docs/houdini/hom/hou/NetworkMovableItem.html)). No persistent per-node UUID is documented. This is the same three-tier shape as Flux: a persistent name-based identity on disk and a per-process identity in memory.

**Names are constrained.** `setName` fails if the name contains characters "other than letters, numbers, periods, dashes, or underscores", if another node already has the name, for top-level managers like `/obj`, and inside a locked asset ([NetworkMovableItem](https://www.sidefx.com/docs/houdini/hom/hou/NetworkMovableItem.html)). Like Flux's name grammar, the character rules keep names safe to splice into paths.

## How Nodes Are Referenced

| Reference form | Example | Tracked by Houdini? |
|----------------|---------|---------------------|
| Wires (node inputs) | Input 0 of `copy1` is `sphere1` | Yes (structural) |
| Channel references | `ch("../grid1/ry")`, `ch("/obj/lamp/tx")`, `chs(...)` for strings | Yes |
| Operator path parameters | Object Merge's "Object 1" path field | Yes (per forum evidence below) |
| `op:` path prefixes in strings | `op:/obj/geo1/out` | No (forum evidence) |
| Paths inside VEX code | `point("/obj/geo1/box1", ...)` | No (forum evidence) |
| Paths inside Python code | `hou.node("/obj/geo1")` in an asset module | No (forum evidence) |

Channel references take "a (possibly relative) path from the current node to the parameter" ([network/expressions](https://www.sidefx.com/docs/houdini/network/expressions.html)). Dependency tracking "works at the parameter level" ([network/dependencies](https://www.sidefx.com/docs/houdini/network/dependencies.html)), and `hou.OpNode.references()` / `dependents()` expose the tracked graph ([hom/hou/OpNode](https://www.sidefx.com/docs/houdini/hom/hou/OpNode.html)).

## Rename: Rewrite What Is Tracked

The official promise is strong: "Houdini automatically updates any existing references to the node in the scene", so "you don't have to worry about renaming a node breaking expressions" ([network/rename](https://www.sidefx.com/docs/houdini/network/rename.html)). The copying docs repeat it: "Houdini will automatically update all references to a node if you rename it" ([network/copying](https://www.sidefx.com/docs/houdini/network/copying.html)).

The limits come from the community rather than SideFX's docs, so treat them as strong hints, not specification:

- `ch()` references are tracked, but an `op:` prefix in a string is not; `opfullpath()` exists "just to track that dependency", and "none of VEX functions will track dependencies" ([forum topic 81194](https://www.sidefx.com/forum/topic/81194/), community answer).
- Hard-coded `hou.node("/obj/...")` paths in an asset's Python module break on rename; the recommended fix is an Operator Path parameter, which Houdini does update ([forum topic 87304](https://www.sidefx.com/forum/topic/87304/)).

So Houdini's rename is a transaction over its **dependency graph**, not a text search. A reference Houdini parsed into a tracked dependency is rewritten; a path hidden inside code or an untracked string is not.

Mass rename has a collision policy: with "Ensure Unique Names", Houdini adds numbers on conflict, so "no rename will fail because a name is already in use, but the new names may not be exactly as you expected" ([network/rename](https://www.sidefx.com/docs/houdini/network/rename.html)).

## Copy and Paste

Copying is where relative paths earn their keep. From [hom/hou/copyNodesTo](https://www.sidefx.com/docs/houdini/hom/hou/copyNodesTo.html):

- "if a node with the same name already exists at the destination, the copy will be renamed."
- Relative channel references between nodes with the same parent are updated to point at the copies; nodes are copied in batches per parent.
- References between nodes with **different** parents are not updated, so they keep pointing at the originals.

Relative references make a copied cluster self-contained; absolute ones tie it to the source. The copying docs advise an absolute reference "if the source and destination are in different networks, or if you might move the destination node" ([network/copying](https://www.sidefx.com/docs/houdini/network/copying.html)).

## Type Identity: Fixed Name Plus Version

Digital asset *types* follow different rules from node instances. A type name has the form `[namespace::]node_name[::version]`, for example `acme::copy::2.0`, and "instances of the old version will still work and use the old implementation" ([assets/namespaces](https://www.sidefx.com/docs/houdini/assets/namespaces.html)). The internal name is permanent: "you can't change the internal name without recreating the asset" ([assets/create](https://www.sidefx.com/docs/houdini/assets/create.html)).

Upgrades are explicit. A version in the type name makes "each version an entirely different asset" with "no provision to upgrade old nodes automatically"; the alternative Version field runs an upgrade handler script when an instance loads ([assets/versioning_systems](https://www.sidefx.com/docs/houdini/assets/versioning_systems.html)). This is the same move vvvv makes with obsolete nodes and converters: when you cannot rewrite every user, keep the old name working and migrate on load.

---

## Lessons for Flux

| Houdini | Flux implication |
|---------|------------------|
| Path is the persistent identity; `sessionId` is per-process | Same three-tier shape as Flux's name-path authored IDs and reminted live IDs; Houdini shows it scales to production |
| Rename rewrites every *tracked* reference | A Flux rename transaction should be driven by typed references in the source model, not by string search, so the set of rewritten references is exactly the set the model knows about |
| Untracked strings (VEX, Python, `op:` strings) break silently | Don't let node paths live in free-form strings; if a reference must be stored, give it a typed field the rename transaction can see |
| Relative references make copies self-contained | Store intra-symbol references relative to the symbol so copy/paste and symbol duplication don't need a rewrite |
| Asset types: permanent internal name + version + upgrade handler | For symbol/library rename across projects Flux cannot rewrite, keep the old name resolvable and migrate on load |

## Sources

Official SideFX documentation (fetched 2026-10-15): [network/paths](https://www.sidefx.com/docs/houdini/network/paths.html), [network/rename](https://www.sidefx.com/docs/houdini/network/rename.html), [network/copying](https://www.sidefx.com/docs/houdini/network/copying.html), [network/expressions](https://www.sidefx.com/docs/houdini/network/expressions.html), [network/dependencies](https://www.sidefx.com/docs/houdini/network/dependencies.html), [hom/hou/Node](https://www.sidefx.com/docs/houdini/hom/hou/Node.html), [hom/hou/OpNode](https://www.sidefx.com/docs/houdini/hom/hou/OpNode.html), [hom/hou/NetworkMovableItem](https://www.sidefx.com/docs/houdini/hom/hou/NetworkMovableItem.html), [hom/hou/copyNodesTo](https://www.sidefx.com/docs/houdini/hom/hou/copyNodesTo.html), [assets/namespaces](https://www.sidefx.com/docs/houdini/assets/namespaces.html), [assets/create](https://www.sidefx.com/docs/houdini/assets/create.html), [assets/versioning_systems](https://www.sidefx.com/docs/houdini/assets/versioning_systems.html). Community forum: [topic 81194](https://www.sidefx.com/forum/topic/81194/), [topic 87304](https://www.sidefx.com/forum/topic/87304/).

Not covered: how `.hip` files key nodes internally (the text format is "undocumented and subject to change"), and whether moving nodes into a subnet rewrites references.
