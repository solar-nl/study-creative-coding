#!/usr/bin/env python3
"""
Extract material parameters from apEx .apx project files.

This script parses the XML structure to extract:
1. Render technique parameter definitions (GUID -> name, type, default)
2. Texture page definitions (GUID -> name)
3. Per-object material parameter overrides
4. Per-object texture bindings

All base64-encoded values are decoded to human-readable formats.
"""

import xml.etree.ElementTree as ET
import base64
import struct
import json
import argparse
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Optional
from enum import IntEnum


class ParamType(IntEnum):
    """Material parameter types from Material.h"""
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
    BLENDMODE1 = 16
    BLENDMODE2 = 17
    BLENDMODE3 = 18
    BLENDMODE4 = 19
    BLENDMODE5 = 20
    BLENDMODE6 = 21
    BLENDMODE7 = 22
    RENDERTARGET = 23


class ParamScope(IntEnum):
    """Parameter scope from Material.h"""
    CONSTANT = 0
    VARIABLE = 1
    ANIMATED = 2


# Texture slot names for readability
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


def decode_material_value(base64_str: str, param_type: int) -> dict:
    """
    Decode a base64-encoded MATERIALVALUE union.

    The MATERIALVALUE union is 16 bytes containing one of:
    - float (4 bytes, rest padding)
    - color[4] (16 bytes as 4 floats)
    - various integer/enum values
    """
    if not base64_str:
        return {"raw": None}

    try:
        data = base64.b64decode(base64_str)
    except Exception:
        return {"raw": base64_str, "error": "decode_failed"}

    if len(data) < 4:
        return {"raw": base64_str, "error": "too_short"}

    result = {"raw_hex": data.hex()}

    try:
        if param_type == ParamType.FLOAT:
            value = struct.unpack('<f', data[:4])[0]
            result["float"] = round(value, 6)

        elif param_type == ParamType.COLOR:
            if len(data) >= 16:
                r, g, b, a = struct.unpack('<ffff', data[:16])
                result["color"] = {
                    "r": round(r, 4),
                    "g": round(g, 4),
                    "b": round(b, 4),
                    "a": round(a, 4)
                }
                # Also provide 0-255 range
                result["color_255"] = {
                    "r": int(min(255, max(0, r * 255))),
                    "g": int(min(255, max(0, g * 255))),
                    "b": int(min(255, max(0, b * 255))),
                    "a": int(min(255, max(0, a * 255)))
                }
            else:
                result["error"] = "color_needs_16_bytes"

        elif param_type in (ParamType.ZMODE, ParamType.ZFUNCTION,
                           ParamType.FILLMODE, ParamType.CULLMODE):
            value = struct.unpack('<I', data[:4])[0]
            result["int"] = value
            # Add human-readable names
            if param_type == ParamType.CULLMODE:
                names = {1: "NONE", 2: "FRONT", 3: "BACK"}
                result["name"] = names.get(value, f"UNKNOWN({value})")
            elif param_type == ParamType.ZFUNCTION:
                names = {0: "LESS_EQUAL", 1: "NEVER", 2: "LESS", 3: "EQUAL",
                        4: "GREATER", 5: "NOT_EQUAL", 6: "GREATER_EQUAL", 7: "ALWAYS"}
                result["name"] = names.get(value, f"UNKNOWN({value})")
            elif param_type == ParamType.FILLMODE:
                result["name"] = "WIREFRAME" if value else "SOLID"
            elif param_type == ParamType.ZMODE:
                names = {0: "DISABLED", 1: "TEST_ONLY", 2: "TEST_AND_WRITE"}
                result["name"] = names.get(value, f"UNKNOWN({value})")

        elif param_type == ParamType.RENDERPRIORITY:
            value = struct.unpack('<i', data[:4])[0]
            result["priority"] = value

        elif ParamType.BLENDMODE0 <= param_type <= ParamType.BLENDMODE7:
            value = data[0] if len(data) > 0 else 0
            src = value & 0x0F
            dst = (value >> 4) & 0x0F
            src_names = ["ZERO", "ONE", "SRCCOLOR", "INVSRCCOLOR", "SRCALPHA",
                        "INVSRCALPHA", "DSTALPHA", "INVDSTALPHA"]
            dst_names = ["ZERO", "ONE", "SRCCOLOR", "INVSRCCOLOR", "SRCALPHA",
                        "INVSRCALPHA", "DSTALPHA", "INVDSTALPHA"]
            result["blend"] = {
                "byte": value,
                "src": src_names[src] if src < len(src_names) else f"UNKNOWN({src})",
                "dst": dst_names[dst] if dst < len(dst_names) else f"UNKNOWN({dst})"
            }
            # Common blend mode names
            if value == 0x01:
                result["blend"]["mode"] = "OPAQUE"
            elif value == 0x54:
                result["blend"]["mode"] = "ALPHA_BLEND"
            elif value == 0x11:
                result["blend"]["mode"] = "ADDITIVE"

        else:
            # Generic integer decode for unknown types
            if len(data) >= 4:
                result["int"] = struct.unpack('<I', data[:4])[0]

    except Exception as e:
        result["error"] = str(e)

    return result


@dataclass
class ParameterDef:
    """A parameter definition from a render technique"""
    guid: str
    name: str
    param_type: int
    param_type_name: str
    scope: int
    scope_name: str
    default_value: dict = field(default_factory=dict)
    value: dict = field(default_factory=dict)


@dataclass
class RenderTechnique:
    """A render technique (material shader) definition"""
    guid: str
    name: str
    tech_type: int
    target_layer: str
    parameters: list = field(default_factory=list)


@dataclass
class TexturePage:
    """A texture page (texgen output) definition"""
    guid: str
    name: str


@dataclass
class MaterialInstance:
    """A material instance on an object"""
    object_guid: str
    object_name: str
    material_guid: str
    material_name: str
    param_overrides: list = field(default_factory=list)
    texture_bindings: list = field(default_factory=list)


class ApxMaterialExtractor:
    """Extract material data from an apEx project file"""

    def __init__(self, apx_path: str):
        self.apx_path = Path(apx_path)
        self.tree = ET.parse(apx_path)
        self.root = self.tree.getroot()

        # Lookup tables
        self.techniques: dict[str, RenderTechnique] = {}
        self.texture_pages: dict[str, TexturePage] = {}
        self.materials: dict[str, str] = {}  # guid -> name
        self.param_defs: dict[str, ParameterDef] = {}  # guid -> def
        self.render_targets: dict[str, str] = {}  # guid -> name

        # Extracted data
        self.material_instances: list[MaterialInstance] = []

    def extract_all(self):
        """Run full extraction"""
        self._extract_render_targets()
        self._extract_texture_pages()
        self._extract_render_techniques()
        self._extract_materials()
        self._extract_material_instances()

    def _extract_render_targets(self):
        """Extract render target definitions"""
        for rt in self.root.iter('rendertarget'):
            guid_el = rt.find('GUID')
            name_el = rt.find('Name')
            if guid_el is not None and name_el is not None:
                self.render_targets[guid_el.text] = name_el.text

    def _extract_texture_pages(self):
        """Extract texture page (texgen) definitions.

        Texture pages don't have their own GUID. Material texture bindings
        reference either:
        1. <Save> elements - named texture outputs that can be referenced
        2. <Operator> elements - individual operators in the graph

        Save elements are the primary way textures are referenced in materials.
        """
        for page in self.root.iter('texturepage'):
            name_el = page.find('Name')
            if name_el is None:
                continue

            page_name = name_el.text

            # Map all Save GUIDs (named texture outputs) to the page name
            for save in page.iter('Save'):
                guid_el = save.find('GUID')
                save_name_el = save.find('Name')
                if guid_el is not None and guid_el.text:
                    # Use save name if available, otherwise page name
                    output_name = page_name
                    if save_name_el is not None and save_name_el.text:
                        output_name = f"{page_name}/{save_name_el.text}"
                    self.texture_pages[guid_el.text] = TexturePage(
                        guid=guid_el.text,
                        name=output_name
                    )

            # Also map operator GUIDs (for completeness)
            for operator in page.iter('Operator'):
                guid_el = operator.find('GUID')
                if guid_el is not None and guid_el.text:
                    # Only add if not already present (Save takes precedence)
                    if guid_el.text not in self.texture_pages:
                        self.texture_pages[guid_el.text] = TexturePage(
                            guid=guid_el.text,
                            name=page_name
                        )

    def _extract_render_techniques(self):
        """Extract render technique definitions with parameters"""
        for tech in self.root.iter('rendertechnique'):
            guid_el = tech.find('GUID')
            name_el = tech.find('Name')
            type_el = tech.find('Type')
            layer_el = tech.find('TargetLayer')

            if guid_el is None:
                continue

            technique = RenderTechnique(
                guid=guid_el.text,
                name=name_el.text if name_el is not None else "Unknown",
                tech_type=int(type_el.text) if type_el is not None else 0,
                target_layer=layer_el.text if layer_el is not None else ""
            )

            # Extract parameters from all passes
            for param in tech.iter('Parameter'):
                param_def = self._parse_parameter(param)
                if param_def:
                    technique.parameters.append(param_def)
                    self.param_defs[param_def.guid] = param_def

            self.techniques[technique.guid] = technique

    def _parse_parameter(self, param_el) -> Optional[ParameterDef]:
        """Parse a parameter element"""
        guid_el = param_el.find('GUID')
        if guid_el is None:
            return None

        name_el = param_el.find('Name')
        type_el = param_el.find('Type')
        scope_el = param_el.find('Scope')
        value_el = param_el.find('Value')
        default_el = param_el.find('DefaultValue')

        param_type = int(type_el.text) if type_el is not None else 0
        scope = int(scope_el.text) if scope_el is not None else 0

        # Get type name
        try:
            param_type_name = ParamType(param_type).name
        except ValueError:
            param_type_name = f"UNKNOWN({param_type})"

        # Get scope name
        try:
            scope_name = ParamScope(scope).name
        except ValueError:
            scope_name = f"UNKNOWN({scope})"

        param_def = ParameterDef(
            guid=guid_el.text,
            name=name_el.text if name_el is not None else "Unknown",
            param_type=param_type,
            param_type_name=param_type_name,
            scope=scope,
            scope_name=scope_name
        )

        if value_el is not None and value_el.text:
            param_def.value = decode_material_value(value_el.text, param_type)

        if default_el is not None and default_el.text:
            param_def.default_value = decode_material_value(default_el.text, param_type)

        return param_def

    def _extract_materials(self):
        """Extract material definitions (name mapping)"""
        for mat in self.root.iter('material'):
            guid_el = mat.find('GUID')
            name_el = mat.find('Name')
            if guid_el is not None and name_el is not None:
                self.materials[guid_el.text] = name_el.text

    def _extract_material_instances(self):
        """Extract per-object material instances with overrides"""
        # Find all model objects with material assignments
        for model in self.root.iter('model'):
            model_name = ""
            name_el = model.find('Name')
            if name_el is not None:
                model_name = name_el.text

            for obj in model.iter('Object'):
                obj_guid_el = obj.find('GUID')
                obj_name_el = obj.find('Name')
                mat_el = obj.find('Material')

                if mat_el is None:
                    continue

                mat_guid = mat_el.get('GUID', '')
                if not mat_guid or mat_guid == 'DEFAULTMATERIAL!DEFAULTMATERIAL!':
                    continue

                instance = MaterialInstance(
                    object_guid=obj_guid_el.text if obj_guid_el is not None else "",
                    object_name=f"{model_name}/{obj_name_el.text}" if obj_name_el is not None else model_name,
                    material_guid=mat_guid,
                    material_name=self.materials.get(mat_guid, "Unknown")
                )

                # Extract parameter overrides
                for param_data in obj.iter('materialparamdata'):
                    param_id = param_data.get('paramid', '')
                    value_b64 = param_data.get('valuebase64', '')

                    # Look up parameter definition
                    param_def = self.param_defs.get(param_id)
                    param_type = param_def.param_type if param_def else 0
                    param_name = param_def.name if param_def else "Unknown"

                    decoded = decode_material_value(value_b64, param_type)

                    instance.param_overrides.append({
                        "param_guid": param_id,
                        "param_name": param_name,
                        "param_type": param_def.param_type_name if param_def else "UNKNOWN",
                        "value": decoded
                    })

                # Extract texture bindings
                for tex_data in obj.iter('materialtexturedata'):
                    param_id = tex_data.get('paramid', '')
                    tex_id = tex_data.get('textureid', '')

                    if tex_id == 'NONENONENONENONENONENONENONENONE':
                        continue

                    # Look up parameter and texture
                    param_def = self.param_defs.get(param_id)
                    texture = self.texture_pages.get(tex_id)

                    slot_name = ""
                    if param_def and param_def.param_type in TEXTURE_SLOT_NAMES:
                        slot_name = TEXTURE_SLOT_NAMES[ParamType(param_def.param_type)]

                    instance.texture_bindings.append({
                        "param_guid": param_id,
                        "param_name": param_def.name if param_def else "Unknown",
                        "slot": slot_name,
                        "texture_guid": tex_id,
                        "texture_name": texture.name if texture else "Unknown"
                    })

                if instance.param_overrides or instance.texture_bindings:
                    self.material_instances.append(instance)

    def to_dict(self) -> dict:
        """Convert extracted data to dictionary"""
        return {
            "source": str(self.apx_path),
            "render_techniques": {
                guid: {
                    "name": tech.name,
                    "type": tech.tech_type,
                    "target_layer": self.render_targets.get(tech.target_layer, tech.target_layer),
                    "parameters": [asdict(p) for p in tech.parameters]
                }
                for guid, tech in self.techniques.items()
            },
            "texture_pages": {
                guid: page.name
                for guid, page in self.texture_pages.items()
            },
            "materials": self.materials,
            "material_instances": [
                {
                    "object": inst.object_name,
                    "object_guid": inst.object_guid,
                    "material": inst.material_name,
                    "material_guid": inst.material_guid,
                    "param_overrides": inst.param_overrides,
                    "texture_bindings": inst.texture_bindings
                }
                for inst in self.material_instances
            ]
        }

    def save_json(self, output_path: str):
        """Save extracted data as JSON"""
        with open(output_path, 'w') as f:
            json.dump(self.to_dict(), f, indent=2)


def main():
    parser = argparse.ArgumentParser(description='Extract material data from apEx .apx files')
    parser.add_argument('input', help='Path to .apx file')
    parser.add_argument('-o', '--output', help='Output JSON path (default: <input>_materials.json)')
    args = parser.parse_args()

    input_path = Path(args.input)
    if args.output:
        output_path = Path(args.output)
    else:
        output_path = input_path.parent / f"{input_path.stem}_materials.json"

    print(f"Extracting materials from: {input_path}")

    extractor = ApxMaterialExtractor(str(input_path))
    extractor.extract_all()

    print(f"Found {len(extractor.techniques)} render techniques")
    print(f"Found {len(extractor.texture_pages)} texture pages")
    print(f"Found {len(extractor.materials)} materials")
    print(f"Found {len(extractor.material_instances)} material instances with overrides")

    extractor.save_json(str(output_path))
    print(f"Saved to: {output_path}")


if __name__ == '__main__':
    main()
