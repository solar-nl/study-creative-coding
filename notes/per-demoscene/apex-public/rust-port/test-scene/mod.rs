//! Test Scene Module
//!
//! Provides geometry, materials, and scene configurations for testing the PBR pipeline.
//!
//! # Quick Start
//!
//! ```rust,ignore
//! use test_scene::{geometry, scene};
//!
//! // Generate test geometry
//! let sphere = geometry::generate_sphere();
//! let plane = geometry::generate_ground_plane();
//!
//! // Load a test scene
//! let scene = scene::TestScene::material_test_grid();
//!
//! // Access scene components
//! let camera = &scene.camera;
//! let lights = &scene.lights;
//! let objects = &scene.objects;
//! ```
//!
//! # Available Test Scenes
//!
//! - [`TestScene::minimal()`] - Single sphere + one light, for initial debugging
//! - [`TestScene::material_test_grid()`] - 5×5 spheres with varying roughness/metallic
//! - [`TestScene::shadow_test()`] - Scene with occluders for shadow testing
//! - [`TestScene::area_light_test()`] - Scene for LTC area light validation
//!
//! # Usage Notes
//!
//! 1. The geometry module generates CPU-side mesh data. Upload to GPU using:
//!    ```rust,ignore
//!    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
//!        label: Some("Vertex Buffer"),
//!        contents: mesh.vertex_bytes(),
//!        usage: wgpu::BufferUsages::VERTEX,
//!    });
//!    ```
//!
//! 2. Material properties from `scene.objects[i].material` should be uploaded
//!    to the ObjectUniforms buffer.
//!
//! 3. See [expected-output.md](expected-output.md) for what each milestone should look like.

pub mod geometry;
pub mod scene;

pub use geometry::{Mesh, Vertex};
pub use scene::{Camera, Light, LightType, Material, SceneObject, TestScene, Transform};
