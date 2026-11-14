#!/usr/bin/env python3
"""Small, dependency-free changesets for Zugriff (Python 3.11+).

Markdown notes, a commit hook, and a local SemVer release command.
The `.version` line of build.zig.zon is the single product version.
Adapted from Tikitaka's tool; see THIRD_PARTY_NOTICES.md for license and copyright notices.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import secrets
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[1]
CHANGESET_DIR = ".changeset"
RELEASE_BRANCH = "main"
TYPES = {"added": "Added", "changed": "Changed", "fixed": "Fixed", "removed": "Removed"}
BUMPS = ("patch", "minor", "major")
VERSION_RE = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", re.ASCII)
# The package manifest holds the version; build.zig reads it with @import("build.zig.zon").version.
VERSION_FILE = "build.zig.zon"
VERSION_LINE_RE = re.compile(r'^(?P<head>[ \t]*\.version[ \t]*=[ \t]*")(?P<version>[^"\n]*)(?P<tail>",[ \t]*)$',
                             re.MULTILINE)
CHANGELOG_HEADER = """# Changelog

Versions follow SemVer. Entries come from the Markdown changesets in `.changeset/`.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the local release workflow.
"""


class ChangesetError(Exception):
    """A user-facing failure; printed without a traceback."""


@dataclass(frozen=True)
class Changeset:
    name: str
    type: str | None
    bump: str | None
    summary: str


def parse_changeset(name: str, text: str) -> Changeset:
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        raise ChangesetError(f"{name}: must start with a '---' frontmatter line")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise ChangesetError(f"{name}: frontmatter is not closed with '---'") from None
    fields: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip():
            continue
        key, sep, value = line.partition(":")
        key = key.strip()
        if not sep or key not in {"type", "bump"} or key in fields:
            raise ChangesetError(f"{name}: expected unique 'type' and 'bump' fields, got {line!r}")
        fields[key] = value.strip().strip("\"'")
    summary = "\n".join(lines[end + 1 :]).strip()
    if not fields and not summary:
        return Changeset(name, None, None, "")
    if fields.get("type") not in TYPES or fields.get("bump") not in BUMPS or not summary:
        raise ChangesetError(
            f"{name}: needs type ({', '.join(TYPES)}), bump ({', '.join(BUMPS)}) and a summary"
        )
    return Changeset(name, fields["type"], fields["bump"], summary)


def is_changeset_path(path: str) -> bool:
    directory, _, name = path.partition("/")
    return directory == CHANGESET_DIR and "/" not in name and name.endswith(".md") and name != "README.md"


def pending(root: Path) -> list[Changeset]:
    files = sorted(p for p in (root / CHANGESET_DIR).glob("*.md") if p.name != "README.md")
    for path in files:
        if path.is_symlink():
            raise ChangesetError(f"{path}: changesets must not be symlinks")
    return [parse_changeset(p.name, p.read_text(encoding="utf-8")) for p in files]


def next_version(previous: str, changesets: list[Changeset]) -> str | None:
    match = VERSION_RE.fullmatch(previous)
    if not match:
        raise ChangesetError(f"unsupported version {previous!r}; expected stable SemVer X.Y.Z")
    bumps = [BUMPS.index(c.bump) for c in changesets if c.bump]
    if not bumps:
        return None
    major, minor, patch = map(int, match.groups())
    bump = max(bumps)
    if bump == 2:
        return f"{major + 1}.0.0"
    if bump == 1:
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def version_line(text: str) -> re.Match[str]:
    matches = list(VERSION_LINE_RE.finditer(text))
    if len(matches) != 1:
        raise ChangesetError(f'{VERSION_FILE} must contain exactly one line `.version = "X.Y.Z",`')
    return matches[0]


def read_version(text: str) -> str:
    version = version_line(text)["version"]
    if not VERSION_RE.fullmatch(version):
        raise ChangesetError(f"{VERSION_FILE} .version must be one stable SemVer X.Y.Z, not {version!r}")
    return version


def with_version(text: str, version: str) -> str:
    """The manifest with only the version line changed."""
    match = version_line(text)
    return text[: match.start("version")] + version + text[match.end("version") :]


def slugify(text: str) -> str:
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")
    return slug[:48].rstrip("-") or "change"


def add(root: Path, kind: str | None, bump: str | None, summary: str, now: dt.datetime) -> Path:
    text = "---\n---\n" if kind is None else f"---\ntype: {kind}\nbump: {bump}\n---\n\n{summary.strip()}\n"
    if kind is None and (bump or summary):
        raise ChangesetError("an empty changeset takes no bump or summary")
    parse_changeset("new changeset", text)
    directory = root / CHANGESET_DIR
    directory.mkdir(exist_ok=True)
    stem = f"{now:%Y%m%d-%H%M%S}-{slugify(summary) if kind else 'empty'}"
    path = directory / f"{stem}.md"
    while path.exists():
        path = directory / f"{stem}-{secrets.token_hex(2)}.md"
    with path.open("x", encoding="utf-8") as file:
        file.write(text)
    return path


def changelog_section(version: str, changesets: list[Changeset], today: dt.date) -> str:
    parts = [f"## {version} - {today.isoformat()}\n"]
    for kind, title in TYPES.items():
        entries = [c for c in changesets if c.type == kind]
        if not entries:
            continue
        parts.append(f"\n### {title}\n\n")
        for entry in entries:
            first, *rest = entry.summary.split("\n")
            parts.append(f"- {first}\n")
            parts.extend(f"  {line}\n" if line.strip() else "\n" for line in rest)
    return "".join(parts)


def insert_section(changelog: str | None, section: str) -> str:
    text = changelog if changelog is not None else CHANGELOG_HEADER
    match = re.search(r"^## ", text, flags=re.MULTILINE)
    if match is None:
        return text.rstrip("\n") + "\n\n" + section
    return text[: match.start()] + section + "\n" + text[match.start() :]


def release_updates(
    read: Callable[[str], str], changesets: list[Changeset], today: dt.date
) -> tuple[str, dict[str, str]]:
    """Plan every output before touching files; also used to verify release commits."""
    manifest = read(VERSION_FILE)
    version = next_version(read_version(manifest), changesets)
    if version is None:
        raise ChangesetError("no changesets with notes are pending; nothing to release")
    changelog = read("CHANGELOG.md")
    if re.search(rf"^## {re.escape(version)}(?:\s|$)", changelog, flags=re.MULTILINE):
        raise ChangesetError(f"CHANGELOG.md already has a section {version}")
    return version, {
        VERSION_FILE: with_version(manifest, version),
        "CHANGELOG.md": insert_section(changelog, changelog_section(version, changesets, today)),
    }


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout


def release(root: Path, today: dt.date) -> str:
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD").strip()
    if branch != RELEASE_BRANCH:
        raise ChangesetError(f"versions are cut on {RELEASE_BRANCH} only (current branch: {branch})")
    if git(root, "status", "--porcelain", "--untracked-files=all").strip():
        raise ChangesetError("commit pending work and changesets first; version needs a clean working tree")
    changesets = pending(root)
    version, updates = release_updates(lambda path: (root / path).read_text(encoding="utf-8"), changesets, today)
    paths = [root / path for path in updates] + [root / CHANGESET_DIR / c.name for c in changesets]
    if any(path.is_symlink() for path in paths):
        raise ChangesetError("release files must not be symlinks")
    for path, text in updates.items():
        (root / path).write_text(text, encoding="utf-8")
    for changeset in changesets:
        (root / CHANGESET_DIR / changeset.name).unlink()
    return version


def amending(pid: int | None = None) -> bool:
    """Whether an ancestor is git commit --amend; Git does not tell hooks."""
    pid = os.getppid() if pid is None else pid
    for _ in range(32):
        if pid <= 1:
            return False
        result = subprocess.run(
            ["ps", "-o", "ppid=,command=", "-p", str(pid)], check=False, capture_output=True, text=True
        )
        fields = result.stdout.split()
        if len(fields) < 2:
            return False
        if Path(fields[1]).name == "git" and any(len(arg) >= 4 and "--amend".startswith(arg) for arg in fields[2:]):
            return True
        pid = int(fields[0])
    return False


def commit_base(root: Path, amend: bool = False) -> str:
    ref = "HEAD^" if amend else "HEAD"
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", ref], cwd=root, check=False, capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return subprocess.run(
        ["git", "hash-object", "-t", "tree", "--stdin"], cwd=root, input="", check=True, capture_output=True, text=True
    ).stdout.strip()


def check_release(root: Path, base: str, staged: dict[str, str]) -> str:
    if git(root, "rev-parse", "--abbrev-ref", "HEAD").strip() != RELEASE_BRANCH:
        raise ChangesetError(f"release commits belong on {RELEASE_BRANCH}")
    paths = [p for p in git(root, "ls-tree", "-r", "--name-only", "-z", base, CHANGESET_DIR).split("\0")
             if is_changeset_path(p)]
    changesets = [parse_changeset(Path(p).name, git(root, "show", f"{base}:{p}")) for p in paths]
    changelog = git(root, "show", ":CHANGELOG.md")
    header = re.search(r"^## \d+\.\d+\.\d+ - (\d{4}-\d{2}-\d{2})$", changelog, re.MULTILINE)
    if header is None:
        raise ChangesetError("release needs a dated changelog section; use make version")
    try:
        today = dt.date.fromisoformat(header[1])
    except ValueError as error:
        raise ChangesetError("invalid changelog release date") from error
    version, updates = release_updates(lambda path: git(root, "show", f"{base}:{path}"), changesets, today)
    if set(staged) != set(updates) | set(paths) or any(staged[p] != "D" for p in paths):
        raise ChangesetError(
            f"release commit must contain only the version line of {VERSION_FILE}, the changelog "
            "and all consumed changesets"
        )
    for path, expected in updates.items():
        if git(root, "show", f":{path}") != expected:
            raise ChangesetError(f"staged {path} does not match pending changesets; use make version")
    return f"release {version}"


def check_staged(root: Path, base: str | None = None) -> str:
    base = base or commit_base(root)
    entries = git(root, "diff", "--cached", "--name-status", "--no-renames", "-z", base).split("\0")
    staged = dict(zip(entries[1::2], entries[0::2]))
    for path, status in staged.items():
        if status != "D" and is_changeset_path(path):
            if not git(root, "ls-files", "--stage", "--", path).startswith("100644 "):
                raise ChangesetError(f"{path}: changesets must be regular non-executable files")
            parse_changeset(path, git(root, "show", f":{path}"))
    merge_head = Path(git(root, "rev-parse", "--git-path", "MERGE_HEAD").strip())
    if (merge_head if merge_head.is_absolute() else root / merge_head).exists():
        return "merge commit; changesets come from the merged branches"
    # A version change must be a real release, even if someone adds an empty note.
    if staged.get(VERSION_FILE) == "D":
        raise ChangesetError(f"{VERSION_FILE} cannot be deleted")
    if VERSION_FILE in staged:
        if not git(root, "ls-files", "--stage", "--", VERSION_FILE).startswith("100644 "):
            raise ChangesetError(f"{VERSION_FILE} must be a regular non-executable file")
        current = read_version(git(root, "show", f":{VERSION_FILE}"))
        old = subprocess.run(["git", "show", f"{base}:{VERSION_FILE}"], cwd=root, capture_output=True, text=True)
        if old.returncode == 0 and read_version(old.stdout) != current:
            return check_release(root, base, staged)
    if any(status == "D" and is_changeset_path(path) for path, status in staged.items()):
        raise ChangesetError("pending changesets are only consumed by a release; keep them until make version")
    added = [p for p, status in staged.items() if status == "A" and is_changeset_path(p)]
    if added:
        return f"changeset: {', '.join(added)}"
    raise ChangesetError(
        "this commit has no changeset (see CONTRIBUTING.md). Describe the change and stage the file:\n"
        "  make changeset\n"
        "  python3 scripts/changeset.py add --type fixed --bump patch 'What changed'\n"
        "  python3 scripts/changeset.py add --empty   # deliberately without release notes\n"
        "Then stage the new file with the change."
    )


def install_hook(root: Path) -> Path:
    """Do not replace an existing hook or redirect a configured hook manager."""
    configured = subprocess.run(["git", "config", "--get", "core.hooksPath"], cwd=root, capture_output=True, text=True)
    if configured.returncode == 0:
        raise ChangesetError("core.hooksPath is already configured; integrate check-staged into that hook instead")
    hook = Path(git(root, "rev-parse", "--git-path", "hooks/pre-commit").strip())
    hook = hook if hook.is_absolute() else root / hook
    source = (root / ".githooks/pre-commit").read_text(encoding="utf-8")
    if hook.is_symlink() or (hook.exists() and hook.read_text(encoding="utf-8") != source):
        raise ChangesetError(f"{hook}: existing hook left untouched; integrate check-staged manually")
    hook.parent.mkdir(parents=True, exist_ok=True)
    hook.write_text(source, encoding="utf-8")
    hook.chmod(0o755)
    return hook


def prompt(root: Path, now: dt.datetime) -> Path:
    if not sys.stdin.isatty():
        raise ChangesetError("no terminal: pass --type, --bump and a summary, or --empty")
    kind = input(f"Type ({'/'.join(TYPES)}, or empty): ").strip()
    if kind == "empty":
        return add(root, None, None, "", now)
    bump = input("Bump (patch/minor/major): ").strip()
    summary = input("Summary for the changelog: ").strip()
    return add(root, kind, bump, summary, now)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    add_parser = commands.add_parser("add", help="write a changeset (interactive without arguments)")
    add_parser.add_argument("--type", "-t", choices=list(TYPES))
    add_parser.add_argument("--bump", "-b", choices=BUMPS)
    add_parser.add_argument("--empty", action="store_true", help="no release notes or version bump")
    add_parser.add_argument("summary", nargs="?", default="")
    commands.add_parser("status", help="validate pending changesets and preview the next version")
    commands.add_parser("version", help=f"prepare a local version on {RELEASE_BRANCH}; never commit, tag or push")
    commands.add_parser("check-staged", help="pre-commit: require a valid changeset in the staged commit")
    commands.add_parser("install-hook", help="install pre-commit without overwriting existing hooks")
    args = parser.parse_args(argv)
    try:
        if args.command == "add":
            now = dt.datetime.now().astimezone()
            if args.empty:
                if args.type or args.bump or args.summary:
                    raise ChangesetError("--empty takes no --type, --bump or summary")
                path = add(ROOT, None, None, "", now)
            elif args.type or args.bump or args.summary:
                if not (args.type and args.bump and args.summary):
                    raise ChangesetError("pass --type, --bump and a summary")
                path = add(ROOT, args.type, args.bump, args.summary, now)
            else:
                path = prompt(ROOT, now)
            print(f"Created {path}\nStage it with the commit: git add {path}")
        elif args.command == "status":
            changesets = pending(ROOT)
            for change in changesets:
                headline = change.summary.split("\n")[0] if change.type else "(empty)"
                print(f"{change.type or '-':8} {change.bump or '-':5} {headline}  [{change.name}]")
            current = read_version((ROOT / VERSION_FILE).read_text(encoding="utf-8"))
            version = next_version(current, changesets)
            print(f"{len(changesets)} pending; current {current}, next {version or 'none (no release notes)'}")
        elif args.command == "version":
            version = release(ROOT, dt.datetime.now().astimezone().date())
            print(f"Prepared {version} in {VERSION_FILE} and CHANGELOG.md; consumed pending changesets.")
            print(f"Review, test and commit separately: version bump to v{version}\nNo commit, tag or push was made.")
        elif args.command == "check-staged":
            root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
            print(f"changeset check: {check_staged(root, commit_base(root, amending()))}")
        elif args.command == "install-hook":
            print(f"Installed {install_hook(ROOT)}")
    except (ChangesetError, OSError, subprocess.CalledProcessError) as error:
        print(f"changeset: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
