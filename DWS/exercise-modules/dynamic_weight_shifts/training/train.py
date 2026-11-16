#!/usr/bin/env python3
"""Train the prototype Dynamic Weight Shifts TCN."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from training.train_motion_tcn_keras import main  # noqa: E402
from tcn_architecture import build_model  # noqa: E402


if __name__ == "__main__":
    main(
        model_builder=build_model,
        architecture_id="dynamic_weight_shifts_tcn.v3",
        architecture_version=3,
        expected_exercise_id="cust_dynamic_weight_shifts",
        expected_camera_view="front",
        expected_landmark_schema_id="seated_balance.v2",
    )
