# tixl - API Design

## Overview

tixl uses an **attribute-based declarative API** for defining operators. Operators are C# classes with special attributes that define their inputs, outputs, and metadata.

## Operator Definition Pattern

### Basic Structure

```csharp
[Guid("746d886c-5ab6-44b1-bb15-f3ce2fadf7e6")]  // Unique operator ID
internal sealed class Camera : Instance<Camera>, ICamera
{
    // Output slots
    [Output(Guid = "2E1742D8-9BA3-4236-A0CD-A2B02C9F5924")]
    public readonly Slot<Command> Output = new();

    // Input slots
    [Input(Guid = "c2c9afc7-3474-40c3-be82-b9f48c92a2c5")]
    public readonly InputSlot<Vector3> Position = new();

    [Input(Guid = "da607ebd-6fec-4ae8-bf91-b70dcb794557")]
    public readonly InputSlot<Vector3> Target = new();

    // Constructor wires up evaluation
    public Camera()
    {
        Output.UpdateAction += UpdateOutputWithSubtree;
    }

    // Evaluation logic
    private void UpdateOutputWithSubtree(EvaluationContext context)
    {
        var position = Position.GetValue(context);
        var target = Target.GetValue(context);
        // ... set up camera matrices ...
    }
}
```

### Key Patterns

| Pattern | Implementation |
|---------|---------------|
| **CRTP** | `Instance<T>` where T is the operator type |
| **Attribute metadata** | `[Guid]`, `[Input]`, `[Output]` attributes |
| **Typed slots** | `InputSlot<T>`, `Slot<T>` for type-safe connections |
| **Callback evaluation** | `UpdateAction` delegate on output slots |
| **Context passing** | `EvaluationContext` flows through the graph |

## Attributes

### @Guid Attribute

Every operator must have a unique GUID:

```csharp
[Guid("unique-guid-here")]
internal sealed class MyOperator : Instance<MyOperator>
```

This enables:
- Stable serialization (file references don't break when renaming)
- Cross-project operator lookup
- Versioning and migration

### @Input Attribute

```csharp
[Input(Guid = "...", MappedType = typeof(float))]
public readonly InputSlot<float> Value = new();
```

Options:
- `Guid`: Unique identifier for this input
- `MappedType`: Optional type for editor display/conversion

### @Output Attribute

```csharp
[Output(Guid = "...", DirtyFlagTrigger = DirtyFlagTrigger.Always)]
public readonly Slot<Command> Output = new();
```

Options:
- `Guid`: Unique identifier for this output
- `DirtyFlagTrigger`: When to invalidate downstream (`Always`, `OnChange`)

## Slot Types

### InputSlot<T>

Standard typed input:

```csharp
[Input(Guid = "...")]
public readonly InputSlot<float> Amplitude = new();

// In UpdateAction:
float amp = Amplitude.GetValue(context);
```

### MultiInputSlot<T>

Accepts multiple connections (variadic):

```csharp
[Input(Guid = "...")]
public readonly MultiInputSlot<Command> SubCommands = new();

// In UpdateAction:
foreach (var cmd in SubCommands.GetCollectedInputs())
{
    cmd.Execute(context);
}
```

### Slot<T> (Output)

```csharp
[Output(Guid = "...")]
public readonly Slot<float> Result = new();

// In UpdateAction:
Result.Value = computedResult;
```

## Common Slot Types

| Type | Purpose |
|------|---------|
| `Slot<Command>` | Rendering commands (most common for visuals) |
| `Slot<float>` | Numeric values |
| `Slot<Vector3>` | 3D positions, directions |
| `Slot<Vector4>` | Colors (RGBA), quaternions |
| `Slot<Matrix4x4>` | Transforms |
| `Slot<Texture2D>` | GPU textures |
| `Slot<MeshBuffers>` | 3D geometry |
| `Slot<bool>` | Toggles |
| `Slot<string>` | Text |

## Interfaces

### ICamera

Operators providing camera functionality:

```csharp
public interface ICamera
{
    Matrix4x4 CameraToClipSpace { get; }
    Matrix4x4 WorldToCamera { get; }
}
```

### ITransformable

Enables transform handles in the editor:

```csharp
public interface ITransformable
{
    InputSlot<Vector3> TranslationInput { get; }
    InputSlot<Vector3> RotationInput { get; }
    InputSlot<Vector3> ScaleInput { get; }
}
```

### IShaderCodeOperator<T>

For operators that compile custom shaders:

```csharp
public interface IShaderCodeOperator<T> where T : class
{
    string ShaderSource { get; }
    string EntryPoint { get; }
    T CompiledShader { get; set; }
}
```

### IStatusProvider

Returns status messages for the editor:

```csharp
public interface IStatusProvider
{
    InstanceStatus GetStatus();
}

public struct InstanceStatus
{
    public StatusLevel Level;  // Ok, Warning, Error
    public string Message;
}
```

## Evaluation Pattern

### Pull-Based Evaluation

```csharp
private void UpdateOutput(EvaluationContext context)
{
    // 1. Pull values from inputs (triggers their evaluation if dirty)
    var a = InputA.GetValue(context);
    var b = InputB.GetValue(context);

    // 2. Compute result
    var result = ComputeResult(a, b);

    // 3. Set output value
    Output.Value = result;
}
```

### Command Composition

For rendering operators:

```csharp
private void UpdateOutput(EvaluationContext context)
{
    // Save state
    var savedTransform = context.ObjectToWorld;

    // Modify context
    context.ObjectToWorld = Matrix4x4.CreateTranslation(Position.GetValue(context));

    // Evaluate child commands (they use modified context)
    var childCommand = SubTree.GetValue(context);
    childCommand?.Execute(context);

    // Restore state
    context.ObjectToWorld = savedTransform;

    // This operator's command just executes children
    Output.Value = new Command { Execute = ctx => childCommand?.Execute(ctx) };
}
```

## Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Operator class | PascalCase, noun | `Camera`, `DrawMesh`, `BlurImage` |
| Input slot | PascalCase, descriptive | `Position`, `Amplitude`, `Color` |
| Output slot | Usually `Output` or `Result` | `Output`, `Result`, `Texture` |
| Private methods | PascalCase with prefix | `UpdateOutput`, `ComputeResult` |

## Example: Simple Math Operator

```csharp
[Guid("12345678-1234-1234-1234-123456789abc")]
internal sealed class Add : Instance<Add>
{
    [Output(Guid = "output-guid")]
    public readonly Slot<float> Result = new();

    [Input(Guid = "input-a-guid")]
    public readonly InputSlot<float> A = new();

    [Input(Guid = "input-b-guid")]
    public readonly InputSlot<float> B = new();

    public Add()
    {
        Result.UpdateAction += Update;
    }

    private void Update(EvaluationContext context)
    {
        Result.Value = A.GetValue(context) + B.GetValue(context);
    }
}
```

## Example: Rendering Operator

```csharp
[Guid("87654321-4321-4321-4321-cba987654321")]
internal sealed class DrawCircle : Instance<DrawCircle>
{
    [Output(Guid = "...")]
    public readonly Slot<Command> Output = new();

    [Input(Guid = "...")]
    public readonly InputSlot<Vector2> Center = new();

    [Input(Guid = "...")]
    public readonly InputSlot<float> Radius = new();

    [Input(Guid = "...")]
    public readonly InputSlot<Vector4> Color = new();

    public DrawCircle()
    {
        Output.UpdateAction += Update;
    }

    private void Update(EvaluationContext context)
    {
        var center = Center.GetValue(context);
        var radius = Radius.GetValue(context);
        var color = Color.GetValue(context);

        Output.Value = new Command
        {
            Execute = ctx =>
            {
                // Issue GPU draw calls here
                DrawCircleToGpu(ctx, center, radius, color);
            }
        };
    }
}
```

## Patterns for Rust Framework

### Attribute → Derive Macros

```rust
#[derive(Operator)]
#[operator(guid = "...")]
struct Camera {
    #[output]
    output: Slot<Command>,

    #[input]
    position: InputSlot<Vec3>,
}
```

### Typed Slots → Generic Structs

```rust
pub struct InputSlot<T> {
    value: Option<T>,
    dirty: Cell<bool>,
    connection: Option<Box<dyn Slot>>,
}

impl<T> InputSlot<T> {
    pub fn get(&self, ctx: &EvaluationContext) -> T { ... }
}
```

### Update Callback → Trait Method

```rust
trait Operator {
    fn update(&mut self, ctx: &mut EvaluationContext);
}
```

### CRTP → Associated Types or Trait Objects

Rust doesn't need CRTP; use associated types or trait objects for polymorphism.

## Key Files to Study

| File | Purpose |
|------|---------|
| `Core/Operator/Attributes/InputAttribute.cs` | Input metadata |
| `Core/Operator/Attributes/OutputAttribute.cs` | Output metadata |
| `Core/Operator/Slot/InputSlot.cs` | Input slot implementation |
| `Core/Operator/Slot/Slot.cs` | Output slot implementation |
| `Operators/Lib/numbers/Add.cs` | Simple math operator |
| `Operators/Lib/render/Camera.cs` | Complex rendering operator |
| `Operators/Lib/render/DrawMesh.cs` | Mesh rendering example |
