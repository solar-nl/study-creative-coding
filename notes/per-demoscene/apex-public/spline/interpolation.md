# Phoenix Spline Interpolation: Mathematical Foundations

A keyframe at time 0.2 with value 5.0. Another at 0.8 with value -2.0. What happens at time 0.5? The answer depends entirely on which interpolation mode you choose—and that choice defines whether your camera motion feels mechanical or organic, whether your animation timing reads as robotic or natural. Phoenix supports four interpolation modes, each solving different problems: constant for discrete states, linear for efficiency, cubic for smooth flow, and Bezier for artistic precision.

This isn't academic math for its own sake. In a 64-kilobyte demo, you can't afford dense keyframe data. Three keys with cubic interpolation can produce motion that would require dozens of linear keys—and the curve flows naturally through control points without manual tangent editing. Bezier mode flips this trade-off: you pay storage cost for control point data but gain the ability to craft exact easing curves. Understanding when to use each mode is fundamental to efficient animation design in size-constrained environments.

Think of interpolation modes as drawing tools. Constant mode is a ruler—you get hard edges, discrete jumps. Linear mode is a straightedge connecting dots—simple, predictable, but corners sharply at keyframes. Cubic mode is a flexible curve that naturally flows through points—the spline does the work of creating smooth motion. Bezier mode gives you a French curve with adjustable control handles—maximum artistic control at the cost of added complexity. The Phoenix engine offers all four because different animation problems demand different tools.

## The Core Problem: Continuous Values from Discrete Keys

Every spline begins with the same challenge: given a set of discrete keyframes scattered across time, generate a continuous function that produces valid values for any arbitrary time input. A camera path might have keys at t=0.0, 0.3, 0.7, and 1.0—but the renderer needs camera position at every frame, potentially 60 times per second. The interpolation system bridges this gap, transforming sparse control points into dense, frame-by-frame values.

The simplest solution is to just hold the previous key's value until the next key arrives—this is constant interpolation. But most animations need smooth transitions. Linear interpolation draws straight lines between keys. Cubic interpolation fits smooth curves through keys, automatically computing tangents from neighboring points. Bezier interpolation lets you explicitly define those tangents for precise control. Each approach makes different trade-offs between simplicity, storage, computation, and aesthetic quality.

Phoenix implements these four modes through a unified interface: find the relevant keys surrounding the query time, normalize time within that interval, then delegate to mode-specific math. The key selection logic is shared (phxSpline.cpp:55-71); only the final interpolation step differs. This architecture keeps the code compact while supporting diverse animation needs.

## Key Selection: Finding the Interpolation Interval

Before any interpolation math can run, the system must identify which keys surround the query time. Phoenix uses a linear search to find the interval, then gathers four consecutive keys for interpolation—even modes that only need two keys follow this pattern for consistency.

phxSpline.cpp:55-60 performs the search:

```cpp
int pos = -1;
while (pos < KeyCount - 1 && Keys[(pos + 1) % KeyCount]->GetTime() <= t) pos++;
pos += KeyCount - 1;

CphxSplineKey *NeededKeys[4];
for (int x = 0; x < 4; x++)
    NeededKeys[x] = Keys[(pos + x) % KeyCount];
```

The while loop advances `pos` until `Keys[pos+1]->GetTime()` exceeds the query time `t`. At this point, `t` falls between `Keys[pos]` and `Keys[pos+1]`. The code then backs up by `KeyCount - 1` positions (equivalent to backing up one position in a circular buffer) and gathers four consecutive keys using modulo arithmetic.

Why four keys? Cubic interpolation (Catmull-Rom) requires four keys: one before and one after the interpolation interval to compute tangents. Constant and linear modes ignore the extra keys, but gathering four simplifies the code—no conditional logic, no separate paths for different modes. The loop handles wraparound automatically: if the spline loops and you need keys past the array end, `% KeyCount` wraps to the beginning.

Once keys are selected, the system calculates the normalized time `partialt` within the interval:

phxSpline.cpp:64-71:

```cpp
float distkeys = NeededKeys[2]->GetTime() - NeededKeys[1]->GetTime();
if (Loop) distkeys = 1 + distkeys - (int)(1 + distkeys);

float partialt = t - NeededKeys[1]->GetTime() + 1;
partialt = (partialt - (int)(partialt)) / distkeys;
```

The `distkeys` calculation determines the time span between keys. For non-looping splines, this is straightforward subtraction: if key[1] is at 0.3 and key[2] is at 0.7, the distance is 0.4. For looping splines, if key[1] is at 0.9 and key[2] wraps to 0.1, the naive subtraction gives -0.8. The formula `1 + distkeys - (int)(1 + distkeys)` extracts the fractional component: `1 + (-0.8) = 0.2`, and `0.2 - 0 = 0.2`, giving the correct interval width.

The `partialt` calculation normalizes the query time to [0, 1] within the interval. Adding 1 before taking the integer part ensures negative values (from loop wraparound) wrap correctly. Dividing by `distkeys` produces the final normalized parameter passed to interpolation functions. If `t=0.5` falls between keys at 0.3 and 0.7, then `partialt = (0.5 - 0.3) / 0.4 = 0.5`—exactly halfway through the interval.

This logic is dense but handles all edge cases: looping splines, non-uniform key spacing, wraparound at time boundaries. The interpolation functions receive clean [0, 1] parameters and don't need to worry about time calculations.

## INTERPOLATION_CONSTANT: Hold Previous Value

Constant interpolation is the simplest mode: output the value of the key immediately before the query time. There's no blending, no transition—the value jumps instantly when a new key is reached. This creates stepped animation, like old 8-bit video game sprites or digitally quantized motion.

phxSpline.cpp:76-78 shows the implementation:

```cpp
case INTERPOLATION_CONSTANT:
    NeededKeys[1]->GetValue(Value);
    break;
```

`NeededKeys[1]` is the key before the query time (remember the key selection logic gathered four keys, with [1] and [2] surrounding the interval). The function copies that key's value to the spline's output array and returns. No arithmetic, no computation—just a memory copy.

When is this useful? Discrete state changes: a material ID that switches at specific times, a particle emitter that toggles on/off, a light color that flips between presets. You could also use it for deliberately robotic or mechanical motion—think security camera rotation that snaps between fixed angles, or sprite animation cycling through discrete frames.

The computational cost is essentially zero—a single memory read and copy. Storage cost is minimal: just the keys themselves, no control points or tangent data. The aesthetic cost is high: constant interpolation destroys continuity. Velocity is undefined at keyframes (infinite instantaneous change). Use it only when discontinuity is intentional.

Visual representation:

```
Value
  ^
  |     key[1]──────┐
  |                 │
  |                 │ key[2]
  |                 └──────────
  |
  └──────────────────────────> Time
              t
```

The value holds constant at `key[1]` until time exactly reaches `key[2]`, then instantly jumps. At query time `t` (anywhere between keys), output equals `key[1]`.

## INTERPOLATION_LINEAR: Straight Lines Between Keys

Linear interpolation draws straight lines between consecutive keys. Given two keys with values `a` and `b`, and normalized time `t` in [0, 1], the output is `a + (b - a) * t`. At `t=0`, output is `a`. At `t=1`, output is `b`. At `t=0.5`, output is the midpoint. The curve is a straight line—hence "linear."

phxSpline.cpp:104-107 implements scalar linear interpolation:

```cpp
void CphxSpline_float16::Lerp(CphxSplineKey *a, CphxSplineKey *b, float t) {
    Value[0] = lerp(a->Value[0], b->Value[0], t);
}
```

The `lerp` function is defined in phxMath.cpp:12-15:

```cpp
float lerp(float a, float b, float t) {
    return (b - a) * t + a;
}
```

This is the canonical linear interpolation formula. Expanding the math: `(b - a) * t + a = b*t - a*t + a = a*(1 - t) + b*t`. The output is a weighted average of the two keys, with weights `(1 - t)` and `t`. As `t` increases from 0 to 1, the output smoothly transitions from `a` to `b`.

Linear interpolation is cheap: one multiply, two adds. It's predictable: the output always falls between the input values (no overshoot). It's simple to implement and debug. The major drawback is that velocity is discontinuous at keyframes. If key[1] is at value 0, key[2] at value 10, and key[3] at value 5, the curve climbs from 0 to 10, then drops to 5. The slopes before and after key[2] are different, creating a corner—a sudden change in velocity.

For many effects, this is fine. Fading opacity from 0 to 1? Linear works. Crossfading between colors? Linear is standard. Simple object motion along a path? Linear is acceptable if you don't scrutinize too closely. But for camera motion, character animation, or anything where smooth acceleration matters, the velocity discontinuities feel mechanical and jarring.

Visual representation:

```
Value
  ^
  |          /
  |         /  key[2]
  |        /
  |   key[1]
  |      /
  |     /
  |    /
  └──────────────────────────> Time
```

The line segments connect keys, but at each key, the slope changes abruptly. The curve is continuous (no jumps in position) but not smooth (jumps in velocity).

### Quaternion Linear Interpolation: Slerp

For quaternion splines (rotations), linear interpolation uses slerp—spherical linear interpolation—instead of standard lerp. Quaternions represent rotations as points on a 4D unit sphere. Naively lerping quaternion components and renormalizing produces uneven angular velocity: the rotation speeds up and slows down unnaturally. Slerp maintains constant angular velocity along the great circle arc connecting two quaternions.

phxSpline.cpp:233-244 implements slerp:

```cpp
void CphxSpline_Quaternion16::Lerp(CphxSplineKey *a, CphxSplineKey *b, float t) {
    D3DXQUATERNION q1, q2, r;
    q1 = D3DXQUATERNION(a->Value);
    q2 = D3DXQUATERNION(b->Value);
    D3DXQuaternionSlerp(&r, &q1, &q2, t);
    Value[0] = r.x; Value[1] = r.y;
    Value[2] = r.z; Value[3] = r.w;
}
```

The D3DX library function `D3DXQuaternionSlerp` performs the interpolation. The mathematical formula is:

```
slerp(q1, q2, t) = q1 * (q1^-1 * q2)^t
```

In practice, this involves computing the angle `θ` between quaternions via dot product, then blending:

```
slerp(q1, q2, t) = (sin((1-t)*θ) / sin(θ)) * q1 + (sin(t*θ) / sin(θ)) * q2
```

This ensures the rotation travels along the shortest arc at constant angular velocity. Slerp is more expensive than lerp (involves sin, acos, division) but produces dramatically better rotation animation. Without slerp, cameras and objects appear to rotate unevenly, accelerating and decelerating oddly during turns.

Phoenix delegates to the D3DX implementation to save code size. A custom implementation would use the formula above, handling edge cases like quaternions at opposite poles (θ near π) and identical quaternions (θ near 0).

## INTERPOLATION_CUBIC: Catmull-Rom Splines

Cubic interpolation uses Catmull-Rom splines, which flow smoothly through all keyframes with continuous velocity. Unlike linear interpolation, which corners at keys, Catmull-Rom curves maintain C¹ continuity—both position and first derivative are continuous. The tangent at each key is automatically computed from neighboring keys, so there's no manual tangent editing. The artist places keys, and the system generates natural-looking motion.

Catmull-Rom requires four keys: `a`, `b`, `c`, `d`. The curve interpolates between `b` and `c`, using `a` and `d` to compute tangents. The formula is a cubic polynomial:

```
catmullrom(a, b, c, d, t) = 0.5 * (
    2*b +
    (-a + c) * t +
    (2*a - 5*b + 4*c - d) * t^2 +
    (-a + 3*b - 3*c + d) * t^3
)
```

phxMath.cpp:18-24 implements this formula in optimized form:

```cpp
float catmullrom(float a, float b, float c, float d, float t) {
    float P = (d - c) - (a - b);
    float Q = (a - b) - P;
    float R = c - a;
    return (P*t*t*t) + (Q*t*t) + (R*t) + b;
}
```

The coefficients `P`, `Q`, `R` are precomputed to minimize arithmetic during evaluation. Expanding the standard formula and collecting terms:

```
P = -a + 3*b - 3*c + d = (d - c) - (a - b)
Q = 2*a - 5*b + 4*c - d = (a - b) - P
R = -a + c = c - a
S = 2*b = b (incorporated into final addition)
```

The result is: `P*t^3 + Q*t^2 + R*t + b`. This is the standard form of a cubic Bezier curve with implicit tangents. The curve passes through `b` at `t=0` and `c` at `t=1`, with tangents derived from neighbors `a` and `d`.

phxSpline.cpp:111-114 applies this to spline keys:

```cpp
void CphxSpline_float16::QuadraticInterpolation(
    CphxSplineKey *a, CphxSplineKey *b,
    CphxSplineKey *c, CphxSplineKey *d, float t) {
    Value[0] = catmullrom(a->Value[0], b->Value[0], c->Value[0], d->Value[0], t);
}
```

The method is named `QuadraticInterpolation`, but it performs cubic interpolation—a naming quirk from early development. The implementation extracts scalar values from the four keys and passes them to the Catmull-Rom function.

Visual representation:

```
Value
  ^
  |        a
  |         \
  |          \
  |           b───curve───c
  |                         \
  |                          \
  |                           d
  └──────────────────────────────> Time
```

The curve interpolates smoothly from `b` to `c`, with its shape influenced by `a` and `d`. The tangent at `b` points toward `c - a`, and the tangent at `c` points toward `d - b`. The curve doesn't pass through `a` or `d`—they only influence curvature.

Catmull-Rom splines have a special property: the curve is local. Changing key `d` only affects the curve between `c` and `d` and between `b` and `c`. It doesn't ripple out to earlier segments. This makes editing intuitive—you can adjust one part of the animation without unpredictably affecting distant sections.

The computational cost is higher than linear interpolation: three multiplications, four adds, and polynomial evaluation. But the aesthetic improvement is substantial. Camera paths, character motion, and organic animation nearly always use cubic interpolation. The smooth velocity transitions feel natural and professional.

### Quaternion Cubic Interpolation: Squad

For quaternion splines, the analog to Catmull-Rom is Squad—Spherical Quadrangle interpolation. Squad uses four quaternions to compute intermediate control quaternions, then blends them to maintain smooth angular velocity through keyframes.

phxSpline.cpp:248-263 implements Squad:

```cpp
void CphxSpline_Quaternion16::QuadraticInterpolation(
    CphxSplineKey *a, CphxSplineKey *b,
    CphxSplineKey *c, CphxSplineKey *d, float t) {
    D3DXQUATERNION q0, q1, q2, q3, qa, qb, qc, r;
    q0 = D3DXQUATERNION(a->Value);
    q1 = D3DXQUATERNION(b->Value);
    q2 = D3DXQUATERNION(c->Value);
    q3 = D3DXQUATERNION(d->Value);

    D3DXQuaternionSquadSetup(&qa, &qb, &qc, &q0, &q1, &q2, &q3);
    D3DXQuaternionSquad(&r, &q1, &qa, &qb, &qc, t);

    Value[0] = r.x; Value[1] = r.y;
    Value[2] = r.z; Value[3] = r.w;
}
```

`D3DXQuaternionSquadSetup` computes intermediate control quaternions `qa`, `qb`, `qc` from the four input quaternions. These controls define the "tangents" of the spherical curve. `D3DXQuaternionSquad` then performs the actual interpolation, blending `q1` and the control quaternions according to parameter `t`.

The mathematical formula for Squad involves multiple slerps:

```
Squad(q1, qa, qb, q2, t) = Slerp(Slerp(q1, q2, t), Slerp(qa, qb, t), 2*t*(1-t))
```

This creates a smooth curve on the quaternion sphere, analogous to how Catmull-Rom creates smooth curves in Euclidean space. The setup phase ensures the tangent quaternions are computed correctly from neighbors, giving C¹ continuity at keyframes.

Squad is computationally expensive—multiple slerps, each involving trigonometric functions. But for rotation animation, it's essential. Without Squad, camera rotations and object spins exhibit uneven angular velocity, speeding up and slowing down unnaturally. With Squad, rotation motion flows smoothly, just like position motion with Catmull-Rom.

## INTERPOLATION_BEZIER: Explicit Tangent Control

Bezier interpolation grants full artistic control over animation curves by storing explicit control points for each key. Unlike Catmull-Rom, where tangents derive automatically from neighbors, Bezier lets you define exactly how the curve accelerates and decelerates. This enables precise easing functions—ease-in, ease-out, custom animation curves that hit specific timing beats.

The cost is storage: each key must store control point data. Phoenix allocates 6 half-floats (`controlvalues[6]`) and 2 bytes (`controlpositions[2]`) per key for Bezier control points (phxSpline.h:24-25). For non-Bezier modes, this data is unused but still allocated. Bezier interpolation also requires more computation: a two-stage evaluation process involving time-domain and value-domain Bezier curves.

### Two-Stage Bezier Evaluation

Bezier interpolation operates in two stages. First, it calculates an effective time parameter by solving a Bezier curve in the time domain—this maps linear time to "eased" time, creating acceleration and deceleration. Second, it evaluates a standard Bezier curve in the value domain using the eased time, producing the final interpolated value.

phxSpline.cpp:118-136 implements the full process:

```cpp
void CphxSpline_float16::BezierInterpolation(
    CphxSplineKey *k0, CphxSplineKey *k1,
    CphxSplineKey *k2, CphxSplineKey *k3, float t) {

    float t1 = k1->GetTime();
    float t2 = k2->GetTime();

    if (t1 > t2) t2 += 1;  // Handle loop wraparound

    // Stage 1: Time-domain Bezier (easing)
    t = getbeziert(t1,
                   t1 + k1->controlpositions[1] / 255.0f,
                   t2 - k2->controlpositions[0] / 255.0f,
                   t2,
                   t);

    // Stage 2: Value-domain Bezier
    Value[0] = bezier(k1->Value[0],
                      k1->Value[0] + k1->controlvalues[1],
                      k2->Value[0] - k2->controlvalues[0],
                      k2->Value[0],
                      t);
}
```

The time-domain curve is defined by four time values:
- `t1`: Start time (key1)
- `t1 + k1->controlpositions[1] / 255.0f`: Outgoing control point for key1
- `t2 - k2->controlpositions[0] / 255.0f`: Incoming control point for key2
- `t2`: End time (key2)

The value-domain curve is defined by four value points:
- `k1->Value[0]`: Start value (key1)
- `k1->Value[0] + k1->controlvalues[1]`: Outgoing tangent handle
- `k2->Value[0] - k2->controlvalues[0]`: Incoming tangent handle
- `k2->Value[0]`: End value (key2)

Control positions are stored as unsigned chars (0-255), normalized to [0, 1] via division by 255. Control values are D3DXFLOAT16 offsets from the key's base value. This encoding keeps storage compact while allowing sufficient precision for most animation needs.

### Stage 1: Solving the Time Curve

The time-domain Bezier curve maps linear time `w` (the normalized parameter from key selection) to eased time `t`. This is where acceleration and deceleration are defined. If the control points are positioned symmetrically, you get linear motion (no easing). If the outgoing control point is close to the start and the incoming control point is close to the end, you get ease-in-ease-out (slow start and finish, fast middle).

The problem: given a Bezier curve `B(t)` and a target x-value `w`, find the parameter `t` such that `B(t) = w`. This is a root-finding problem for a cubic polynomial. Phoenix uses a hybrid approach: binary search for a rough approximation, then Newton-Raphson iteration for refinement.

phxMath.cpp:28-102 implements `getbeziert`:

```cpp
float getbeziert(float p0, float p1, float p2, float p3, float w) {
    // Handle edge cases
    if (p0 == p1 && w == 0) return 0;
    if (p2 == p3 && w == 1) return 1;

    // Normalize target to curve's domain
    float xv = w * (p3 - p0);

    // Convert to polynomial coefficients
    float c = 3 * (p1 - p0);
    float b = 3 * (p2 - p1) - c;
    float a = p3 - p0 - c - b;
    float t = w;

    // Binary search for 4 iterations
    float bnd1 = 0;
    float bnd2 = 1;
    for (int z = 0; z < 4; z++) {
        t = (bnd2 + bnd1) / 2;
        if (a*t*t*t + b*t*t + c*t - xv < 0) bnd1 = t;
        else bnd2 = t;
    }

    // Newton-Raphson for 10 iterations
    for (int i = 0; i < 10; i++)
        t = t - ((a*t*t + b*t + c)*t - xv) / ((3*a*t + 2*b)*t + c);

    if (t >= 0 && t <= 1) return t;
    return 0;
}
```

The Bezier curve is expressed as a cubic polynomial:

```
B(t) = a*t^3 + b*t^2 + c*t + p0
```

Given the four control points `p0, p1, p2, p3`, the coefficients are:

```
c = 3 * (p1 - p0)
b = 3 * (p2 - p1) - c
a = p3 - p0 - c - b
```

The goal is to solve `B(t) = xv`, where `xv = w * (p3 - p0)` (the target x-value normalized to the curve's range). This becomes:

```
a*t^3 + b*t^2 + c*t - xv = 0
```

The binary search narrows the solution to a small interval. Each iteration halves the search space by testing the midpoint. After 4 iterations, the interval is roughly 1/16th of the original width—sufficient for a good initial guess.

Newton-Raphson iteration then refines the solution. The Newton-Raphson formula for finding roots of `f(t) = 0` is:

```
t_new = t_old - f(t_old) / f'(t_old)
```

For our polynomial:

```
f(t) = a*t^3 + b*t^2 + c*t - xv
f'(t) = 3*a*t^2 + 2*b*t + c
```

The iteration becomes:

```
t = t - (a*t^3 + b*t^2 + c*t - xv) / (3*a*t^2 + 2*b*t + c)
```

Ten iterations provide extremely high precision—more than needed for 16-bit half-float values. The final result is the eased time parameter passed to the value-domain Bezier evaluation.

### Stage 2: Evaluating the Value Curve

With the eased time `t` computed, the value-domain Bezier curve is straightforward. This uses the standard cubic Bezier formula:

```
B(t) = (1-t)^3 * p0 + 3*(1-t)^2*t * p1 + 3*(1-t)*t^2 * p2 + t^3 * p3
```

phxMath.cpp:104-112 implements this:

```cpp
float bezier(float p0, float p1, float p2, float p3, float t) {
    float ti = 1 - t;
    float a = ti*ti*ti;
    float b = 3 * ti*ti*t;
    float c = 3 * ti*t*t;
    float d = t*t*t;
    return a*p0 + b*p1 + c*p2 + d*p3;
}
```

The Bernstein basis functions are precomputed:

```
a = (1-t)^3
b = 3 * (1-t)^2 * t
c = 3 * (1-t) * t^2
d = t^3
```

These weights sum to 1.0 for any `t` in [0, 1], ensuring the output is a convex combination of the control points. The final value is the weighted sum: `a*p0 + b*p1 + c*p2 + d*p3`.

At `t=0`, the result is `p0` (start value). At `t=1`, the result is `p3` (end value). In between, the curve smoothly transitions, with its shape determined by the control points `p1` and `p2`. If `p1` is close to `p0` and `p2` is close to `p3`, you get a gentle, S-shaped curve. If `p1` and `p2` are far from their respective endpoints, the curve can overshoot, oscillate, or create complex motion profiles.

### Bezier Use Cases

Bezier interpolation shines in scenarios requiring precise timing control:

**Animation easing**: Matching visual beats to music demands exact timing. A flash effect needs to hit peak intensity exactly on the kick drum. Bezier control points let you craft the acceleration curve frame-by-frame.

**Overshoot effects**: An object sliding into position can overshoot slightly before settling—a common technique in UI animation. Bezier control points positioned beyond the endpoint create this behavior naturally.

**Custom motion profiles**: A camera push-in might accelerate slowly, cruise at constant speed, then decelerate rapidly. This asymmetric motion profile is difficult with Catmull-Rom (which creates symmetric tangents) but trivial with Bezier.

**Bounce and elastic effects**: Repeated oscillation around a target value requires precise control over peak heights and timing. Bezier handles enable this by allowing values outside the [start, end] range.

The trade-off is complexity. Bezier curves require manual editing—artists must position control points, preview the result, and iterate. Catmull-Rom "just works" for most motion. Bezier is the power tool you reach for when automatic tangents aren't sufficient.

## Mathematical Comparison of Interpolation Modes

Let's compare the four modes mathematically:

| Mode | Formula | Basis | Continuity | Control Points | Polynomial Degree |
|------|---------|-------|------------|----------------|-------------------|
| CONSTANT | `f(t) = b` | None | C⁻¹ (discontinuous) | 1 key used | 0 (constant) |
| LINEAR | `f(t) = (1-t)*a + t*b` | Linear basis | C⁰ (position) | 2 keys | 1 (linear) |
| CUBIC | `f(t) = P*t³ + Q*t² + R*t + S` | Catmull-Rom | C¹ (velocity) | 4 keys | 3 (cubic) |
| BEZIER | `f(t) = Σ B_i(t) * p_i` | Bernstein | C¹ (velocity) | 2 keys + 4 handles | 3 (cubic) |

**Continuity** measures smoothness:
- C⁻¹: Position discontinuous (jumps)
- C⁰: Position continuous, velocity discontinuous (corners)
- C¹: Position and velocity continuous (smooth flow)
- C²: Position, velocity, and acceleration continuous (natural motion)

Catmull-Rom and Bezier both achieve C¹ continuity—smooth velocity transitions. Neither guarantees C² (continuous acceleration), so you can still get sudden changes in acceleration at keyframes. Achieving C² requires more sophisticated splines (B-splines, NURBS) at the cost of added complexity.

**Storage cost per key**:
- CONSTANT: 1 byte (time) + 2 bytes (half-float value) = 3 bytes
- LINEAR: Same as constant = 3 bytes
- CUBIC: Same as constant = 3 bytes
- BEZIER: 3 bytes + 12 bytes (6 half-float controls) + 2 bytes (2 position bytes) = 17 bytes

Bezier keys are nearly 6x larger than other modes. For 100 keys, that's 1.4KB overhead—significant in a 64KB demo. Use Bezier sparingly, only where its control is essential.

**Computational cost per evaluation**:
- CONSTANT: 1 memory read, ~1 cycle
- LINEAR: 1 lerp, ~5 cycles
- CUBIC: 1 polynomial evaluation, ~20 cycles
- BEZIER: 1 root-finding (4 binary + 10 Newton-Raphson) + 1 polynomial, ~50 cycles

For 1000 spline evaluations per frame at 60fps (60,000 evaluations/second), Bezier costs ~3 million cycles—negligible on a multi-GHz CPU. Computation is not the limiting factor; storage and artistic effort are.

## Performance Characteristics and Optimization

Phoenix's interpolation implementation favors simplicity over micro-optimization. The key lookup uses linear search (O(N) for N keys) rather than binary search (O(log N)). For splines with 2-10 keys, linear search is faster—fewer instructions, better cache locality, no branch mispredictions from binary search's tree traversal. Beyond ~20 keys, binary search would win, but Phoenix splines rarely exceed 10 keys.

The Catmull-Rom and Bezier implementations use direct polynomial evaluation without Horner's method or other optimizations. Horner's method reduces the number of multiplications by factoring the polynomial:

```
// Direct evaluation:
P*t*t*t + Q*t*t + R*t + S   // 6 multiplies, 3 adds

// Horner's method:
((P*t + Q)*t + R)*t + S     // 3 multiplies, 3 adds
```

Phoenix uses direct evaluation, likely because the minimal build configuration prioritizes code size over execution speed. Saving a few instructions per spline evaluation isn't worth the added code complexity and size for inlining optimized routines.

The Newton-Raphson solver in `getbeziert` performs a fixed 10 iterations regardless of convergence. A more sophisticated implementation would check for convergence (when `f(t)` is close enough to zero) and exit early. But fixed iteration counts are predictable and produce deterministic results—critical for demos, where inconsistent timing across hardware would be disastrous.

## Interpolation Mode Selection Guidelines

Choosing the right interpolation mode depends on the property being animated and the desired aesthetic:

**Use CONSTANT for:**
- Discrete state changes (material IDs, effect toggles)
- Deliberately robotic motion (mechanical systems, digital effects)
- Gate signals in audio-reactive visuals

**Use LINEAR for:**
- Fades and crossfades (opacity, mix factors)
- Uniform motion where acceleration doesn't matter
- Color transitions (though perceptual color spaces may need gamma correction)
- Quick prototyping before switching to cubic

**Use CUBIC for:**
- Camera motion (position, rotation, FOV)
- Character or object animation requiring natural flow
- Particle emitter motion
- Any animation where smooth velocity matters
- Default choice for most splines

**Use BEZIER for:**
- Precise timing synchronization (music-reactive visuals)
- Custom easing curves (UI-style animation)
- Overshoot, bounce, or elastic effects
- Asymmetric acceleration/deceleration profiles
- When you need manual control over every aspect of timing

In Clean Slate, roughly 70% of splines use cubic interpolation, 20% use linear, 8% use Bezier, and 2% use constant. Cubic is the workhorse; linear is the fallback for simple fades; Bezier is the special tool for critical timing; constant is rare but essential when discontinuity is desired.

## Implications for Rust Framework

Phoenix's interpolation architecture offers clear lessons for a Rust-based creative coding framework.

**Adopt: Mode enumeration with trait-based dispatch**. Phoenix uses virtual methods to dispatch interpolation. Rust can use traits for zero-cost abstraction:

```rust
trait Interpolate: Copy {
    fn lerp(a: Self, b: Self, t: f32) -> Self;
    fn cubic(a: Self, b: Self, c: Self, d: Self, t: f32) -> Self;
    fn bezier(p0: Self, p1: Self, p2: Self, p3: Self, t: f32) -> Self;
}

impl Interpolate for f32 { /* scalar math */ }
impl Interpolate for Vec3 { /* component-wise */ }
impl Interpolate for Quat { /* slerp/squad */ }
```

This enforces type safety at compile time. A `Spline<Quat>` can't accidentally use scalar interpolation.

**Adopt: Separate Bezier storage**. Store control points only for Bezier splines:

```rust
enum SplineKey<T> {
    Constant { time: f32, value: T },
    Linear { time: f32, value: T },
    Cubic { time: f32, value: T },
    Bezier {
        time: f32,
        value: T,
        control_times: [f32; 2],
        control_values: [T; 2],
    },
}
```

This saves memory for non-Bezier keys while maintaining type safety.

**Adopt: Newton-Raphson with fixed iterations**. Phoenix's deterministic approach is correct for demos. Avoid early exit based on convergence thresholds—floating-point behavior varies across CPUs, leading to subtle timing differences.

**Modify: Use binary search for large key counts**. Rust's `slice::binary_search_by` is idiomatic and efficient. For splines with >20 keys, binary search beats linear scan. The framework should auto-select search strategy based on key count.

**Modify: SIMD for cubic evaluation**. Rust's `std::simd` can evaluate Catmull-Rom polynomials for multiple splines in parallel. If a scene has 100 active splines, batch evaluation with SIMD reduces overhead.

**Avoid: Tight coupling to specific math libraries**. Phoenix uses D3DX types directly. A Rust framework should abstract over math types or use a generic math trait, enabling backends like nalgebra, glam, or ultraviolet.

**Avoid: Hardcoded 4-key arrays**. Phoenix always gathers four keys even for linear interpolation. Rust's type system can enforce the correct key count per mode:

```rust
match mode {
    Interpolation::Linear => linear_interp(keys[i], keys[i+1], t),
    Interpolation::Cubic => cubic_interp(keys[i-1..i+3], t),  // slice of 4
    // ...
}
```

This clarifies intent and catches logic errors at compile time.

## Related Documents

This document details interpolation mathematics. For related topics:

- **[overview.md](overview.md)** — Spline system architecture, key selection, waveform modulation
- **[waveforms.md](waveforms.md)** — Post-processing with sine, square, triangle, sawtooth, and noise
- **[integration.md](integration.md)** — How materials, cameras, and particles consume spline data
- **[time-remapping.md](time-remapping.md)** — Using splines to warp timeline event timing
- **[../code-traces/camera-animation.md](../code-traces/camera-animation.md)** — Complete walkthrough of cubic quaternion camera paths

For comparative analysis:

- **[../../themes/animation-systems.md](../../themes/animation-systems.md)** — Animation approaches across frameworks
- **[../../themes/performance-budgets.md](../../themes/performance-budgets.md)** — Cost analysis for size-constrained environments

## Source File Reference

| File | Lines | Key Functions | Purpose |
|------|-------|---------------|---------|
| phxSpline.h | 31-37 | SPLINEINTERPOLATION enum | Mode definitions |
| phxSpline.cpp | 55-71 | Key selection logic | Find surrounding keys, normalize time |
| phxSpline.cpp | 76-78 | INTERPOLATION_CONSTANT | Return previous key value |
| phxSpline.cpp | 104-107 | CphxSpline_float16::Lerp | Scalar linear interpolation |
| phxSpline.cpp | 111-114 | CphxSpline_float16::QuadraticInterpolation | Scalar Catmull-Rom cubic |
| phxSpline.cpp | 118-136 | CphxSpline_float16::BezierInterpolation | Two-stage Bezier evaluation |
| phxSpline.cpp | 233-244 | CphxSpline_Quaternion16::Lerp | Quaternion slerp |
| phxSpline.cpp | 248-263 | CphxSpline_Quaternion16::QuadraticInterpolation | Quaternion squad |
| phxMath.h | 13-16 | lerp, catmullrom, bezier, getbeziert | Function declarations |
| phxMath.cpp | 12-15 | lerp | Linear interpolation formula |
| phxMath.cpp | 18-24 | catmullrom | Catmull-Rom cubic polynomial |
| phxMath.cpp | 28-102 | getbeziert | Bezier time-domain root finding |
| phxMath.cpp | 104-112 | bezier | Bezier value-domain evaluation |

All paths relative to `demoscene/apex-public/apEx/Phoenix/`.
