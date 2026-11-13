# Node Identity in vvvv gamma: Ids for Structure, Names for Meaning

> *A follow-up to [Node Instance Identity](../../../insights/node-instance-identity.md): how VL documents keep wires attached, how a node finds its definition, and what survives a rename.*

---

## The Problem

A vvvv patch is saved as an XML `.vl` document, and one document can call nodes defined in a dozen others: its own patches, other `.vl` files, NuGet packages, .NET assemblies. Two different kinds of reference have to survive editing:

- **Structural references** inside one document: this link connects that pin to that pad.
- **Semantic references** from a node to the definition it calls: this node is an application of `ToString (Format)` from the CoreLib.

vvvv answers these two questions with two different mechanisms, and that split is the main lesson for anyone designing a node-graph file format.

## Mental Model: Seat Numbers and Job Titles

Think of a theatre production. Every seat in the house has a number printed on it, and the seating chart (who sits next to whom, which cable runs from which socket) is drawn in seat numbers. Renaming a cast member changes nothing on the chart. But the script refers to roles by *title* ("the Narrator enters"), and when a role is renamed, someone has to go through every script that mentions it.

In vvvv, **element Ids are seat numbers** and **node references are job titles**.

---

## Element Ids: Random, Persisted, Document-Scoped

Every structural element in a `.vl` document carries an `Id` attribute, including the document itself:

```xml
<Document xmlns:p="property" xmlns:r="reflection" Id="M1XXME8bUtmNxzMxVHhNaw" LanguageVersion="2025.7.4-0017-g9af2347bad" Version="0.128">
```

Measured on `VL.Skia/VL.Skia.vl` from [vvvv/VL.StandardLibs](https://github.com/vvvv/VL.StandardLibs) (4.3 MB):

| Property | Observation |
|----------|-------------|
| Elements with an `Id` | 29,287: pins, links, nodes, control points, patches, fragments, pads, canvases, definitions, slots, dependencies, the document |
| Format | Always 22 characters from `[0-9A-Za-z]` (base62); the leading character spread is consistent with an encoded random 128-bit value (exact encoding not verified) |
| Duplicates | None among the 29,287 Ids |
| Scope | Unique within the document; VL.Core's `UniqueId` is "the persistent/serialized id of the element as well as the persistent/serialized id of the document where the element resides in" (`VL.Core/src/UniqueId.cs:7-8`) |

All wiring inside a document is expressed in these Ids. A link stores its two endpoints and nothing else:

```xml
<Link Id="DKZO1ggbE03LxEsxTV3Xha" Ids="Sa130YqG0zuM9kXjbk3l1A,QFVyQwl1VyyPqOfDSCds6k" />
```

(`VL.CoreLib/help/2D/HowTo Compute the distance between two points.vl:242`.) Pads point at the property they read with `SlotId`, fragments point at their patch with `Patch`. None of these references contain a name, so renaming anything leaves the wiring untouched.

## Node References: By Name, With Hints

A node does **not** store the Id of the definition it calls. It stores a chain of name choices:

```xml
<Node Bounds="542,568,56,26" Id="E2gJhKQsCdfNVOGtrWih2I">
  <p:NodeReference LastCategoryFullName="System.Conversion" LastSymbolSource="CoreLibBasics.vl">
    <Choice Kind="NodeFlag" Name="Node" Fixed="true" />
    <Choice Kind="OperationCallFlag" Name="ToString (Format)" />
  </p:NodeReference>
  <Pin Id="PTymu4AABDNLHjPNbuXC41" Name="Input" Kind="StateInputPin" />
```

(Same file, lines 80-85.) Three details matter:

- **Name and kind are the reference.** The node "version" is part of the name (`ToString (Format)`), matching The Gray Book's description of node names as display name plus optional version plus category (`references/the-gray-book/reference/language/nodes.md`). When needed, the reference narrows by category with a `CategoryReference` element.
- **`Last*` attributes are hints, not keys.** `LastCategoryFullName` and `LastSymbolSource` (`LastDependency` in newer files) record where the definition was found last time, to speed up and disambiguate resolution. They are not consulted as identity.
- **Pins match by name and kind.** A node's pins carry their own element Ids for wiring, but they are paired with the definition's pins by `Name` and `Kind`.

Cross-document references are by location, never by Id: `<NugetDependency Location="VL.CoreLib" Version="...">` names a package and version, `<DocumentDependency Location="./VL.Stride.Games.vl">` a relative path (`VL.Stride.Runtime/VL.Stride.Video.vl:3,289`). A node's name is resolved against everything the document depends on.

## Rename: The Editor Rewrites the Callers

Because node references are names, renaming a definition (F2, "Rename a nodes definition", `reference/hde/keyboard-shortcuts.md:122`) only works if every call site is rewritten. The changelogs show the editor doing exactly that, and the edge cases it had to fix:

- "Fixed renamings being applied to intermediate solutions instead of only the baseline. Fixes node references breaking when having the same name as another definition temporarily" (`changelog/2020.1.md:78`). A rename passed through a transient state in which two definitions shared a name, and references resolved to the wrong one.
- "The rename will also only be applied after the user commits to it and not on every keystroke" (`changelog/2021.4.md:503`). Each keystroke had been a rename transaction.
- A vvvv developer on the forum describes renames reaching *other loaded documents*: changes made by "our converters (node and pin renamings)" show up as modifications to dependent documents on save ([forum.vvvv.org/t/22490](https://forum.vvvv.org/t/22490)). Documents that are not loaded at rename time are not covered; what happens to them was not verified.

For shipped libraries, vvvv cannot rewrite its users' files, so it keeps the old name alive instead: an obsolete node plus a converter, for example "`ImGui (Version 1) [Graphics.Skia.Layer]` added as obsolete node - converter added" (`changelog/6.x.md:20`).

When resolution fails, the node or pin turns red. The node-replace command repairs what it can by name: "The node replace command renames pins in case there is a simple solution ... will no longer lead to a red pin with the message 'Pin X does not exist on Y'" (`changelog/6.x.md:246`).

## Instance Identity: A Path of Persistent Ids

At runtime, each node application is an instance, and vvvv addresses instances by a path made of element Ids, not names. The 2021.4 release made this explicit: "The node path is now made out of unique (and persistent) ids. Elements can be identified across sessions" (`changelog/2021.4.md:495`).

In source, `NodePath` is a struct over an `ImmutableStack<UniqueId>` (`VL.Core/src/NodePath.cs:15-22`), each entry a (document Id, element Id) pair. The older session-only form survives as an `ObsoleteStack` of `uint` volatile ids (`NodePath.cs:37-39`). Whether hot-swap uses this path to carry state across recompiles is not documented; the compiler is closed source.

Because the path is built from application Ids, renaming a definition never changes the key of any running instance.

---

## Where vvvv Sits

| Question | vvvv's answer | Closest studied system |
|----------|---------------|------------------------|
| What holds the wiring together? | Random persisted Ids, document-scoped | tixl |
| How does a node find its definition? | Name + kind + category, with location hints | werkkzeug4 |
| What happens on definition rename? | Editor rewrites call sites in loaded documents; libraries keep obsolete forwards | werkkzeug4's `RenameAllOps`, extended across documents |
| How is a running instance addressed? | Stack of (document Id, element Id) | tixl's `InstancePath` |

The design separates **who a node is** (an Id that never changes) from **what a node calls** (a name, rewritten on rename). For Flux, the transferable idea is that these are different questions with different answers: a node-graph format can make structural identity rename-proof while keeping definition references readable and diffable by name, as long as definition rename is a transaction over every document that might call it.

## Sources

- `.vl` files from [vvvv/VL.StandardLibs](https://github.com/vvvv/VL.StandardLibs) (main branch, fetched 2026-10-15; now a submodule at `libraries/vvvv-ecosystem/VL.StandardLibs`): `VL.Skia/VL.Skia.vl`, `VL.CoreLib/help/2D/HowTo Compute the distance between two points.vl`, `VL.Stride.Runtime/VL.Stride.Video.vl`, `VL.Fundamentals/VL.Fundamentals.vl`
- VL.Core source: `VL.Core/src/UniqueId.cs`, `VL.Core/src/NodePath.cs`
- The Gray Book (`references/the-gray-book/`): `changelog/2020.1.md`, `changelog/2021.4.md`, `changelog/6.x.md`, `reference/hde/keyboard-shortcuts.md`, `reference/language/nodes.md`
- vvvv forum: [t/22490](https://forum.vvvv.org/t/22490)
