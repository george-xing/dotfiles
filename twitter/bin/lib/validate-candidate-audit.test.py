#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-candidate-audit.py")


def write_audit(data):
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    with tmp:
        json.dump(data, tmp)
    return Path(tmp.name)


def candidate(**overrides):
    base = {
        "statusUrl": "https://x.com/example/status/1",
        "author": "Example",
        "timeISO": "2026-05-26T00:00:00Z",
        "text": "A useful post about coding agents.",
        "articleLink": None,
        "hardFiltered": False,
        "scores": {
            "importance": 4,
            "novelty": 3,
            "personal_relevance": 5,
            "substance": 4,
            "delight": 1,
            "total": 17,
        },
        "candidateLabels": ["AI", "coding_agents"],
        "selectedForDraft": True,
        "shipped": True,
        "section": "AI coding workflows",
        "rejectionReason": None,
        "cutReason": None,
        "scoreReason": "Concrete coding-agent workflow signal.",
    }
    base.update(overrides)
    return base


def audit_with(candidates):
    return {
        "runAt": "2026-05-26T00:00:00+00:00",
        "dryRun": False,
        "rawTileCount": len(candidates),
        "auditedTileCount": len(candidates),
        "candidateCount": len(candidates),
        "selectedForDraftCount": sum(1 for c in candidates if c.get("selectedForDraft")),
        "shippedCount": sum(1 for c in candidates if c.get("shipped")),
        "sectionNames": ["AI coding workflows"],
        "shippedUrls": [c["statusUrl"] for c in candidates if c.get("shipped")],
        "candidates": candidates,
    }


class ValidateCandidateAuditTest(unittest.TestCase):
    def run_validator(self, data):
        path = write_audit(data)
        try:
            return subprocess.run(
                [str(SCRIPT), str(path)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        finally:
            path.unlink(missing_ok=True)

    def test_valid_audit_passes(self):
        result = self.run_validator(audit_with([candidate()]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("warnings: 0", result.stdout)

    def test_soft_candidate_without_labels_warns(self):
        result = self.run_validator(audit_with([
            candidate(
                candidateLabels=[],
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="telegram_budget",
                cutReason=None,
            )
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("soft candidate has no labels", result.stdout)

    def test_empty_labels_allowed_only_for_low_substance_or_off_topic(self):
        result = self.run_validator(audit_with([
            candidate(
                candidateLabels=[],
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="marketing",
                cutReason=None,
                scores={
                    "importance": 1,
                    "novelty": 1,
                    "personal_relevance": 1,
                    "substance": 1,
                    "delight": 0,
                    "total": 4,
                },
            ),
            candidate(
                statusUrl="https://x.com/example/status/2",
                candidateLabels=[],
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="off_topic",
                cutReason=None,
                scores={
                    "importance": 1,
                    "novelty": 1,
                    "personal_relevance": 0,
                    "substance": 2,
                    "delight": 0,
                    "total": 4,
                },
            ),
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("soft candidate has no labels (Example, https://x.com/example/status/1)", result.stdout)
        self.assertNotIn("soft candidate has no labels (Example, https://x.com/example/status/2)", result.stdout)

    def test_shipped_selected_divergence_requires_cut_reason(self):
        result = self.run_validator(audit_with([
            candidate(shipped=False, cutReason=None)
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("selected for draft but not shipped without cutReason", result.stdout)

    def test_shipped_urls_must_match_shipped_candidates(self):
        data = audit_with([candidate()])
        data["shippedUrls"] = []

        result = self.run_validator(data)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("shippedUrls does not match shipped candidates", result.stdout)

    def test_personally_relevant_cut_warns(self):
        result = self.run_validator(audit_with([
            candidate(
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="lower_score_than_cluster",
                cutReason=None,
            )
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("high personal_relevance candidate rejected", result.stdout)

    def test_lower_score_than_cluster_requires_selected_label_overlap(self):
        result = self.run_validator(audit_with([
            candidate(
                statusUrl="https://x.com/example/status/1",
                candidateLabels=["AI", "coding_agents"],
                selectedForDraft=True,
                shipped=True,
                section="AI coding workflows",
            ),
            candidate(
                statusUrl="https://x.com/example/status/2",
                candidateLabels=["NYC", "food"],
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="lower_score_than_cluster",
                cutReason=None,
                scores={
                    "importance": 2,
                    "novelty": 2,
                    "personal_relevance": 2,
                    "substance": 2,
                    "delight": 1,
                    "total": 9,
                },
            ),
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("lower_score_than_cluster without selected-cluster label overlap", result.stdout)

    def test_high_personal_relevance_cut_before_delivery_warns(self):
        result = self.run_validator(audit_with([
            candidate(
                shipped=False,
                cutReason="telegram_budget",
            )
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("high personal_relevance candidate cut before delivery", result.stdout)

    def test_generic_only_labels_warn(self):
        result = self.run_validator(audit_with([
            candidate(
                candidateLabels=["random"],
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="weak_personal_fit",
                cutReason=None,
                scores={
                    "importance": 1,
                    "novelty": 1,
                    "personal_relevance": 1,
                    "substance": 2,
                    "delight": 2,
                    "total": 7,
                },
            )
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("candidate has only generic labels", result.stdout)

    def test_generic_score_reason_warns(self):
        result = self.run_validator(audit_with([
            candidate(
                selectedForDraft=False,
                shipped=False,
                section=None,
                rejectionReason="weak_personal_fit",
                cutReason=None,
                scoreReason="auto-labeled; not selected",
                scores={
                    "importance": 1,
                    "novelty": 1,
                    "personal_relevance": 1,
                    "substance": 2,
                    "delight": 2,
                    "total": 7,
                },
            )
        ]))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("candidate has generic scoreReason", result.stdout)


if __name__ == "__main__":
    unittest.main()
