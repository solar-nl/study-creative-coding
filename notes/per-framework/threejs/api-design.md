# three.js API Design

## Public API Surface

three.js exposes a class-based, object-oriented API.

## Naming Conventions

### Classes
- **PascalCase**: `Scene`, `Mesh`, `Vector3`, `WebGLRenderer`
- **Hierarchy in name**: `MeshBasicMaterial`, `MeshStandardMaterial`
- **Suffixes**: `*Geometry`, `*Material`, `*Helper`, `*Controls`

### Methods
- **camelCase**: `add()`, `remove()`, `updateMatrixWorld()`
- **Verb-noun**: `lookAt()`, `setFromAxisAngle()`
- **Getters/setters**: Properties with side effects

### Properties
- **camelCase**: `position`, `rotation`, `visible`
- **Boolean naming**: `visible`, `castShadow`, `receiveShadow`

### Constants
- **ALL_CAPS**: `THREE.FrontSide`, `THREE.PCFShadowMap`

## Method Signatures

### Constructor Patterns
```javascript
// Geometry: dimensions
new BoxGeometry(width, height, depth);

// Material: config object
new MeshStandardMaterial({ color: 0xff0000, metalness: 0.5 });

// Camera: frustum params
new PerspectiveCamera(fov, aspect, near, far);
```

### Fluent Returns
Many math operations return `this`:
```javascript
vector.add(other).normalize().multiplyScalar(2);
```

### Optional Config Objects
Materials and many classes use options objects:
```javascript
new WebGLRenderer({
  antialias: true,
  alpha: true,
  preserveDrawingBuffer: true
});
```

## Error Handling

- **Console warnings**: For deprecated features
- **Soft failures**: Missing textures show magenta
- **Type checking**: Limited, relies on duck typing

## Type System

- JavaScript untyped, but TypeScript definitions available
- `@types/three` for TypeScript support
- JSDoc comments in source

## API Patterns Worth Studying

### Scene Graph
```javascript
const group = new Group();
group.add(mesh1, mesh2);
scene.add(group);

// Transforms are hierarchical
group.position.set(10, 0, 0);  // mesh1 and mesh2 move too
```

### Geometry + Material = Mesh
```javascript
const geometry = new BoxGeometry(1, 1, 1);
const material = new MeshStandardMaterial({ color: 0xff0000 });
const mesh = new Mesh(geometry, material);
```

### Event Dispatcher
```javascript
object.addEventListener('removed', (event) => {
  console.log('Object removed from scene');
});
```

### Clone Pattern
```javascript
const clonedMesh = mesh.clone();
const clonedGeometry = geometry.clone();
```

## Recommendations for Rust

1. **Scene graph** — Use Arena pattern or ECS for spatial hierarchy
2. **Geometry/Material separation** — Rust's type system enforces this well
3. **Builder pattern** — Replace config objects with builders
4. **Method chaining** — Return `&mut Self` or `Self`
5. **Event system** — Consider observer pattern or channels
