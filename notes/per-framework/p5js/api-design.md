# p5.js API Design

## Public API Surface

p5.js exposes a large, flat API optimized for discoverability and ease of use.

## Naming Conventions

### Functions
- **Lowercase camelCase**: `createCanvas`, `loadImage`, `mousePressed`
- **Verb-first for actions**: `fill()`, `stroke()`, `translate()`
- **Adjective/noun for state**: `width`, `height`, `frameCount`
- **Boolean prefixes**: `keyIsPressed`, `mouseIsPressed`

### Classes
- **p5.ClassName**: `p5.Color`, `p5.Vector`, `p5.Image`, `p5.Font`
- Exposed on p5 namespace, not global

### Constants
- **UPPER_SNAKE_CASE**: `CENTER`, `CORNER`, `RGB`, `HSB`

## Method Signatures

### Overloaded Parameters
Many functions accept multiple signatures:

```javascript
// color() accepts:
color(gray)                    // grayscale
color(gray, alpha)             // grayscale + alpha
color(r, g, b)                 // RGB
color(r, g, b, a)              // RGBA
color('#ff0000')               // hex string
color('rgb(255,0,0)')          // CSS color string
```

### Optional Parameters
- Defaults are sensible
- Parameters omitted from the end
- Sometimes parameters in the middle are optional

## Fluent Patterns

p5.js doesn't use method chaining heavily. Functions typically return `undefined` or a value, not `this`.

**Exception**: p5.Vector is chainable:
```javascript
let v = createVector(1, 2, 3).add(1, 1, 1).mult(2);
```

## Error Handling

### Friendly Error System (FES)
- Runtime parameter validation
- Helpful error messages with suggestions
- Can be disabled for production: `p5.disableFriendlyErrors = true`

### Error Types
- Type mismatches: "circle() was expecting Number for parameter 0"
- Missing files: "Unable to load image.png"
- WebGL context: "WebGL is not supported in this browser"

## Type System

p5.js is untyped JavaScript, but:
- JSDoc annotations throughout
- TypeScript definitions available (`@types/p5`)
- Parameter validation at runtime via FES

## API Patterns Worth Studying

### Mode-based State
```javascript
colorMode(HSB);         // Changes how color() interprets values
rectMode(CENTER);       // Changes how rect() interprets position
angleMode(DEGREES);     // Changes how trig functions work
```

### Callback Registration
```javascript
function setup() { }    // Defined globally, p5 finds it
function draw() { }     // Called every frame
function mousePressed() { }  // Event callback
```

### Async Loading Pattern
```javascript
let img;
function preload() {
  img = loadImage('photo.jpg');  // Returns immediately
}
function setup() {
  // img is ready here
}
```

## Recommendations for Rust

1. **Consider overloaded functions** via trait implementations or macros
2. **Mode-based state** maps well to enums
3. **Callback registration** could use closures or trait objects
4. **Preload pattern** could use async/await or a loading state
