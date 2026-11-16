#!/usr/bin/env python3
"""Train the screen-left two-head Dynamic Weight Shifts TCN candidate."""

from __future__ import annotations

import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from training.train_motion_tcn_keras import main  # noqa: E402
from tcn_architecture import build_model  # noqa: E402


def feature_path(argv: list[str]) -> Path:
    try:
        return Path(argv[argv.index("--features") + 1])
    except (ValueError, IndexError) as exc:
        raise ValueError("--features is required") from exc


def validate_left_contract(argv: list[str]) -> None:
    payload = json.loads(feature_path(argv).read_text(encoding="utf-8"))
    expected = {
        "phases": ["rest", "target"],
        "qualities": ["correct_left", "wrong_left"],
        "classContract": "dynamic_weight_shifts_form_screen_left.v1",
        "trainingDirection": "left",
        "qualityTrainingPhases": ["target"],
    }
    mismatches = [
        f"{key}={payload.get(key)!r}"
        for key, value in expected.items()
        if payload.get(key) != value
    ]
    if mismatches:
        raise ValueError(
            "Left TCN feature contract mismatch: " + ", ".join(mismatches)
        )


if __name__ == "__main__":
    validate_left_contract(sys.argv[1:])
    main(
        model_builder=build_model,
        architecture_id="dynamic_weight_shifts_left_tcn.v1",
        architecture_version=1,
        expected_exercise_id="cust_dynamic_weight_shifts",
        expected_camera_view="front",
        expected_landmark_schema_id="seated_balance.v2",
    )
