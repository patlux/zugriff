#!/usr/bin/env python3
"""Generates src/core/emoji_data.zig from pinned public sources.

Zugriff never loads emoji data at run time: the table is compiled into the
binary. This script is the only way that table changes.

Sources (downloaded into --sources, or read from there if present):

- Unicode emoji-test.txt 16.0: the emoji, their order, groups and skin tones
- Unicode CLDR 47 annotations and derived annotations, German and English:
  names and search keywords
- GitHub gemoji 4.1.0: shortcodes such as :joy:

Usage:
    python3 scripts/emoji_data.py --sources /tmp/zugriff-emoji-sources
    python3 scripts/emoji_data.py --from-rust ../zugriff-menu/crates/zugriff-core/src/emoji/data.rs
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "src/core/emoji_data.zig"

CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/47.0.0/cldr-json"
SOURCES = {
    "emoji-test.txt": "https://unicode.org/Public/emoji/16.0/emoji-test.txt",
    "annotations-de.json": f"{CLDR}/cldr-annotations-full/annotations/de/annotations.json",
    "annotations-en.json": f"{CLDR}/cldr-annotations-full/annotations/en/annotations.json",
    "annotationsDerived-de.json": f"{CLDR}/cldr-annotations-derived-full/annotationsDerived/de/annotations.json",
    "annotationsDerived-en.json": f"{CLDR}/cldr-annotations-derived-full/annotationsDerived/en/annotations.json",
    "gemoji.json": "https://raw.githubusercontent.com/github/gemoji/v4.1.0/db/emoji.json",
}

GROUPS = {
    "Smileys & Emotion": "Smileys",
    "People & Body": "People",
    "Animals & Nature": "Animals",
    "Food & Drink": "Food",
    "Travel & Places": "Travel",
    "Activities": "Activities",
    "Objects": "Objects",
    "Symbols": "Symbols",
    "Flags": "Flags",
}

TONES = [
    "light skin tone",
    "medium-light skin tone",
    "medium skin tone",
    "medium-dark skin tone",
    "dark skin tone",
]
TONE_MODIFIERS = {chr(code) for code in range(0x1F3FB, 0x1F400)}


def fetch(sources: pathlib.Path) -> None:
    sources.mkdir(parents=True, exist_ok=True)
    for name, url in SOURCES.items():
        target = sources / name
        if not target.exists():
            print(f"lade {url}")
            with urllib.request.urlopen(url, timeout=60) as response:
                target.write_bytes(response.read())


def fold(text: str) -> str:
    """Lowercase without umlauts, so `tranen` finds `Tränen`."""
    text = text.lower()
    for umlaut, plain in (("ä", "a"), ("ö", "o"), ("ü", "u"), ("ß", "ss")):
        text = text.replace(umlaut, plain)
    return text


def key(glyph: str) -> str:
    """CLDR and gemoji drop the emoji presentation selector."""
    return glyph.replace("\ufe0f", "")


def annotations(sources: pathlib.Path, language: str) -> dict[str, dict]:
    plain = json.loads((sources / f"annotations-{language}.json").read_text())
    derived = json.loads((sources / f"annotationsDerived-{language}.json").read_text())
    merged = dict(derived["annotationsDerived"]["annotations"])
    merged.update(plain["annotations"]["annotations"])
    return merged


def parse_test(sources: pathlib.Path) -> list[tuple[str, str, str]]:
    """(glyph, group, English name) of every fully-qualified emoji, in order."""
    rows = []
    group = None
    for line in (sources / "emoji-test.txt").read_text().splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if not line or line.startswith("#"):
            continue
        codes, rest = line.split(";", 1)
        status, comment = rest.split("#", 1)
        if status.strip() != "fully-qualified":
            continue
        glyph = "".join(chr(int(code, 16)) for code in codes.split())
        # "😀 E1.0 grinning face"
        name = comment.strip().split(" ", 2)[2]
        rows.append((glyph, group, name))
    return rows


def zig_string(text: str) -> str:
    """A Zig string literal: UTF-8 as is, quotes, backslashes and controls escaped."""
    out = []
    for char in text:
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif ord(char) < 0x20:
            out.append(f"\\x{ord(char):02x}")
        else:
            out.append(char)
    return '"' + "".join(out) + '"'


# Lines stay under ziglint's 120 bytes: long fields are split at their
# `|` separators into pieces joined with `++` (comptime concatenation).
PIECE_BYTES = 80


def zig_field(name: str, value: str) -> list[str]:
    pieces = [""]
    for word in value.split("|"):
        sep = "|" if pieces[-1] or len(pieces) > 1 else ""
        candidate = pieces[-1] + sep + word
        if pieces[-1] and len(candidate.encode()) > PIECE_BYTES:
            pieces[-1] += "|"
            pieces.append(word)
        else:
            pieces[-1] = candidate
    if len(pieces) == 1:
        return [f"        .{name} = {zig_string(pieces[0])},"]
    lines = [f"        .{name} = {zig_string(pieces[0])} ++"]
    for piece in pieces[1:-1]:
        lines.append(f"            {zig_string(piece)} ++")
    lines.append(f"            {zig_string(pieces[-1])},")
    return lines


def render_zig(entries: list[dict]) -> str:
    lines = [
        "// Generated by scripts/emoji_data.py from Unicode emoji 16.0, CLDR 47 (de, en)",
        "// and gemoji 4.1.0. Do not edit by hand; run the script instead.",
        'const Emoji = @import("emoji.zig").Emoji;',
        "",
        f"pub const table = [{len(entries)}]Emoji{{",
    ]
    for entry in entries:
        lines.append("    .{")
        lines.append(f"        .glyph = {zig_string(entry['glyph'])},")
        lines.append(f"        .group = .{entry['group'].lower()},")
        for name in ("name", "folded", "keywords", "english", "codes"):
            lines.extend(zig_field(name, entry[name]))
        if entry["tones"]:
            lines.append("        .tones = .{")
            lines.extend(f"            {zig_string(tone)}," for tone in entry["tones"])
            lines.append("        },")
        else:
            lines.append("        .tones = null,")
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines) + "\n"


def from_rust(path: pathlib.Path) -> list[dict]:
    """The entries of zugriff-menu's generated `emoji/data.rs` (the same sources)."""
    string = r'"(?:[^"\\]|\\.)*"'
    entries = []
    for block in re.findall(r"Emoji \{(.*?)\n    \}", path.read_text(), re.S):
        entry = {}
        for name in ("glyph", "name", "folded", "keywords", "english", "codes"):
            entry[name] = json.loads(re.search(name + r": (" + string + ")", block).group(1))
        entry["group"] = re.search(r"group: Group::(\w+)", block).group(1)
        tones = re.search(r"tones: (None|Some\(\[(.*?)\]\))", block, re.S)
        entry["tones"] = None if tones.group(1) == "None" else [json.loads(t) for t in re.findall(string, tones.group(2))]
        entries.append(entry)
    return entries


def write(entries: list[dict]) -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(render_zig(entries))
    toned = sum(1 for entry in entries if entry["tones"])
    print(f"{len(entries)} Emoji, {toned} mit Hauttönen -> {OUTPUT.relative_to(ROOT)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sources", type=pathlib.Path, help="folder for the downloaded sources")
    parser.add_argument("--from-rust", type=pathlib.Path, help="read the entries from zugriff-menu's emoji/data.rs instead")
    arguments = parser.parse_args()
    if arguments.from_rust:
        write(from_rust(arguments.from_rust))
        return
    if not arguments.sources:
        parser.error("--sources or --from-rust is required")

    fetch(arguments.sources)
    german = annotations(arguments.sources, "de")
    english = annotations(arguments.sources, "en")
    gemoji = {
        key(entry["emoji"]): entry["aliases"]
        for entry in json.loads((arguments.sources / "gemoji.json").read_text())
    }

    rows = parse_test(arguments.sources)
    by_name = {name: glyph for glyph, _, name in rows}

    entries = []
    missing = []
    for glyph, group, name in rows:
        if group not in GROUPS or TONE_MODIFIERS & set(glyph):
            continue
        de = german.get(key(glyph))
        en = english.get(key(glyph)) or {"tts": [name]}
        if de is None:
            # Newer than CLDR 47 (the Sark flag): the English name stands in
            # rather than dropping the emoji.
            missing.append(f"{glyph} {name}")
            de = en

        tones = [by_name.get(f"{name}: {tone}") for tone in TONES]
        if any(tones) and not all(tones):
            raise SystemExit(f"{name}: nur einige Hauttöne gefunden")

        de_name = de["tts"][0]
        de_keywords = [word for word in de.get("default", []) if fold(word) != fold(de_name)]
        en_name = en["tts"][0]
        en_keywords = [word for word in en.get("default", []) if fold(word) != fold(en_name)]
        entries.append(
            {
                "glyph": glyph,
                "group": GROUPS[group],
                "name": de_name,
                "folded": fold(de_name),
                "keywords": "|".join(fold(word) for word in de_keywords),
                "english": "|".join(fold(word) for word in [en_name, *en_keywords]),
                "codes": "|".join(gemoji.get(key(glyph), [])),
                "tones": tones if all(tones) else None,
            }
        )

    if len(missing) > 5:
        raise SystemExit("ohne deutschen CLDR-Namen: " + ", ".join(missing))
    for entry in missing:
        print(f"ohne deutschen CLDR-Namen, englisch übernommen: {entry}")
    write(entries)


if __name__ == "__main__":
    main()
