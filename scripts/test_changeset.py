"""Unit and real-Git integration tests; only disposable repositories are changed."""

from __future__ import annotations

import datetime as dt
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("changeset.py")
REPO = SCRIPT.parent.parent
_SPEC = importlib.util.spec_from_file_location("changeset", SCRIPT)
assert _SPEC and _SPEC.loader
changeset = importlib.util.module_from_spec(_SPEC)
sys.modules["changeset"] = changeset
_SPEC.loader.exec_module(changeset)
TODAY = dt.date(2026, 10, 5)
NOW = dt.datetime(2026, 10, 5, 9, 30, tzinfo=dt.UTC)
ZON = changeset.VERSION_FILE


def manifest(version: str = "1.1.7", extra: str = "") -> str:
    """A build.zig.zon in the shape of Zugriff's own, with a dependency carrying no version."""
    return (
        ".{\n"
        "    .name = .zugriff,\n"
        f'    .version = "{version}",\n'
        "    .dependencies = .{\n"
        "        .nanoui = .{\n"
        '            .url = "git+https://example.invalid/nanoui#0000",\n'
        '            .hash = "nanoui-0.14.4-abc",\n'
        "        },\n"
        "    },\n"
        f'    .minimum_zig_version = "0.17.1",{extra}\n'
        "    .fingerprint = 0x84910c26a45f0932,\n"
        "}\n"
    )


class ParseTests(unittest.TestCase):
    def test_typed_empty_and_crlf_notes(self) -> None:
        parsed = changeset.parse_changeset("a.md", '---\r\ntype: "fixed"\r\nbump: patch\r\n---\r\n\r\nKeep drafts.\r\n')
        self.assertEqual((parsed.type, parsed.bump, parsed.summary), ("fixed", "patch", "Keep drafts."))
        self.assertIsNone(changeset.parse_changeset("b.md", "---\n---\n").bump)

    def test_invalid_frontmatter_is_rejected(self) -> None:
        for text in (
            "no frontmatter", "---\ntype: fixed\n", "---\n---\nnotes without type\n",
            "---\ntype: fixed\n---\nSummary\n",
            "---\ntype: feature\nbump: patch\n---\nSummary\n",
            "---\ntype: fixed\nbump: huge\n---\nSummary\n",
            "---\ntype: fixed\nbump: patch\n---\n",
            "---\ntype: fixed\nbump: patch\nscope: app\n---\nSummary\n",
            "---\ntype: fixed\nbump: patch\nbump: major\n---\nSummary\n",
        ):
            with self.subTest(text=text), self.assertRaises(changeset.ChangesetError):
                changeset.parse_changeset("bad.md", text)

    def test_only_direct_markdown_notes_count(self) -> None:
        self.assertTrue(changeset.is_changeset_path(".changeset/a.md"))
        for path in (".changeset/README.md", ".changeset/nested/a.md", "other/a.md", ".changeset/a.txt"):
            self.assertFalse(changeset.is_changeset_path(path))

    def test_semver_highest_bump_wins(self) -> None:
        notes = [changeset.Changeset("empty.md", None, None, "")]
        self.assertIsNone(changeset.next_version("1.1.7", notes))
        for bump, expected in (("patch", "1.1.8"), ("minor", "1.2.0"), ("major", "2.0.0")):
            notes.append(changeset.Changeset(f"{bump}.md", "changed", bump, "Summary"))
            self.assertEqual(changeset.next_version("1.1.7", notes), expected)
        self.assertEqual(changeset.next_version("0.3.9", notes), "1.0.0")

    def test_invalid_or_prerelease_versions_fail_closed(self) -> None:
        for version in ("1.2", "01.2.3", "1.2.3-beta.1", "1.2.3+build", "2026.10.01-1", "1.2.3\n"):
            with self.subTest(version=version), self.assertRaises(changeset.ChangesetError):
                changeset.next_version(version, [])

    def test_manifest_has_exactly_one_stable_version_line(self) -> None:
        self.assertEqual(changeset.read_version(manifest("0.0.1")), "0.0.1")
        self.assertEqual(changeset.read_version('.{ .name = .x,\n.version = "2.3.4",\n}\n'), "2.3.4")
        for text in (
            manifest("1.2.3-beta.1"), manifest("v1.2.3"), manifest("01.2.3"), manifest(""),
            manifest().replace('    .version = "1.1.7",\n', ""),
            manifest(extra='\n    .version = "1.1.7",'),
            '.{ .name = .x, .version = "1.2.3" }\n',
        ):
            with self.subTest(text=text), self.assertRaises(changeset.ChangesetError):
                changeset.read_version(text)

    def test_with_version_changes_only_the_version_line(self) -> None:
        before = manifest("1.1.7")
        after = changeset.with_version(before, "1.2.0")
        self.assertEqual(after, manifest("1.2.0"))
        self.assertEqual([a for a, b in zip(before.splitlines(), after.splitlines()) if a != b],
                         ['    .version = "1.1.7",'])


class RepoTests(unittest.TestCase):
    def setUp(self) -> None:
        # Git hooks export index/repository variables. Never let fixtures use the
        # calling repository's index, hooks, signing configuration or worktree.
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self._env = patch.dict(os.environ, env, clear=True)
        self._env.start()
        self.addCleanup(self._env.stop)
        self._tmp = tempfile.TemporaryDirectory(prefix="zugriff-changeset-test-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.write(ZON, manifest())
        self.write("CHANGELOG.md", changeset.CHANGELOG_HEADER)
        self.write(".changeset/README.md", "Changeset instructions\n")
        self.write("scripts/changeset.py", SCRIPT.read_text())
        self.write(".githooks/pre-commit", (REPO / ".githooks/pre-commit").read_text())
        self.commit("init")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, text=True).stdout

    def cli(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(self.root / "scripts/changeset.py"), *args], cwd=self.root,
                              check=check, capture_output=True, text=True)

    def write(self, path: str, text: str) -> Path:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding="utf-8")
        return destination

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def note(self, kind: str = "fixed", bump: str = "patch", summary: str = "Keep drafts.") -> Path:
        return changeset.add(self.root, kind, bump, summary, NOW)

    def snapshot(self) -> dict[str, bytes]:
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*")
                if p.is_file() and ".git" not in p.relative_to(self.root).parts}

    def test_add_slug_collision_and_empty(self) -> None:
        first = self.note(summary="Frühstück für alle")
        second = self.note(summary="Frühstück für alle")
        self.assertEqual(first.name, "20261005-093000-fruhstuck-fur-alle.md")
        self.assertNotEqual(first, second)
        empty = changeset.add(self.root, None, None, "", NOW)
        self.assertEqual(empty.read_text(), "---\n---\n")
        with self.assertRaises(changeset.ChangesetError):
            changeset.add(self.root, None, "patch", "", NOW)

    def test_hook_requires_new_note_and_checks_index_not_worktree(self) -> None:
        self.write("src/main.zig", "one\n")
        self.git("add", "src/main.zig")
        with self.assertRaisesRegex(changeset.ChangesetError, "no changeset"):
            changeset.check_staged(self.root)
        path = self.note()
        self.git("add", ".changeset")
        path.write_text("invalid unstaged content")
        self.assertIn(path.name, changeset.check_staged(self.root))
        self.git("add", ".changeset")
        with self.assertRaises(changeset.ChangesetError):
            changeset.check_staged(self.root)

    def test_manifest_change_without_version_change_is_ordinary_work(self) -> None:
        # Pinning a new dependency touches build.zig.zon but is no release.
        self.write(ZON, manifest().replace("nanoui-0.14.4-abc", "nanoui-0.14.5-def"))
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, "no changeset"):
            changeset.check_staged(self.root)
        changeset.add(self.root, None, None, "", NOW)
        self.git("add", "-A")
        self.assertIn("changeset", changeset.check_staged(self.root))

    def test_modifying_an_old_note_does_not_replace_a_new_note(self) -> None:
        path = self.note()
        self.commit("change")
        path.write_text(path.read_text().replace("Keep drafts.", "New summary."))
        self.git("add", ".changeset")
        with self.assertRaisesRegex(changeset.ChangesetError, "no changeset"):
            changeset.check_staged(self.root)

    def test_invalid_modified_note_is_checked_even_with_new_empty_note(self) -> None:
        path = self.note()
        self.commit("change")
        path.write_text("invalid")
        changeset.add(self.root, None, None, "", NOW)
        self.git("add", ".changeset")
        with self.assertRaises(changeset.ChangesetError):
            changeset.check_staged(self.root)

    def test_real_hook_rejects_normal_commit_accepts_empty_and_amend(self) -> None:
        hook = changeset.install_hook(self.root)
        self.assertTrue(hook.stat().st_mode & 0o111)
        self.assertEqual(changeset.install_hook(self.root), hook)
        self.write("src/main.zig", "one\n")
        with self.assertRaises(subprocess.CalledProcessError) as rejected:
            self.commit("missing")
        self.assertIn("no changeset", rejected.exception.stderr)
        changeset.add(self.root, None, None, "", NOW)
        self.commit("intentional empty note")
        self.write("src/main.zig", "two\n")
        self.git("commit", "-q", "-a", "--amend", "--no-edit")
        self.assertEqual(self.git("show", "HEAD:src/main.zig"), "two\n")
        self.write("src/main.zig", "three\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.git("commit", "-q", "-a", "-m", "missing again")

    def test_hook_runs_from_a_linked_worktree(self) -> None:
        # Hooks live in the common .git; a worktree's commits are checked against its own index.
        changeset.install_hook(self.root)
        tree = self.root.parent / f"{self.root.name}-tree"
        self.git("worktree", "add", "-q", str(tree), "-b", "topic")
        self.addCleanup(lambda: self.git("worktree", "remove", "--force", str(tree)))
        (tree / "src").mkdir()
        (tree / "src/main.zig").write_text("one\n")
        changeset.git(tree, "add", "-A")
        with self.assertRaises(subprocess.CalledProcessError) as rejected:
            changeset.git(tree, "commit", "-q", "-m", "missing")
        self.assertIn("no changeset", rejected.exception.stderr)
        changeset.add(tree, None, None, "", NOW)
        changeset.git(tree, "add", "-A")
        changeset.git(tree, "commit", "-q", "-m", "with note")

    def test_root_commit_and_root_amend(self) -> None:
        root = self.root / "fresh"
        root.mkdir()
        changeset.git(root, "init", "-q", "-b", "main")
        changeset.git(root, "config", "user.email", "test@example.invalid")
        changeset.git(root, "config", "user.name", "Test")
        (root / "scripts").mkdir()
        (root / "scripts/changeset.py").write_text(SCRIPT.read_text())
        (root / ".git/hooks/pre-commit").write_text((REPO / ".githooks/pre-commit").read_text())
        (root / ".git/hooks/pre-commit").chmod(0o755)
        changeset.add(root, None, None, "", NOW)
        changeset.git(root, "add", "-A")
        changeset.git(root, "commit", "-q", "-m", "root")
        changeset.git(root, "commit", "-q", "--amend", "--no-edit")

    def test_existing_hook_and_hook_manager_are_preserved(self) -> None:
        hook = self.write(".git/hooks/pre-commit", "#!/bin/sh\nexit 7\n")
        with self.assertRaisesRegex(changeset.ChangesetError, "existing hook"):
            changeset.install_hook(self.root)
        self.assertEqual(hook.read_text(), "#!/bin/sh\nexit 7\n")
        self.git("config", "core.hooksPath", ".custom-hooks")
        with self.assertRaisesRegex(changeset.ChangesetError, "core.hooksPath"):
            changeset.install_hook(self.root)
        self.assertEqual(self.git("config", "--get", "core.hooksPath").strip(), ".custom-hooks")

    def test_symlink_note_is_rejected(self) -> None:
        (self.root / ".changeset/link.md").symlink_to("../CHANGELOG.md")
        self.git("add", ".changeset")
        with self.assertRaisesRegex(changeset.ChangesetError, "regular"):
            changeset.check_staged(self.root)
        with self.assertRaisesRegex(changeset.ChangesetError, "symlinks"):
            changeset.pending(self.root)

    def test_merge_commit_uses_branch_notes(self) -> None:
        changeset.install_hook(self.root)
        self.git("switch", "-q", "-c", "feature")
        self.note("added", "minor", "Feature.")
        self.write("src/feature.zig", "feature\n")
        self.commit("feature")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "--no-commit", "feature")
        self.assertIn("merge commit", changeset.check_staged(self.root))
        self.git("commit", "-q", "-m", "merge feature")

    def test_release_updates_version_line_and_preserves_changelog_history(self) -> None:
        changeset.install_hook(self.root)
        self.note()
        self.note("added", "minor", "Photos\nwith a cutout.")
        changeset.add(self.root, None, None, "", NOW)
        self.commit("changes")
        self.assertEqual(changeset.release(self.root, TODAY), "1.2.0")
        self.assertEqual(changeset.pending(self.root), [])
        self.assertTrue((self.root / ".changeset/README.md").exists())
        self.assertEqual((self.root / ZON).read_text(), manifest("1.2.0"))
        first = (self.root / "CHANGELOG.md").read_text()
        self.assertIn("### Added\n\n- Photos\n  with a cutout.\n\n### Fixed\n\n- Keep drafts.\n", first)
        self.git("add", "-A")
        self.assertEqual(changeset.check_staged(self.root), "release 1.2.0")
        self.git("commit", "-q", "-m", "version bump to v1.2.0")
        self.git("commit", "-q", "--amend", "--no-edit")
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "nothing to release"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)
        self.note("changed", "major", "Breaking change.")
        self.commit("breaking change")
        self.assertEqual(changeset.release(self.root, TODAY), "2.0.0")
        changelog = (self.root / "CHANGELOG.md").read_text()
        self.assertLess(changelog.index("## 2.0.0"), changelog.index("## 1.2.0"))
        self.assertTrue(changelog.endswith(first[first.index("## 1.2.0"):]))

    def test_release_rejects_empty_only_dirty_and_feature_branch_without_writes(self) -> None:
        changeset.add(self.root, None, None, "", NOW)
        self.commit("empty")
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "nothing to release"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)
        self.note()
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "clean working tree"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)
        self.commit("note")
        self.git("switch", "-q", "-c", "feature")
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "main only"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_version_and_duplicate_changelog_fail_before_writes(self) -> None:
        self.note()
        self.write(ZON, manifest("1.2.3-beta.1"))
        self.commit("invalid version")
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "stable SemVer"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)
        self.write(ZON, manifest())
        self.write("CHANGELOG.md", changeset.CHANGELOG_HEADER + "\n## 1.1.8 - 2026-10-04\n")
        self.commit("duplicate changelog")
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "already has a section"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)

    def test_release_exemption_rejects_unrelated_work_incomplete_bumps_and_wrong_notes(self) -> None:
        self.note()
        self.commit("change")
        changeset.release(self.root, TODAY)
        self.write("src/unrelated.zig", "unrelated\n")
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, "only the version line"):
            changeset.check_staged(self.root)
        (self.root / "src/unrelated.zig").unlink()
        self.git("add", "-A")
        self.write(ZON, manifest("1.1.9"))
        self.git("add", "-A")
        with self.assertRaises(changeset.ChangesetError):
            changeset.check_staged(self.root)
        self.write(ZON, manifest("1.1.8"))
        self.write("CHANGELOG.md", (self.root / "CHANGELOG.md").read_text().replace("Keep drafts.", "Invented note."))
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, "does not match"):
            changeset.check_staged(self.root)

    def test_release_commit_cannot_change_more_of_the_manifest(self) -> None:
        self.note()
        self.commit("change")
        changeset.release(self.root, TODAY)
        self.write(ZON, manifest("1.1.8").replace("nanoui-0.14.4-abc", "nanoui-0.14.5-def"))
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, f"staged {ZON} does not match"):
            changeset.check_staged(self.root)

    def test_invalid_note_fails_before_writes(self) -> None:
        path = self.note()
        path.write_text("invalid changeset")
        self.commit("invalid note")
        before = self.snapshot()
        with self.assertRaises(changeset.ChangesetError):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)

    def test_empty_note_cannot_hide_manual_version_bump(self) -> None:
        self.write(ZON, manifest("9.0.0"))
        changeset.add(self.root, None, None, "", NOW)
        self.git("add", "-A")
        with self.assertRaises(changeset.ChangesetError):
            changeset.check_staged(self.root)

    def test_manifest_deletion_is_not_an_internal_change(self) -> None:
        (self.root / ZON).unlink()
        changeset.add(self.root, None, None, "", NOW)
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, f"{ZON} cannot be deleted"):
            changeset.check_staged(self.root)

    def test_manifest_symlink_is_rejected_by_hook_and_release(self) -> None:
        self.note()
        self.write("manifest.zon", manifest())
        (self.root / ZON).unlink()
        (self.root / ZON).symlink_to("manifest.zon")
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, "regular"):
            changeset.check_staged(self.root)
        # Commit without installing a hook to exercise the release command too.
        self.commit("symlink fixture")
        before = self.snapshot()
        with self.assertRaisesRegex(changeset.ChangesetError, "symlinks"):
            changeset.release(self.root, TODAY)
        self.assertEqual(self.snapshot(), before)

    def test_pending_note_cannot_be_discarded_with_an_empty_note(self) -> None:
        path = self.note()
        self.commit("pending fix")
        path.unlink()
        changeset.add(self.root, None, None, "", NOW)
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, "only consumed by a release"):
            changeset.check_staged(self.root)

    def test_release_commit_rejects_feature_branch_and_unconsumed_note(self) -> None:
        path = self.note()
        note = path.read_text()
        self.commit("pending fix")
        changeset.release(self.root, TODAY)
        path.write_text(note)
        self.git("add", "-A")
        with self.assertRaisesRegex(changeset.ChangesetError, "all consumed changesets"):
            changeset.check_staged(self.root)
        path.unlink()
        self.git("add", "-A")
        self.git("switch", "-q", "-c", "feature")
        with self.assertRaisesRegex(changeset.ChangesetError, "belong on main"):
            changeset.check_staged(self.root)

    def test_merge_still_validates_notes(self) -> None:
        self.git("switch", "-q", "-c", "feature")
        path = self.note()
        self.commit("feature")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "--no-commit", "feature")
        path.write_text("invalid note")
        self.git("add", ".changeset")
        with self.assertRaises(changeset.ChangesetError):
            changeset.check_staged(self.root)

    def test_cli_add_status_version_and_failure_messages(self) -> None:
        self.assertIn("next none", self.cli("status").stdout)
        result = self.cli("add", "--type", "fixed", "--bump", "patch", "CLI fix.")
        self.assertIn("Created", result.stdout)
        self.assertIn("next 1.1.8", self.cli("status").stdout)
        self.commit("CLI change")
        result = self.cli("version")
        self.assertIn(f"Prepared 1.1.8 in {ZON}", result.stdout)
        self.assertIn("No commit, tag or push", result.stdout)
        for args in (("add", "--empty", "--bump", "patch"), ("add", "--type", "fixed", "missing bump"), ("add",)):
            result = self.cli(*args, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("Traceback", result.stderr)


class ProjectTests(unittest.TestCase):
    def test_real_project_plan_updates_only_the_version_line_and_changelog(self) -> None:
        note = changeset.Changeset("a.md", "fixed", "patch", "Test release.")
        version, updates = changeset.release_updates(lambda p: (REPO / p).read_text(), [note], TODAY)
        previous = changeset.read_version((REPO / ZON).read_text())
        self.assertEqual(version, changeset.next_version(previous, [note]))
        self.assertEqual(set(updates), {ZON, "CHANGELOG.md"})
        old_lines, new_lines = (REPO / ZON).read_text().splitlines(), updates[ZON].splitlines()
        self.assertEqual([(a, b) for a, b in zip(old_lines, new_lines) if a != b],
                         [(f'    .version = "{previous}",', f'    .version = "{version}",')])
        self.assertIn(f"## {version} - {TODAY}", updates["CHANGELOG.md"])


if __name__ == "__main__":
    unittest.main()
