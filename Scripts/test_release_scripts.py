"""Tests for the release scripts that run in the public repository's release
and preview workflows: release_notes.sh, release_version.sh, the argument
handling of check_app_store_signature.sh, and the shipped CHANGELOG.md.

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
ROOT = SCRIPTS.parent
# The public tree's own file; in the development repository it lives in the
# public overlay.
SHIPPED_CHANGELOG = next(
    (path for path in (ROOT / "CHANGELOG.md", ROOT / "Public" / "CHANGELOG.md") if path.is_file()),
    ROOT / "CHANGELOG.md",
)

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

    def test_an_empty_unreleased_section_above_the_release_is_ignored(self) -> None:
        changelog = "# Changelog\n\n## Unreleased\n\n## 0.1.0\n\nThe first public version.\n\n- One thing.\n"
        self.sync("aaaaaaa", changelog=changelog)
        self.git("tag", "v0.1.0")
        self.git("tag", "v0.2.0-rc.1")

        release = self.notes("v0.1.0")
        next_candidate = self.notes("v0.2.0-rc.1")

        self.assertEqual(release.returncode, 0, release.stderr)
        self.assertIn("The first public version.\n\n- One thing.", release.stdout)
        self.assertNotIn("Pre-release", release.stdout)
        # Nothing written for the next version yet: refused, not empty notes.
        self.assertNotEqual(next_candidate.returncode, 0)
        self.assertIn("no '## 0.2.0-rc.1' section", next_candidate.stderr)

    def test_the_shipped_changelog_has_the_first_releases_notes(self) -> None:
        self.sync("aaaaaaa", changelog=SHIPPED_CHANGELOG.read_text(encoding="utf-8"))
        self.git("tag", "v0.1.0")

        result = self.notes("v0.1.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("## KVoice 0.1.0\n\nThe first public version."), result.stdout[:200])
        self.assertNotIn("## Unreleased", result.stdout)

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


class CheckAppStoreSignatureArgumentTests(unittest.TestCase):
    """The option handling, which refuses before any codesign call, so it
    runs anywhere; the checks themselves need a signed bundle."""

    def check(self, *args: str) -> subprocess.CompletedProcess[str]:
        return run(["sh", str(SCRIPTS / "check_app_store_signature.sh"), *args], SCRIPTS)

    def test_developer_id_and_pcc_exclude_each_other(self) -> None:
        for order in (("--pcc", "--developer-id"), ("--developer-id", "--pcc")):
            with self.subTest(order=order):
                result = self.check(*order, "kvoice.app")
                self.assertEqual(result.returncode, 2)
                self.assertIn("exclude each other", result.stderr)

    def test_an_unknown_option_is_refused(self) -> None:
        result = self.check("--developer", "kvoice.app")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown option --developer", result.stderr)

    def test_each_mode_still_needs_a_bundle(self) -> None:
        for mode in ((), ("--pcc",), ("--developer-id",)):
            with self.subTest(mode=mode):
                result = self.check(*mode, "no-such.app")
                self.assertEqual(result.returncode, 2)
                self.assertIn("no app bundle at no-such.app", result.stderr)


WORKFLOWS = next(
    (path for path in (ROOT / ".github" / "workflows", ROOT / "Public" / ".github" / "workflows")
     if (path / "preview.yml").is_file()),
    ROOT / ".github" / "workflows",
)


class ArchiveAppStoreScriptTests(unittest.TestCase):
    """The installer identity is found, not assumed.

    Apple issues it as "3rd Party Mac Developer Installer" or "Mac Installer
    Distribution", and exportArchive matches the name literally; the v0.1.0
    release failed on a hard-coded "Mac Installer Distribution".
    """

    def test_installer_identity_is_detected_from_the_keychain(self) -> None:
        script = (SCRIPTS / "archive_app_store.sh").read_text(encoding="utf-8")
        self.assertNotIn("installerSigningCertificate string Mac Installer Distribution", script)
        self.assertIn("installerSigningCertificate string $installer_identity", script)
        self.assertIn("3rd Party Mac Developer Installer|Mac Installer Distribution", script)


class PreviewWorkflowTests(unittest.TestCase):
    """preview.yml builds with the release's own steps and pins, by hand only,
    behind the release environment. Text checks: standard library only."""

    def text(self, name: str) -> str:
        return (WORKFLOWS / name).read_text(encoding="utf-8")

    def pins(self, text: str) -> set[str]:
        return {line.split("uses:", 1)[1].strip() for line in text.splitlines()
                if "uses:" in line and "@" in line}

    def test_both_workflows_build_the_dmg_with_the_shared_action(self) -> None:
        self.assertTrue((WORKFLOWS.parent / "actions" / "notarized-dmg" / "action.yml").is_file())
        self.assertEqual(self.text("release.yml").count("uses: ./.github/actions/notarized-dmg"), 1)
        preview = self.text("preview.yml")
        self.assertEqual(preview.count("uses: ./.github/actions/notarized-dmg"), 2)
        self.assertIn("configuration: Release", preview)
        self.assertIn("configuration: AppStore", preview)

    def test_the_preview_reuses_the_releases_action_pins(self) -> None:
        preview = self.pins(self.text("preview.yml"))
        self.assertTrue(preview)
        self.assertLessEqual(preview, self.pins(self.text("release.yml")))

    def test_the_preview_runs_by_hand_and_signs_only_behind_the_release_environment(self) -> None:
        preview = self.text("preview.yml")
        on = preview.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("workflow_dispatch:", on)
        for trigger in ("push:", "pull_request", "schedule:", "workflow_run:"):
            self.assertNotIn(trigger, on)
        self.assertEqual(preview.count("environment: release"), 2)
        cleanup = "if: always()\n        run: |\n          if [ -n \"${KVOICE_CI_KEYCHAIN:-}\" ]; then\n            ./Scripts/ci_remove_signing_identity.sh"
        self.assertEqual(preview.count(cleanup), 2)
        self.assertEqual(preview.count("kvoice-signing.*/kvoice-ci.keychain-db"), 2, "the fallback cleanup")
        self.assertEqual(self.text("release.yml").count(cleanup), 1)
        self.assertIn("needs: [version, developer-id]", preview, "the editions are built one after the other")
        self.assertIn("github.repository == 'kccarlos/kvoice'", preview)
        self.assertIn("refs/heads/main", preview)
        self.assertNotIn("KVOICE_PCC_ENTITLEMENT", preview)
        self.assertNotIn("APPLE_DISTRIBUTION", preview)
        self.assertNotIn("APP_STORE_PROFILE", preview)


# The App Store listing: `appstore/` in the public tree, the overlay's
# `Public/appstore/` here.
APPSTORE = next(
    (path for path in (ROOT / "appstore", ROOT / "Public" / "appstore") if path.is_dir()),
    ROOT / "appstore",
)


class AppStoreMetadataTests(unittest.TestCase):
    """App Store Connect's limits for the en-US listing, checked before the
    text is pasted (or uploaded) rather than when it is refused."""

    LIMITS = {
        "name.txt": 30,
        "subtitle.txt": 30,
        "promotional_text.txt": 170,
        "description.txt": 4000,
        "keywords.txt": 100,
        "release_notes.txt": 4000,
    }
    URLS = {
        "support_url.txt": "https://github.com/kccarlos/kvoice/issues",
        "marketing_url.txt": "https://github.com/kccarlos/kvoice",
        "privacy_url.txt": "https://github.com/kccarlos/kvoice/blob/main/PRIVACY.md",
    }

    def field(self, name: str, locale: str | None = "en-US") -> str:
        base = APPSTORE / "metadata"
        path = base / locale / name if locale else base / name
        return path.read_text(encoding="utf-8").rstrip("\n")

    def test_every_field_is_present_and_within_its_limit(self) -> None:
        for name, limit in self.LIMITS.items():
            with self.subTest(name):
                value = self.field(name)
                self.assertTrue(value.strip(), "empty")
                self.assertLessEqual(len(value), limit)
                self.assertEqual(value, value.strip(), "no leading or trailing blanks")
        self.assertNotIn("\n", self.field("name.txt"))
        self.assertNotIn("\n", self.field("subtitle.txt"))

    def test_keywords_are_comma_separated_without_spaces_or_repeats(self) -> None:
        keywords = self.field("keywords.txt")
        self.assertNotIn(", ", keywords)
        self.assertNotIn(" ,", keywords)
        words = keywords.split(",")
        self.assertTrue(all(words), "no empty keyword")
        self.assertEqual(len(words), len(set(w.lower() for w in words)), "no repeats")

    def test_urls_and_the_account_level_fields(self) -> None:
        for name, url in self.URLS.items():
            with self.subTest(name):
                self.assertEqual(self.field(name), url)
        self.assertEqual(self.field("copyright.txt", locale=None), "2026 kccarlos")
        self.assertEqual(self.field("primary_category.txt", locale=None), "PRODUCTIVITY")
        self.assertEqual(self.field("secondary_category.txt", locale=None), "UTILITIES")

    def test_the_listing_describes_the_store_edition_only(self) -> None:
        # Guideline 2.3.10: no pointer to another distribution in the
        # metadata; Private Cloud Compute is not available yet.
        listing = " ".join(self.field(name) for name in ("description.txt", "promotional_text.txt", "release_notes.txt", "subtitle.txt"))
        for phrase in ("github", "download the full", "Private Cloud Compute", "DMG", "Developer ID"):
            self.assertNotIn(phrase.lower(), listing.lower(), phrase)

    def test_the_listing_leads_with_dictation_and_ai_actions(self) -> None:
        # The headline is speak once, get finished text (dictation + AI
        # actions); the built-in actions are named as they ship.
        first = self.field("description.txt").split("\n", 1)[0].lower()
        self.assertIn("speak", first)
        self.assertIn("translation", first)
        self.assertIn("translate", self.field("keywords.txt").split(","))
        description = self.field("description.txt")
        for action in ("Clean Up", "Polish", "Message", "Notes", "Prompt", "Writing", "Email Draft",
                       "Summarize", "TODO List", "Q&A", "Terminal", "Translate"):
            self.assertIn(action, description, action)

    def test_review_notes_and_privacy_answers_exist(self) -> None:
        notes = (APPSTORE / "review_notes.txt").read_text(encoding="utf-8")
        self.assertLessEqual(len(notes), 4000, "App Review Information notes limit")
        self.assertIn("PostEvent", notes)
        self.assertIn("TextEdit", notes)
        privacy = (APPSTORE / "app_privacy.md").read_text(encoding="utf-8")
        self.assertIn("Data Not Collected", privacy)

    def test_screenshots_are_a_store_size_and_small(self) -> None:
        shots = sorted((APPSTORE / "screenshots" / "en-US").glob("*.*"))
        allowed = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}
        for shot in shots:
            with self.subTest(shot.name):
                self.assertIn(shot.suffix.lower(), {".png", ".jpg", ".jpeg"})
                self.assertLess(shot.stat().st_size, 1_000_000, "the export gate's per-file limit")
                self.assertIn(image_size(shot), allowed)


def image_size(path: Path) -> tuple[int, int]:
    """Width and height from a PNG's IHDR or a JPEG's SOF marker."""
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    index = 2
    while index < len(data):
        if data[index] != 0xFF:
            index += 1
            continue
        marker = data[index + 1]
        length = int.from_bytes(data[index + 2:index + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[index + 7:index + 9], "big"), int.from_bytes(data[index + 5:index + 7], "big")
        index += 2 + length
    raise ValueError(f"no image size in {path}")


if __name__ == "__main__":
    unittest.main()
