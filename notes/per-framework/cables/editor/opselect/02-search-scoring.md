# Search and Scoring Algorithm

> *Type "di" and DrawImage appears first - not Divide, not Direction. The search is not magic; it is math.*

---

## The Problem: Smart Ranking for Thousands of Operators

Simple string matching fails creative tools. If you search "blur" and get results in alphabetical order, you waste time scrolling past `BlurArray` to find `Blur_v4`. If the search only matches operator names, you miss operators whose *descriptions* mention blur but have different names. And if you are dragging from a texture port, showing non-texture operators at all is just noise.

The challenge is ranking. Given a query like "di" and a context like "dragging from texture output", how do you decide that `DrawImage` should appear before `Divide`? The answer involves combining multiple weak signals - abbreviation matches, name matches, port compatibility, popularity - into a single relevance score that puts the right operator at the top.

---

## Mental Model: Search Engine Ranking

Think of the operator search like a miniature search engine. Google does not just find pages containing your keywords - it ranks them by combining hundreds of signals: keyword density, page authority, freshness, user engagement. The OpSearch engine does something similar at smaller scale.

Each operator starts with a score of zero. As the search processes your query, it adds or subtracts points based on various factors:

```
┌─────────────────────────────────────────────────────────────┐
│                    Query: "blur"                            │
│                    Context: texture port                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Scoring Factors                                            │
│  ─────────────────────────────────────────────────────────  │
│  [+4] ShortName contains "blur"                             │
│  [+3] First port is texture (matches context)               │
│  [+2] Shortness bonus (shorter names rank higher)           │
│  [+1] Popularity from usage data                            │
│  ─────────────────────────────────────────────────────────  │
│  Total: 10 points                                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Results sorted by score:                                   │
│  1. Blur_v4 .............. 10 pts                           │
│  2. BlurHQ ................ 9 pts                           │
│  3. MotionBlur ............ 8 pts                           │
│  4. BlurArray ............. 2 pts  (no texture port: -10)   │
└─────────────────────────────────────────────────────────────┘
```

No single factor dominates. An operator with a perfect name match but incompatible ports loses to one with a partial match but perfect type compatibility. This multi-signal approach is what makes the search feel "smart."

---

## Building the Operator List

Before any search happens, the OpSearch engine builds a consolidated list of all available operators. This happens once when the editor loads and gets cached for subsequent searches.

The `_buildList()` method aggregates operators from five sources:

1. **Code Ops** - Operators loaded in the current runtime
2. **Op Docs** - Documented operators from the server
3. **Extensions** - Third-party operator collections
4. **Team Namespaces** - Operators specific to your team
5. **Patch Ops** - Custom operators saved to this patch

```javascript
_buildList() {
    const codeOpNames = this._getOpsNamesFromCode([], "Ops", Ops, "");
    let items = this._createListItemsByNames(codeOpNames);

    const docOpName = gui.opDocs.getOpDocs().map((ext) => ext.name);
    items = items.concat(this._createListItemsByNames(docOpName, items));

    const extensionNames = gui.opDocs.getExtensions().map((ext) => ext.name);
    items = items.concat(this._createListItemsByNames(extensionNames, items));

    // ... team namespaces, patch ops

    // Deduplicate by opId
    const newList = {};
    items.forEach((item) => {
        if (!newList.hasOwnProperty(item.opId)) {
            newList[item.opId] = item;
        }
    });
}
```

Deduplication matters because the same operator might appear in multiple sources. An operator could be both loaded in code and documented on the server. The `opId` check ensures each operator appears only once.

After building the list, the method preprocesses each operator for efficient searching. Lowercase variants of names, namespaces, and summaries are cached so the search loop does not convert strings repeatedly:

```javascript
this._list[i]._lowerCaseName = this._list[i].name.toLowerCase();
this._list[i]._shortName = this._list[i].shortName.toLowerCase();
this._list[i]._summary = this._list[i].summary.toLowerCase();
this._list[i]._nameSpace = this._list[i].nameSpace.toLowerCase() + ".";
```

---

## The Word Database: Understanding Operator Names

Here is where things get clever. Operator names in cables.gl follow PascalCase: `DrawImage`, `TextureEffects`, `ArrayLength`. The `_rebuildWordList()` method splits these into component words:

```javascript
_rebuildWordList() {
    for (let i = 0; i < this._list.length; i++) {
        // Split PascalCase: "DrawImage" → ["Draw", "Image"]
        const res = this._list[i].name.split(/(?=[A-Z,0-9,/.])/);

        for (let j = 0; j < res.length; j++) {
            if (res[j].length > 2) buildWordDB[res[j].toLowerCase()] = 1;
        }

        // Generate abbreviation: "DrawImage" → "di"
        let shortName = "";
        const ccParts = this._list[i].shortName.split(/(?=[A-Z,0-9,/.])/);
        for (let j = 0; j < ccParts.length; j++)
            shortName += ccParts[j].substr(0, 1);
        this._list[i].abbrev = shortName.toLocaleLowerCase();
    }

    this._wordsDb = Object.keys(buildWordDB);
    this._wordsDb.sort((a, b) => b.length - a.length);  // Longest first
}
```

This creates two things:

1. **Word Database** - A sorted list of all words found in operator names (`["textureeffects", "texture", "effects", "draw", "image", ...]`). Sorted longest-first so longer matches take priority.

2. **Abbreviations** - Each operator gets an `abbrev` property: `DrawImage` becomes `di`, `TextureEffects` becomes `te`, `ArraySum` becomes `as`.

Why sort the word database by length? Because when the search expands your query, you want `texture` to match before `text`. The longest match wins.

---

## The Search Algorithm

The `search()` method is the main entry point. It takes your query, optionally expands it using the word database, then scores every operator.

**Step 1: Query Expansion**

If you type `drawimage`, the word database can recognize this as `draw` + `image` and expand it into a multi-word query:

```javascript
search(query, originalSearch) {
    if (this._wordsDb) {
        let q = query;
        const queryParts = [];

        do {
            found = false;
            for (let i = 0; i < this._wordsDb.length; i++) {
                const idx = q.indexOf(this._wordsDb[i]);
                if (idx > -1) {
                    queryParts.push(this._wordsDb[i]);
                    q = q.substr(0, idx) + " " + q.substr(idx + this._wordsDb[i].length);
                    break;
                }
            }
        } while (found);

        if (queryParts.length > 0) {
            query = queryParts.join(" ") + " " + q;
        }
    }
    // ...
}
```

**Step 2: Reset Scores**

Every operator's score resets to zero before each search:

```javascript
for (let i = 0; i < this._list.length; i++) {
    this._list[i].score = 0;
    this._list[i].scoreDebug = "";
}
```

**Step 3: Score Each Word**

For multi-word queries, each word is scored independently and points accumulate:

```javascript
if (query.indexOf(" ") > -1) {
    const words = query.split(" ");
    for (let i = 0; i < words.length; i++) {
        this._searchWord(i, origQuery, this._list, words[i]);
    }
}
```

The `wordIndex` parameter matters. If an operator matches the second word but not the first, its score stays zero. You cannot game the system by matching only part of a multi-word query.

---

## Scoring Factors Reference

The `_searchWord()` method applies all scoring factors. Here is the complete breakdown:

| Factor | Points | Condition |
|--------|--------|-----------|
| **VIP Operator** | +2 | MainLoop gets a boost |
| **Abbreviation Match** | +4 to +12 | Higher for shorter abbreviations: 2 chars = +12, 3 = +10, 4 = +8 |
| **Uppercase Abbreviation** | +5 | Query typed in uppercase (e.g., "DI" not "di") |
| **Summary Contains Query** | +1 | Search description, not just name |
| **Namespace Contains Query** | +1 | `ops.gl.texture` matches "texture" |
| **ShortName Contains Query** | +4 | Core name match |
| **ShortName Equals Query** | +5 | Exact match bonus |
| **Full Namespace Contains Query** | +2 | Match against complete path |
| **ShortName Starts With Query** | +2.5 | Prefix match bonus |
| **Exact Name Match** | +2 | Complete match |
| **Math Namespace** | +1 | `Ops.Math.*` gets slight boost |
| **Patch Op** | +3 | Your custom ops rank higher |
| **Team Op** | +2 | Team ops rank higher |
| **Shortness Bonus** | 0 to +2 | Shorter names rank higher |
| **Popularity** | varies | Based on usage statistics |
| **First Port Fits** | +3 | First port type matches context |
| **No Compatible Port** | -5 to -10 | No port of matching type exists |
| **Wrong Graphics API** | -5 | WebGL op in WebGPU context or vice versa |
| **Outdated/Deprecated** | -1 | Old versions rank lower |
| **Not Usable** | = 0.1 | Floor score for unusable ops |

---

## Port Type Compatibility Scoring

When you drag from a port, type compatibility becomes the dominant factor. The scoring handles two scenarios:

**Scenario 1: Dragging from a Port (`linkNewOpToPort`)**

The search checks if the operator has any port of the matching type and direction. If you are dragging from an output port, it looks for inputs:

```javascript
if (this._newOpOptions.linkNewOpToPort.direction === Port.DIR_OUT) {
    // Check input ports
    if (docs.layout.portsIn[0].type == this._newOpOptions.linkNewOpToPort.type) {
        points += 3;  // First port matches!
    }

    for (let j = 0; j < docs.layout.portsIn.length; j++) {
        if (docs.layout.portsIn[j].type == this._newOpOptions.linkNewOpToPort.type) {
            foundPortType = true;
            break;
        }
    }

    if (!foundPortType) {
        points -= 10;  // Harsh penalty - no compatible port
    }
}
```

The -10 penalty seems aggressive, but it makes sense. If you are dragging a texture and an operator has no texture inputs, showing it prominently wastes your time.

**Scenario 2: Inserting Into Existing Link (`linkNewLink`)**

When clicking an existing connection to insert an operator, the candidate must have *both* a compatible input and output:

```javascript
if (this._newOpOptions.linkNewLink) {
    // Check for input that matches the link's output type
    for (let j = 0; j < docs.layout.portsIn.length; j++) {
        if (docs.layout.portsIn[j].type == this._newOpOptions.linkNewLink.portIn.type) {
            foundPortTypeIn = true;
        }
    }

    // Check for output that matches the link's input type
    for (let j = 0; j < docs.layout.portsOut.length; j++) {
        if (docs.layout.portsOut[j].type == this._newOpOptions.linkNewLink.portOut.type) {
            foundPortTypeOut = true;
        }
    }

    if (!foundPortTypeOut && !foundPortTypeIn) {
        points -= 5;  // Can't fit in this link
    }
}
```

---

## Trace: Searching "di" When Dragging from Texture Output

Let us follow the complete scoring path for a common scenario.

**Context**: You have dragged from a texture output port and typed "di".

**Step 1: Query receives no expansion** (too short for word database)

**Step 2: Score each operator**

For `DrawImage`:
- Abbreviation is "di", query is "di": exact abbreviation match at start
- Query length is 2: **+12 points** (short abbreviations get maximum boost)
- First input port is texture, matches drag context: **+3 points**
- Shortness bonus: name is short: **+1.8 points**
- Total: approximately **16.8 points**

For `Divide`:
- Abbreviation is "d" (single word), does not match "di"
- ShortName "divide" contains "di": **+4 points**
- First input port is number, not texture: **-10 points**
- Net score: approximately **-4 points** (filtered to bottom)

For `Direction`:
- Abbreviation is "d", does not match "di"
- ShortName "direction" contains "di": **+4 points**
- First port is vector, not texture: **-10 points**
- Net score: approximately **-4 points**

**Result**: DrawImage scores 16+ points while Divide and Direction score negative. The texture context made all the difference.

---

## Trace: Searching "blur" Without Context

Same query, different context. You opened the operator browser from empty canvas.

For `Blur_v4`:
- ShortName "blur" contains "blur": **+4 points**
- ShortName starts with "blur": **+2.5 points**
- ShortName equals "blur": **+5 points**
- In `Ops.Gl.TextureEffects` namespace: no math boost
- Shortness bonus: **+1.5 points**
- Total: approximately **13 points**

For `BlurArray`:
- ShortName "blurarray" contains "blur": **+4 points**
- ShortName starts with "blur": **+2.5 points**
- No exact match
- Longer name, smaller shortness bonus: **+1.2 points**
- Total: approximately **7.7 points**

Without port context, both operators are viable. But exact matches and shorter names still push `Blur_v4` to the top.

---

## Edge Cases and Gotchas

### Multi-Word Queries Require All Words to Match

If you search "texture blur", an operator must match both words to score above zero. The first-word check prevents partial matches from polluting results:

```javascript
if (wordIndex > 0 && list[i].score === 0) continue;
```

### Uppercase Abbreviations Get Extra Boost

Typing "DI" instead of "di" adds 5 bonus points. This is intentional - if you deliberately typed uppercase, you probably know exactly what you want:

```javascript
if (query === query.toUpperCase()) {
    p += 5;
    scoreDebug += "+5 uppercase abbreviation<br/>";
}
```

### Deprecated Operators Still Appear

Old or deprecated operators are not hidden, just penalized (-1 point). This prevents confusion when following old tutorials that reference deprecated ops. You can still find them, they just rank lower than current versions.

### Graphics API Mismatch Penalty

The search detects whether you are working in WebGL or WebGPU context and penalizes operators for the wrong API:

```javascript
if (this.prefereGApi == CgContext.API_WEBGL) {
    if (list[i].name.startsWith(defaultOps.prefixes.webgpu)) {
        points -= 5;
    }
}
```

This keeps WebGPU operators from cluttering WebGL projects and vice versa.

---

## What's Next

The scoring algorithm produces a ranked list, but someone needs to *display* that list. The next chapter explores how the operator browser renders search results: DOM recycling for performance, highlight rendering for query matches, and the documentation preview that appears when you hover over a result.
