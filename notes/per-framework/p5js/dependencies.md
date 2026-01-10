# p5.js - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `package.json` |
| **Package Manager** | npm |
| **Build System** | Grunt + Browserify |
| **Version** | 1.11.11 |

## Project Structure

```
p5js/
├── package.json
├── Gruntfile.js          # Build configuration
├── src/
│   ├── core/             # Core functionality
│   ├── color/            # Color utilities
│   ├── data/             # Data structures
│   ├── dom/              # DOM manipulation
│   ├── events/           # Event handling
│   ├── image/            # Image processing
│   ├── io/               # Input/output
│   ├── math/             # Math utilities
│   ├── typography/       # Text rendering
│   ├── utilities/        # Helpers
│   └── webgl/            # WebGL renderer
└── lib/                  # Built output
```

## Dependencies by Category

### Runtime Dependencies

p5.js has **minimal runtime dependencies** - most functionality is built-in:

| Dependency | Version | Purpose |
|------------|---------|---------|
| (none) | - | Browser APIs only |

### Build Dependencies (devDependencies)

#### Build Tools

| Dependency | Version | Purpose |
|------------|---------|---------|
| `grunt` | 1.6.1 | Task runner |
| `browserify` | 16.5.0 | Module bundler |
| `babel` | 7.7.7 | ES6+ transpilation |
| `@babel/preset-env` | 7.7.7 | Browser targeting |
| `uglify-js` | 3.4.9 | Minification |

#### Font Handling

| Dependency | Version | Purpose |
|------------|---------|---------|
| [`[opentype.js](https://github.com/opentypejs/opentype.js)`](https://github.com/processing/p5.js/blob/main/src/opentype.js) | 0.9.0 | Font file parsing |

#### GIF Support

| Dependency | Version | Purpose |
|------------|---------|---------|
| `gifenc` | 1.0.3 | GIF encoding |
| `omggif` | 1.0.10 | GIF processing |

#### Geometry

| Dependency | Version | Purpose |
|------------|---------|---------|
| `libtess` | 1.2.2 | Polygon tessellation |

#### Utilities

| Dependency | Version | Purpose |
|------------|---------|---------|
| `i18next` | varies | Internationalization |
| `fetch-jsonp` | varies | JSONP requests |
| `whatwg-fetch` | varies | Fetch polyfill |

#### Testing

| Dependency | Version | Purpose |
|------------|---------|---------|
| `mocha` | varies | Test framework |
| `chai` | varies | Assertions |
| `puppeteer` | 18.2.1 | Headless browser testing |
| `nyc` | varies | Code coverage |

#### Linting

| Dependency | Version | Purpose |
|------------|---------|---------|
| `eslint` | varies | Code linting |
| `husky` | varies | Git hooks |
| `lint-staged` | varies | Staged file linting |

## Graphics Dependencies

p5.js uses **native browser APIs** exclusively:

| Feature | Browser API |
|---------|-------------|
| 2D Drawing | Canvas 2D Context |
| 3D Drawing | WebGL |
| Image Loading | HTMLImageElement |
| Video | HTMLVideoElement |
| Audio | Web Audio API |
| File I/O | File API |

## Dependency Philosophy

p5.js follows a **minimal dependency** approach:

1. **No runtime deps** - Everything bundled, no CDN dependencies
2. **Browser-native** - Leverages built-in browser capabilities
3. **Self-contained** - Single file distribution (`p5.min.js`)
4. **Polyfills only** - External code only for browser compatibility

## Build Output

```
lib/
├── p5.js           # Development build (~4MB)
├── p5.min.js       # Production build (~1MB)
└── modules/        # Optional addons
    ├── p5.sound.js
    └── ...
```

## Dependency Graph Notes

- **Almost zero runtime deps** - Maximizes portability
- **Build deps are heavy** - Complex build process
- **[opentype.js](https://github.com/opentypejs/opentype.js) is key** - Enables custom font support
- **libtess for WebGL** - Complex shape tessellation

## Key Files

- Package config: `frameworks/p5js/package.json`
- Build config: `frameworks/p5js/Gruntfile.js`
