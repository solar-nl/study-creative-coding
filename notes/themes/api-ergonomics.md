# Theme: API Ergonomics

> Partially documented. Needs deeper analysis per framework.

Cross-cutting analysis of how frameworks expose functionality to users.

## Concept Overview

API ergonomics determine how pleasant a framework is to use:
- Method naming conventions
- Parameter patterns
- Error handling
- Type system usage
- Discoverability

## Framework Implementations

### Naming Conventions

| Framework | Functions | Classes | Constants |
|-----------|-----------|---------|-----------|
| p5.js | camelCase | p5.Class | UPPER_SNAKE |
| Processing | camelCase | PClass | UPPER_SNAKE |
| three.js | camelCase | PascalCase | THREE.UPPER |
| OpenFrameworks | ofCamelCase | ofClass | OF_UPPER |
| openrndr | camelCase | PascalCase | UPPER_SNAKE |
| nannou | snake_case | PascalCase | UPPER_SNAKE |

### Method Chaining

| Framework | Supports? | Pattern |
|-----------|-----------|---------|
| p5.js | Limited | Only on p5.Vector |
| three.js | Yes | Math objects return this |
| openrndr | Yes | Builder pattern |
| nannou | Yes | Builder and drawing |

### Error Handling

| Framework | Approach |
|-----------|----------|
| p5.js | Friendly Error System |
| three.js | Console warnings |
| Rust frameworks | Result/Option types |

## Recommendations for Rust Framework

1. **snake_case for Rust** — Follow Rust conventions
2. **Builder pattern** — Fluent configuration
3. **Method chaining** — Return `&mut Self` or `Self`
4. **Abbreviated common methods** — `x_y()` style for creative coding
5. **Type-safe errors** — Use Result<T, E> appropriately
