//! Procedural Geometry Generation
//!
//! Generates test meshes for verifying the PBR pipeline.
//! All geometry includes positions, normals, and UVs suitable for PBR rendering.

use bytemuck::{Pod, Zeroable};
use std::f32::consts::PI;

// ============================================================================
// Vertex Format
// ============================================================================

/// Vertex format matching the pipeline's expected layout.
///
/// Must match the WGSL struct in gbuffer.wgsl:
/// ```wgsl
/// struct VertexInput {
///     @location(0) position: vec3<f32>,
///     @location(1) normal: vec3<f32>,
///     @location(2) uv: vec2<f32>,
///     @location(3) color: vec4<f32>,
/// }
/// ```
#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct Vertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
    pub color: [f32; 4],
}

impl Vertex {
    pub fn new(position: [f32; 3], normal: [f32; 3], uv: [f32; 2]) -> Self {
        Self {
            position,
            normal,
            uv,
            color: [1.0, 1.0, 1.0, 1.0],
        }
    }

    pub fn with_color(mut self, color: [f32; 4]) -> Self {
        self.color = color;
        self
    }
}

/// A mesh ready for GPU upload.
#[derive(Debug)]
pub struct Mesh {
    pub vertices: Vec<Vertex>,
    pub indices: Vec<u32>,
}

impl Mesh {
    /// Calculate vertex buffer size in bytes.
    pub fn vertex_buffer_size(&self) -> u64 {
        (self.vertices.len() * std::mem::size_of::<Vertex>()) as u64
    }

    /// Calculate index buffer size in bytes.
    pub fn index_buffer_size(&self) -> u64 {
        (self.indices.len() * std::mem::size_of::<u32>()) as u64
    }

    /// Get vertex data as bytes for upload.
    pub fn vertex_bytes(&self) -> &[u8] {
        bytemuck::cast_slice(&self.vertices)
    }

    /// Get index data as bytes for upload.
    pub fn index_bytes(&self) -> &[u8] {
        bytemuck::cast_slice(&self.indices)
    }
}

// ============================================================================
// UV Sphere
// ============================================================================

/// Generate a UV sphere with the given resolution.
///
/// # Arguments
/// * `radius` - Sphere radius
/// * `sectors` - Horizontal divisions (longitude)
/// * `stacks` - Vertical divisions (latitude)
///
/// # Returns
/// A mesh with proper normals and UVs for PBR rendering.
pub fn generate_uv_sphere(radius: f32, sectors: u32, stacks: u32) -> Mesh {
    let mut vertices = Vec::new();
    let mut indices = Vec::new();

    let sector_step = 2.0 * PI / sectors as f32;
    let stack_step = PI / stacks as f32;

    // Generate vertices
    for i in 0..=stacks {
        let stack_angle = PI / 2.0 - i as f32 * stack_step; // From +PI/2 to -PI/2
        let xy = radius * stack_angle.cos();
        let z = radius * stack_angle.sin();

        for j in 0..=sectors {
            let sector_angle = j as f32 * sector_step;

            // Position
            let x = xy * sector_angle.cos();
            let y = xy * sector_angle.sin();

            // Normal (normalized position for unit sphere)
            let nx = x / radius;
            let ny = y / radius;
            let nz = z / radius;

            // UV
            let u = j as f32 / sectors as f32;
            let v = i as f32 / stacks as f32;

            vertices.push(Vertex::new([x, z, y], [nx, nz, ny], [u, v]));
        }
    }

    // Generate indices
    for i in 0..stacks {
        let k1 = i * (sectors + 1);
        let k2 = k1 + sectors + 1;

        for j in 0..sectors {
            let k1j = k1 + j;
            let k2j = k2 + j;

            // Two triangles per quad (except at poles)
            if i != 0 {
                indices.push(k1j);
                indices.push(k2j);
                indices.push(k1j + 1);
            }

            if i != stacks - 1 {
                indices.push(k1j + 1);
                indices.push(k2j);
                indices.push(k2j + 1);
            }
        }
    }

    Mesh { vertices, indices }
}

/// Generate a standard test sphere (radius 1, 32x16 resolution).
pub fn generate_sphere() -> Mesh {
    generate_uv_sphere(1.0, 32, 16)
}

/// Generate a high-quality sphere for smooth specular highlights.
pub fn generate_sphere_hq() -> Mesh {
    generate_uv_sphere(1.0, 64, 32)
}

// ============================================================================
// Cube
// ============================================================================

/// Generate a cube with proper face normals and UVs.
///
/// Each face has its own vertices (no shared vertices) so normals are correct.
pub fn generate_cube(size: f32) -> Mesh {
    let s = size / 2.0;

    // Define the 6 faces with their vertices
    // Each face: 4 vertices with position, normal, uv
    let faces: [([[f32; 3]; 4], [f32; 3]); 6] = [
        // Front face (+Z)
        (
            [[-s, -s, s], [s, -s, s], [s, s, s], [-s, s, s]],
            [0.0, 0.0, 1.0],
        ),
        // Back face (-Z)
        (
            [[s, -s, -s], [-s, -s, -s], [-s, s, -s], [s, s, -s]],
            [0.0, 0.0, -1.0],
        ),
        // Top face (+Y)
        (
            [[-s, s, s], [s, s, s], [s, s, -s], [-s, s, -s]],
            [0.0, 1.0, 0.0],
        ),
        // Bottom face (-Y)
        (
            [[-s, -s, -s], [s, -s, -s], [s, -s, s], [-s, -s, s]],
            [0.0, -1.0, 0.0],
        ),
        // Right face (+X)
        (
            [[s, -s, s], [s, -s, -s], [s, s, -s], [s, s, s]],
            [1.0, 0.0, 0.0],
        ),
        // Left face (-X)
        (
            [[-s, -s, -s], [-s, -s, s], [-s, s, s], [-s, s, -s]],
            [-1.0, 0.0, 0.0],
        ),
    ];

    let uvs: [[f32; 2]; 4] = [[0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]];

    let mut vertices = Vec::with_capacity(24);
    let mut indices = Vec::with_capacity(36);

    for (face_idx, (positions, normal)) in faces.iter().enumerate() {
        let base = (face_idx * 4) as u32;

        for (i, pos) in positions.iter().enumerate() {
            vertices.push(Vertex::new(*pos, *normal, uvs[i]));
        }

        // Two triangles per face
        indices.extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }

    Mesh { vertices, indices }
}

/// Generate a unit cube (size 1).
pub fn generate_unit_cube() -> Mesh {
    generate_cube(1.0)
}

// ============================================================================
// Plane
// ============================================================================

/// Generate a horizontal plane (Y-up).
///
/// # Arguments
/// * `width` - Size along X axis
/// * `depth` - Size along Z axis
/// * `subdivisions` - Number of subdivisions (1 = single quad)
pub fn generate_plane(width: f32, depth: f32, subdivisions: u32) -> Mesh {
    let mut vertices = Vec::new();
    let mut indices = Vec::new();

    let half_w = width / 2.0;
    let half_d = depth / 2.0;
    let step_x = width / subdivisions as f32;
    let step_z = depth / subdivisions as f32;

    // Generate vertices
    for z in 0..=subdivisions {
        for x in 0..=subdivisions {
            let px = -half_w + x as f32 * step_x;
            let pz = -half_d + z as f32 * step_z;

            let u = x as f32 / subdivisions as f32;
            let v = z as f32 / subdivisions as f32;

            vertices.push(Vertex::new(
                [px, 0.0, pz],
                [0.0, 1.0, 0.0], // Normal pointing up
                [u, v],
            ));
        }
    }

    // Generate indices
    let row_size = subdivisions + 1;
    for z in 0..subdivisions {
        for x in 0..subdivisions {
            let bl = z * row_size + x;
            let br = bl + 1;
            let tl = bl + row_size;
            let tr = tl + 1;

            // Two triangles per quad
            indices.push(bl);
            indices.push(tl);
            indices.push(br);

            indices.push(br);
            indices.push(tl);
            indices.push(tr);
        }
    }

    Mesh { vertices, indices }
}

/// Generate a unit plane (10x10, 1 subdivision).
pub fn generate_unit_plane() -> Mesh {
    generate_plane(10.0, 10.0, 1)
}

/// Generate a ground plane with subdivisions for better lighting.
pub fn generate_ground_plane() -> Mesh {
    generate_plane(20.0, 20.0, 10)
}

// ============================================================================
// Material Test Grid
// ============================================================================

/// Generate a grid of spheres for testing material properties.
///
/// Creates an NxN grid of spheres, useful for visualizing roughness/metallic
/// combinations.
///
/// # Arguments
/// * `rows` - Number of rows
/// * `cols` - Number of columns
/// * `spacing` - Distance between sphere centers
/// * `radius` - Sphere radius
///
/// # Returns
/// A vector of (mesh, grid_x, grid_y) tuples for material assignment.
pub fn generate_material_test_grid(
    rows: u32,
    cols: u32,
    spacing: f32,
    radius: f32,
) -> Vec<(Mesh, u32, u32)> {
    let mut result = Vec::new();
    let sphere_template = generate_uv_sphere(radius, 32, 16);

    let offset_x = (cols - 1) as f32 * spacing / 2.0;
    let offset_z = (rows - 1) as f32 * spacing / 2.0;

    for row in 0..rows {
        for col in 0..cols {
            let x = col as f32 * spacing - offset_x;
            let z = row as f32 * spacing - offset_z;

            // Clone and translate the sphere
            let mut mesh = Mesh {
                vertices: sphere_template.vertices.clone(),
                indices: sphere_template.indices.clone(),
            };

            for vertex in &mut mesh.vertices {
                vertex.position[0] += x;
                vertex.position[2] += z;
            }

            result.push((mesh, col, row));
        }
    }

    result
}

/// Generate a 5x5 material test grid with standard spacing.
///
/// Intended use:
/// - X axis: roughness 0.1 to 0.9
/// - Y axis: metallic 0.0 to 1.0
pub fn generate_standard_material_grid() -> Vec<(Mesh, u32, u32)> {
    generate_material_test_grid(5, 5, 2.5, 1.0)
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Merge multiple meshes into a single mesh.
///
/// Useful for batching static geometry.
pub fn merge_meshes(meshes: &[&Mesh]) -> Mesh {
    let total_vertices: usize = meshes.iter().map(|m| m.vertices.len()).sum();
    let total_indices: usize = meshes.iter().map(|m| m.indices.len()).sum();

    let mut vertices = Vec::with_capacity(total_vertices);
    let mut indices = Vec::with_capacity(total_indices);

    let mut vertex_offset = 0u32;

    for mesh in meshes {
        vertices.extend_from_slice(&mesh.vertices);

        for &index in &mesh.indices {
            indices.push(index + vertex_offset);
        }

        vertex_offset += mesh.vertices.len() as u32;
    }

    Mesh { vertices, indices }
}

/// Transform a mesh by a 4x4 matrix.
///
/// Transforms positions and normals (using inverse-transpose for normals).
pub fn transform_mesh(mesh: &mut Mesh, transform: [[f32; 4]; 4]) {
    // Extract 3x3 rotation/scale for normals
    let normal_matrix = [
        [transform[0][0], transform[0][1], transform[0][2]],
        [transform[1][0], transform[1][1], transform[1][2]],
        [transform[2][0], transform[2][1], transform[2][2]],
    ];

    for vertex in &mut mesh.vertices {
        // Transform position
        let p = vertex.position;
        vertex.position = [
            transform[0][0] * p[0] + transform[1][0] * p[1] + transform[2][0] * p[2] + transform[3][0],
            transform[0][1] * p[0] + transform[1][1] * p[1] + transform[2][1] * p[2] + transform[3][1],
            transform[0][2] * p[0] + transform[1][2] * p[1] + transform[2][2] * p[2] + transform[3][2],
        ];

        // Transform normal (should use inverse-transpose, simplified here)
        let n = vertex.normal;
        let transformed_n = [
            normal_matrix[0][0] * n[0] + normal_matrix[1][0] * n[1] + normal_matrix[2][0] * n[2],
            normal_matrix[0][1] * n[0] + normal_matrix[1][1] * n[1] + normal_matrix[2][1] * n[2],
            normal_matrix[0][2] * n[0] + normal_matrix[1][2] * n[1] + normal_matrix[2][2] * n[2],
        ];

        // Normalize
        let len = (transformed_n[0].powi(2) + transformed_n[1].powi(2) + transformed_n[2].powi(2)).sqrt();
        if len > 0.0001 {
            vertex.normal = [
                transformed_n[0] / len,
                transformed_n[1] / len,
                transformed_n[2] / len,
            ];
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sphere_generation() {
        let sphere = generate_sphere();
        assert!(!sphere.vertices.is_empty());
        assert!(!sphere.indices.is_empty());
        assert_eq!(sphere.indices.len() % 3, 0); // Triangles
    }

    #[test]
    fn test_cube_generation() {
        let cube = generate_unit_cube();
        assert_eq!(cube.vertices.len(), 24); // 6 faces × 4 vertices
        assert_eq!(cube.indices.len(), 36);  // 6 faces × 2 triangles × 3 indices
    }

    #[test]
    fn test_plane_generation() {
        let plane = generate_unit_plane();
        assert_eq!(plane.vertices.len(), 4);  // Single quad
        assert_eq!(plane.indices.len(), 6);   // 2 triangles
    }

    #[test]
    fn test_vertex_layout() {
        // Verify vertex struct has expected size
        assert_eq!(std::mem::size_of::<Vertex>(), 48); // 12 + 12 + 8 + 16 = 48 bytes
    }

    #[test]
    fn test_material_grid() {
        let grid = generate_standard_material_grid();
        assert_eq!(grid.len(), 25); // 5×5
    }
}
