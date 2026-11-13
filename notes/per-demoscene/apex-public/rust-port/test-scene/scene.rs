//! Test Scene Configuration
//!
//! Defines cameras, lights, materials, and scene objects for testing the PBR pipeline.

use bytemuck::{Pod, Zeroable};

// ============================================================================
// Transform
// ============================================================================

/// 3D transform with position, rotation (Euler), and scale.
#[derive(Debug, Clone, Copy)]
pub struct Transform {
    pub position: [f32; 3],
    pub rotation: [f32; 3],  // Euler angles in radians (pitch, yaw, roll)
    pub scale: [f32; 3],
}

impl Default for Transform {
    fn default() -> Self {
        Self {
            position: [0.0, 0.0, 0.0],
            rotation: [0.0, 0.0, 0.0],
            scale: [1.0, 1.0, 1.0],
        }
    }
}

impl Transform {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_position(mut self, x: f32, y: f32, z: f32) -> Self {
        self.position = [x, y, z];
        self
    }

    pub fn with_rotation(mut self, pitch: f32, yaw: f32, roll: f32) -> Self {
        self.rotation = [pitch, yaw, roll];
        self
    }

    pub fn with_scale(mut self, x: f32, y: f32, z: f32) -> Self {
        self.scale = [x, y, z];
        self
    }

    pub fn with_uniform_scale(mut self, s: f32) -> Self {
        self.scale = [s, s, s];
        self
    }

    /// Convert to a 4x4 matrix (column-major for WGSL).
    /// Order: Scale → Rotate → Translate
    pub fn to_matrix(&self) -> [[f32; 4]; 4] {
        let (sx, sy, sz) = (self.scale[0], self.scale[1], self.scale[2]);
        let (px, py, pz) = (self.rotation[0], self.rotation[1], self.rotation[2]);

        // Rotation matrices
        let (sin_x, cos_x) = px.sin_cos();
        let (sin_y, cos_y) = py.sin_cos();
        let (sin_z, cos_z) = pz.sin_cos();

        // Combined rotation (ZYX order)
        let r00 = cos_y * cos_z;
        let r01 = cos_y * sin_z;
        let r02 = -sin_y;

        let r10 = sin_x * sin_y * cos_z - cos_x * sin_z;
        let r11 = sin_x * sin_y * sin_z + cos_x * cos_z;
        let r12 = sin_x * cos_y;

        let r20 = cos_x * sin_y * cos_z + sin_x * sin_z;
        let r21 = cos_x * sin_y * sin_z - sin_x * cos_z;
        let r22 = cos_x * cos_y;

        // Scale and translate
        [
            [r00 * sx, r01 * sx, r02 * sx, 0.0],
            [r10 * sy, r11 * sy, r12 * sy, 0.0],
            [r20 * sz, r21 * sz, r22 * sz, 0.0],
            [self.position[0], self.position[1], self.position[2], 1.0],
        ]
    }
}

// ============================================================================
// Camera
// ============================================================================

/// Camera configuration for the test scene.
#[derive(Debug, Clone, Copy)]
pub struct Camera {
    pub position: [f32; 3],
    pub target: [f32; 3],
    pub up: [f32; 3],
    pub fov_y: f32,        // Vertical FOV in radians
    pub near: f32,
    pub far: f32,
}

impl Default for Camera {
    fn default() -> Self {
        Self {
            position: [0.0, 5.0, 10.0],
            target: [0.0, 0.0, 0.0],
            up: [0.0, 1.0, 0.0],
            fov_y: std::f32::consts::FRAC_PI_4, // 45 degrees
            near: 0.1,
            far: 100.0,
        }
    }
}

impl Camera {
    /// Create a camera positioned to view the material test grid.
    pub fn for_material_grid() -> Self {
        Self {
            position: [0.0, 8.0, 12.0],
            target: [0.0, 0.0, 0.0],
            up: [0.0, 1.0, 0.0],
            fov_y: std::f32::consts::FRAC_PI_4,
            near: 0.1,
            far: 100.0,
        }
    }

    /// Create an orbital camera at given angle and distance.
    pub fn orbital(angle_y: f32, angle_x: f32, distance: f32, target: [f32; 3]) -> Self {
        let x = distance * angle_x.cos() * angle_y.sin();
        let y = distance * angle_x.sin();
        let z = distance * angle_x.cos() * angle_y.cos();

        Self {
            position: [target[0] + x, target[1] + y, target[2] + z],
            target,
            up: [0.0, 1.0, 0.0],
            fov_y: std::f32::consts::FRAC_PI_4,
            near: 0.1,
            far: 100.0,
        }
    }

    /// Compute view matrix (column-major).
    pub fn view_matrix(&self) -> [[f32; 4]; 4] {
        let f = normalize(sub(self.target, self.position));
        let r = normalize(cross(f, self.up));
        let u = cross(r, f);

        let tx = -dot(r, self.position);
        let ty = -dot(u, self.position);
        let tz = dot(f, self.position);

        [
            [r[0], u[0], -f[0], 0.0],
            [r[1], u[1], -f[1], 0.0],
            [r[2], u[2], -f[2], 0.0],
            [tx, ty, tz, 1.0],
        ]
    }

    /// Compute perspective projection matrix (column-major, right-handed, [0,1] depth).
    pub fn projection_matrix(&self, aspect: f32) -> [[f32; 4]; 4] {
        let f = 1.0 / (self.fov_y / 2.0).tan();
        let nf = 1.0 / (self.near - self.far);

        [
            [f / aspect, 0.0, 0.0, 0.0],
            [0.0, f, 0.0, 0.0],
            [0.0, 0.0, self.far * nf, -1.0],
            [0.0, 0.0, self.near * self.far * nf, 0.0],
        ]
    }
}

// ============================================================================
// Lights
// ============================================================================

/// Light types supported by the pipeline.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LightType {
    Point,
    Spot,
    Directional,
    AreaSphere,
}

/// Light configuration.
#[derive(Debug, Clone, Copy)]
pub struct Light {
    pub light_type: LightType,
    pub position: [f32; 3],
    pub direction: [f32; 3],      // For spot/directional
    pub color: [f32; 3],
    pub intensity: f32,
    pub radius: f32,              // Attenuation radius for point/spot, sphere radius for area
    pub inner_angle: f32,         // Spot inner cone (radians)
    pub outer_angle: f32,         // Spot outer cone (radians)
    pub casts_shadow: bool,
}

impl Light {
    /// Create a white point light.
    pub fn point(position: [f32; 3], intensity: f32, radius: f32) -> Self {
        Self {
            light_type: LightType::Point,
            position,
            direction: [0.0, -1.0, 0.0],
            color: [1.0, 1.0, 1.0],
            intensity,
            radius,
            inner_angle: 0.0,
            outer_angle: 0.0,
            casts_shadow: false,
        }
    }

    /// Create a directional light (like the sun).
    pub fn directional(direction: [f32; 3], color: [f32; 3], intensity: f32) -> Self {
        Self {
            light_type: LightType::Directional,
            position: [0.0, 0.0, 0.0],
            direction: normalize(direction),
            color,
            intensity,
            radius: 0.0,
            inner_angle: 0.0,
            outer_angle: 0.0,
            casts_shadow: true,
        }
    }

    /// Create a spot light.
    pub fn spot(
        position: [f32; 3],
        direction: [f32; 3],
        intensity: f32,
        radius: f32,
        inner_angle: f32,
        outer_angle: f32,
    ) -> Self {
        Self {
            light_type: LightType::Spot,
            position,
            direction: normalize(direction),
            color: [1.0, 1.0, 1.0],
            intensity,
            radius,
            inner_angle,
            outer_angle,
            casts_shadow: false,
        }
    }

    /// Create a sphere area light.
    pub fn area_sphere(position: [f32; 3], sphere_radius: f32, color: [f32; 3], intensity: f32) -> Self {
        Self {
            light_type: LightType::AreaSphere,
            position,
            direction: [0.0, -1.0, 0.0],
            color,
            intensity,
            radius: sphere_radius,
            inner_angle: 0.0,
            outer_angle: 0.0,
            casts_shadow: false,
        }
    }

    pub fn with_color(mut self, color: [f32; 3]) -> Self {
        self.color = color;
        self
    }

    pub fn with_shadow(mut self) -> Self {
        self.casts_shadow = true;
        self
    }

    /// Convert to LightData struct for GPU upload.
    /// Layout matches the 16-float LightData in data-structures.md
    pub fn to_gpu_data(&self) -> [f32; 16] {
        let type_id = match self.light_type {
            LightType::Point => 0.0,
            LightType::Spot => 1.0,
            LightType::Directional => 2.0,
            LightType::AreaSphere => 3.0,
        };

        [
            // vec4 position_type
            self.position[0], self.position[1], self.position[2], type_id,
            // vec4 direction_radius
            self.direction[0], self.direction[1], self.direction[2], self.radius,
            // vec4 color_intensity
            self.color[0], self.color[1], self.color[2], self.intensity,
            // vec4 params (inner_angle, outer_angle, shadow_index, padding)
            self.inner_angle, self.outer_angle, if self.casts_shadow { 0.0 } else { -1.0 }, 0.0,
        ]
    }
}

// ============================================================================
// Materials
// ============================================================================

/// PBR material definition.
#[derive(Debug, Clone, Copy)]
pub struct Material {
    pub albedo: [f32; 3],
    pub metallic: f32,
    pub roughness: f32,
    pub emissive: [f32; 3],
    pub emissive_intensity: f32,
}

impl Default for Material {
    fn default() -> Self {
        Self {
            albedo: [0.8, 0.8, 0.8],
            metallic: 0.0,
            roughness: 0.5,
            emissive: [0.0, 0.0, 0.0],
            emissive_intensity: 0.0,
        }
    }
}

impl Material {
    /// Create a dielectric (non-metal) material.
    pub fn dielectric(albedo: [f32; 3], roughness: f32) -> Self {
        Self {
            albedo,
            metallic: 0.0,
            roughness,
            emissive: [0.0, 0.0, 0.0],
            emissive_intensity: 0.0,
        }
    }

    /// Create a metallic material.
    pub fn metal(albedo: [f32; 3], roughness: f32) -> Self {
        Self {
            albedo,
            metallic: 1.0,
            roughness,
            emissive: [0.0, 0.0, 0.0],
            emissive_intensity: 0.0,
        }
    }

    /// Create an emissive material.
    pub fn emissive(color: [f32; 3], intensity: f32) -> Self {
        Self {
            albedo: color,
            metallic: 0.0,
            roughness: 1.0,
            emissive: color,
            emissive_intensity: intensity,
        }
    }

    /// Generate a material for the test grid based on grid position.
    /// X axis = roughness (0.1 to 0.9)
    /// Y axis = metallic (0.0 to 1.0)
    pub fn from_grid_position(x: u32, y: u32, grid_size: u32) -> Self {
        let roughness = 0.1 + (x as f32 / (grid_size - 1) as f32) * 0.8;
        let metallic = y as f32 / (grid_size - 1) as f32;

        Self {
            albedo: [0.9, 0.1, 0.1],  // Red for visibility
            metallic,
            roughness,
            emissive: [0.0, 0.0, 0.0],
            emissive_intensity: 0.0,
        }
    }

    /// Convert to GPU data (matches ObjectUniforms.material_params layout).
    pub fn to_gpu_params(&self) -> [f32; 4] {
        [self.metallic, self.roughness, self.emissive_intensity, 0.0]
    }
}

/// Common material presets.
pub mod materials {
    use super::Material;

    pub fn gold() -> Material {
        Material::metal([1.0, 0.765, 0.336], 0.3)
    }

    pub fn silver() -> Material {
        Material::metal([0.972, 0.960, 0.915], 0.2)
    }

    pub fn copper() -> Material {
        Material::metal([0.955, 0.637, 0.538], 0.4)
    }

    pub fn plastic_red() -> Material {
        Material::dielectric([0.9, 0.1, 0.1], 0.4)
    }

    pub fn plastic_white() -> Material {
        Material::dielectric([0.9, 0.9, 0.9], 0.5)
    }

    pub fn rubber() -> Material {
        Material::dielectric([0.1, 0.1, 0.1], 0.9)
    }

    pub fn ceramic() -> Material {
        Material::dielectric([0.95, 0.95, 0.95], 0.1)
    }
}

// ============================================================================
// Scene Object
// ============================================================================

/// A renderable object in the scene.
#[derive(Debug, Clone)]
pub struct SceneObject {
    pub name: String,
    pub mesh_index: usize,  // Index into scene's mesh array
    pub transform: Transform,
    pub material: Material,
}

// ============================================================================
// Test Scenes
// ============================================================================

/// Complete test scene configuration.
pub struct TestScene {
    pub camera: Camera,
    pub lights: Vec<Light>,
    pub objects: Vec<SceneObject>,
    pub ambient_color: [f32; 3],
    pub ambient_intensity: f32,
}

impl TestScene {
    /// Create the standard material test scene.
    ///
    /// 5×5 grid of spheres with varying roughness/metallic.
    /// One directional light + one point light for variety.
    pub fn material_test_grid() -> Self {
        let mut objects = Vec::new();

        // Create 5×5 sphere grid
        for y in 0..5u32 {
            for x in 0..5u32 {
                let px = (x as f32 - 2.0) * 2.5;
                let pz = (y as f32 - 2.0) * 2.5;

                objects.push(SceneObject {
                    name: format!("sphere_{}_{}", x, y),
                    mesh_index: 0, // Sphere mesh
                    transform: Transform::new().with_position(px, 0.0, pz),
                    material: Material::from_grid_position(x, y, 5),
                });
            }
        }

        // Ground plane
        objects.push(SceneObject {
            name: "ground".to_string(),
            mesh_index: 1, // Plane mesh
            transform: Transform::new().with_position(0.0, -1.5, 0.0),
            material: Material::dielectric([0.3, 0.3, 0.3], 0.8),
        });

        Self {
            camera: Camera::for_material_grid(),
            lights: vec![
                Light::directional([-0.5, -1.0, -0.3], [1.0, 0.98, 0.95], 3.0).with_shadow(),
                Light::point([5.0, 5.0, 5.0], 50.0, 15.0).with_color([1.0, 0.9, 0.8]),
            ],
            objects,
            ambient_color: [0.1, 0.12, 0.15],
            ambient_intensity: 0.3,
        }
    }

    /// Create a scene for testing shadow mapping.
    pub fn shadow_test() -> Self {
        let objects = vec![
            // Main sphere
            SceneObject {
                name: "sphere".to_string(),
                mesh_index: 0,
                transform: Transform::new().with_position(0.0, 1.0, 0.0),
                material: materials::plastic_white(),
            },
            // Smaller occluding sphere
            SceneObject {
                name: "occluder".to_string(),
                mesh_index: 0,
                transform: Transform::new()
                    .with_position(2.0, 3.0, 0.0)
                    .with_uniform_scale(0.5),
                material: materials::plastic_red(),
            },
            // Ground
            SceneObject {
                name: "ground".to_string(),
                mesh_index: 1,
                transform: Transform::new(),
                material: Material::dielectric([0.5, 0.5, 0.5], 0.7),
            },
        ];

        Self {
            camera: Camera::orbital(0.5, 0.4, 10.0, [0.0, 1.0, 0.0]),
            lights: vec![
                Light::directional([-1.0, -2.0, -1.0], [1.0, 1.0, 1.0], 5.0).with_shadow(),
            ],
            objects,
            ambient_color: [0.05, 0.05, 0.08],
            ambient_intensity: 0.2,
        }
    }

    /// Create a scene for testing area lights.
    pub fn area_light_test() -> Self {
        let objects = vec![
            // Center sphere
            SceneObject {
                name: "sphere".to_string(),
                mesh_index: 0,
                transform: Transform::new().with_position(0.0, 0.0, 0.0),
                material: materials::ceramic(),
            },
            // Metal sphere for reflection
            SceneObject {
                name: "metal_sphere".to_string(),
                mesh_index: 0,
                transform: Transform::new().with_position(3.0, 0.0, 0.0),
                material: materials::gold(),
            },
            // Ground
            SceneObject {
                name: "ground".to_string(),
                mesh_index: 1,
                transform: Transform::new().with_position(0.0, -1.5, 0.0),
                material: Material::dielectric([0.2, 0.2, 0.2], 0.5),
            },
        ];

        Self {
            camera: Camera::orbital(0.3, 0.3, 8.0, [0.0, 0.0, 0.0]),
            lights: vec![
                Light::area_sphere([0.0, 4.0, 0.0], 0.5, [1.0, 0.95, 0.9], 20.0),
                Light::area_sphere([-3.0, 2.0, 2.0], 0.3, [0.3, 0.5, 1.0], 15.0),
            ],
            objects,
            ambient_color: [0.02, 0.02, 0.03],
            ambient_intensity: 0.1,
        }
    }

    /// Create a minimal scene for initial debugging.
    pub fn minimal() -> Self {
        Self {
            camera: Camera::default(),
            lights: vec![
                Light::point([3.0, 5.0, 3.0], 30.0, 10.0),
            ],
            objects: vec![
                SceneObject {
                    name: "sphere".to_string(),
                    mesh_index: 0,
                    transform: Transform::new(),
                    material: Material::dielectric([1.0, 0.0, 0.0], 0.5),
                },
            ],
            ambient_color: [0.1, 0.1, 0.1],
            ambient_intensity: 0.5,
        }
    }
}

// ============================================================================
// Vector Math Helpers
// ============================================================================

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn normalize(v: [f32; 3]) -> [f32; 3] {
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    if len > 0.0001 {
        [v[0] / len, v[1] / len, v[2] / len]
    } else {
        [0.0, 0.0, 0.0]
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_material_grid_scene() {
        let scene = TestScene::material_test_grid();
        assert_eq!(scene.objects.len(), 26); // 25 spheres + 1 ground
        assert!(!scene.lights.is_empty());
    }

    #[test]
    fn test_camera_matrices() {
        let camera = Camera::default();
        let view = camera.view_matrix();
        let proj = camera.projection_matrix(1.0);

        // Basic sanity checks
        assert_eq!(view[3][3], 1.0);
        assert_eq!(proj[3][3], 0.0); // Perspective projection
    }

    #[test]
    fn test_light_gpu_data() {
        let light = Light::point([1.0, 2.0, 3.0], 10.0, 5.0);
        let data = light.to_gpu_data();
        assert_eq!(data.len(), 16);
        assert_eq!(data[0], 1.0); // position.x
        assert_eq!(data[3], 0.0); // type = point
    }
}
