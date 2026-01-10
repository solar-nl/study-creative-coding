#!/usr/bin/env python3
"""
Wikipedia-style reference linker for markdown files.

Scans markdown files for unlinked references to:
- Framework source files (e.g., baseContext.py)
- Libraries and dependencies (e.g., fontTools, rustybuzz)
- External tools (e.g., gifsicle, ffmpeg)

Usage:
    python scripts/link_references.py notes/per-framework/drawbot/  # Preview changes
    python scripts/link_references.py notes/per-framework/drawbot/ --apply  # Apply changes
    python scripts/link_references.py notes/ --recursive  # Scan all subdirectories
"""

import argparse
import json
import re
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Optional


@dataclass
class Reference:
    """A detected reference that could be linked."""
    original: str
    linked: str
    line_num: int
    ref_type: str  # 'file', 'library', 'tool'
    context: str   # Surrounding text for context
    position: int = 0  # Character position in line


@dataclass
class FileContext:
    """Context about which framework a file belongs to."""
    framework: str
    github_base: str
    branch: str


class ReferenceLinker:
    def __init__(self, registry_path: Path):
        with open(registry_path) as f:
            self.registry = json.load(f)

        # Build lookup tables
        self.library_patterns = self._build_library_patterns()
        self.tool_patterns = self._build_tool_patterns()
        self.file_extensions = {'.py', '.rs', '.kt', '.js', '.ts', '.java', '.cpp', '.h'}

    def _build_library_patterns(self) -> dict[str, str]:
        """Build case-insensitive lookup for library names."""
        patterns = {}
        for name, info in self.registry.get('libraries', {}).items():
            url = info['url'] if isinstance(info, dict) else info
            patterns[name.lower()] = (name, url)
            if isinstance(info, dict) and 'aliases' in info:
                for alias in info['aliases']:
                    patterns[alias.lower()] = (name, url)
        return patterns

    def _build_tool_patterns(self) -> dict[str, str]:
        """Build lookup for tool names."""
        patterns = {}
        for name, info in self.registry.get('tools', {}).items():
            url = info['url'] if isinstance(info, dict) else info
            patterns[name.lower()] = (name, url)
        return patterns

    def detect_framework_context(self, file_path: Path) -> Optional[FileContext]:
        """Determine which framework a markdown file is discussing."""
        # Check if path contains framework name
        path_str = str(file_path).lower()
        for fw_name, fw_info in self.registry.get('frameworks', {}).items():
            if fw_name in path_str:
                return FileContext(
                    framework=fw_name,
                    github_base=fw_info['github'],
                    branch=fw_info.get('branch', 'main')
                )
        return None

    def get_file_url(self, filename: str, context: FileContext, line_start: int = None, line_end: int = None) -> Optional[str]:
        """Generate GitHub URL for a source file."""
        fw_info = self.registry['frameworks'].get(context.framework, {})
        base_path = fw_info.get('base_path', '')
        file_mappings = fw_info.get('file_mappings', {})

        # Check if we have a known mapping for this file
        if filename in file_mappings:
            rel_path = file_mappings[filename]
        else:
            # Try to construct path from base_path
            rel_path = f"{base_path}/{filename}" if base_path else filename

        url = f"{context.github_base}/blob/{context.branch}/{rel_path}"

        # Add line number anchors
        if line_start:
            if line_end and line_end != line_start:
                url += f"#L{line_start}-L{line_end}"
            else:
                url += f"#L{line_start}"

        return url

    def is_inside_link(self, text: str, match_start: int, match_end: int) -> bool:
        """Check if a match is already inside a markdown link."""
        before = text[:match_start]
        after = text[match_end:]

        # Check if we're inside the text part of [text](url)
        # Look for unmatched [ before the match
        open_brackets = before.count('[') - before.count(']')
        if open_brackets > 0:
            # Check if there's a ]( after the match (completing the link)
            if '](' in after:
                return True

        # Also check if the match itself is already a link: [match](url)
        # Look for pattern where match is immediately preceded by [ and followed by ](
        if before.endswith('[') and after.startswith(']('):
            return True

        # Check if we're inside a URL (between ]( and ))
        # Look for ]( before without closing )
        if '](' in before:
            last_link_start = before.rfind('](')
            url_part = before[last_link_start + 2:]  # Skip the '](' itself
            if ')' not in url_part:
                # We're inside a URL
                return True

        # Check for already-linked pattern: [text](url) where our match is part of text
        # This catches cases like [wgpu](url) when searching for "wgpu"
        link_pattern = rf'\[([^\]]*{re.escape(text[match_start:match_end])}[^\]]*)\]\([^)]+\)'
        if re.search(link_pattern, text):
            # Find where this link is
            for m in re.finditer(link_pattern, text):
                if m.start() <= match_start < m.end():
                    return True

        return False

    def is_inside_code_block(self, lines: list[str], line_idx: int) -> bool:
        """Check if a line is inside a fenced code block."""
        in_fence = False
        for i, line in enumerate(lines[:line_idx]):
            if line.strip().startswith('```'):
                in_fence = not in_fence
        return in_fence

    def find_unlinked_files(self, content: str, lines: list[str], context: Optional[FileContext]) -> list[Reference]:
        """Find file references that aren't linked."""
        refs = []

        # Pattern: `filename.ext` or `filename.ext:line` or `filename.ext:line-line`
        # Negative lookbehind for [ to avoid already-linked refs
        pattern = r'(?<!\[)`([a-zA-Z_][a-zA-Z0-9_]*\.(?:py|rs|kt|js|ts|java|cpp|h))(?::(\d+)(?:-(\d+))?)?`'

        for line_num, line in enumerate(lines, 1):
            if self.is_inside_code_block(lines, line_num - 1):
                continue

            for match in re.finditer(pattern, line):
                full_match = match.group(0)
                filename = match.group(1)
                line_start = int(match.group(2)) if match.group(2) else None
                line_end = int(match.group(3)) if match.group(3) else None

                # Skip if already inside a link
                if self.is_inside_link(line, match.start(), match.end()):
                    continue

                # Generate linked version
                if context:
                    url = self.get_file_url(filename, context, line_start, line_end)
                    if url:
                        display = f"{filename}"
                        if line_start:
                            display += f":{line_start}"
                            if line_end:
                                display += f"-{line_end}"
                        linked = f"[`{display}`]({url})"

                        refs.append(Reference(
                            original=full_match,
                            linked=linked,
                            line_num=line_num,
                            ref_type='file',
                            context=line.strip()[:80],
                            position=match.start()
                        ))

        return refs

    def find_unlinked_libraries(self, content: str, lines: list[str]) -> list[Reference]:
        """Find library names that aren't linked."""
        refs = []

        # Libraries that are common English words - require backticks or exact case
        ambiguous_names = {'image', 'palette', 'lyon'}

        for line_num, line in enumerate(lines, 1):
            if self.is_inside_code_block(lines, line_num - 1):
                continue

            for lib_lower, (lib_name, url) in self.library_patterns.items():
                # For ambiguous names, require backticks or exact match
                if lib_lower in ambiguous_names:
                    # Match in backticks: `image` or exact case match
                    pattern = rf'`{re.escape(lib_name)}`'
                    for match in re.finditer(pattern, line):
                        if self.is_inside_link(line, match.start(), match.end()):
                            continue
                        original = match.group(0)
                        linked = f"[{original}]({url})"
                        refs.append(Reference(
                            original=original,
                            linked=linked,
                            line_num=line_num,
                            ref_type='library',
                            context=line.strip()[:80],
                            position=match.start()
                        ))
                else:
                    # Match the library name with word boundaries
                    pattern = rf'\b{re.escape(lib_name)}\b'
                    for match in re.finditer(pattern, line, re.IGNORECASE):
                        # Skip if already inside a link
                        if self.is_inside_link(line, match.start(), match.end()):
                            continue

                        # Skip if in backticks (will be handled separately if needed)
                        before = line[:match.start()]
                        if before.count('`') % 2 == 1:  # Inside inline code
                            continue

                        original = match.group(0)
                        linked = f"[{original}]({url})"

                        refs.append(Reference(
                            original=original,
                            linked=linked,
                            line_num=line_num,
                            ref_type='library',
                            context=line.strip()[:80],
                            position=match.start()
                        ))

        return refs

    def find_unlinked_tools(self, content: str, lines: list[str]) -> list[Reference]:
        """Find tool names that aren't linked."""
        refs = []

        for line_num, line in enumerate(lines, 1):
            if self.is_inside_code_block(lines, line_num - 1):
                continue

            for tool_lower, (tool_name, url) in self.tool_patterns.items():
                pattern = rf'\b{re.escape(tool_name)}\b'
                for match in re.finditer(pattern, line, re.IGNORECASE):
                    if self.is_inside_link(line, match.start(), match.end()):
                        continue

                    # Skip if in backticks
                    before = line[:match.start()]
                    if before.count('`') % 2 == 1:
                        continue

                    original = match.group(0)
                    linked = f"[{original}]({url})"

                    refs.append(Reference(
                        original=original,
                        linked=linked,
                        line_num=line_num,
                        ref_type='tool',
                        context=line.strip()[:80],
                        position=match.start()
                    ))

        return refs

    def process_file(self, file_path: Path, apply: bool = False) -> list[Reference]:
        """Process a single markdown file."""
        content = file_path.read_text()
        lines = content.split('\n')

        context = self.detect_framework_context(file_path)

        all_refs = []
        all_refs.extend(self.find_unlinked_files(content, lines, context))
        all_refs.extend(self.find_unlinked_libraries(content, lines))
        all_refs.extend(self.find_unlinked_tools(content, lines))

        # Deduplicate by (line_num, original)
        seen = set()
        unique_refs = []
        for ref in all_refs:
            key = (ref.line_num, ref.original)
            if key not in seen:
                seen.add(key)
                unique_refs.append(ref)

        if apply and unique_refs:
            # Apply replacements using position-based replacement
            # Process from end to start (by position) to preserve earlier positions
            new_lines = lines.copy()

            # Group refs by line number
            refs_by_line = {}
            for ref in unique_refs:
                refs_by_line.setdefault(ref.line_num, []).append(ref)

            for line_num, line_refs in refs_by_line.items():
                line_idx = line_num - 1
                line = new_lines[line_idx]

                # Sort by position descending (replace from end to start)
                for ref in sorted(line_refs, key=lambda r: r.position, reverse=True):
                    # Replace at the specific position
                    pos = ref.position
                    end_pos = pos + len(ref.original)
                    line = line[:pos] + ref.linked + line[end_pos:]

                new_lines[line_idx] = line

            file_path.write_text('\n'.join(new_lines))

        return unique_refs


def main():
    parser = argparse.ArgumentParser(description='Link references in markdown files')
    parser.add_argument('path', type=Path, help='File or directory to process')
    parser.add_argument('--apply', action='store_true', help='Apply changes (default: preview only)')
    parser.add_argument('--recursive', '-r', action='store_true', help='Process directories recursively')
    parser.add_argument('--registry', type=Path, default=Path(__file__).parent.parent / 'references.json',
                       help='Path to references.json registry')

    args = parser.parse_args()

    if not args.registry.exists():
        print(f"Error: Registry not found at {args.registry}", file=sys.stderr)
        sys.exit(1)

    linker = ReferenceLinker(args.registry)

    # Collect files to process
    if args.path.is_file():
        files = [args.path]
    elif args.path.is_dir():
        if args.recursive:
            files = list(args.path.rglob('*.md'))
        else:
            files = list(args.path.glob('*.md'))
    else:
        print(f"Error: {args.path} does not exist", file=sys.stderr)
        sys.exit(1)

    total_refs = 0
    for file_path in sorted(files):
        refs = linker.process_file(file_path, apply=args.apply)
        if refs:
            print(f"\n{'=' * 60}")
            print(f"📄 {file_path.relative_to(args.path.parent) if args.path.is_dir() else file_path.name}")
            print(f"{'=' * 60}")

            for ref in refs:
                icon = {'file': '📁', 'library': '📚', 'tool': '🔧'}.get(ref.ref_type, '📎')
                status = '✅' if args.apply else '🔍'
                print(f"  {status} {icon} Line {ref.line_num}: {ref.original}")
                print(f"       → {ref.linked}")

            total_refs += len(refs)

    print(f"\n{'=' * 60}")
    if args.apply:
        print(f"✅ Applied {total_refs} link(s) across {len(files)} file(s)")
    else:
        print(f"🔍 Found {total_refs} unlinked reference(s) across {len(files)} file(s)")
        if total_refs > 0:
            print(f"   Run with --apply to add links")


if __name__ == '__main__':
    main()
