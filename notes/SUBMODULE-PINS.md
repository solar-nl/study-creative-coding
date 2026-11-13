# Submodule Pins: Studied-At Snapshots

Notes cite `file:line` locations inside submodules. Each section below records the commits as they were *before* an update, so a reference written before that date resolves against that snapshot: `git -C <path> checkout <commit>`. Newest snapshot first. `scripts/update_submodules.sh` (or `/update-submodules`) prepends a new section on every run.

## Snapshot 2026-10-26 (harfang3d added)

The new submodule only; all other pins are unchanged from the 2026-10-25 snapshot below. Upstream has had no commits since this one, so `frameworks/harfang3d` is on the frozen list in `scripts/update_submodules.sh`.

| Path | Commit | Commit date | Branch / tag |
|------|--------|-------------|--------------|
| `frameworks/harfang3d` | `abc8fc5de961` | 2023-08-16 | main (v3.2.7+2; of its eleven nested submodules only `extern/bgfx/{bgfx,bx,bimg}` were initialized, bgfx at `3d4bd88c0635`; all nested pins listed in `notes/per-framework/harfang3d/README.md`) |

## Snapshot 2026-10-25 (open formats survey)

The checkouts `research/open-formats/framework-support-matrix.md` cites. These are the states after the 2026-10-15 update, which the 2026-10-15 "before update" snapshot does not record. Rows unchanged from the 2026-10-21 and 2026-10-15 snapshots (apex-public, fr_public, ltc_code, controlp5, toxiclibs, rend3, vello, mixbox, VL.StandardLibs, openrndr, processing) are omitted.

| Path | Commit | Commit date | Branch / tag |
|------|--------|-------------|--------------|
| `examples/webgpu-samples` | `e040ec1a20db` | 2026-09-22 | main |
| `frameworks/cinder` | `f90f332d1a4d` | 2026-03-20 | master |
| `frameworks/drawbot` | `71cff6df68ff` | 2026-05-20 | master (3.132+39) |
| `frameworks/nannou` | `bffa9887b185` | 2026-07-16 | master (v0.20.0+5) |
| `frameworks/openframeworks` | `f9e8d959fc80` | 2026-10-13 | master (0.12.0+523) |
| `frameworks/p5js` | `6fb945f72b77` | 2026-08-17 | v1 (v1.11.14-rc.2+6) |
| `libraries/cpp/filament` | `97d16d9f1270` | 2026-10-15 | main (rc/1.78.1-cut+15) |
| `libraries/openrndr-ecosystem/orx` | `3d3ada30bae4` | 2026-10-15 | master (v0.5.1-SNAPSHOT.2+29) |
| `libraries/rust/wgpu` | `14328f49918c` | 2026-10-14 | trunk (v30.0.0+619) |
| `libraries/web/babylonjs` | `39d7f0e152e4` | 2026-10-15 | master (9.30.0+22) |
| `libraries/web/pixijs` | `65552017d232` | 2026-10-10 | main (v8.22.0+8) |
| `libraries/web/threejs` | `628bf37748e4` | 2026-10-15 | dev (r184+1164) |
| `references/the-gray-book` | `dc7784dadabb` | 2026-10-15 | main |
| `visual-programming/cables` | `f294f9e6ee21` | 2026-10-15 | develop (v0.6.0+2181) |
| `visual-programming/cables_ui` | `9b7881da206c` | 2026-10-15 | develop (v0.6.0+1361) |
| `visual-programming/tixl` | `10d2d7ea3480` | 2026-10-13 | main (v4.3.0.2+77) |

## Snapshot 2026-10-21 (vello, VL.StandardLibs added; openrndr and processing studied)

The two new submodules, plus the checkouts the 2026-10-21 openrndr and Processing rendering notes cite (both newer than the 2026-10-15 snapshot, which was taken before that day's update). All other pins are unchanged from the 2026-10-15 snapshot below.

| Path | Commit | Commit date | Branch / tag |
|------|--------|-------------|--------------|
| `libraries/rust/vello` | `65338c258f09` | 2026-10-21 | main (vello_gpu 0.3.0, compute vello 0.11.0) |
| `libraries/vvvv-ecosystem/VL.StandardLibs` | `41aa0e507705` | 2026-10-21 | main (nested ImGui.NET-nativebuild submodule not initialized) |
| `frameworks/openrndr` | `00c47af75ddc` | 2026-10-11 | master (rendering-pipeline.md, code-traces/contour-to-pixels.md) |
| `frameworks/processing` | `be0ee8266e07` | 2026-09-25 | main (rendering-pipeline.md, code-traces/shape-to-pixels.md) |

## Snapshot 2026-10-15 (before update)

| Path | Commit | Commit date | Branch / tag |
|------|--------|-------------|--------------|
| `demoscene/apex-public` | `fff9223ff225` | 2023-11-18 | tags/apEx.424 |
| `demoscene/fr_public` | `8c8f82c2ae01` | 2017-04-09 | master |
| `examples/webgpu-samples` | `d97946e9e76b` | 2025-12-27 | main |
| `frameworks/cinder` | `a5bbe9e3d2e9` | 2025-12-26 | master |
| `frameworks/drawbot` | `da3746c950ee` | 2025-12-17 | master |
| `frameworks/nannou` | `b670e7a385d6` | 2025-06-21 | master |
| `frameworks/openframeworks` | `3f457231d4ef` | 2025-11-18 | master |
| `frameworks/openrndr` | `7b47ecc4f3d7` | 2026-01-04 | master |
| `frameworks/p5js` | `98c2345b510c` | 2026-01-04 | main |
| `frameworks/processing` | `edaf153ba445` | 2025-12-23 | main |
| `libraries/cpp/filament` | `1cd48619e382` | 2026-02-13 | main |
| `libraries/ltc_code` | `31e5e96b54f9` | 2019-04-14 | master |
| `libraries/openrndr-ecosystem/orx` | `8aadbc84df18` | 2026-01-04 | master |
| `libraries/processing-ecosystem/controlp5` | `1f7cb649865e` | 2016-04-14 | tags/v2.2.6 |
| `libraries/processing-ecosystem/toxiclibs` | `6896bc17e853` | 2014-12-01 | tags/0021 |
| `libraries/rend3` | `d088a841b046` | 2024-05-03 | trunk |
| `libraries/rust/wgpu` | `aba9161b72c0` | 2025-12-30 | trunk |
| `libraries/universal/mixbox` | `a1bdb75a668f` | 2022-12-16 | master |
| `libraries/web/babylonjs` | `dba916029426` | 2026-01-10 | master |
| `libraries/web/pixijs` | `d7e9a5d440fc` | 2026-01-05 | tags/v8.15.0 |
| `libraries/web/threejs` | `7cd43e066a72` | 2026-01-05 | dev |
| `references/the-gray-book` | `c0f945be35aa` | 2026-01-08 | master |
| `visual-programming/cables` | `4efd01cc3b03` | 2026-01-02 | develop |
| `visual-programming/cables_ui` | `48a89302f159` | 2026-01-09 | develop |
| `visual-programming/tixl` | `97f8456727e3` | 2026-01-05 | main |
