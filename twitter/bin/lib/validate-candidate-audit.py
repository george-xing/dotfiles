#!/usr/bin/env python3
"""Validate twitter-digest candidate audit invariants.

Exit code 0 means the audit is parseable and structurally usable. Quality
concerns are printed as warnings so a run can ship while leaving reviewable
signals in the log. Exit code 1 means the audit has a schema or consistency
problem that can corrupt dedup or make the audit misleading.
"""

import json
import sys
from pathlib import Path


SCORE_KEYS = ("importance", "novelty", "personal_relevance", "substance", "delight", "total")
ALLOWED_EMPTY_LABEL_REASONS = {
    "low_substance",
    "off_topic",
}
GENERIC_ONLY_LABELS = {"random", "misc", "other"}
GENERIC_SCORE_REASONS = {
    "auto-labeled; not selected",
    "scored but not selected",
    "not selected",
}


def is_hard_filtered(candidate):
    return bool(candidate.get("hardFiltered"))


def issue(kind, message, candidate=None):
    prefix = f"{kind}: {message}"
    if candidate:
        url = candidate.get("statusUrl") or "<no statusUrl>"
        author = candidate.get("author") or "<unknown author>"
        return f"{prefix} ({author}, {url})"
    return prefix


def validate(audit):
    errors = []
    warnings = []

    candidates = audit.get("candidates")
    if not isinstance(candidates, list):
        return [issue("error", "candidates must be an array")], warnings

    shipped_candidates = []
    selected_for_draft = []
    selected_labels = {
        label
        for candidate in candidates
        if isinstance(candidate, dict) and candidate.get("selectedForDraft")
        for label in candidate.get("candidateLabels", [])
        if isinstance(label, str)
    }

    for idx, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            errors.append(issue("error", f"candidate {idx} must be an object"))
            continue

        hard_filtered = is_hard_filtered(candidate)
        rejection = candidate.get("rejectionReason")
        labels = candidate.get("candidateLabels")

        if candidate.get("shipped"):
            shipped_candidates.append(candidate)
        if candidate.get("selectedForDraft"):
            selected_for_draft.append(candidate)

        if candidate.get("shipped") and hard_filtered:
            errors.append(issue("error", "hard-filtered candidate is marked shipped", candidate))

        if candidate.get("shipped") and not candidate.get("selectedForDraft"):
            errors.append(issue("error", "shipped candidate was not selectedForDraft", candidate))

        if candidate.get("selectedForDraft") and not candidate.get("shipped") and not candidate.get("cutReason"):
            warnings.append(issue("warning", "selected for draft but not shipped without cutReason", candidate))

        if candidate.get("shipped") and not candidate.get("section"):
            errors.append(issue("error", "shipped candidate has no section", candidate))

        if hard_filtered:
            if not rejection:
                errors.append(issue("error", "hard-filtered candidate has no rejectionReason", candidate))
            continue

        scores = candidate.get("scores")
        if not isinstance(scores, dict):
            errors.append(issue("error", "soft candidate has no scores object", candidate))
        else:
            for key in SCORE_KEYS:
                value = scores.get(key)
                if not isinstance(value, int):
                    errors.append(issue("error", f"scores.{key} must be an integer", candidate))
                elif key == "total":
                    if not 0 <= value <= 25:
                        errors.append(issue("error", "scores.total must be between 0 and 25", candidate))
                elif not 0 <= value <= 5:
                    errors.append(issue("error", f"scores.{key} must be between 0 and 5", candidate))

            expected_total = sum(scores.get(k, 0) for k in SCORE_KEYS[:-1] if isinstance(scores.get(k), int))
            if isinstance(scores.get("total"), int) and scores["total"] != expected_total:
                warnings.append(issue("warning", "scores.total does not equal dimension sum", candidate))

            if (
                not candidate.get("selectedForDraft")
                and scores.get("personal_relevance", 0) >= 4
                and rejection not in {"marketing", "already_digested", "promoted", "no_status_url"}
            ):
                warnings.append(issue("warning", "high personal_relevance candidate rejected", candidate))

            if (
                candidate.get("selectedForDraft")
                and not candidate.get("shipped")
                and scores.get("personal_relevance", 0) >= 4
            ):
                warnings.append(issue("warning", "high personal_relevance candidate cut before delivery", candidate))

        if not isinstance(labels, list):
            errors.append(issue("error", "candidateLabels must be an array", candidate))
        elif not labels and rejection not in ALLOWED_EMPTY_LABEL_REASONS:
            warnings.append(issue("warning", "soft candidate has no labels", candidate))
        elif (
            labels
            and set(str(label).lower() for label in labels).issubset(GENERIC_ONLY_LABELS)
            and rejection not in ALLOWED_EMPTY_LABEL_REASONS
        ):
            warnings.append(issue("warning", "candidate has only generic labels", candidate))
        elif (
            rejection == "lower_score_than_cluster"
            and not candidate.get("selectedForDraft")
            and not (set(labels) & selected_labels)
        ):
            warnings.append(
                issue("warning", "lower_score_than_cluster without selected-cluster label overlap", candidate)
            )

        if not candidate.get("shipped") and not candidate.get("selectedForDraft") and not rejection:
            errors.append(issue("error", "unselected candidate has no rejectionReason", candidate))

        if candidate.get("shipped") and rejection:
            errors.append(issue("error", "shipped candidate has rejectionReason", candidate))

        score_reason = candidate.get("scoreReason")
        if not score_reason:
            warnings.append(issue("warning", "candidate has no scoreReason", candidate))
        elif str(score_reason).strip().lower() in GENERIC_SCORE_REASONS:
            warnings.append(issue("warning", "candidate has generic scoreReason", candidate))

    shipped_urls = audit.get("shippedUrls")
    if shipped_urls is not None:
        if not isinstance(shipped_urls, list) or not all(isinstance(u, str) for u in shipped_urls):
            errors.append(issue("error", "shippedUrls must be an array of strings"))
        else:
            expected = sorted(c.get("statusUrl") for c in shipped_candidates if c.get("statusUrl"))
            observed = sorted(shipped_urls)
            if observed != expected:
                errors.append(issue("error", "shippedUrls does not match shipped candidates"))

    shipped_count = audit.get("shippedCount")
    if shipped_count is not None and shipped_count != len(shipped_candidates):
        errors.append(issue("error", "shippedCount does not match shipped candidates"))

    selected_count = audit.get("selectedForDraftCount")
    if selected_count is not None and selected_count != len(selected_for_draft):
        errors.append(issue("error", "selectedForDraftCount does not match selectedForDraft candidates"))

    totals = [
        c.get("scores", {}).get("total")
        for c in candidates
        if isinstance(c, dict) and not is_hard_filtered(c) and isinstance(c.get("scores"), dict)
    ]
    if len(set(totals)) <= 2 and len(totals) >= 10:
        warnings.append(issue("warning", "score distribution collapsed into two or fewer total-score buckets"))

    return errors, warnings


def main(argv):
    if len(argv) != 2:
        print("usage: validate-candidate-audit.py <audit.json>", file=sys.stderr)
        return 2

    path = Path(argv[1])
    try:
        audit = json.loads(path.read_text())
    except Exception as exc:
        print(f"error: failed to parse audit JSON: {exc}")
        return 1

    errors, warnings = validate(audit)
    for line in errors + warnings:
        print(line)
    print(f"errors: {len(errors)}")
    print(f"warnings: {len(warnings)}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
