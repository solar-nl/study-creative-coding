# The Operator Browser Dialog

> *Type anywhere, find anything - the operator browser is how cables.gl turns keystrokes into nodes on your canvas.*

---

## The Problem: Finding the Right Operator Fast

You are in the middle of building a visual effect. You have just connected a texture output and now need a blur. Or maybe you dragged a number output and want to add a multiplier. Either way, you need to find the right operator among thousands - and you need to do it *fast*, without breaking your creative flow.

The naive solution would be a simple list: scroll through everything, or use basic string matching. But with thousands of operators across namespaces like `Ops.Gl.Texture`, `Ops.Math`, and `Ops.User.YourName`, simple filtering returns too many irrelevant results. Worse, when you are dragging from a port, most operators would not even be type-compatible.

What you actually want is something smarter: a search that understands context, recognizes abbreviations, knows which operators are popular, and can even interpret math shortcuts like typing `+5` to add a Sum operator with 5 pre-filled.

---

## Mental Model: A Context-Aware Command Palette

Think of the operator browser as a **command palette meets autocomplete**. If you have used VS Code's Ctrl+P or Spotlight on macOS, the interaction pattern is familiar:

1. **Invoke it anywhere** - Press a key, and the dialog appears at your cursor
2. **Type to filter** - Results narrow instantly as you type
3. **Context shapes results** - If you are dragging from a port, only compatible operators appear
4. **Smart ranking** - Results are scored by relevance, not just alphabetical order

The key insight is that this is not just a filter - it is a **scoring engine**. Each result gets points for matching your query in various ways: name match, abbreviation match, namespace match, type compatibility, and popularity. The results you see are sorted by score, which is why typing "di" shows "DrawImage" before "Divide" in a texture context.

```
┌──────────────────────────────────────────────────────┐
│ OpSelect Dialog                                      │
├──────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────┐ │
│  │ Search: [blur____________]                      │ │
│  └─────────────────────────────────────────────────┘ │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │ ► Ops.Gl.TextureEffects.Blur_v4     [Add]      │ │ ◄─ Selected
│  │   Ops.Gl.TextureEffects.BlurHQ                 │ │
│  │   Ops.Gl.TextureEffects.MotionBlur             │ │
│  │   ...                                          │ │
│  └─────────────────────────────────────────────────┘ │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │ Op Documentation Panel                         │ │
│  │ Port layout, description, links...             │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

---

## The Dialog Lifecycle

The operator browser has three key lifecycle moments: opening, searching, and closing.

### Opening: Setting Up Context

When the dialog opens via `show()`, it captures the context that will shape everything that follows:

```javascript
show(options, linkOp, linkPort, link) {
    // Store context for filtering and suggestions
    CABLES.UI.OPSELECT.linkNewLink = link;        // Existing link we're inserting into
    CABLES.UI.OPSELECT.linkNewOpToPort = linkPort; // Port we're dragging from
    CABLES.UI.OPSELECT.newOpPos = options;         // Where to place the new op

    this._newOpOptions = {
        "subPatch": options.subPatch,
        "linkNewOpToPort": linkPort,
        "linkNewOpToOp": linkOp,
        "linkNewLink": link
    };
    // ... initialize UI, focus search input
}
```

Here is where it gets interesting. The `linkPort` and `link` parameters are optional. When you press the keyboard shortcut on an empty canvas, they are null. But when you drag from a port or click on an existing connection, they carry type information that dramatically changes what suggestions appear.

### Searching: Minimum Characters and Debouncing

Search does not begin immediately. The system waits for a minimum of 2 characters (`MIN_CHARS_QUERY`) before querying, which prevents the expensive search operation from running on every keystroke:

```javascript
onInput(e) {
    this._typedSinceOpening = true;

    // Debounce based on query length
    let searchDelay = 0;
    if (this._getQuery().length == 2) searchDelay = 250;  // Longer delay for short queries
    if (this._getQuery().length == 3) searchDelay = 50;   // Shorter delay as query gets specific

    setTimeout(() => {
        this.search();
    }, searchDelay);
}
```

The debounce delay is clever: short queries (2 characters) get a longer delay because they match many operators and the search is expensive. As the query gets more specific, the delay shortens because fewer operators match.

### Closing: Returning Focus

When the dialog closes via `close()`, it hides the modal background and returns focus to the canvas:

```javascript
close() {
    this.#bg.hide();
    gui.currentModal = null;
    gui.patchView.focus();  // Return keyboard focus to the patch
}
```

---

## Search Input: Math Operator Shortcuts

Here is a feature that saves significant time once you know about it. If you start your search with a math symbol, the browser interprets it as a shortcut:

| Prefix | Operator | Example |
|--------|----------|---------|
| `+` | Sum | `+5` adds Sum with 5 |
| `-` | Subtract | `-2` adds Subtract with 2 |
| `*` | Multiply | `*10` adds Multiply with 10 |
| `/` | Divide | `/2` adds Divide with 2 |
| `>` | GreaterThan | `>100` adds comparison |
| `<` | LessThan | `<0` adds comparison |
| `=` | Equals | `=1` adds equals check |
| `%` | Modulo | `%360` adds modulo |

The implementation checks the first character against a lookup table:

```javascript
search() {
    let sq = this._getQuery();
    let mathPortType = this._getMathPortType();

    // Check for math shortcuts
    for (let i in defaultOps.defaultMathOps[mathPortType])
        if (sq.charAt(0) === i)
            sq = defaultOps.defaultMathOps[mathPortType][i];  // Replace with op name
    // ...
}
```

The `mathPortType` matters too. If you are dragging from an array port, `+` maps to `ArraySum` instead of the numeric `Sum`. The system adapts to context.

---

## Context-Aware Suggestions

When you open the browser without typing anything, the suggestions depend entirely on context.

**No context (opened from empty canvas):** Shows the namespace tree for browsing.

**Dragging from a port (`linkNewOpToPort`):** Shows operators whose first port matches your drag direction and type:

```javascript
_showSuggestionsInfo() {
    let ops = opNames.getOpsForPortLink(
        CABLES.UI.OPSELECT.linkNewOpToPort,
        CABLES.UI.OPSELECT.linkNewLink
    );
    // Renders suggestion buttons for variables, triggers, etc.
}
```

**Clicking on existing link (`linkNewLink`):** Shows operators that can be inserted between the existing connection - they need both a compatible input *and* compatible output.

The dialog also shows quick-action buttons based on context:
- **Create Variable**: When dragging from a value port (number, string, array, object)
- **Use Existing Variable**: When variables of matching type already exist
- **Create Trigger**: When working with trigger connections
- **Use Existing Trigger**: When named triggers already exist in the patch

---

## Keyboard Navigation

The dialog is designed for keyboard-first interaction:

| Key | Action |
|-----|--------|
| Arrow Up/Down | Move selection through results |
| Enter | Add selected operator and close |
| Shift+Enter | Add selected operator and reopen (for adding multiple) |
| Escape | Close without adding |

The `navigate()` method handles selection movement:

```javascript
navigate(diff) {
    this.displayBoxIndex += diff;

    // Clamp to valid range
    if (this.displayBoxIndex < 0) this.displayBoxIndex = 0;
    const oBoxCollection = ele.byQueryAll(".searchresult:not(.hidden)");
    if (this.displayBoxIndex >= oBoxCollection.length)
        this.displayBoxIndex = oBoxCollection.length - 1;

    // Update selection styling
    for (let i = 0; i < oBoxCollection.length; i++)
        oBoxCollection[i].classList.remove("selected");
    oBoxCollection[this.displayBoxIndex].classList.add("selected");

    // Scroll to keep selection visible
    const scrollTop = (this.displayBoxIndex - 5) * (this.itemHeight + 1);
    ele.byClass("searchbrowser").scrollTop = scrollTop;

    this.updateInfo();  // Update documentation panel
}
```

The scroll logic keeps the selection visible with 5 items of padding above it.

---

## Trace: Dragging from a Texture Output and Adding Blur

Let us walk through a concrete scenario. You have a texture output port and want to add a blur effect.

**1. Mouse down on texture port, drag into empty space, release**

The GlPatch system captures the drag and opens OpSelect:

```javascript
// Somewhere in the port drag handling:
gui.opSelect().show(
    { x: mouseX, y: mouseY, subPatch: currentSubPatch },
    sourceOp,      // The op we're dragging from
    texturePort,   // The output port (type: texture)
    null           // No existing link
);
```

**2. OpSelect opens with context**

`CABLES.UI.OPSELECT.linkNewOpToPort` is set to the texture port. The suggestions panel immediately shows texture-compatible operators and a "Create Variable" button.

**3. You type "blur"**

After 2 characters, `onInput()` triggers search. The OpSearch engine scores all operators:
- `Ops.Gl.TextureEffects.Blur_v4` scores high: name match (+4), first input port is texture (+3)
- `Ops.Math.BlurArray` scores lower: name match (+4), but no texture port (-10)

**4. Results display sorted by score**

```javascript
tinysort(".searchresult", { "data": "score" });  // Sort DOM elements by score
```

Blur_v4 appears at the top.

**5. You press Enter**

```javascript
addSelectedOp() {
    const selEle = ele.byClass("selected");
    const opname = selEle.dataset.opname;  // "Ops.Gl.TextureEffects.Blur_v4"
    this.addOp(opname, false, selEle.dataset.itemType);
}

addOp(opname, reopenModal, itemType) {
    this._newOpOptions.createdLocally = true;
    this.close();
    gui.patchView.addOp(opname, this._newOpOptions);
    // newOpOptions includes linkNewOpToPort, so the new op auto-connects
}
```

**6. Blur operator appears, connected to your texture**

The `gui.patchView.addOp()` call creates the operator at `CABLES.UI.OPSELECT.newOpPos` and, because `linkNewOpToPort` was set, automatically creates a link from your texture output to the blur's texture input.

---

## Edge Cases and Gotchas

### No Results Found

When the query matches nothing, the status bar updates to show "no results" and a warning if relevant:

```javascript
if (num === 0 && query.length >= MIN_CHARS_QUERY) {
    ele.show(this._eleNoResults);
}
```

If you are not a collaborator on the patch, your user ops are hidden - the dialog warns about this.

### Extensions and Team Namespaces

Results can include operator *collections* (extensions, team namespaces) that are not yet loaded. When you select one of these:

```javascript
if (itemType === "extension" || itemType === "team") {
    gui.opSelect().loadCollection(opname);  // Load ops, then reopen dialog
}
```

The dialog closes, loads the collection's operators, rebuilds the search list, and reopens with your query preserved.

### Enter Pressed While Still Searching

If you press Enter before the debounced search completes, the system remembers:

```javascript
if (this._searching) {
    this._enterPressedEarly = true;  // Will add op when search finishes
    return;
}
```

This prevents the frustrating case where you type fast and hit Enter, but the selection has not updated yet.

---

## What's Next

The operator browser gets results from the OpSearch scoring engine, but we have only scratched the surface of *how* that scoring works. The next chapter, [Search & Scoring Algorithm](02-search-scoring.md), dives into word-based matching, abbreviation detection, popularity weighting, and port type compatibility scoring.
