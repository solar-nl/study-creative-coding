// lighting-ltc.wgsl - Linearly Transformed Cosines Area Light Evaluation
//
// Implements accurate sphere area light shading using the LTC method.
// Transforms the BRDF distribution to match a clamped cosine, enabling
// closed-form integration over polygonal light sources.
//
// Reference: [05-ltc-area-lights.md](../05-ltc-area-lights.md)
// Paper: Heitz et al., "Real-Time Polygonal-Light Shading with LTCs"

// ============================================================================
// Constants
// ============================================================================

const PI: f32 = 3.14159265359;
const TWO_PI: f32 = 6.28318530718;
const HALF_PI: f32 = 1.57079632679;
const EPSILON: f32 = 0.0001;

/// Number of vertices for sphere discretization (24-gon approximation)
const SPHERE_VERTICES: u32 = 24u;

// ============================================================================
// Bind Groups
// ============================================================================

struct SceneUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    light_count: vec4<f32>,
    resolution: vec4<f32>,
    inverse_view: mat4x4<f32>,
    inverse_projection: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> scene: SceneUniforms;

// LTC lookup textures
@group(1) @binding(0) var ltc_matrix: texture_2d<f32>;
@group(1) @binding(1) var ltc_fresnel: texture_2d<f32>;
@group(1) @binding(2) var ltc_sampler: sampler;

// G-Buffer textures
@group(2) @binding(0) var gbuffer_albedo: texture_2d<f32>;
@group(2) @binding(1) var gbuffer_normal: texture_2d<f32>;
@group(2) @binding(2) var gbuffer_depth: texture_depth_2d;
@group(2) @binding(3) var gbuffer_sampler: sampler;

// ============================================================================
// LTC Core Functions
// ============================================================================

/// Sample LTC inverse matrix from lookup texture
///
/// Returns a 3x3 matrix that transforms the BRDF lobe to match a clamped cosine.
/// The matrix is parameterized by (cos_theta, roughness).
fn sample_ltc_matrix(cos_theta: f32, roughness: f32) -> mat3x3<f32> {
    // UV coordinates for 16×16 texture
    let uv = vec2<f32>(roughness, sqrt(1.0 - cos_theta));

    // Sample RGBA (a, b, c, d)
    let t = textureSampleLevel(ltc_matrix, ltc_sampler, uv, 0.0);

    // Reconstruct 3×3 matrix from 4 unique values
    // | a  0  b |
    // | 0  1  0 |
    // | c  0  d |
    return mat3x3<f32>(
        vec3<f32>(t.x, 0.0, t.z),  // Column 0: (a, 0, c)
        vec3<f32>(0.0, 1.0, 0.0),  // Column 1: (0, 1, 0)
        vec3<f32>(t.y, 0.0, t.w),  // Column 2: (b, 0, d)
    );
}

/// Sample Fresnel magnitude and bias from lookup texture
fn sample_ltc_fresnel(cos_theta: f32, roughness: f32) -> vec2<f32> {
    let uv = vec2<f32>(roughness, sqrt(1.0 - cos_theta));
    return textureSampleLevel(ltc_fresnel, ltc_sampler, uv, 0.0).rg;
}

// ============================================================================
// Polygon Clipping (Sutherland-Hodgman)
// ============================================================================

/// Clip polygon to hemisphere above the shading point
///
/// Uses Sutherland-Hodgman algorithm to clip the light polygon against
/// the z=0 plane (horizon). Returns the number of vertices after clipping.
fn clip_polygon_to_horizon(
    vertices_in: ptr<function, array<vec3<f32>, 32>>,
    count_in: u32,
    vertices_out: ptr<function, array<vec3<f32>, 32>>,
) -> u32 {
    var count_out: u32 = 0u;

    if count_in == 0u {
        return 0u;
    }

    // Process each edge
    var prev = (*vertices_in)[count_in - 1u];
    var prev_above = prev.z > 0.0;

    for (var i: u32 = 0u; i < count_in; i = i + 1u) {
        let curr = (*vertices_in)[i];
        let curr_above = curr.z > 0.0;

        if prev_above {
            // Previous vertex is above horizon
            (*vertices_out)[count_out] = prev;
            count_out = count_out + 1u;
        }

        if prev_above != curr_above {
            // Edge crosses horizon - compute intersection
            let t = prev.z / (prev.z - curr.z);
            let intersection = prev + t * (curr - prev);
            (*vertices_out)[count_out] = intersection;
            count_out = count_out + 1u;
        }

        prev = curr;
        prev_above = curr_above;
    }

    return count_out;
}

// ============================================================================
// Edge Integration
// ============================================================================

/// Integrate one edge of the clipped polygon
///
/// Uses the rational polynomial approximation for the edge integral.
/// Returns the contribution of this edge to the total irradiance.
fn integrate_edge(v1: vec3<f32>, v2: vec3<f32>) -> f32 {
    let cos_theta = dot(v1, v2);
    let theta = acos(clamp(cos_theta, -1.0, 1.0));

    // Cross product gives the perpendicular direction and magnitude
    let cross_v = cross(v1, v2);

    // Rational approximation to theta / sin(theta)
    // More numerically stable than direct evaluation
    let x = abs(theta);
    var res: f32;
    if x < 0.0001 {
        // Taylor expansion for small angles
        res = 1.0 + x * x / 6.0;
    } else {
        res = x / sin(x);
    }

    return cross_v.z * res;
}

/// Integrate entire polygon using edge integration
fn integrate_polygon(vertices: ptr<function, array<vec3<f32>, 32>>, count: u32) -> f32 {
    if count < 3u {
        return 0.0;
    }

    var sum: f32 = 0.0;

    // Sum edge integrals
    for (var i: u32 = 0u; i < count; i = i + 1u) {
        let j = (i + 1u) % count;
        sum += integrate_edge((*vertices)[i], (*vertices)[j]);
    }

    // The integral gives irradiance / π, normalize
    return max(0.0, sum) / TWO_PI;
}

// ============================================================================
// Sphere Light Polygon Generation
// ============================================================================

/// Generate a polygon approximating a sphere as seen from shading point
///
/// Creates a 24-vertex disc tangent to the sphere at its closest point.
fn generate_sphere_polygon(
    shading_pos: vec3<f32>,
    sphere_center: vec3<f32>,
    sphere_radius: f32,
    vertices: ptr<function, array<vec3<f32>, 32>>,
) -> u32 {
    let to_sphere = sphere_center - shading_pos;
    let distance = length(to_sphere);

    // Check if shading point is inside sphere
    if distance < sphere_radius {
        return 0u;
    }

    let dir = to_sphere / distance;

    // Tangent point on sphere surface
    let sin_theta = sphere_radius / distance;
    let cos_theta = sqrt(1.0 - sin_theta * sin_theta);
    let tangent_distance = distance * cos_theta;
    let disc_center = shading_pos + dir * tangent_distance;

    // Radius of the visible disc
    let disc_radius = sphere_radius * cos_theta;

    // Build orthonormal basis for disc
    var up = vec3<f32>(0.0, 1.0, 0.0);
    if abs(dot(dir, up)) > 0.999 {
        up = vec3<f32>(1.0, 0.0, 0.0);
    }
    let right = normalize(cross(up, dir));
    let actual_up = cross(dir, right);

    // Generate polygon vertices
    for (var i: u32 = 0u; i < SPHERE_VERTICES; i = i + 1u) {
        let angle = f32(i) * TWO_PI / f32(SPHERE_VERTICES);
        let local_pos = cos(angle) * right + sin(angle) * actual_up;
        (*vertices)[i] = disc_center + local_pos * disc_radius;
    }

    return SPHERE_VERTICES;
}

// ============================================================================
// LTC Area Light Evaluation
// ============================================================================

/// Evaluate sphere area light using LTC
///
/// Returns RGB color contribution (specular + diffuse components).
fn evaluate_sphere_light_ltc(
    world_pos: vec3<f32>,
    N: vec3<f32>,
    V: vec3<f32>,
    albedo: vec3<f32>,
    roughness: f32,
    metallic: f32,
    light_position: vec3<f32>,
    light_radius: f32,
    light_color: vec3<f32>,
    light_intensity: f32,
) -> vec3<f32> {
    // View-dependent parameters
    let n_dot_v = max(dot(N, V), 0.0001);

    // Sample LTC matrices and Fresnel terms
    let Minv = sample_ltc_matrix(n_dot_v, roughness);
    let fresnel = sample_ltc_fresnel(n_dot_v, roughness);

    // Build tangent frame with N as up
    var T1: vec3<f32>;
    if abs(N.y) < 0.999 {
        T1 = normalize(cross(N, vec3<f32>(0.0, 1.0, 0.0)));
    } else {
        T1 = normalize(cross(N, vec3<f32>(1.0, 0.0, 0.0)));
    }
    let T2 = cross(N, T1);

    // Tangent-to-world rotation
    let T2W = mat3x3<f32>(T1, T2, N);

    // Generate sphere polygon
    var world_vertices: array<vec3<f32>, 32>;
    let vertex_count = generate_sphere_polygon(world_pos, light_position, light_radius, &world_vertices);

    if vertex_count == 0u {
        return vec3<f32>(0.0);
    }

    // Transform vertices to local tangent space
    var local_vertices: array<vec3<f32>, 32>;
    for (var i: u32 = 0u; i < vertex_count; i = i + 1u) {
        let dir = world_vertices[i] - world_pos;
        local_vertices[i] = transpose(T2W) * dir;
    }

    // -------------------------
    // Specular Contribution
    // -------------------------

    // Apply inverse LTC matrix and project to unit sphere
    var spec_vertices: array<vec3<f32>, 32>;
    for (var i: u32 = 0u; i < vertex_count; i = i + 1u) {
        spec_vertices[i] = normalize(Minv * local_vertices[i]);
    }

    // Clip to horizon and integrate
    var spec_clipped: array<vec3<f32>, 32>;
    let spec_count = clip_polygon_to_horizon(&spec_vertices, vertex_count, &spec_clipped);
    let spec_integral = integrate_polygon(&spec_clipped, spec_count);

    // Apply Fresnel using precomputed magnitude/bias
    let F0 = mix(vec3<f32>(0.04), albedo, metallic);
    let specular_factor = fresnel.x * F0 + fresnel.y * (vec3<f32>(1.0) - F0);
    let specular = specular_factor * spec_integral;

    // -------------------------
    // Diffuse Contribution
    // -------------------------

    // Identity matrix for diffuse (no transformation)
    var diff_vertices: array<vec3<f32>, 32>;
    for (var i: u32 = 0u; i < vertex_count; i = i + 1u) {
        diff_vertices[i] = normalize(local_vertices[i]);
    }

    var diff_clipped: array<vec3<f32>, 32>;
    let diff_count = clip_polygon_to_horizon(&diff_vertices, vertex_count, &diff_clipped);
    let diff_integral = integrate_polygon(&diff_clipped, diff_count);

    // Diffuse color (non-metallic portion)
    let diffuse_color = albedo * (1.0 - metallic);
    let diffuse = diffuse_color * diff_integral / PI;

    // -------------------------
    // Final Combination
    // -------------------------

    return (specular + diffuse) * light_color * light_intensity;
}

// ============================================================================
// Main Fragment Shader
// ============================================================================

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    let x = f32(vertex_index & 1u) * 4.0 - 1.0;
    let y = f32((vertex_index >> 1u) & 1u) * 4.0 - 1.0;
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    out.uv = vec2<f32>((x + 1.0) * 0.5, (1.0 - y) * 0.5);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Sample G-Buffer
    let albedo_metal = textureSample(gbuffer_albedo, gbuffer_sampler, in.uv);
    let normal_rough = textureSample(gbuffer_normal, gbuffer_sampler, in.uv);
    let depth = textureSample(gbuffer_depth, gbuffer_sampler, in.uv);

    // Skip sky pixels
    if depth >= 1.0 {
        return vec4<f32>(0.0);
    }

    // Unpack G-Buffer
    let albedo = albedo_metal.rgb;
    let metallic = albedo_metal.a;
    let N = normalize(normal_rough.rgb * 2.0 - 1.0);
    let roughness = max(normal_rough.a, 0.04);

    // Reconstruct world position
    let ndc = vec2<f32>(in.uv.x * 2.0 - 1.0, (1.0 - in.uv.y) * 2.0 - 1.0);
    let clip_pos = vec4<f32>(ndc, depth, 1.0);
    let view_pos = scene.inverse_projection * clip_pos;
    let world_pos_h = scene.inverse_view * (view_pos / view_pos.w);
    let world_pos = world_pos_h.xyz;

    // View direction
    let V = normalize(scene.camera_position.xyz - world_pos);

    // Example: single sphere area light
    // In practice, you'd loop over multiple lights from a buffer
    let light_position = vec3<f32>(0.0, 3.0, 0.0);
    let light_radius = 0.5;
    let light_color = vec3<f32>(1.0, 0.95, 0.9);
    let light_intensity = 10.0;

    let result = evaluate_sphere_light_ltc(
        world_pos,
        N,
        V,
        albedo,
        roughness,
        metallic,
        light_position,
        light_radius,
        light_color,
        light_intensity,
    );

    return vec4<f32>(result, 1.0);
}
