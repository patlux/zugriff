#!/usr/bin/env python3
"""Generates src/core/emoji_data.zig and emoji_strings.txt from pinned public sources.

Zugriff never loads emoji data at run time: the table is compiled into the
binary. This script is the only way that table changes.

Sources (downloaded into --sources, or read from there if present):

- Unicode emoji-test.txt 16.0: the emoji, their order, groups and skin tones
- Unicode CLDR 47 annotations and derived annotations, German and English:
  names (shown in the palette's language) and search keywords
- GitHub gemoji 4.1.0: shortcodes such as :joy:

Usage:
    python3 scripts/emoji_data.py --sources /tmp/zugriff-emoji-sources
    python3 scripts/emoji_data.py --from-rust ../zugriff-menu-rust/crates/zugriff-core/src/emoji/data.rs
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "src/core/emoji_data.zig"
STRINGS = ROOT / "src/core/emoji_strings.txt"

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


# One line per emoji in STRINGS: glyph, name, folded, keywords, english, codes,
# the English name as CLDR writes it and, for emoji with skin tones, the five toned glyphs, each followed by a tab
# and the last one by the newline. The Zig table holds only where a line starts
# and how long its fields are, so the binary keeps every text once and no
# slice headers.
FIELDS = ("glyph", "name", "folded", "keywords", "english", "codes", "english_name")
TONE_COUNT = 5
MAX_FIELD_BYTES = 0xFFFF  # the table stores lengths as u16


def fields(entry: dict) -> list[str]:
    values = [entry[name] for name in FIELDS] + (entry["tones"] or [])
    for value in values:
        if "\t" in value or "\n" in value:
            raise SystemExit(f"{entry['glyph']}: Tab oder Zeilenumbruch in {value!r}")
        if len(value.encode()) > MAX_FIELD_BYTES:
            raise SystemExit(f"{entry['glyph']}: Feld länger als {MAX_FIELD_BYTES} Bytes")
    return values


def render(entries: list[dict]) -> tuple[bytes, str]:
    """The text file and the Zig table that points into it."""
    strings = bytearray()
    records = []
    for entry in entries:
        values = [value.encode() for value in fields(entry)]
        lens = [len(value) for value in values] + [0] * (len(FIELDS) + TONE_COUNT - len(values))
        records.append(
            f"    .{{ .start = {len(strings)}, .group = .{entry['group'].lower()}, "
            f".lens = .{{ {', '.join(str(n) for n in lens)} }} }},"
        )
        strings += b"\t".join(values) + b"\n"
    if len(strings) > 0xFFFF_FFFF:
        raise SystemExit("emoji_strings.txt ist größer als 4 GiB")
    lines = [
        "// Generated by scripts/emoji_data.py from Unicode emoji 16.0, CLDR 47 (de, en)",
        "// and gemoji 4.1.0. Do not edit by hand; run the script instead.",
        'const Record = @import("emoji.zig").Record;',
        "",
        "/// One line per emoji, its fields separated by tabs.",
        f'pub const strings = @embedFile("{STRINGS.name}");',
        "",
        f"pub const table = [{len(entries)}]Record{{",
        *records,
        "};",
    ]
    return bytes(strings), "\n".join(lines) + "\n"


def from_rust(path: pathlib.Path) -> list[dict]:
    """The entries of zugriff-menu-rust's generated `emoji/data.rs` (the same sources)."""
    string = r'"(?:[^"\\]|\\.)*"'
    entries = []
    for block in re.findall(r"Emoji \{(.*?)\n    \}", path.read_text(), re.S):
        entry = {}
        for name in ("glyph", "name", "folded", "keywords", "english", "codes"):
            entry[name] = json.loads(re.search(name + r": (" + string + ")", block).group(1))
        # The Rust table keeps the English name folded only.
        entry["english_name"] = entry["english"].split("|", 1)[0]
        entry["group"] = re.search(r"group: Group::(\w+)", block).group(1)
        tones = re.search(r"tones: (None|Some\(\[(.*?)\]\))", block, re.S)
        entry["tones"] = None if tones.group(1) == "None" else [json.loads(t) for t in re.findall(string, tones.group(2))]
        entries.append(entry)
    return entries


def write(entries: list[dict]) -> None:
    strings, table = render(entries)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    STRINGS.write_bytes(strings)
    OUTPUT.write_text(table)
    toned = sum(1 for entry in entries if entry["tones"])
    print(
        f"{len(entries)} Emoji, {toned} mit Hauttönen -> "
        f"{OUTPUT.relative_to(ROOT)}, {STRINGS.relative_to(ROOT)}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sources", type=pathlib.Path, help="folder for the downloaded sources")
    parser.add_argument("--from-rust", type=pathlib.Path, help="read the entries from zugriff-menu-rust's emoji/data.rs instead")
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
                "english_name": en_name,
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
