"""Tests for the release scripts that run in the public repository's release
workflow: release_notes.sh and release_version.sh.

Standard library only. Each release-notes test builds a throwaway git
repository shaped like the public one (a CHANGELOG.md and `sync:` commits)
and runs the real script against it.

    python3 -m unittest Scripts.test_release_scripts
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent

CHANGELOG = """# Changelog

Notable changes to kvoice, for people who use it.

## Unreleased

- Something not released yet.

## 0.2.0 — 2026-10-01

- A new thing users notice.
- A fixed thing.

## 0.1.0 — 2026-09-30

- The first public version.
"""


def run(args: list[str], cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=False)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        (self.root / "Scripts").mkdir()
        shutil.copy(SCRIPTS / "release_notes.sh", self.root / "Scripts" / "release_notes.sh")
        self.env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "Example",
            "GIT_AUTHOR_EMAIL": "example@example.com",
            "GIT_COMMITTER_NAME": "Example",
            "GIT_COMMITTER_EMAIL": "example@example.com",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
        }
        self.git("init", "-q", "-b", "main")

    def tearDown(self) -> None:
        self._directory.cleanup()

    def git(self, *args: str) -> str:
        result = run(["git", *args], self.root, self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def sync(self, sha: str, body: str = "", changelog: str = CHANGELOG) -> None:
        (self.root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
        (self.root / "file.txt").write_text(sha, encoding="utf-8")
        self.git("add", "-A")
        message = f"sync: kvoice dev @ {sha}" + (f"\n\n{body}" if body else "")
        self.git("commit", "-q", "-m", message)

    def notes(self, tag: str, *extra: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return run(["sh", "Scripts/release_notes.sh", tag, *extra], self.root, {**self.env, **(env or {})})

    def test_the_versions_changelog_section_and_the_sync_commits_since_the_previous_tag(self) -> None:
        self.sync("aaaaaaa")
        self.git("tag", "v0.1.0")
        self.sync("bbbbbbb", body="Includes #12 by @someone")
        self.sync("ccccccc")
        self.git("tag", "v0.2.0")

        result = self.notes("v0.2.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertTrue(out.startswith("## KVoice 0.2.0\n"))
        self.assertIn("- A new thing users notice.", out)
        self.assertIn("- A fixed thing.", out)
        self.assertNotIn("The first public version", out, "only this version's section")
        self.assertNotIn("not released yet", out)
        self.assertIn("since v0.1.0", out)
        self.assertIn("- sync: kvoice dev @ bbbbbbb", out)
        self.assertIn("  Includes #12 by @someone", out, "the contributor credit is kept")
        self.assertIn("- sync: kvoice dev @ ccccccc", out)
        self.assertNotIn("aaaaaaa", out, "commits of the previous release are not repeated")
        self.assertLess(out.index("bbbbbbb"), out.index("ccccccc"), "oldest first")
        self.assertIn("Open Anyway", out, "not notarized unless told")

    def test_the_first_release_lists_every_sync_commit(self) -> None:
        self.sync("aaaaaaa")
        self.sync("bbbbbbb")
        self.git("tag", "v0.1.0")

        result = self.notes("v0.1.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("- The first public version.", result.stdout)
        self.assertIn("aaaaaaa", result.stdout)
        self.assertIn("bbbbbbb", result.stdout)

    def test_a_release_without_its_section_is_refused(self) -> None:
        self.sync("aaaaaaa")
        self.git("tag", "v0.3.0")

        result = self.notes("v0.3.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no '## 0.3.0' section", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_prerelease_falls_back_to_its_version_then_unreleased(self) -> None:
        self.sync("aaaaaaa")
        self.git("tag", "v0.2.0-rc.1")
        self.git("tag", "v0.9.0-rc.1")

        on_version = self.notes("v0.2.0-rc.1")
        on_unreleased = self.notes("v0.9.0-rc.1")

        self.assertEqual(on_version.returncode, 0, on_version.stderr)
        self.assertIn("- A new thing users notice.", on_version.stdout)
        self.assertIn("Pre-release", on_version.stdout)
        self.assertEqual(on_unreleased.returncode, 0, on_unreleased.stderr)
        self.assertIn("- Something not released yet.", on_unreleased.stdout)

    def test_the_checksum_and_the_notarized_install_note(self) -> None:
        self.sync("aaaaaaa")
        self.git("tag", "v0.1.0")
        sha = self.root / "KVoice-0.1.0.dmg.sha256"
        sha.write_text("0123abcd  KVoice-0.1.0.dmg\n", encoding="utf-8")

        result = self.notes("v0.1.0", str(sha), env={"KVOICE_NOTARIZED": "true"})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0123abcd  KVoice-0.1.0.dmg", result.stdout)
        self.assertIn("notarized by Apple", result.stdout)
        self.assertNotIn("Open Anyway", result.stdout)

    def test_an_unknown_tag_is_refused(self) -> None:
        self.sync("aaaaaaa")

        result = self.notes("v1.0.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no tag v1.0.0", result.stderr)


class ReleaseVersionTests(unittest.TestCase):
    def version(self, tag: str, build: str = "7") -> subprocess.CompletedProcess[str]:
        return run(["sh", str(SCRIPTS / "release_version.sh"), tag, build], SCRIPTS)

    def test_a_release_tag(self) -> None:
        result = self.version("v1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "KVOICE_MARKETING_VERSION=1.2.3",
                "KVOICE_STORE_VERSION=1.2.3",
                "KVOICE_BUILD_NUMBER=7",
                "KVOICE_PRERELEASE=false",
            ],
        )

    def test_a_prerelease_tag_keeps_dotted_integers_for_the_store(self) -> None:
        result = self.version("v1.2.3-rc.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KVOICE_MARKETING_VERSION=1.2.3-rc.1", result.stdout)
        self.assertIn("KVOICE_STORE_VERSION=1.2.3", result.stdout)
        self.assertIn("KVOICE_PRERELEASE=true", result.stdout)

    def test_malformed_input_is_refused(self) -> None:
        for tag, build in (("1.2.3", "7"), ("v1.2", "7"), ("v1.2.3", "seven")):
            with self.subTest(tag=tag, build=build):
                self.assertNotEqual(self.version(tag, build).returncode, 0)


if __name__ == "__main__":
    unittest.main()
