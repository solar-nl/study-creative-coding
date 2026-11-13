#!/usr/bin/env python3
"""
Export reproduction data as per-scene files ordered by timeline.

Creates a directory structure:
  output/
    _index.json          # Timeline order and scene list
    _texgen/             # Shared texture generation graphs
      colors-gradients.json
      zebra.json
      ...
    _materials.json      # Material technique definitions
    scenes/
      001_intro-cassette.json
      002_blob.json
      003_zebra-heights.json
      ...
"""

import xml.etree.ElementTree as ET
import base64
import struct
import json
import re
import argparse
from pathlib import Path
from collections import OrderedDict
from typing import Any

# Import filter schemas from the main export script
import sys
sys.path.insert(0, str(Path(__file__).parent))
from export_reproduction_data import (
    FILTER_SCHEMAS, DEFAULT_SCHEMA, decode_param, decode_resolution,
    decode_material_value, ParamType, TEXTURE_SLOT_NAMES
)


def slugify(name: str) -> str:
    """Convert a name to a filesystem-safe slug."""
    # Remove special characters, replace spaces with hyphens
    slug = re.sub(r'[^\w\s-]', '', name.lower())
    slug = re.sub(r'[-\s]+', '-', slug).strip('-')
    return slug


class SceneExporter:
    """Export reproduction data as per-scene files."""

    def __init__(self, apx_path: str):
        self.apx_path = Path(apx_path)
        self.tree = ET.parse(apx_path)
        self.root = self.tree.getroot()

        # Lookup tables
        self.filter_names: dict[str, str] = {}
        self.texture_outputs: dict[str, dict] = {}
        self.technique_params: dict[str, dict] = {}
        self.materials: dict[str, str] = {}
        self.model_scenes: dict[str, str] = {}  # model_guid -> scene_name
        self.scene_names: dict[str, str] = {}  # scene_guid -> scene_name

        # Extracted data
        self.timeline_scenes: list[dict] = []
        self.texgen_pages: dict[str, dict] = {}
        self.mesh_materials: dict[str, list] = {}  # scene_name -> [meshes]
        self.used_textures: set[str] = set()

    def export_all(self, output_dir: Path):
        """Run full extraction and write to directory."""
        output_dir.mkdir(parents=True, exist_ok=True)

        # Extract data
        self._extract_filters()
        self._extract_texgen_pages()
        self._extract_technique_params()
        self._extract_materials()
        self._extract_scene_names()  # Must come before timeline
        self._extract_timeline()
        self._extract_mesh_materials()

        # Write output files
        self._write_index(output_dir)
        self._write_texgen(output_dir)
        self._write_materials(output_dir)
        self._write_scenes(output_dir)

        return {
            "scenes": len(self.timeline_scenes),
            "texgen_pages": len(self.used_textures),
            "total_meshes": sum(len(m) for m in self.mesh_materials.values()),
        }

    def _extract_filters(self):
        """Extract filter GUID -> name mapping."""
        for filt in self.root.iter('texturefilter'):
            guid_el = filt.find('GUID')
            name_el = filt.find('Name')
            if guid_el is not None and name_el is not None:
                self.filter_names[guid_el.text] = name_el.text

    def _extract_texgen_pages(self):
        """Extract texgen pages with operators and connectivity."""
        for page in self.root.iter('texturepage'):
            name_el = page.find('Name')
            xres_el = page.find('xres')
            yres_el = page.find('yres')
            hdr_el = page.find('hdr')

            if name_el is None:
                continue

            page_name = name_el.text
            page_data = {
                "resolution": {
                    "width": 1 << int(xres_el.text) if xres_el is not None else 256,
                    "height": 1 << int(yres_el.text) if yres_el is not None else 256,
                },
                "hdr": hdr_el is not None and hdr_el.text == "1",
                "operators": [],
                "outputs": {},
            }

            # Extract operators
            operator_list = []
            positions = []

            for op in page.iter('Operator'):
                op_data = self._parse_operator(op)
                if op_data:
                    positions.append({
                        "x1": op_data.pop("_x1"),
                        "y1": op_data.pop("_y1"),
                        "x2": op_data.pop("_x2"),
                        "y2": op_data.pop("_y2"),
                    })
                    operator_list.append(op_data)

            # Resolve connectivity
            for i, op in enumerate(operator_list):
                inputs = []
                x1, y1, x2 = positions[i]["x1"], positions[i]["y1"], positions[i]["x2"]

                for j, pos in enumerate(positions):
                    if j != i and pos["y2"] == y1:
                        if pos["x1"] < x2 and pos["x2"] > x1:
                            inputs.append(j)

                inputs.sort(key=lambda idx: positions[idx]["x1"])
                op["inputs"] = inputs

            page_data["operators"] = operator_list

            # Extract Save outputs
            for save in page.iter('Save'):
                guid_el = save.find('GUID')
                save_name_el = save.find('Name')
                source_el = save.find('Source')

                if guid_el is None:
                    continue

                save_name = save_name_el.text if save_name_el is not None else "output"
                source_idx = int(source_el.text) if source_el is not None else len(operator_list) - 1

                output_key = f"{page_name}/{save_name}"
                page_data["outputs"][save_name] = source_idx

                self.texture_outputs[guid_el.text] = {
                    "page": page_name,
                    "output": save_name,
                    "key": output_key,
                }

            self.texgen_pages[page_name] = page_data

    def _parse_operator(self, op_el) -> dict | None:
        """Parse an operator element."""
        guid_el = op_el.find('GUID')
        filter_el = op_el.find('Filter')
        res_el = op_el.find('Resolution')
        seed_el = op_el.find('Seed')
        x1_el = op_el.find('x1')
        y1_el = op_el.find('y1')
        x2_el = op_el.find('x2')
        y2_el = op_el.find('y2')

        if guid_el is None:
            return None

        filter_guid = filter_el.text if filter_el is not None else ""
        filter_name = self.filter_names.get(filter_guid, "Unknown")

        res_byte = int(res_el.text) if res_el is not None else 0x88
        width, height = decode_resolution(res_byte)

        # Get raw parameters
        raw_params = {}
        for param in op_el.iter('Parameter'):
            param_id = param.get('ID')
            if param_id is not None:
                raw_params[int(param_id)] = int(param.text) if param.text else 0

        # Decode parameters
        schema = FILTER_SCHEMAS.get(filter_name, DEFAULT_SCHEMA)
        decoded_params = {}

        for idx, (name, ptype, *rest) in schema.get("params", {}).items():
            raw_val = raw_params.get(idx, 0)
            enum_map = rest[0] if rest and isinstance(rest[0], dict) else None
            decoded_params[name] = decode_param(raw_val, ptype, enum_map)

        return {
            "filter": filter_name,
            "resolution": [width, height],
            "seed": int(seed_el.text) if seed_el is not None else 0,
            "params": decoded_params,
            "_x1": int(x1_el.text) if x1_el is not None else 0,
            "_y1": int(y1_el.text) if y1_el is not None else 0,
            "_x2": int(x2_el.text) if x2_el is not None else 0,
            "_y2": int(y2_el.text) if y2_el is not None else 0,
        }

    def _extract_technique_params(self):
        """Extract material technique parameter definitions."""
        for tech in self.root.iter('rendertechnique'):
            for param in tech.iter('Parameter'):
                guid_el = param.find('GUID')
                name_el = param.find('Name')
                type_el = param.find('Type')
                default_el = param.find('DefaultValue')

                if guid_el is None:
                    continue

                param_type = int(type_el.text) if type_el is not None else 0
                default_val = None
                if default_el is not None and default_el.text:
                    default_val = decode_material_value(default_el.text, param_type)

                self.technique_params[guid_el.text] = {
                    "name": name_el.text if name_el is not None else "Unknown",
                    "type": param_type,
                    "default": default_val,
                }

    def _extract_materials(self):
        """Extract material definitions."""
        for mat in self.root.iter('material'):
            guid_el = mat.find('GUID')
            name_el = mat.find('Name')
            if guid_el is not None and name_el is not None:
                self.materials[guid_el.text] = name_el.text

    def _extract_scene_names(self):
        """Extract scene GUID -> name mapping."""
        for scene in self.root.iter('scene'):
            guid_el = scene.find('GUID')
            name_el = scene.find('Name')
            if guid_el is not None and name_el is not None:
                self.scene_names[guid_el.text] = name_el.text

    def _extract_timeline(self):
        """Extract timeline scenes in order."""
        seen_scenes = set()

        for event in self.root.iter('event'):
            # Scene is a GUID reference, not a name
            scene_guid_el = event.find('scene')
            start_el = event.find('StartFrame')
            event_type_el = event.find('Type')

            if scene_guid_el is None or not scene_guid_el.text:
                continue

            # Resolve scene name from GUID
            scene_guid = scene_guid_el.text
            scene_name = self.scene_names.get(scene_guid, "")

            if not scene_name:
                continue

            # Skip internal scenes
            if scene_name.startswith('---') and scene_name.endswith('---'):
                continue

            # Parse scene name (format: "++scene / blob")
            if '/' in scene_name:
                parts = scene_name.split('/')
                clean_name = parts[-1].strip()
            else:
                clean_name = scene_name.strip()

            if clean_name in seen_scenes:
                continue

            seen_scenes.add(clean_name)
            start_frame = int(start_el.text) if start_el is not None else 0

            self.timeline_scenes.append({
                "name": clean_name,
                "start_frame": start_frame,
                "raw_name": scene_name,
            })

        # Sort by start frame
        self.timeline_scenes.sort(key=lambda x: x["start_frame"])

    def _extract_mesh_materials(self):
        """Extract per-mesh material instances grouped by scene."""
        for model in self.root.iter('model'):
            model_name = ""
            name_el = model.find('Name')
            if name_el is not None:
                model_name = name_el.text

            # Determine scene from model name
            parts = model_name.split('/') if model_name else []
            if len(parts) >= 2 and parts[0] == 'scenes':
                scene_key = parts[1].lower()
            else:
                scene_key = parts[0].lower() if parts else "unknown"

            for obj in model.iter('Object'):
                obj_name_el = obj.find('Name')
                mat_el = obj.find('Material')

                if mat_el is None:
                    continue

                mat_guid = mat_el.get('GUID', '')
                if not mat_guid or mat_guid == 'DEFAULTMATERIAL!DEFAULTMATERIAL!':
                    continue

                mesh_name = obj_name_el.text if obj_name_el is not None else "Unknown"
                mat_name = self.materials.get(mat_guid, "Unknown")

                # Collect parameters
                params = {}
                textures = {}

                for param_data in obj.iter('materialparamdata'):
                    param_id = param_data.get('paramid', '')
                    value_b64 = param_data.get('valuebase64', '')

                    param_def = self.technique_params.get(param_id, {})
                    param_name = param_def.get("name", "unknown")
                    param_type = param_def.get("type", 0)

                    decoded = decode_material_value(value_b64, param_type)
                    if decoded is not None:
                        params[param_name] = decoded

                for tex_data in obj.iter('materialtexturedata'):
                    param_id = tex_data.get('paramid', '')
                    tex_id = tex_data.get('textureid', '')

                    if tex_id == 'NONENONENONENONENONENONENONENONE':
                        continue

                    param_def = self.technique_params.get(param_id, {})
                    param_type = param_def.get("type", 0)
                    slot = TEXTURE_SLOT_NAMES.get(param_type, f"slot_{param_type}")

                    tex_info = self.texture_outputs.get(tex_id, {})
                    tex_key = tex_info.get("key", tex_id)

                    textures[slot] = tex_key

                    # Track used textures
                    if tex_info.get("page"):
                        self.used_textures.add(tex_info["page"])

                if params or textures:
                    if scene_key not in self.mesh_materials:
                        self.mesh_materials[scene_key] = []

                    self.mesh_materials[scene_key].append({
                        "mesh": mesh_name,
                        "model": model_name,
                        "material": mat_name,
                        "params": params,
                        "textures": textures,
                    })

    def _write_index(self, output_dir: Path):
        """Write timeline index file."""
        index = {
            "title": "Clean Slate",
            "scene_count": len(self.timeline_scenes),
            "timeline": []
        }

        for i, scene in enumerate(self.timeline_scenes):
            slug = slugify(scene["name"])
            index["timeline"].append({
                "order": i + 1,
                "name": scene["name"],
                "file": f"scenes/{i+1:03d}_{slug}.json",
                "start_frame": scene["start_frame"],
            })

        with open(output_dir / "_index.json", 'w') as f:
            json.dump(index, f, indent=2)

    def _write_texgen(self, output_dir: Path):
        """Write texgen files (only used textures)."""
        texgen_dir = output_dir / "_texgen"
        texgen_dir.mkdir(exist_ok=True)

        for page_name in sorted(self.used_textures):
            if page_name not in self.texgen_pages:
                continue

            page_data = self.texgen_pages[page_name]
            slug = slugify(page_name)

            with open(texgen_dir / f"{slug}.json", 'w') as f:
                json.dump({
                    "name": page_name,
                    **page_data
                }, f, indent=2)

    def _write_materials(self, output_dir: Path):
        """Write materials reference file."""
        # Collect unique materials used
        used_materials = set()
        for meshes in self.mesh_materials.values():
            for mesh in meshes:
                used_materials.add(mesh["material"])

        materials_data = {
            "materials": sorted(used_materials)
        }

        with open(output_dir / "_materials.json", 'w') as f:
            json.dump(materials_data, f, indent=2)

    def _write_scenes(self, output_dir: Path):
        """Write per-scene files."""
        scenes_dir = output_dir / "scenes"
        scenes_dir.mkdir(exist_ok=True)

        for i, scene in enumerate(self.timeline_scenes):
            scene_name = scene["name"]
            scene_key = scene_name.lower()
            slug = slugify(scene_name)

            # Find matching meshes (fuzzy match on scene name)
            meshes = []
            for key, mesh_list in self.mesh_materials.items():
                # Match if key contains scene name or vice versa
                if scene_key in key or key in scene_key:
                    meshes.extend(mesh_list)
                # Also match partial (e.g., "blob" matches "blob1")
                elif any(scene_key.startswith(key) or key.startswith(scene_key)
                        for _ in [1]):
                    meshes.extend(mesh_list)

            # Collect textures used by this scene
            scene_textures = set()
            for mesh in meshes:
                for tex in mesh.get("textures", {}).values():
                    if "/" in tex:
                        page = tex.split("/")[0]
                        scene_textures.add(page)

            scene_data = {
                "name": scene_name,
                "order": i + 1,
                "start_frame": scene["start_frame"],
                "textures_used": sorted(scene_textures),
                "objects": meshes,
            }

            filename = f"{i+1:03d}_{slug}.json"
            with open(scenes_dir / filename, 'w') as f:
                json.dump(scene_data, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description='Export scene-based reproduction data')
    parser.add_argument('input', help='Path to .apx file')
    parser.add_argument('-o', '--output', help='Output directory', default='reproduction')
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = input_path.parent / args.output

    print(f"Extracting scenes from: {input_path}")
    print(f"Output directory: {output_dir}")

    exporter = SceneExporter(str(input_path))
    stats = exporter.export_all(output_dir)

    print(f"\nExported:")
    print(f"  {stats['scenes']} scenes (timeline order)")
    print(f"  {stats['texgen_pages']} texgen pages (used only)")
    print(f"  {stats['total_meshes']} mesh materials")
    print(f"\nFiles written to: {output_dir}/")


if __name__ == '__main__':
    main()
