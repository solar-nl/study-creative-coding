# Node Instance Identity: Names, IDs, and the Rename Problem

You rename a node in the editor from `blur` to `softGlow`. Several things were pointing at that node: the wires into and out of it, an animation curve driving its radius, an exposed parameter on the parent symbol that forwards to it, the position it occupies on the canvas, the selection in a second view, the undo history, and possibly an override in another file that reaches into this symbol. After the rename, which of those still point at the right thing?

Every node-graph system has to answer that question, and the answer depends on one design choice: **what a node's identity is made of**. This note compares how tixl, cables.gl, werkkzeug4, apEx and three.js answer it. It places Flux's current design (deterministic, name-derived identifiers) on the same map and turns Flux's open work item, a rename transaction, into a concrete specification.

**The short version:** Flux's name-derived IDs are a defensible choice for its requirements, and one other studied system, werkkzeug4, worked the same way and shipped a rename transaction. The risk is not the ID scheme. The risk is a rename transaction that misses one kind of reference. The reference inventory in [What a Rename Must Rewrite](#what-a-rename-must-rewrite) is the checklist.

---

## Three Ways to Name a House

Think of three ways to direct mail to a house:

- **By description**: "the house with the red door on Elm Street." Anyone can read it and anyone can write it down, but paint the door blue and the mail goes astray. This is **identity as name** (werkkzeug4).
- **By plate number**: a random number issued once and printed on a plate by the door. It survives repainting, renaming, even moving the plate to a new street, but nobody can work it out from looking at the house, and a copy of the house needs a new number. This is **identity as a random persisted ID** (tixl, cables, apEx, three.js).
- **By a computed code**: hash the street and the house name into a postcode. Anyone holding the same street plan computes the same code without a registry, but rename the house and its code changes, so you must send a forwarding order to everyone who has the old one. This is **identity as a hash of the name path** (Flux, and cables inside reusable subpatches).

None of these is wrong. Each makes a different operation cheap and a different operation dangerous.

---

## Identity Lives in Three Tiers

Before comparing systems, separate three different identities that are easy to conflate. Every system studied has all three, even if it doesn't name them.

| Tier | What it identifies | Lifetime | Example |
|------|-------------------|----------|---------|
| **Authored identity** | A child placed inside a symbol definition, as saved on disk | As long as the file exists | tixl `Symbol.Child.Id`, cables `op.id`, Flux serialized child IDs |
| **Instance identity** | One live use of that child; a compound used twice has two instances | One session | tixl `Instance.InstancePath`, Flux live node IDs |
| **Runtime handle** | A slot in the executor's arrays | One compilation | Indices into a compiled plan; apEx player indices |

The rename problem is almost entirely a problem of the **authored tier**. Instance and runtime identities are derived and can be reminted freely: tixl rebuilds instances from paths of authored IDs, Flux remints live IDs on every instantiation, and apEx's player turns everything into array indices. So the questions in this note are about what goes on disk and what references it.

---

## The Map: Determinism vs. Rename Stability

Two properties pull against each other:

- **Deterministic generation:** the same authored structure always produces the same IDs, without consulting a previous file. This is what makes generator-produced projects reproducible and regenerated files diff cleanly.
- **Rename stability:** renaming something leaves its ID and every reference to it untouched.

| System | Authored identity | Deterministic? | Rename-stable? | Rename strategy |
|--------|------------------|----------------|----------------|-----------------|
| werkkzeug4 | The store name the author typed | Yes (the name *is* the ID) | No | Transaction: `RenameAllOps` rewrites every link |
| tixl | Random GUID per child, persisted | No at birth, stable after | Yes | Nothing to do; name is a label |
| cables.gl | Random 9-char id per op; UUID per op type | No | Yes for ops and types; **no for ports** | Port renames relink by name, best effort |
| cables.gl blueprints | Hash of instance prefix + original id | Yes | n/a (inner ids derived per instance) | Original id kept as a second key |
| apEx | 128-bit GUID per resource, name alongside | No | Yes | Nothing to do; name is a label |
| three.js | `uuid` per object, `name` alongside | No | Yes | Nothing to do |
| vvvv gamma | Random persisted Id per element; node→definition by **name** | No (structure) / Yes (definition refs) | Structure yes; definition refs no | Editor rewrites callers in loaded documents; libraries keep obsolete forwards |
| Houdini | Node path (`/obj/geo1/box1`); session-only numeric id | Yes (the path is the name) | No | Rename rewrites every *tracked* reference (`ch()`, operator paths); untracked strings break |
| **Flux** | UUIDv5 of the child's name path | Yes | **No** | Rename = new ID; in-file references rewritten on export; editor rename disabled until a transaction exists |

The interesting row is the first one, because werkkzeug4 sits exactly where Flux sits.

### werkkzeug4: names as identity, with a rename transaction

In werkkzeug4, an operator becomes referenceable by giving it a name, which makes it a *store*. Other operators reach it through a `LinkName` string. Every time the document connects, werkkzeug4 resolves the names from scratch:

- **Collect:** named ops become stores, and names must be C-style identifiers (`demoscene/fr_public/altona_wz4/altona/main/wz4lib/doc.cpp:2658-2667`).
- **Reject duplicates:** a repeated store name is a connect error on both ops (`doc.cpp:2674-2682`).
- **Resolve:** each link looks up its target by string, `FindStore(link->LinkName)`, and an unknown name is the error "link/load name not found" (`doc.cpp:2706-2713`).

Renaming would break every `LinkName`, so werkkzeug4 has a document-wide rename: `wDocument::RenameAllOps(from, to)` (`doc.cpp:3585-3605`). It does three things in order:

1. **Refuse on collision.** If any op is already called `to`, return without changing anything.
2. **Rewrite name and references together.** Change the op's name, and every `LinkName` equal to `from` anywhere in the document.
3. **Reconnect.** Re-run the resolution pass so errors surface immediately.

The editor exposes both a plain rename and a "rename all" command (`gui.hpp:226-227,285`), so the transaction is a choice the author makes. This is the werkkzeug4 lesson for Flux: **a name-derived identity works if the rename is a single document-wide transaction that knows every place a name can appear.** Its blind spot is the same one Flux would have: any reference stored somewhere the transaction doesn't scan is silently left behind.

### tixl: random GUIDs, names as labels

tixl gives every placed child a GUID when it is created (`Guid.NewGuid()` in the add-child command) and never derives one from a name. A connection is four GUIDs, `SourceParentOrChildId`, `SourceSlotId`, `TargetParentOrChildId` and `TargetSlotId` (`visual-programming/tixl/Core/Operator/Symbol.ConnectionSubClasses.cs:82-85`), so no reference anywhere contains a name.

- **Child rename** only sets a display string; the command looks the child up by ID and changes nothing else (`Editor/UiModel/Commands/Graph/ChangeSymbolChildNameCommand.cs`).
- **Slot rename** keeps the slot GUID. The command's own comment: "The slot's Guid is left untouched by a rename, so connections and animations survive both directions" (`Editor/UiModel/Commands/Graph/RenameSlotCommand.cs:6-10`). The cost is elsewhere: slot GUIDs are declared in C# attributes, so the rename rewrites source and recompiles.
- **Diffability without determinism.** tixl writes children and inputs sorted by ID and connections sorted by target (`Core/Model/SymbolJson.cs`), so saving an unchanged symbol produces identical bytes. Random IDs only cause save churn if they are *reminted*; minted once and persisted, they diff cleanly.

tixl does have deterministic IDs, but only as a repair tool. `Child.CreateIdDeterministically` hashes the symbol ID and parent ID (`Core/Operator/Symbol.Child.cs:321-346`). It is used for parentless root instances and to resolve ID collisions after copy/paste, and the code admits its limit: a collision with a parentless instance "is not implemented atm so throw an exception" (`Core/Operator/Symbol.Instantiation.cs:73-76`).

### cables.gl: random ids, a stable type id, and fragile ports

cables mints a random 9-character base-36 string per op (`visual-programming/cables/src/core/utils.js:79-88`, with the comment "WARNING this is slow when done alot"). Op *types* went through their own identity migration: a patch now references a type by a UUID `opId` rather than its namespaced name, and the loader says so directly: "creating ops by id should be the default way from now on!" (`src/core/core_patch.js:440-446`). That migration is why renaming an op type no longer breaks saved patches.

Ports were not migrated. A saved link stores port *names* plus op ids (`src/core/core_link.js:153-156`), so renaming a port breaks links, and the editor's `replaceOp` re-links by lowercased port name as a best effort.

Inside reusable subpatches ("blueprints"), cables does exactly what Flux does: inner ids are made deterministic by hashing the instance prefix with the original id, `hashString(options.prefixHash + oldId)` (`src/core/core_patch.js:1660-1666`). Because this rewrites ids per instance, cables needs a second stable key to re-attach links that cross the subpatch boundary, so it stores the original id in `storage.ref` (`core_patch.js:1686-1690`). Two lessons follow. When derived IDs replace authored ones, something eventually needs the authored one back. And hash width matters: this is a 32-bit string hash, where Flux uses a 128-bit UUIDv5.

### apEx and three.js: the plate-number model

The apEx tool identifies every resource by a 128-bit GUID and stores display names next to references. A timeline event in the Clean Slate project data carries `guid`, `scene_guid`, `clip_guid` and `camera_guid`, plus `scene_name` and `clip_name` (`research/apex-public/clean-slate/extracted/timeline.json`). The names are denormalized copies for readability, not identity. At export, the 64k player replaces all of this with array indices (`notes/per-demoscene/apex-public/texgen/pipeline.md`), which is the runtime-handle tier.

three.js does the same at object level: every `Object3D` gets `this.uuid = generateUUID()` and a separate `this.name` (`libraries/web/threejs/src/core/Object3D.js:97,104`), and serialization writes resources keyed by uuid (`Object3D.js:1418-1424`).

### vvvv gamma: Ids for structure, names for meaning

vvvv splits the question in two ([full study](../notes/per-reference/the-gray-book/node-identity.md)). Inside a `.vl` document, every element carries a random 22-character base62 `Id`, and all wiring is expressed in those Ids: a link stores only its two endpoint Ids. But a node refers to the *definition* it calls by name (`<Choice Kind="OperationCallFlag" Name="ToString (Format)" />`), never by the definition's Id, with `LastCategoryFullName`/`LastDependency` attributes as resolution hints. Renaming a definition therefore runs a werkkzeug4-style rewrite of every caller, which the editor applies across loaded documents; shipped libraries keep old names alive as obsolete nodes with converters. Running instances are keyed by a stack of (document Id, element Id) pairs, so they never notice a rename.

### Houdini: the path is the identity, rename follows tracked dependencies

Houdini is the production-scale version of Flux's scheme ([full study](../notes/per-reference/houdini/node-identity.md)). A node's persistent identity is its path; the only id beside it, `sessionId()`, is "only guaranteed to be unique in a single Houdini process". Renaming a node "automatically updates any existing references to the node in the scene" ([network/rename](https://www.sidefx.com/docs/houdini/network/rename.html)), but the rewrite is driven by Houdini's dependency graph, not a text search: `ch()` channel references and operator-path parameters are rewritten, while paths inside VEX, Python code or `op:` strings are not (community-reported). Copying rewrites relative references between nodes with the same parent and leaves cross-parent references pointing at the originals.

---

## Why Flux's Position Is Defensible

Flux's design specs record why it chose name-path IDs: random IDs reminted on every save made editor saves rewrite every ID in the file, and made regenerating a generator-built demo produce a diff that was 100% noise ("Deterministic Authoring IDs", 2026-07-08).

tixl shows that the first problem can also be solved by minting once and persisting. The second cannot: a generator that rebuilds a project from code has no previous file to read IDs from. **Deterministic generation is the only way for generated projects to reproduce their own IDs.** Since Flux builds its demos and acceptance fixtures through generators using public authoring APIs, that requirement is real, and it puts Flux in werkkzeug4's corner of the map rather than tixl's.

Flux's three-tier split also contains the cost. Only authored IDs are name-derived; live IDs are reminted on instantiation and compiled handles index the runtime ("Lossless authoring: source ownership", 2026-09-06). A rename never needs to touch a running graph. It needs to touch source documents and anything keyed by authored IDs.

---

## What a Rename Must Rewrite

This is the inventory a Flux rename transaction must cover. Each row is a place where a child's authored ID, or the name it is derived from, can be stored. The tixl and cables columns show how a GUID system avoids the problem, which is a useful check that the list is complete.

| Reference kind | Where it lives | tixl keys it by | Rename transaction must... |
|----------------|---------------|-----------------|---------------------------|
| **Connections** inside the symbol | Source symbol | Child GUID + slot GUID | Rewrite both ends |
| **Exposed slots** forwarding to an inner child | Source symbol interface | Slot GUID | Rewrite the internal-child target |
| **Animation targets** | Source symbol animation data | `[childId][inputId]` per symbol (`Core/Operator/Animator.cs`) | Rewrite the target child |
| **Value overrides** on the child | Source symbol | Stored on the child record | Move with the child |
| **Overrides reaching into nested symbols** | The *parent's* source document, addressed by a path through children | Not supported per path in tixl (edits change the shared symbol) | Rewrite every path segment equal to the old name, in every document that instantiates this symbol |
| **Cross-file symbol references** | Other source files | Symbol GUID | Only for *symbol* rename: rewrite every file referencing it (Flux's specs already scope this as a project-wide transaction) |
| **Editor layout** (position, size, comments, sections) | UI data | Child GUID, in a separate `.t3ui` file | Rewrite in the same transaction as the source |
| **Selection, navigation history, pinned views** | Editor session | Paths of child GUIDs | Rewrite or invalidate live paths |
| **Undo/redo entries** | Editor session | Child GUIDs | Make the rename itself an undoable step and rewrite or invalidate older entries |
| **String references outside the graph** (named variables, script text, external tools) | Anywhere | Not covered: cables broadcasts a `variableRename` event to loaded ops only | Either forbid these, or flag them as unresolvable on rename |

Three failure modes from the studied systems map onto this table:

1. **Split storage drifts.** tixl keeps graph data in `.t3` and layout in `.t3ui`. When a child's ID changes on collision repair, it needs `Child.PreviousId` so the UI file can migrate its entry (`Core/Operator/Symbol.Child.cs`, `Editor/UiModel/SymbolUi.cs`). For Flux, every ID-keyed store must be rewritten in **one** transaction, or recover from a recorded old→new map.
2. **Unscanned references survive as stale strings.** werkkzeug4's `RenameAllOps` rewrites `LinkName`s only. cables' variable rename reaches only ops listening at that moment. Anything outside the transaction's scan breaks silently.
3. **Rewritten identities need a memory.** cables' blueprints must keep the original id in `storage.ref` to reconnect boundary links. If Flux ever needs references it cannot rewrite, such as other projects reaching into a library symbol's internals, it will need the same thing: an alias record of "this child used to be called X".

---

## Recommendation: Keep Name-Derived IDs, Build the Rename as One Transaction

**Keep name-derived authored IDs, and build rename as a document-set transaction in the werkkzeug4 shape:**

1. **Validate first.** Reject the new name if it is grammar-invalid or already used at that level, before changing anything.
2. **Compute the old→new ID map** for the renamed child and every descendant path under it (a renamed compound child changes the paths of everything inside it).
3. **Rewrite every row of the inventory** in one pass across all affected source documents, including UI layout and nested override paths in parent documents.
4. **Re-validate.** Re-run the same resolution checks a load would, so a missed reference surfaces as an error immediately rather than at the next reopen.
5. **Record the map** in the undo entry, so undo is the inverse rewrite.

The make-or-break step is 3, and the way to keep it complete is to make the inventory **exhaustive by construction** rather than by memory. Give the reference kinds one enum, and make the rewriter match on it without a wildcard, so adding a new kind of ID-bearing field fails to compile until the rename handles it. Here's what that looks like:

```rust
/// Every place an authored child id (or its name) can be stored.
enum ChildReference {
    Connection,
    ExposedSlot,
    AnimationTarget,
    NestedOverridePath,
    EditorLayout,
    SessionPath,
}

fn rewrite(kind: ChildReference, doc: &mut SourceDoc, ids: &IdMap) {
    match kind {
        ChildReference::Connection => doc.rewrite_connection_ends(ids),
        ChildReference::ExposedSlot => doc.rewrite_exposed_slots(ids),
        ChildReference::AnimationTarget => doc.rewrite_animation_targets(ids),
        ChildReference::NestedOverridePath => doc.rewrite_override_paths(ids),
        ChildReference::EditorLayout => doc.rewrite_layout_keys(ids),
        ChildReference::SessionPath => doc.invalidate_session_paths(ids),
        // no `_ =>` arm: a new variant is a compile error here
    }
}
```

Houdini confirms the principle at scale: its rename is reliable for every reference it *tracks* as a dependency and silently misses paths hidden in code strings. The Flux equivalent is to keep every reference to a child in a typed field of the source model, so the set the rename rewrites is exactly the set the model knows about.

The enum guards the code side. A complementary test closes the loop from the data side: serialize a fixture project containing every reference kind, rename a nested child, and assert that no string equal to the old ID or old name remains anywhere in the written files.

**When to revisit:** if references start crossing a boundary the transaction cannot reach (library symbols mounted read-only and referenced from other projects, or published projects that third parties depend on), a project-scope rewrite is no longer enough. At that point Flux would need what tixl, apEx and three.js have built in, an identity that does not change on rename. The least disruptive route is "born from the name, then frozen": mint the UUIDv5 at creation as today, but persist it and keep it on rename. That gives up the invariant that an ID can always be recomputed from the current name, and it requires collision checks against persisted IDs (tixl's `CreateIdDeterministically` repair path is the cautionary example).

---

## Gaps in This Study

- **vvvv:** what happens to documents that are *not* loaded when a definition is renamed, and whether hot-swap keys state by node path (compiler is closed source).
- **Houdini:** the exact set of untracked reference kinds is community-reported rather than documented, and whether collapsing nodes into a subnet rewrites references was not verified.
- **tixl symbol rename:** `Editor/Compilation/SymbolNaming.cs` was not read; whether a symbol's GUID survives renaming is inferred from the fact that children reference symbols by ID.

## Sources

- werkkzeug4: `demoscene/fr_public/altona_wz4/altona/main/wz4lib/doc.cpp`, `doc.hpp:448,514`, `gui.hpp`
- tixl: `visual-programming/tixl/Core/Operator/`, `Core/Model/SymbolJson.cs`, `Editor/UiModel/Commands/Graph/`, `Editor/UiModel/Modification/Duplicate.cs`; [tixl architecture notes](../notes/per-framework/tixl/architecture.md)
- cables.gl: `visual-programming/cables/src/core/utils.js`, `core_patch.js`, `core_link.js`; `visual-programming/cables_ui/src/ui/components/patchview.js`
- apEx: `research/apex-public/clean-slate/extracted/`, [apEx notes](../notes/per-demoscene/apex-public/)
- three.js: `libraries/web/threejs/src/core/Object3D.js`
- vvvv gamma: [node identity study](../notes/per-reference/the-gray-book/node-identity.md) (`.vl` files from vvvv/VL.StandardLibs, The Gray Book changelogs)
- Houdini: [node identity study](../notes/per-reference/houdini/node-identity.md) (SideFX documentation)
- Flux design specs: "Deterministic Authoring IDs — Name-Path v5 at the Serialization Seam" (2026-07-08) and "Lossless authoring: source ownership" (2026-09-06)
- Commits referenced as of the 2026-10-15 snapshot in [SUBMODULE-PINS.md](../notes/SUBMODULE-PINS.md)
