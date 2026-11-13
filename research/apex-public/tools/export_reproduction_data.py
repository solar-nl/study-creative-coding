#!/usr/bin/env python3
"""
Export reproduction-ready data from apEx .apx project files.

Creates a comprehensive export containing:
1. Texgen graphs with semantic parameters and explicit connectivity
2. Material instances with merged technique defaults + per-object overrides
3. Mesh-to-material-to-texture bindings

Output format is designed for easy reproduction in another engine.
"""

import xml.etree.ElementTree as ET
import base64
import struct
import json
import argparse
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Optional, Any
from enum import IntEnum


# =============================================================================
# TEXGEN FILTER PARAMETER SCHEMAS
# =============================================================================

# Parameter schemas define how to interpret the 16 raw bytes for each filter type
# Based on analysis of HLSL shaders in notes/per-demoscene/apex-public/texgen/

FILTER_SCHEMAS = {
    # === GENERATORS (no inputs) ===
    "Noise": {
        "params": {
            0: ("octaves", "int", "Number of noise octaves"),
            1: ("persistence", "norm", "Amplitude falloff per octave"),
            2: ("frequency", "norm", "Base frequency multiplier"),
            3: ("mode", "enum", {0: "smoothstep", 1: "linear"}),
        },
        "inputs": 0,
    },
    "Gradient": {
        "params": {
            0: ("type", "enum", {
                0: "radial", 1: "diamond", 2: "horizontal", 3: "vertical",
                4: "horizontal_mirror", 5: "vertical_mirror"
            }),
        },
        "inputs": 0,
    },
    "Solid Color": {
        "params": {
            0: ("r", "norm", "Red"),
            1: ("g", "norm", "Green"),
            2: ("b", "norm", "Blue"),
            3: ("a", "norm", "Alpha"),
        },
        "inputs": 0,
    },
    "Envmap": {
        "params": {
            0: ("outer_radius", "norm", "Outer radius"),
            1: ("inner_radius", "norm", "Inner radius"),
            2: ("scale_x", "norm", "X scale"),
            3: ("scale_y", "norm", "Y scale"),
        },
        "inputs": 0,
    },
    "SubPlasma": {
        "params": {
            0: ("density", "norm", "Density (octaves)"),
            1: ("linear", "bool", "Use linear interpolation"),
        },
        "inputs": 0,
    },
    "Tiles": {
        "params": {
            0: ("count_x", "norm", "Horizontal tile count (x255)"),
            1: ("count_y", "norm", "Vertical tile count (x255)"),
            2: ("offset", "norm", "Row offset"),
            3: ("border", "norm", "Border width"),
        },
        "inputs": 0,
    },
    "Rectangle": {
        "params": {
            0: ("center_x", "norm", "Center X"),
            1: ("center_y", "norm", "Center Y"),
            2: ("width", "norm", "Width"),
            3: ("height", "norm", "Height"),
            4: ("softness", "norm", "Edge softness"),
            5: ("rotation", "angle", "Rotation angle"),
        },
        "inputs": 0,
    },
    "Cells": {
        "params": {
            0: ("iterations", "int", "Voronoi iterations"),
            1: ("power", "norm", "Distance power"),
            2: ("size", "norm", "Cell size"),
            3: ("manhattan", "bool", "Use Manhattan distance"),
        },
        "inputs": 0,
    },
    "Text": {
        "params": {},
        "inputs": 0,
    },

    # === COLOR OPERATIONS (1 input) ===
    "Colorize": {
        "params": {
            0: ("color1_r", "byte", "Color 1 red"),
            1: ("color1_g", "byte", "Color 1 green"),
            2: ("color1_b", "byte", "Color 1 blue"),
            3: ("color1_a", "byte", "Color 1 alpha"),
            4: ("color2_r", "byte", "Color 2 red"),
            5: ("color2_g", "byte", "Color 2 green"),
            6: ("color2_b", "byte", "Color 2 blue"),
            7: ("color2_a", "byte", "Color 2 alpha"),
            8: ("channel", "enum", {0: "R", 1: "G", 2: "B", 3: "A"}),
        },
        "inputs": 1,
    },
    "Scale": {
        "params": {
            0: ("min_r", "norm", "Minimum red"),
            1: ("min_g", "norm", "Minimum green"),
            2: ("min_b", "norm", "Minimum blue"),
            3: ("min_a", "norm", "Minimum alpha"),
            4: ("max_r", "norm", "Maximum red"),
            5: ("max_g", "norm", "Maximum green"),
            6: ("max_b", "norm", "Maximum blue"),
            7: ("max_a", "norm", "Maximum alpha"),
        },
        "inputs": 1,
    },
    "Contrast": {
        "params": {
            0: ("contrast", "norm", "Contrast (0.5 = neutral)"),
            1: ("brightness", "norm", "Brightness (0.5 = neutral)"),
        },
        "inputs": 1,
    },
    "HSL": {
        "params": {
            0: ("hue", "norm", "Hue shift"),
            1: ("saturation", "norm", "Saturation multiplier"),
            2: ("lightness", "norm", "Lightness (0.5 = neutral)"),
        },
        "inputs": 1,
    },
    "Invert": {
        "params": {},
        "inputs": 1,
    },
    "Curves": {
        "params": {},  # Uses lookup texture, no direct params
        "inputs": 1,
    },
    "Palette": {
        "params": {
            0: ("offset", "norm", "Palette offset"),
            1: ("scale", "norm", "Palette scale"),
        },
        "inputs": 1,
    },

    # === TRANSFORMS (1 input) ===
    "Rotozoom": {
        "params": {
            0: ("angle", "angle", "Rotation angle"),
            1: ("zoom", "norm", "Zoom factor (inverse)"),
            2: ("center_x", "norm", "Center X"),
            3: ("center_y", "norm", "Center Y"),
        },
        "inputs": 1,
    },
    "Translate": {
        "params": {
            0: ("rotate45", "bool", "Rotate 45 degrees"),
            1: ("offset_x", "norm", "X offset"),
            2: ("offset_y", "norm", "Y offset"),
        },
        "inputs": 1,
    },
    "Mirror": {
        "params": {
            0: ("axis", "enum", {0: "horizontal", 1: "vertical"}),
        },
        "inputs": 1,
    },
    "Loop": {
        "params": {
            0: ("tile_x", "int", "Horizontal tiles"),
            1: ("tile_y", "int", "Vertical tiles"),
        },
        "inputs": 1,
    },
    "Pixelize": {
        "params": {
            0: ("count_x", "norm", "Horizontal pixel count (x255)"),
            1: ("count_y", "norm", "Vertical pixel count (x255)"),
        },
        "inputs": 1,
    },
    "To Polar": {
        "params": {
            0: ("center_x", "norm", "Center X"),
            1: ("center_y", "norm", "Center Y"),
        },
        "inputs": 1,
    },

    # === FILTERS (1 input) ===
    "Blur": {
        "params": {
            0: ("radius_x", "norm", "Horizontal radius"),
            1: ("radius_y", "norm", "Vertical radius"),
        },
        "inputs": 1,
    },
    "Normalmap": {
        "params": {
            0: ("mode", "enum", {0: "sobel", 1: "scharr"}),
            1: ("strength", "norm", "Normal strength"),
        },
        "inputs": 1,
    },

    # === BLEND/COMBINE (2 inputs) ===
    "Combine": {
        "params": {
            0: ("mode", "enum", {
                0: "add", 1: "sub", 2: "mul", 3: "max", 4: "min",
                5: "overlay", 6: "screen", 7: "darken", 8: "lighten"
            }),
        },
        "inputs": 2,
    },
    "Mix": {
        "params": {
            0: ("amount", "norm", "Mix amount (0=first, 1=second)"),
        },
        "inputs": 2,
    },
    "MixMap": {
        "params": {
            0: ("channel", "enum", {0: "R", 1: "G", 2: "B", 3: "A"}),
        },
        "inputs": 3,  # texture1, texture2, mix_map
    },
    "Replace Alpha": {
        "params": {},
        "inputs": 2,
    },

    # === DISTORTION (2 inputs: texture + displacement map) ===
    "DirBlur": {
        "params": {
            0: ("channel", "enum", {0: "R", 1: "G", 2: "B", 3: "A"}),
            1: ("amount", "norm", "Blur amount"),
        },
        "inputs": 2,
    },
    "Turbulence": {
        "params": {
            0: ("channel", "enum", {0: "R", 1: "G", 2: "B", 3: "A"}),
            1: ("amount", "norm", "Distortion amount"),
        },
        "inputs": 2,
    },
    "Mapdistort": {
        "params": {
            0: ("channel", "enum", {0: "R", 1: "G", 2: "B", 3: "A"}),
            1: ("amount_x", "norm", "X distortion"),
            2: ("amount_y", "norm", "Y distortion"),
        },
        "inputs": 2,
    },

    # === SPECIAL ===
    "Sprinkle": {
        "params": {
            0: ("quantity", "norm", "Number of sprites (x255)"),
            1: ("min_size", "norm", "Minimum size"),
            2: ("max_size", "norm", "Maximum size"),
        },
        "inputs": 1,
    },
}

# Default schema for unknown filters - treat all as normalized floats
DEFAULT_SCHEMA = {
    "params": {i: (f"param_{i}", "norm", "") for i in range(16)},
    "inputs": 1,
}


def decode_param(value: int, param_type: str, enum_map: dict = None) -> Any:
    """Decode a raw parameter byte based on its type."""
    if param_type == "byte":
        return value
    elif param_type == "int":
        return value
    elif param_type == "norm":
        return round(value / 255.0, 4)
    elif param_type == "angle":
        return round(value / 255.0 * 360.0, 2)
    elif param_type == "bool":
        return value != 0
    elif param_type == "enum":
        return enum_map.get(value, f"unknown({value})")
    return value


def decode_resolution(res_byte: int) -> tuple[int, int]:
    """Decode packed resolution byte to (width, height)."""
    x_exp = (res_byte >> 4) & 0x0F
    y_exp = res_byte & 0x0F
    return (1 << x_exp, 1 << y_exp)


# =============================================================================
# MATERIAL PARAMETER TYPES
# =============================================================================

class ParamType(IntEnum):
    FLOAT = 0
    COLOR = 1
    ZMODE = 2
    ZFUNCTION = 3
    FILLMODE = 4
    CULLMODE = 5
    RENDERPRIORITY = 6
    TEXTURE0 = 7
    TEXTURE1 = 8
    TEXTURE2 = 9
    TEXTURE3 = 10
    TEXTURE4 = 11
    TEXTURE5 = 12
    TEXTURE6 = 13
    TEXTURE7 = 14
    BLENDMODE0 = 15


TEXTURE_SLOT_NAMES = {
    ParamType.TEXTURE0: "albedo_metalness",
    ParamType.TEXTURE1: "normal_roughness",
    ParamType.TEXTURE2: "emissive_alpha",
    ParamType.TEXTURE3: "texture3",
    ParamType.TEXTURE4: "texture4",
    ParamType.TEXTURE5: "texture5",
    ParamType.TEXTURE6: "texture6",
    ParamType.TEXTURE7: "texture7",
}


def decode_material_value(base64_str: str, param_type: int) -> Any:
    """Decode base64 material value to semantic representation."""
    if not base64_str:
        return None
    try:
        data = base64.b64decode(base64_str)
    except Exception:
        return None

    if len(data) < 4:
        return None

    if param_type == ParamType.FLOAT:
        return round(struct.unpack('<f', data[:4])[0], 6)
    elif param_type == ParamType.COLOR:
        if len(data) >= 16:
            r, g, b, a = struct.unpack('<ffff', data[:16])
            return {"r": round(r, 4), "g": round(g, 4), "b": round(b, 4), "a": round(a, 4)}
    elif param_type == ParamType.CULLMODE:
        val = struct.unpack('<I', data[:4])[0]
        return {1: "none", 2: "front", 3: "back"}.get(val, f"unknown({val})")
    elif param_type == ParamType.ZMODE:
        val = struct.unpack('<I', data[:4])[0]
        return {0: "disabled", 1: "test_only", 2: "test_and_write"}.get(val, f"unknown({val})")
    elif param_type == ParamType.ZFUNCTION:
        val = struct.unpack('<I', data[:4])[0]
        return {0: "less_equal", 1: "never", 2: "less", 3: "equal",
                4: "greater", 5: "not_equal", 6: "greater_equal", 7: "always"}.get(val, f"unknown({val})")
    elif param_type == ParamType.RENDERPRIORITY:
        return struct.unpack('<i', data[:4])[0]
    elif ParamType.BLENDMODE0 <= param_type <= ParamType.BLENDMODE0 + 7:
        val = data[0]
        if val == 0x01:
            return "opaque"
        elif val == 0x54:
            return "alpha_blend"
        elif val == 0x11:
            return "additive"
        return f"blend(src={val & 0x0F}, dst={(val >> 4) & 0x0F})"
    return struct.unpack('<I', data[:4])[0]


# =============================================================================
# MAIN EXTRACTOR
# =============================================================================

class ReproductionDataExtractor:
    """Extract reproduction-ready data from apEx project."""

    def __init__(self, apx_path: str):
        self.apx_path = Path(apx_path)
        self.tree = ET.parse(apx_path)
        self.root = self.tree.getroot()

        # Lookup tables
        self.filter_names: dict[str, str] = {}  # filter_guid -> name
        self.texture_outputs: dict[str, dict] = {}  # output_guid -> {page, name, graph}
        self.technique_params: dict[str, dict] = {}  # param_guid -> {name, type, default}
        self.materials: dict[str, str] = {}  # material_guid -> name
        self.render_targets: dict[str, str] = {}  # rt_guid -> name

        # Output data
        self.texgen_pages: dict[str, dict] = {}
        self.mesh_materials: list[dict] = []

    def extract_all(self) -> dict:
        """Run full extraction and return reproduction data."""
        self._extract_filters()
        self._extract_render_targets()
        self._extract_texgen_pages()
        self._extract_technique_params()
        self._extract_materials()
        self._extract_mesh_materials()

        return {
            "source": str(self.apx_path),
            "texgen": self.texgen_pages,
            "meshes": self.mesh_materials,
            "stats": {
                "texgen_pages": len(self.texgen_pages),
                "texture_outputs": len(self.texture_outputs),
                "meshes_with_materials": len(self.mesh_materials),
            }
        }

    def _extract_filters(self):
        """Extract filter GUID -> name mapping from texturefilter elements."""
        for filt in self.root.iter('texturefilter'):
            guid_el = filt.find('GUID')
            name_el = filt.find('Name')
            if guid_el is not None and name_el is not None:
                self.filter_names[guid_el.text] = name_el.text

    def _extract_render_targets(self):
        """Extract render target definitions."""
        for rt in self.root.iter('rendertarget'):
            guid_el = rt.find('GUID')
            name_el = rt.find('Name')
            if guid_el is not None and name_el is not None:
                self.render_targets[guid_el.text] = name_el.text

    def _extract_texgen_pages(self):
        """Extract texgen pages with operators, connectivity, and outputs."""
        for page in self.root.iter('texturepage'):
            name_el = page.find('Name')
            xres_el = page.find('xres')
            yres_el = page.find('yres')
            hdr_el = page.find('hdr')

            if name_el is None:
                continue

            page_name = name_el.text
            page_data = {
                "name": page_name,
                "resolution": {
                    "x_exp": int(xres_el.text) if xres_el is not None else 8,
                    "y_exp": int(yres_el.text) if yres_el is not None else 8,
                },
                "hdr": hdr_el is not None and hdr_el.text == "1",
                "operators": [],
                "outputs": {},  # save_name -> operator_index
            }

            # Extract operators with positions
            operator_list = []
            positions = []  # Store positions separately for connectivity resolution

            for op in page.iter('Operator'):
                op_data = self._parse_operator(op)
                if op_data:
                    # Store position data separately
                    positions.append({
                        "x1": op_data["x1"],
                        "y1": op_data["y1"],
                        "x2": op_data["x2"],
                        "y2": op_data["y2"],
                    })
                    operator_list.append(op_data)

            # Resolve connectivity based on positions
            # In apEx, an operator takes inputs from operators in the row directly above
            # where X ranges overlap. Input's y2 must equal this operator's y1.
            for i, op in enumerate(operator_list):
                inputs = []
                x1, y1, x2, y2 = positions[i]["x1"], positions[i]["y1"], positions[i]["x2"], positions[i]["y2"]

                # Find all operators whose output row (y2) matches our input row (y1)
                # and whose X range overlaps with ours
                for j, pos in enumerate(positions):
                    if j == i:
                        continue
                    pi_x1, pi_y1, pi_x2, pi_y2 = pos["x1"], pos["y1"], pos["x2"], pos["y2"]
                    # Check if this operator's output row matches our input row
                    if pi_y2 == y1:
                        # Check if X ranges overlap
                        if pi_x1 < x2 and pi_x2 > x1:
                            inputs.append(j)

                # Sort inputs by x position (left to right) for consistent ordering
                inputs.sort(key=lambda idx: positions[idx]["x1"])

                op["inputs"] = inputs
                # Remove position data from final output (it was only for connectivity)
                del op["x1"]
                del op["y1"]
                del op["x2"]
                del op["y2"]

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

                # Register for material lookups
                self.texture_outputs[guid_el.text] = {
                    "page": page_name,
                    "output": save_name,
                    "key": output_key,
                }

            self.texgen_pages[page_name] = page_data

    def _parse_operator(self, op_el) -> Optional[dict]:
        """Parse an operator element with semantic parameters."""
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

        # Get filter name
        filter_guid = filter_el.text if filter_el is not None else ""
        filter_name = self.filter_names.get(filter_guid, "Unknown")

        # Decode resolution
        res_byte = int(res_el.text) if res_el is not None else 0x88
        width, height = decode_resolution(res_byte)

        # Get raw parameters
        raw_params = {}
        for param in op_el.iter('Parameter'):
            param_id = param.get('ID')
            if param_id is not None:
                raw_params[int(param_id)] = int(param.text) if param.text else 0

        # Decode parameters semantically
        schema = FILTER_SCHEMAS.get(filter_name, DEFAULT_SCHEMA)
        decoded_params = {}

        for idx, (name, ptype, *rest) in schema.get("params", {}).items():
            raw_val = raw_params.get(idx, 0)
            enum_map = rest[0] if rest and isinstance(rest[0], dict) else None
            decoded_params[name] = decode_param(raw_val, ptype, enum_map)

        # Build operator data
        op_data = {
            "filter": filter_name,
            "resolution": {"width": width, "height": height},
            "seed": int(seed_el.text) if seed_el is not None else 0,
            "params": decoded_params,
            # Keep positions temporarily for connectivity resolution
            "x1": int(x1_el.text) if x1_el is not None else 0,
            "y1": int(y1_el.text) if y1_el is not None else 0,
            "x2": int(x2_el.text) if x2_el is not None else 0,
            "y2": int(y2_el.text) if y2_el is not None else 0,
        }

        return op_data

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

    def _extract_mesh_materials(self):
        """Extract per-mesh material instances with merged parameters."""
        for model in self.root.iter('model'):
            model_name = ""
            name_el = model.find('Name')
            if name_el is not None:
                model_name = name_el.text

            for obj in model.iter('Object'):
                obj_name_el = obj.find('Name')
                mat_el = obj.find('Material')

                if mat_el is None:
                    continue

                mat_guid = mat_el.get('GUID', '')
                if not mat_guid or mat_guid == 'DEFAULTMATERIAL!DEFAULTMATERIAL!':
                    continue

                mesh_name = f"{model_name}/{obj_name_el.text}" if obj_name_el is not None else model_name
                mat_name = self.materials.get(mat_guid, "Unknown")

                # Collect parameter overrides
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

                    # Get slot name
                    slot = TEXTURE_SLOT_NAMES.get(param_type, f"slot_{param_type}")

                    # Resolve texture
                    tex_info = self.texture_outputs.get(tex_id, {})
                    tex_key = tex_info.get("key", tex_id)

                    textures[slot] = tex_key

                if params or textures:
                    self.mesh_materials.append({
                        "mesh": mesh_name,
                        "material": mat_name,
                        "params": params,
                        "textures": textures,
                    })


def main():
    parser = argparse.ArgumentParser(description='Export reproduction-ready data from apEx .apx files')
    parser.add_argument('input', help='Path to .apx file')
    parser.add_argument('-o', '--output', help='Output JSON path')
    args = parser.parse_args()

    input_path = Path(args.input)
    if args.output:
        output_path = Path(args.output)
    else:
        output_path = input_path.parent / f"{input_path.stem}_reproduction.json"

    print(f"Extracting reproduction data from: {input_path}")

    extractor = ReproductionDataExtractor(str(input_path))
    data = extractor.extract_all()

    print(f"Found {data['stats']['texgen_pages']} texgen pages")
    print(f"Found {data['stats']['texture_outputs']} texture outputs")
    print(f"Found {data['stats']['meshes_with_materials']} meshes with materials")

    with open(output_path, 'w') as f:
        json.dump(data, f, indent=2)

    print(f"Saved to: {output_path}")


if __name__ == '__main__':
    main()
