#!/usr/bin/env python3
"""Offline consistency check for the repository's Markdown documentation.

Verifies, without touching the network:

* every relative link in a tracked Markdown file points at a file or
  directory that exists in the repository;
* every in-repo anchor (`#section`, `OTHER.md#section`) names a heading or an
  explicit HTML anchor that exists in the target document, using GitHub's
  heading-slug rules;
* `CLAUDE.md` is still a symlink to `AGENTS.md`, the one file both kinds of
  coding agent read (see AGENTS.md).

External links (`https:`, `mailto:` and so on) are deliberately not checked:
whether a remote page is up is not something a pull request can fix, and a
flaky third-party server must never turn CI red.

Run from anywhere: `python3 .github/scripts/check-docs.py`. Exits non-zero and
lists every problem when something is broken. Standard library only.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]

# Inline links and images: [text](target "title"), ![alt](<target>).
INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)")
# Reference definitions: [id]: target "title"
REFERENCE_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
# Raw HTML links and anchors.
HTML_HREF = re.compile(r"""<a\s[^>]*?href\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
HTML_ANCHOR = re.compile(r"""<[a-z][^>]*?\s(?:id|name)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
ATX_HEADING = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT_UNDERLINE = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def tracked_markdown() -> list[Path]:
    output = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.md"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return [ROOT / name for name in output.split("\0") if name]


def prose_lines(text: str) -> list[tuple[int, str]]:
    """The document's lines outside fenced code blocks, numbered from 1."""
    lines: list[tuple[int, str]] = []
    fence: str | None = None
    for number, line in enumerate(text.splitlines(), start=1):
        match = FENCE.match(line)
        if fence is None:
            if match:
                fence = match.group(1)
                continue
            lines.append((number, line))
        elif match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence) \
                and not line.strip()[len(match.group(1)):].strip():
            fence = None
    return lines


def strip_code_spans(line: str) -> str:
    """Blanks out inline code so a `[x](y)` shown as code is not a link."""
    return re.sub(r"(`+)(?:(?!\1).)+?\1", lambda m: " " * len(m.group(0)), line)


def slugify(heading: str) -> str:
    """GitHub's anchor for a heading: rendered text, lowercased, with
    everything but letters, digits, `_`, `-` and spaces removed, and spaces
    turned into hyphens."""
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", heading)   # images → alt text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)       # links → link text
    text = re.sub(r"<[^>]+>", "", text)                         # inline HTML
    text = text.replace("`", "")
    text = re.sub(r"(\*+|(?<!\w)_+|_+(?!\w))", "", text)        # emphasis markers
    text = text.strip().lower()
    kept = []
    for char in text:
        category = unicodedata.category(char)
        if char in "-_ " or category[0] in "LN" or category == "Mn":
            kept.append(char)
    return "".join(kept).replace(" ", "-")


def anchors_of(path: Path, cache: dict[Path, set[str]]) -> set[str]:
    if path in cache:
        return cache[path]
    anchors: set[str] = set()
    seen: dict[str, int] = {}
    lines = prose_lines(path.read_text(encoding="utf-8"))
    for index, (_, line) in enumerate(lines):
        heading = None
        match = ATX_HEADING.match(line)
        if match:
            heading = match.group(2) or ""
        elif index + 1 < len(lines) and line.strip() and not line.lstrip().startswith(("-", "*", ">", "|")):
            following_number, following = lines[index + 1]
            # A setext underline must sit directly below its text; `---`
            # after a blank line is a thematic break, not a heading.
            if following_number == lines[index][0] + 1 and SETEXT_UNDERLINE.match(following):
                heading = line.strip()
        if heading is not None:
            slug = slugify(heading)
            count = seen.get(slug, 0)
            seen[slug] = count + 1
            anchors.add(slug if count == 0 else f"{slug}-{count}")
        for explicit in HTML_ANCHOR.findall(line):
            anchors.add(explicit)
    cache[path] = anchors
    return anchors


def links_in(path: Path) -> list[tuple[int, str]]:
    links: list[tuple[int, str]] = []
    for number, line in prose_lines(path.read_text(encoding="utf-8")):
        prose = strip_code_spans(line)
        targets = [m.group(1) for m in INLINE_LINK.finditer(prose)]
        targets += HTML_HREF.findall(prose)
        reference = REFERENCE_DEF.match(prose)
        if reference:
            targets.append(reference.group(1))
        for target in targets:
            links.append((number, target.strip("<>")))
    return links


def check_link(source: Path, target: str, cache: dict[Path, set[str]]) -> str | None:
    if SCHEME.match(target) or target.startswith("//"):
        return None  # external: not checked (see module docstring)
    file_part, _, anchor = target.partition("#")
    file_part = unquote(file_part.split("?", 1)[0])
    if file_part:
        if file_part.startswith("/"):
            resolved = (ROOT / file_part.lstrip("/")).resolve()
        else:
            resolved = (source.parent / file_part).resolve()
        if not resolved.is_relative_to(ROOT):
            return f"points outside the repository: {target}"
        if not resolved.exists():
            return f"broken link: {target}"
    else:
        resolved = source.resolve()
    if anchor:
        if resolved.is_dir() or resolved.suffix.lower() != ".md":
            return None  # GitHub line anchors (#L10) and the like: not checkable here
        if unquote(anchor) not in anchors_of(resolved, cache):
            return f"missing anchor: {target}"
    return None


def main() -> int:
    problems: list[str] = []

    claude = ROOT / "CLAUDE.md"
    if not claude.is_symlink():
        problems.append("CLAUDE.md: must be a symlink to AGENTS.md, but is not a symlink")
    elif os.readlink(claude) != "AGENTS.md":
        problems.append(f"CLAUDE.md: must be a symlink to AGENTS.md, but points to {os.readlink(claude)}")

    cache: dict[Path, set[str]] = {}
    documents = [path for path in tracked_markdown() if not path.is_symlink()]
    checked = 0
    for document in documents:
        for number, target in links_in(document):
            checked += 1
            problem = check_link(document, target, cache)
            if problem:
                problems.append(f"{document.relative_to(ROOT)}:{number}: {problem}")

    if problems:
        for problem in problems:
            print(f"::error::{problem}" if os.environ.get("GITHUB_ACTIONS") else problem)
        print(f"\n{len(problems)} documentation problem(s) found.", file=sys.stderr)
        return 1
    print(f"Docs OK: {len(documents)} Markdown files, {checked} links checked, CLAUDE.md -> AGENTS.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
