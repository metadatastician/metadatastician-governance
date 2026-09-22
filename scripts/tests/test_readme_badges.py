# SPDX-License-Identifier: MPL-2.0
"""Regression tests for the compliance badges in README.adoc."""

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
README = (REPOSITORY_ROOT / "README.adoc").read_text(encoding="utf-8")
COMPLIANCE_BLOCK = README.split("// Compliance\n", maxsplit=1)[1].split(
    "\n\n", maxsplit=1
)[0]


class ReadmeBadgeTests(unittest.TestCase):
    def test_unrelated_best_practices_badge_is_absent(self) -> None:
        readme_casefolded = README.casefold()

        self.assertNotIn("bestpractices.dev", readme_casefolded)
        self.assertNotIn("openssf best practices", readme_casefolded)
        self.assertNotIn("/projects/8509", readme_casefolded)

    def test_repository_scorecard_badge_is_preserved(self) -> None:
        expected_badge = (
            "image:https://api.scorecard.dev/projects/github.com/metadatastician/"
            "metadatastician-governance/badge[OpenSSF Scorecard,"
            'link="https://scorecard.dev/viewer/?uri=github.com/metadatastician/'
            'metadatastician-governance"]'
        )

        self.assertEqual(COMPLIANCE_BLOCK.count(expected_badge), 1)
        self.assertEqual(COMPLIANCE_BLOCK.casefold().count("openssf"), 1)

    def test_compliance_badges_remain_separated_from_status(self) -> None:
        _, content_after_compliance = README.split("// Compliance\n", maxsplit=1)
        _, content_after_badges = content_after_compliance.split("\n\n", maxsplit=1)

        self.assertTrue(content_after_badges.startswith("Status: "))


if __name__ == "__main__":
    unittest.main()
