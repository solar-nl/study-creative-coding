#!/usr/bin/env python3
"""
apEx project file (.apx) unpacker - Full extraction.

Extracts all content from apEx/Phoenix project files:
- Shader code (texture generators, render techniques)
- Texture pages with operator graphs
- Materials and their technique bindings
- Models with mesh filters and transformations
- Scenes with object hierarchies and animation clips
- Timeline events with spline data
- Render targets and layers

Usage:
    python scripts/unpack_apx.py "path/to/project.apx"
    python scripts/unpack_apx.py project.apx -o extracted/
    python scripts/unpack_apx.py project.apx --list
    python scripts/unpack_apx.py project.apx --shaders-only

Output structure:
    output_dir/
    ├── index.md                    # Summary with statistics
    ├── shaders/
    │   ├── texgen/                 # Texture generator shaders
    │   └── materials/              # Render technique shaders
    ├── textures/                   # Texture page graphs (JSON)
    ├── models/                     # Model definitions (JSON)
    ├── scenes/                     # Scene graphs with animations (JSON)
    ├── timeline/                   # Timeline events (JSON)
    ├── render_targets.json
    ├── render_layers.json
    └── materials.json              # Material -> technique mappings
"""

import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional, Any


# ============================================================================
# Data Classes
# ============================================================================

@dataclass
class Spline:
    """Animation spline with keyframes and waveform modulation."""
    interpolation: int = 0
    loop: int = 0
    waveform: int = 0
    multiplicative_waveform: int = 0
    wf_amplitude: int = 0
    wf_frequency: int = 0
    wf_randseed: int = 0
    values: list[int] = field(default_factory=list)  # Static values
    keys: list[dict] = field(default_factory=list)   # Animated keyframes


@dataclass
class Parameter:
    """Material or texture generator parameter."""
    guid: str = ""
    name: str = ""
    scope: int = 0
    param_type: int = 0
    default_value: Optional[str] = None
    value: Optional[str] = None
    texture_guid: Optional[str] = None


@dataclass
class ShaderPass:
    """A single render pass within a technique."""
    name: str = ""
    code: str = ""
    minifiable: bool = True
    parameters: list[Parameter] = field(default_factory=list)


@dataclass
class RenderTechnique:
    """A material/render technique with shader passes."""
    guid: str = ""
    name: str = ""
    technique_type: int = 0
    target_layer: Optional[str] = None
    passes: list[ShaderPass] = field(default_factory=list)


@dataclass
class TextureGenerator:
    """A procedural texture generator shader."""
    guid: str = ""
    name: str = ""
    code: str = ""
    parameters: list[Parameter] = field(default_factory=list)


@dataclass
class TextureOperator:
    """An operator instance in a texture page."""
    guid: str = ""
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    filter_guid: str = ""  # References a TextureGenerator
    resolution: int = 0
    seed: int = 0
    parameters: dict[int, int] = field(default_factory=dict)


@dataclass
class TexturePage:
    """A texture generation page/graph."""
    guid: str = ""
    name: str = ""
    xres: int = 8
    yres: int = 8
    hdr: bool = False
    operators: list[TextureOperator] = field(default_factory=list)


@dataclass
class Material:
    """A material definition linking name to technique."""
    guid: str = ""
    name: str = ""
    technique_guid: str = ""


@dataclass
class MeshFilter:
    """A mesh generation filter."""
    filter_type: int = 0
    name: str = ""
    transformations: dict[int, int] = field(default_factory=dict)
    parameters: dict[int, int] = field(default_factory=dict)
    enabled: bool = True


@dataclass
class ModelObject:
    """An object within a model."""
    guid: str = ""
    name: str = ""
    object_type: int = 0
    transformations: dict[int, int] = field(default_factory=dict)
    parameters: dict[int, int] = field(default_factory=dict)
    float_parameter: Optional[float] = None
    parent_guids: list[str] = field(default_factory=list)
    cloned_object: Optional[str] = None
    filters: list[MeshFilter] = field(default_factory=list)


@dataclass
class Model:
    """A 3D model definition."""
    guid: str = ""
    name: str = ""
    objects: list[ModelObject] = field(default_factory=list)


@dataclass
class ClipSpline:
    """A spline attached to a clip."""
    spline_type: int = 0
    spline: Optional[Spline] = None


@dataclass
class ClipData:
    """Animation data for an object in a specific clip."""
    target_clip: str = ""
    randseed: int = 0
    turbulence_freq: int = 0
    splines: list[ClipSpline] = field(default_factory=list)


@dataclass
class SceneObject:
    """An object within a scene."""
    guid: str = ""
    name: str = ""
    object_type: int = 0
    clip_data: list[ClipData] = field(default_factory=list)


@dataclass
class Clip:
    """An animation clip within a scene."""
    guid: str = ""
    name: str = ""


@dataclass
class Scene:
    """A scene definition with objects and clips."""
    guid: str = ""
    name: str = ""
    clips: list[Clip] = field(default_factory=list)
    objects: list[SceneObject] = field(default_factory=list)


@dataclass
class TimelineEvent:
    """A timeline event."""
    guid: str = ""
    name: str = ""
    event_type: int = 0
    pass_index: int = 0
    start_frame: int = 0
    end_frame: int = 0
    target_rt: str = ""
    time_spline: Optional[Spline] = None
    scene_guid: Optional[str] = None
    clip_guid: Optional[str] = None
    camera_guid: Optional[str] = None
    subscene_target: Optional[str] = None


@dataclass
class RenderTarget:
    """A render target definition."""
    guid: str = ""
    name: str = ""
    resolution: int = 0
    pixel_format: int = 0
    is_cubemap: bool = False
    z_resolution: int = 0
    hidden: bool = False


@dataclass
class RenderLayer:
    """A render layer configuration."""
    guid: str = ""
    name: str = ""
    render_targets: list[str] = field(default_factory=list)
    omit_depth: bool = False
    clear_targets: bool = False
    is_voxelizer: bool = False
    ignore_helpers: bool = False
    pickable: bool = False


# ============================================================================
# Constants
# ============================================================================

PARAM_TYPE_NAMES = {
    0: "Float", 1: "Color", 2: "ZMode", 3: "ZFunction", 4: "FillMode",
    5: "CullMode", 6: "RenderPriority", 7: "Texture0", 8: "Texture1",
    9: "Texture2", 10: "Texture3", 11: "Texture4", 12: "Texture5",
    13: "Texture6", 14: "Texture7", 15: "BlendMode0", 16: "BlendMode1",
    17: "BlendMode2", 18: "BlendMode3", 19: "BlendMode4", 20: "BlendMode5",
    21: "BlendMode6", 22: "BlendMode7", 23: "RenderTarget",
    24: "ParticleLifeFloat", 25: "DepthTexture7", 26: "3DTexture6",
    27: "MeshData0", 28: "MeshData1", 29: "MeshData2", 30: "MeshData3",
    31: "MeshData4", 32: "MeshData5", 33: "MeshData6", 34: "MeshData7",
    35: "ParticleLife", 36: "LTC1", 37: "LTC2",
}

TECHNIQUE_TYPE_NAMES = {
    0: "Material", 1: "PostProcess", 2: "ShaderToy", 3: "Particle",
}

EVENT_TYPE_NAMES = {
    0: "RenderScene", 1: "CameraShake", 2: "Particle", 3: "CameraOverride",
    4: "SubScene", 5: "RenderDemo", 6: "RenderDemo", 7: "EnvMapFlip",
}


# ============================================================================
# Parsing Functions
# ============================================================================

def sanitize_filename(name: str) -> str:
    """Convert a name to a valid filename."""
    name = re.sub(r'\[([^\]]+)\]', r'\1', name)
    name = re.sub(r'[^\w\s-]', '', name)
    name = re.sub(r'\s+', '-', name.strip())
    return name.lower() or "unnamed"


def decode_shader_code(code: str) -> str:
    """Decode HTML entities in shader code."""
    code = html.unescape(code)
    code = code.replace('\r\n', '\n').replace('\r', '\n')
    return code


def parse_spline(elem: ET.Element) -> Spline:
    """Parse a spline element."""
    spline = Spline(
        interpolation=int(elem.findtext('interpolation', '0')),
        loop=int(elem.findtext('loop', '0')),
        waveform=int(elem.findtext('waveform', '0')),
        multiplicative_waveform=int(elem.findtext('multiplicativewaveform', '0')),
        wf_amplitude=int(elem.findtext('wfamplitude', '0')),
        wf_frequency=int(elem.findtext('wffrequency', '0')),
        wf_randseed=int(elem.findtext('wfrandseed', '0')),
    )

    # Parse static values
    for val_elem in elem.findall('value'):
        spline.values.append(int(val_elem.text or '0'))

    # Parse keyframes
    for key_elem in elem.findall('key'):
        key = {
            'time': int(key_elem.findtext('time', '0')),
            'values': [],
            'control_pos': [],
            'control_values': [],
        }
        for val in key_elem.findall('value'):
            key['values'].append(int(val.text or '0'))
        for cp in key_elem.findall('controlpos'):
            key['control_pos'].append(int(cp.text or '0'))
        for cv in key_elem.findall('controlvalue'):
            key['control_values'].append(int(cv.text or '0'))
        spline.keys.append(key)

    return spline


def parse_parameter(elem: ET.Element) -> Parameter:
    """Parse a Parameter element."""
    return Parameter(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        scope=int(elem.findtext('Scope', '0')),
        param_type=int(elem.findtext('Type', '0')),
        default_value=elem.findtext('DefaultValue'),
        value=elem.findtext('Value'),
        texture_guid=elem.findtext('TextureGUID'),
    )


def parse_texture_generator(elem: ET.Element) -> Optional[TextureGenerator]:
    """Parse a texture generator element."""
    guid = elem.findtext('GUID')
    name = elem.findtext('Name')
    code_elem = elem.find('Code')

    if not all([guid, name]):
        return None

    code = ''
    if code_elem is not None and code_elem.text:
        code = decode_shader_code(code_elem.text)

    return TextureGenerator(
        guid=guid,
        name=name,
        code=code,
        parameters=[parse_parameter(p) for p in elem.findall('Parameter')],
    )


def parse_render_technique(elem: ET.Element) -> RenderTechnique:
    """Parse a rendertechnique element."""
    technique = RenderTechnique(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        technique_type=int(elem.findtext('Type', '0')),
        target_layer=elem.findtext('TargetLayer'),
    )

    for pass_elem in elem.findall('Pass'):
        code_elem = pass_elem.find('Code')
        code = decode_shader_code(code_elem.text) if code_elem is not None and code_elem.text else ''

        shader_pass = ShaderPass(
            name=pass_elem.findtext('Name', 'Unnamed Pass'),
            code=code,
            minifiable=pass_elem.findtext('Minifiable', '1') == '1',
            parameters=[parse_parameter(p) for p in pass_elem.findall('Parameter')],
        )
        technique.passes.append(shader_pass)

    return technique


def parse_texture_operator(elem: ET.Element) -> TextureOperator:
    """Parse a texture Operator element."""
    op = TextureOperator(
        guid=elem.findtext('GUID', ''),
        x1=int(elem.findtext('x1', '0')),
        y1=int(elem.findtext('y1', '0')),
        x2=int(elem.findtext('x2', '0')),
        y2=int(elem.findtext('y2', '0')),
        filter_guid=elem.findtext('Filter', ''),
        resolution=int(elem.findtext('Resolution', '0')),
        seed=int(elem.findtext('Seed', '0')),
    )

    for param in elem.findall('Parameter'):
        param_id = param.get('ID')
        if param_id is not None and param.text:
            op.parameters[int(param_id)] = int(param.text)

    return op


def parse_texture_page(elem: ET.Element) -> TexturePage:
    """Parse a texturepage element."""
    page = TexturePage(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        xres=int(elem.findtext('xres', '8')),
        yres=int(elem.findtext('yres', '8')),
        hdr=elem.findtext('hdr', '0') == '1',
    )

    for op_elem in elem.findall('Operator'):
        page.operators.append(parse_texture_operator(op_elem))

    return page


def parse_material(elem: ET.Element) -> Material:
    """Parse a material element."""
    return Material(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        technique_guid=elem.findtext('Tech', ''),
    )


def parse_mesh_filter(elem: ET.Element) -> MeshFilter:
    """Parse a mesh Filter element."""
    f = MeshFilter(
        filter_type=int(elem.get('Type', '0')),
        name=elem.findtext('Name', ''),
        enabled=elem.findtext('enabled', '1') == '1',
    )

    for t in elem.findall('transformation'):
        idx = t.get('index')
        val = t.get('value')
        if idx is not None and val is not None:
            f.transformations[int(idx)] = int(val)

    for p in elem.findall('parameter'):
        idx = p.get('index')
        val = p.get('value')
        if idx is not None and val is not None:
            f.parameters[int(idx)] = int(val)

    return f


def parse_model_object(elem: ET.Element) -> ModelObject:
    """Parse a model Object element."""
    obj = ModelObject(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        object_type=int(elem.get('Type', '0')),
        cloned_object=elem.findtext('clonedobject'),
    )

    for t in elem.findall('transformation'):
        idx = t.get('index')
        val = t.get('value')
        if idx is not None and val is not None:
            obj.transformations[int(idx)] = int(val)

    for p in elem.findall('parameter'):
        idx = p.get('index')
        val = p.get('value')
        if idx is not None and val is not None:
            obj.parameters[int(idx)] = int(val)

    fp = elem.findtext('floatparameter')
    if fp:
        obj.float_parameter = float(fp)

    for pg in elem.findall('parentguid'):
        val = pg.get('value')
        if val and val != 'NONENONENONENONENONENONENONENONE':
            obj.parent_guids.append(val)

    for filter_elem in elem.findall('Filter'):
        obj.filters.append(parse_mesh_filter(filter_elem))

    return obj


def parse_model(elem: ET.Element) -> Model:
    """Parse a model element."""
    model = Model(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
    )

    for obj_elem in elem.findall('Object'):
        model.objects.append(parse_model_object(obj_elem))

    return model


def parse_clip_data(elem: ET.Element) -> ClipData:
    """Parse clipdata element."""
    cd = ClipData(
        target_clip=elem.get('targetclip', ''),
        randseed=int(elem.findtext('randseed', '0')),
        turbulence_freq=int(elem.findtext('turbulencefreq', '0')),
    )

    for cs_elem in elem.findall('clipspline'):
        cs = ClipSpline(
            spline_type=int(cs_elem.get('type', '0')),
        )
        spline_elem = cs_elem.find('spline')
        if spline_elem is not None:
            cs.spline = parse_spline(spline_elem)
        cd.splines.append(cs)

    return cd


def parse_scene_object(elem: ET.Element) -> SceneObject:
    """Parse a scene Object element."""
    obj = SceneObject(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        object_type=int(elem.get('Type', '0')),
    )

    for cd_elem in elem.findall('clipdata'):
        obj.clip_data.append(parse_clip_data(cd_elem))

    return obj


def parse_scene(elem: ET.Element) -> Scene:
    """Parse a scene element."""
    scene = Scene(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
    )

    for clip_elem in elem.findall('Clip'):
        scene.clips.append(Clip(
            guid=clip_elem.findtext('GUID', ''),
            name=clip_elem.findtext('Name', ''),
        ))

    for obj_elem in elem.findall('Object'):
        scene.objects.append(parse_scene_object(obj_elem))

    return scene


def parse_timeline_event(elem: ET.Element) -> TimelineEvent:
    """Parse an event element."""
    event = TimelineEvent(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        event_type=int(elem.findtext('Type', '0')),
        pass_index=int(elem.findtext('Pass', '0')),
        start_frame=int(elem.findtext('StartFrame', '0')),
        end_frame=int(elem.findtext('EndFrame', '0')),
        target_rt=elem.findtext('TargetRT', ''),
        scene_guid=elem.findtext('scene'),
        clip_guid=elem.findtext('clip'),
        camera_guid=elem.findtext('camera'),
        subscene_target=elem.findtext('subscenetarget'),
    )

    ts_elem = elem.find('TimeSpline')
    if ts_elem is not None:
        event.time_spline = parse_spline(ts_elem)

    return event


def parse_render_target(elem: ET.Element) -> RenderTarget:
    """Parse a rendertarget element."""
    return RenderTarget(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        resolution=int(elem.findtext('ResolutionDescriptor', '0')),
        pixel_format=int(elem.findtext('PixelFormat', '0')),
        is_cubemap=elem.findtext('CubeMap', '0') == '1',
        z_resolution=int(elem.findtext('ZResolution', '0')),
        hidden=elem.findtext('HiddenFromTimeline', '0') == '1',
    )


def parse_render_layer(elem: ET.Element) -> RenderLayer:
    """Parse a renderlayer element."""
    return RenderLayer(
        guid=elem.findtext('GUID', ''),
        name=elem.findtext('Name', ''),
        render_targets=[rt.text for rt in elem.findall('RenderTarget') if rt.text],
        omit_depth=elem.findtext('OmitDepthBuffer', '0') == '1',
        clear_targets=elem.findtext('ClearRenderTargets', '0') == '1',
        is_voxelizer=elem.findtext('Voxelizer', '0') == '1',
        ignore_helpers=elem.findtext('IgnoreHelperObjects', '0') == '1',
        pickable=elem.findtext('Pickable', '0') == '1',
    )


# ============================================================================
# Main Unpacker Class
# ============================================================================

class ApxUnpacker:
    """Full extraction of apEx project files."""

    def __init__(self, apx_path: Path):
        self.apx_path = apx_path
        self.tree = ET.parse(apx_path)
        self.root = self.tree.getroot()

        # Shader code
        self.texgens: list[TextureGenerator] = []
        self.techniques: list[RenderTechnique] = []

        # Texture system
        self.texture_pages: list[TexturePage] = []

        # Materials
        self.materials: list[Material] = []

        # Models
        self.models: list[Model] = []

        # Scenes & animation
        self.scenes: list[Scene] = []

        # Timeline
        self.events: list[TimelineEvent] = []

        # Render config
        self.render_targets: list[RenderTarget] = []
        self.render_layers: list[RenderLayer] = []

        self._parse()

    def _parse(self):
        """Parse all content."""
        for elem in self.root:
            tag = elem.tag

            if tag == 'rendertechnique':
                self.techniques.append(parse_render_technique(elem))
            elif tag == 'rendertarget':
                self.render_targets.append(parse_render_target(elem))
            elif tag == 'renderlayer':
                self.render_layers.append(parse_render_layer(elem))
            elif tag == 'texturepage':
                self.texture_pages.append(parse_texture_page(elem))
            elif tag == 'material':
                self.materials.append(parse_material(elem))
            elif tag == 'model':
                self.models.append(parse_model(elem))
            elif tag == 'scene':
                self.scenes.append(parse_scene(elem))
            elif tag == 'event':
                self.events.append(parse_timeline_event(elem))
            else:
                # Try as texture generator
                texgen = parse_texture_generator(elem)
                if texgen:
                    self.texgens.append(texgen)

    def _build_guid_maps(self) -> dict[str, Any]:
        """Build GUID -> name lookup maps."""
        maps = {
            'texgen': {tg.guid: tg.name for tg in self.texgens},
            'technique': {t.guid: t.name for t in self.techniques},
            'render_target': {rt.guid: rt.name for rt in self.render_targets},
            'render_layer': {rl.guid: rl.name for rl in self.render_layers},
            'material': {m.guid: m.name for m in self.materials},
            'model': {m.guid: m.name for m in self.models},
            'scene': {s.guid: s.name for s in self.scenes},
        }
        # Add clips from scenes
        maps['clip'] = {}
        for scene in self.scenes:
            for clip in scene.clips:
                maps['clip'][clip.guid] = f"{scene.name}/{clip.name}"
        return maps

    def list_contents(self):
        """Print summary of contents."""
        print(f"\n📦 {self.apx_path.name}")
        print("=" * 70)

        # Shaders
        texgen_with_code = [tg for tg in self.texgens if tg.code]
        tech_with_code = [t for t in self.techniques if any(p.code for p in t.passes)]

        print(f"\n🎨 Texture Generators: {len(texgen_with_code)} with shader code")
        for tg in texgen_with_code[:8]:
            lines = len(tg.code.split('\n'))
            print(f"   • {tg.name} ({lines} lines)")
        if len(texgen_with_code) > 8:
            print(f"   ... and {len(texgen_with_code) - 8} more")

        print(f"\n🖌️  Render Techniques: {len(tech_with_code)}")
        for tech in tech_with_code[:10]:
            type_name = TECHNIQUE_TYPE_NAMES.get(tech.technique_type, "Unknown")
            total_lines = sum(len(p.code.split('\n')) for p in tech.passes if p.code)
            print(f"   • [{type_name}] {tech.name} ({len(tech.passes)} passes, {total_lines} lines)")
        if len(tech_with_code) > 10:
            print(f"   ... and {len(tech_with_code) - 10} more")

        # Texture pages
        total_ops = sum(len(p.operators) for p in self.texture_pages)
        print(f"\n📐 Texture Pages: {len(self.texture_pages)} ({total_ops} total operators)")
        for page in self.texture_pages[:5]:
            print(f"   • {page.name} ({len(page.operators)} ops, {page.xres}x{page.yres})")
        if len(self.texture_pages) > 5:
            print(f"   ... and {len(self.texture_pages) - 5} more")

        # Materials
        print(f"\n🎭 Materials: {len(self.materials)}")
        for mat in self.materials[:5]:
            print(f"   • {mat.name}")
        if len(self.materials) > 5:
            print(f"   ... and {len(self.materials) - 5} more")

        # Models
        total_objects = sum(len(m.objects) for m in self.models)
        print(f"\n🏗️  Models: {len(self.models)} ({total_objects} total objects)")
        for model in self.models[:5]:
            print(f"   • {model.name} ({len(model.objects)} objects)")
        if len(self.models) > 5:
            print(f"   ... and {len(self.models) - 5} more")

        # Scenes
        total_scene_objects = sum(len(s.objects) for s in self.scenes)
        total_clips = sum(len(s.clips) for s in self.scenes)
        print(f"\n🎬 Scenes: {len(self.scenes)} ({total_scene_objects} objects, {total_clips} clips)")
        for scene in self.scenes[:5]:
            print(f"   • {scene.name} ({len(scene.objects)} objs, {len(scene.clips)} clips)")
        if len(self.scenes) > 5:
            print(f"   ... and {len(self.scenes) - 5} more")

        # Timeline
        if self.events:
            duration_frames = max(e.end_frame for e in self.events)
            print(f"\n⏱️  Timeline Events: {len(self.events)} (duration: {duration_frames} frames)")
            for event in self.events[:5]:
                type_name = EVENT_TYPE_NAMES.get(event.event_type, f"Type{event.event_type}")
                print(f"   • [{type_name}] {event.start_frame}-{event.end_frame}")
            if len(self.events) > 5:
                print(f"   ... and {len(self.events) - 5} more")

        # Render config
        print(f"\n🎯 Render Targets: {len(self.render_targets)}")
        print(f"📑 Render Layers: {len(self.render_layers)}")

        # Stats
        total_shader_lines = sum(len(tg.code.split('\n')) for tg in self.texgens if tg.code)
        total_shader_lines += sum(len(p.code.split('\n')) for t in self.techniques for p in t.passes if p.code)

        total_splines = sum(
            len(cd.splines)
            for scene in self.scenes
            for obj in scene.objects
            for cd in obj.clip_data
        )

        print(f"\n📊 Statistics:")
        print(f"   • Total shader lines: ~{total_shader_lines}")
        print(f"   • Total animation splines: ~{total_splines}")
        print(f"   • Total texture operators: {total_ops}")

    def extract(self, output_dir: Path, shaders_only: bool = False):
        """Extract all content to output directory."""
        output_dir.mkdir(parents=True, exist_ok=True)

        guid_maps = self._build_guid_maps()
        extracted = {'shaders': 0, 'json': 0}

        # === Shaders ===
        shader_dir = output_dir / 'shaders'
        texgen_dir = shader_dir / 'texgen'
        materials_dir = shader_dir / 'materials'
        texgen_dir.mkdir(parents=True, exist_ok=True)
        materials_dir.mkdir(parents=True, exist_ok=True)

        # Texture generators
        for tg in self.texgens:
            if not tg.code:
                continue
            filename = sanitize_filename(tg.name) + '.hlsl'
            filepath = texgen_dir / filename

            header = f"// Texture Generator: {tg.name}\n"
            header += f"// GUID: {tg.guid}\n"
            if tg.parameters:
                header += f"// Parameters:\n"
                for p in tg.parameters:
                    type_name = PARAM_TYPE_NAMES.get(p.param_type, f"Type{p.param_type}")
                    header += f"//   [{p.param_type}] {p.name} ({type_name})\n"
            header += "\n"

            filepath.write_text(header + tg.code)
            extracted['shaders'] += 1

        # Render techniques
        for tech in self.techniques:
            if not any(p.code for p in tech.passes):
                continue
            filename = sanitize_filename(tech.name) + '.hlsl'
            filepath = materials_dir / filename

            type_name = TECHNIQUE_TYPE_NAMES.get(tech.technique_type, "Unknown")
            header = f"// Render Technique: {tech.name}\n"
            header += f"// Type: {type_name}\n"
            header += f"// GUID: {tech.guid}\n"
            if tech.target_layer:
                layer_name = guid_maps['render_layer'].get(tech.target_layer, tech.target_layer[:16])
                header += f"// Target Layer: {layer_name}\n"
            header += "\n"

            content = header
            for i, sp in enumerate(tech.passes):
                content += f"// {'='*70}\n"
                content += f"// Pass {i+1}: {sp.name}\n"
                if sp.parameters:
                    for p in sp.parameters:
                        ptype = PARAM_TYPE_NAMES.get(p.param_type, f"Type{p.param_type}")
                        scope = ['Constant', 'Variable', 'Animated'][p.scope] if p.scope < 3 else f"Scope{p.scope}"
                        content += f"//   • {p.name} ({ptype}, {scope})\n"
                content += f"// {'='*70}\n\n"
                content += sp.code if sp.code else "// (no shader code)\n"
                content += "\n\n"

            filepath.write_text(content)
            extracted['shaders'] += 1

        if shaders_only:
            print(f"\n✅ Extracted {extracted['shaders']} shader files to {output_dir}/shaders/")
            return

        # === JSON Data ===

        def to_dict(obj):
            """Convert dataclass to dict, handling nested dataclasses."""
            if hasattr(obj, '__dataclass_fields__'):
                return {k: to_dict(v) for k, v in asdict(obj).items()}
            elif isinstance(obj, list):
                return [to_dict(i) for i in obj]
            elif isinstance(obj, dict):
                return {k: to_dict(v) for k, v in obj.items()}
            return obj

        # Texture pages
        if self.texture_pages:
            textures_dir = output_dir / 'textures'
            textures_dir.mkdir(exist_ok=True)
            for page in self.texture_pages:
                filename = sanitize_filename(page.name) + '.json'
                # Resolve filter GUIDs to names
                page_dict = to_dict(page)
                for op in page_dict['operators']:
                    op['filter_name'] = guid_maps['texgen'].get(op['filter_guid'], 'Unknown')
                (textures_dir / filename).write_text(json.dumps(page_dict, indent=2))
                extracted['json'] += 1

        # Materials
        if self.materials:
            materials_data = []
            for mat in self.materials:
                mat_dict = to_dict(mat)
                mat_dict['technique_name'] = guid_maps['technique'].get(mat.technique_guid, 'Unknown')
                materials_data.append(mat_dict)
            (output_dir / 'materials.json').write_text(json.dumps(materials_data, indent=2))
            extracted['json'] += 1

        # Models
        if self.models:
            models_dir = output_dir / 'models'
            models_dir.mkdir(exist_ok=True)
            for model in self.models:
                filename = sanitize_filename(model.name) + '.json'
                (models_dir / filename).write_text(json.dumps(to_dict(model), indent=2))
                extracted['json'] += 1

        # Scenes
        if self.scenes:
            scenes_dir = output_dir / 'scenes'
            scenes_dir.mkdir(exist_ok=True)
            for scene in self.scenes:
                filename = sanitize_filename(scene.name) + '.json'
                (scenes_dir / filename).write_text(json.dumps(to_dict(scene), indent=2))
                extracted['json'] += 1

        # Timeline
        if self.events:
            timeline_data = []
            for event in self.events:
                event_dict = to_dict(event)
                event_dict['type_name'] = EVENT_TYPE_NAMES.get(event.event_type, f"Type{event.event_type}")
                event_dict['target_rt_name'] = guid_maps['render_target'].get(event.target_rt, 'Unknown')
                if event.scene_guid:
                    event_dict['scene_name'] = guid_maps['scene'].get(event.scene_guid, 'Unknown')
                if event.clip_guid:
                    event_dict['clip_name'] = guid_maps['clip'].get(event.clip_guid, 'Unknown')
                timeline_data.append(event_dict)
            (output_dir / 'timeline.json').write_text(json.dumps(timeline_data, indent=2))
            extracted['json'] += 1

        # Render targets
        if self.render_targets:
            (output_dir / 'render_targets.json').write_text(
                json.dumps([to_dict(rt) for rt in self.render_targets], indent=2)
            )
            extracted['json'] += 1

        # Render layers
        if self.render_layers:
            layers_data = []
            for layer in self.render_layers:
                layer_dict = to_dict(layer)
                layer_dict['render_target_names'] = [
                    guid_maps['render_target'].get(rt, rt[:16]) for rt in layer.render_targets
                ]
                layers_data.append(layer_dict)
            (output_dir / 'render_layers.json').write_text(json.dumps(layers_data, indent=2))
            extracted['json'] += 1

        # === Index ===
        self._write_index(output_dir, guid_maps, extracted)

        print(f"\n✅ Extracted to {output_dir}/")
        print(f"   📁 shaders/texgen/ ({len([t for t in self.texgens if t.code])} files)")
        print(f"   📁 shaders/materials/ ({len([t for t in self.techniques if any(p.code for p in t.passes)])} files)")
        print(f"   📁 textures/ ({len(self.texture_pages)} files)")
        print(f"   📁 models/ ({len(self.models)} files)")
        print(f"   📁 scenes/ ({len(self.scenes)} files)")
        print(f"   📄 timeline.json ({len(self.events)} events)")
        print(f"   📄 materials.json ({len(self.materials)} materials)")
        print(f"   📄 render_targets.json ({len(self.render_targets)} targets)")
        print(f"   📄 render_layers.json ({len(self.render_layers)} layers)")

    def _write_index(self, output_dir: Path, guid_maps: dict, extracted: dict):
        """Write index.md summary."""
        index = f"# Extracted: {self.apx_path.name}\n\n"
        index += f"Source: `{self.apx_path}`\n\n"

        index += "## Shaders\n\n"
        index += "### Texture Generators\n\n"
        for tg in sorted(self.texgens, key=lambda x: x.name):
            if tg.code:
                filename = sanitize_filename(tg.name) + '.hlsl'
                lines = len(tg.code.split('\n'))
                index += f"- [{tg.name}](shaders/texgen/{filename}) ({lines} lines)\n"

        index += "\n### Render Techniques\n\n"
        for tech in sorted(self.techniques, key=lambda x: x.name):
            if any(p.code for p in tech.passes):
                filename = sanitize_filename(tech.name) + '.hlsl'
                type_name = TECHNIQUE_TYPE_NAMES.get(tech.technique_type, "Unknown")
                index += f"- [{tech.name}](shaders/materials/{filename}) [{type_name}]\n"

        index += "\n## Texture Pages\n\n"
        for page in sorted(self.texture_pages, key=lambda x: x.name):
            filename = sanitize_filename(page.name) + '.json'
            index += f"- [{page.name}](textures/{filename}) ({len(page.operators)} operators)\n"

        index += "\n## Models\n\n"
        for model in sorted(self.models, key=lambda x: x.name):
            filename = sanitize_filename(model.name) + '.json'
            index += f"- [{model.name}](models/{filename}) ({len(model.objects)} objects)\n"

        index += "\n## Scenes\n\n"
        for scene in sorted(self.scenes, key=lambda x: x.name):
            filename = sanitize_filename(scene.name) + '.json'
            index += f"- [{scene.name}](scenes/{filename}) ({len(scene.objects)} objects, {len(scene.clips)} clips)\n"

        index += "\n## Timeline\n\n"
        if self.events:
            duration = max(e.end_frame for e in self.events)
            index += f"Total events: {len(self.events)}, Duration: {duration} frames\n\n"
            index += "See [timeline.json](timeline.json)\n"

        index += "\n## Render Configuration\n\n"
        index += f"- [render_targets.json](render_targets.json) ({len(self.render_targets)} targets)\n"
        index += f"- [render_layers.json](render_layers.json) ({len(self.render_layers)} layers)\n"
        index += f"- [materials.json](materials.json) ({len(self.materials)} materials)\n"

        (output_dir / 'index.md').write_text(index)


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Extract all content from apEx project files (.apx)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument('apx_file', type=Path, help='Path to .apx project file')
    parser.add_argument('-o', '--output', type=Path, help='Output directory')
    parser.add_argument('--list', action='store_true', help='List contents only')
    parser.add_argument('--shaders-only', action='store_true', help='Extract only shaders')

    args = parser.parse_args()

    if not args.apx_file.exists():
        print(f"Error: File not found: {args.apx_file}", file=sys.stderr)
        sys.exit(1)

    try:
        unpacker = ApxUnpacker(args.apx_file)
    except ET.ParseError as e:
        print(f"Error: Failed to parse XML: {e}", file=sys.stderr)
        sys.exit(1)

    if args.list:
        unpacker.list_contents()
    else:
        output_dir = args.output or Path(args.apx_file.stem + '_extracted')
        unpacker.extract(output_dir, shaders_only=args.shaders_only)


if __name__ == '__main__':
    main()
