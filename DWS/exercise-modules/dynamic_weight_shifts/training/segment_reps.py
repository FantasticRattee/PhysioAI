#!/usr/bin/env python3
"""Split MediaPipe Dynamic Weight Shifts sequences into weak-labeled reps."""

from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
import math
from pathlib import Path
from typing import Any

import numpy as np


EXERCISE_ID = "cust_dynamic_weight_shifts"
EXERCISE_LABEL = "dynamic_weight_shifts"
SCHEMA_ID = "seated_balance.v1"
SAMPLE_FPS = 10.0
TARGET_THRESHOLD_DEG = 2.5
SYNTHETIC_BOUNDARY_VARIANTS = (
    (1.8, "not_reached_target"),
    (2.2, "not_reached_target"),
    (2.4, "not_reached_target"),
    (2.6, "reached_target"),
    (3.2, "reached_target"),
    (4.0, "reached_target"),
)
PRIMARY_LANDMARKS = ["left_shoulder", "right_shoulder", "left_hip", "right_hip"]
STABILIZER_LANDMARKS = [
    "left_knee", "right_knee",
    "left_ankle", "right_ankle",
    "left_wrist", "right_wrist",
]
MODEL_INPUT_LANDMARKS = PRIMARY_LANDMARKS + STABILIZER_LANDMARKS
INDEX = {
    "left_shoulder": 11,
    "right_shoulder": 12,
    "left_hip": 23,
    "right_hip": 24,
    "left_ankle": 27,
    "right_ankle": 28,
}
VIDEO_SPLIT = {
    "IMG_2943.MOV": "train",
    "IMG_2944.MOV": "validation",
    "IMG_2945.MOV": "test",
}


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--analysis-output",
        type=Path,
        default=root / "analysis" / "dynamic-weight-shifts" / "output",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=root / "data" / "local" / "exercises"
        / "dynamic_weight_shifts__cust_dynamic_weight_shifts" / "dataset.jsonl",
    )
    parser.add_argument("--no-synthetic-variants", action="store_true")
    return parser.parse_args()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def stable_id(*parts: str) -> str:
    digest = hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:16]
    return f"ds_{EXERCISE_ID}_{digest}"


def target_episodes(phases: list[dict[str, str]]) -> list[tuple[int, int, str]]:
    episodes = []
    index = 0
    while index < len(phases):
        if phases[index]["phase"] != "target":
            index += 1
            continue
        direction = phases[index]["direction"]
        end = index
        while (
            end + 1 < len(phases)
            and phases[end + 1]["phase"] == "target"
            and phases[end + 1]["direction"] == direction
        ):
            end += 1
        if end - index + 1 >= 2:
            episodes.append((index, end, direction))
        index = end + 1
    return episodes


def completed_segments(phases: list[dict[str, str]]) -> list[dict[str, int | str]]:
    segments = []
    episodes = target_episodes(phases)
    absolute_signal = [abs(float(item["centered_torso_lean_deg"])) for item in phases]
    for episode_index, (target_start, target_end, direction) in enumerate(episodes):
        previous_target_end = episodes[episode_index - 1][1] if episode_index else -1
        next_target_start = episodes[episode_index + 1][0] if episode_index + 1 < len(episodes) else len(phases)
        before = range(previous_target_end + 1, target_start)
        after = range(target_end + 1, next_target_start)
        if not before or not after:
            continue
        previous_center = min(before, key=lambda index: absolute_signal[index])
        next_center = min(after, key=lambda index: absolute_signal[index])
        # A sampled frame does not always land inside the discrete "center"
        # phase during a fast crossing. Use the nearest signal minimum, but keep
        # the same 1-degree return criterion used by the sequence state machine.
        if absolute_signal[previous_center] > 1.0 or absolute_signal[next_center] > 1.0:
            continue
        start = max(previous_target_end + 1, previous_center - 2)
        end = min(next_target_start - 1, next_center + 2)
        if target_start - start < 3 or end - target_end < 3:
            continue
        segments.append({
            "start": start,
            "end": end,
            "targetStart": target_start,
            "targetEnd": target_end,
            "direction": direction,
        })
    return segments


def landmark_center(frame: dict[str, Any], left: str, right: str) -> np.ndarray:
    left_point = frame["landmarks"][INDEX[left]]
    right_point = frame["landmarks"][INDEX[right]]
    return np.asarray([
        (left_point["x"] + right_point["x"]) / 2,
        (left_point["y"] + right_point["y"]) / 2,
    ])


def rep_metrics(records: list[dict[str, Any]], phases: list[dict[str, str]]) -> dict[str, Any]:
    shoulder = np.asarray([
        landmark_center(frame, "left_shoulder", "right_shoulder") for frame in records
    ])
    hip = np.asarray([landmark_center(frame, "left_hip", "right_hip") for frame in records])
    ankle = np.asarray([
        landmark_center(frame, "left_ankle", "right_ankle") for frame in records
    ])
    shoulder_width = np.asarray([
        math.hypot(
            frame["landmarks"][INDEX["left_shoulder"]]["x"]
            - frame["landmarks"][INDEX["right_shoulder"]]["x"],
            frame["landmarks"][INDEX["left_shoulder"]]["y"]
            - frame["landmarks"][INDEX["right_shoulder"]]["y"],
        )
        for frame in records
    ])
    scale = max(float(np.median(shoulder_width)), 1e-6)
    shoulder_x = (shoulder[:, 0] - ankle[:, 0]) / scale
    hip_x = (hip[:, 0] - ankle[:, 0]) / scale
    shoulder_range = float(np.percentile(shoulder_x, 95) - np.percentile(shoulder_x, 5))
    hip_range = float(np.percentile(hip_x, 95) - np.percentile(hip_x, 5))
    coupling = float(np.corrcoef(shoulder_x, hip_x)[0, 1]) if len(records) >= 3 else 0.0
    amplitude = max(abs(float(item["centered_torso_lean_deg"])) for item in phases)
    velocities = [abs(float(item["torso_angular_velocity_deg_s"])) for item in phases]
    return_error = abs(float(phases[-1]["centered_torso_lean_deg"]))
    visibility = [float(frame["features"]["core_visibility_min"]) for frame in records]
    support = [float(frame["features"]["hand_support_likelihood"]) for frame in records]
    amplitude_band = "small" if amplitude < 5 else "medium" if amplitude < 10 else "large"
    velocity_p95 = float(np.percentile(velocities, 95))
    speed_band = "slow" if velocity_p95 < 8 else "reference" if velocity_p95 < 18 else "fast"
    return {
        "amplitudeDeg": amplitude,
        "amplitudeBand": amplitude_band,
        "angularVelocityP95DegS": velocity_p95,
        "speedBand": speed_band,
        "returnToCenterErrorDeg": return_error,
        "shoulderRangeShoulderWidths": shoulder_range,
        "hipRangeShoulderWidths": hip_range,
        "shoulderToHipRangeRatio": shoulder_range / max(hip_range, 1e-6),
        "shoulderHipCoupling": coupling,
        "coreVisibilityMin": min(visibility),
        "handSupportGeometryMean": float(np.mean(support)),
    }


def tuple_landmarks(record: dict[str, Any]) -> list[list[float]]:
    return [
        [point["x"], point["y"], point["z"], point["visibility"]]
        for point in record["landmarks"]
    ]


def standard_phase(phase: str) -> str:
    if phase == "center":
        return "rest"
    if phase == "target":
        return "target"
    return "moving_to_target"


def anatomical_direction(screen_direction: str) -> str:
    return "left" if screen_direction == "screen_right" else "right"


def build_actual_row(
    video: str,
    rep_number: int,
    records: list[dict[str, Any]],
    phases: list[dict[str, str]],
    metrics: dict[str, Any],
    screen_direction: str,
) -> dict[str, Any]:
    rep_id = f"dws_{Path(video).stem.lower()}_rep_{rep_number:03d}"
    direction = anatomical_direction(screen_direction)
    split = VIDEO_SPLIT[video]
    first_time = int(records[0]["timestamp_ms"])
    frames = []
    target_offset = next(
        index for index, phase in enumerate(phases) if phase["phase"] == "target"
    )
    for frame_index, (record, phase) in enumerate(zip(records, phases)):
        resolved_phase = standard_phase(phase["phase"])
        if frame_index < min(3, target_offset):
            resolved_phase = "rest"
        frames.append({
            "t": int(record["timestamp_ms"]) - first_time,
            "landmarks": tuple_landmarks(record),
            "angles": {"trunk_shift": abs(float(phase["centered_torso_lean_deg"]))},
            "phase": resolved_phase,
            "boundaryStatus": "inside",
            "dataQuality": "usable",
            "safetyStatus": "ok",
            "visibilityScore": float(record["features"]["core_visibility_mean"]) * 100,
            "missingPrimary": [],
            "missingStabilizer": [],
        })
    tags = [
        f"direction:{direction}",
        f"screen_direction:{screen_direction}",
        f"amplitude:{metrics['amplitudeBand']}",
        f"speed:{metrics['speedBand']}",
        "label_source:rule_weak",
        "completion:center_target_center",
        "pose_model:mediapipe_heavy",
        "camera:front_non_mirrored",
    ]
    return {
        "id": stable_id(video, rep_id, "actual"),
        "patientId": None,
        "therapistId": None,
        "version": 2,
        "exerciseId": EXERCISE_ID,
        "exerciseLabel": EXERCISE_LABEL,
        "label": "reached_target",
        "motionLabel": "reached_target",
        "suggestedLabel": "reached_target",
        "dataQuality": "usable",
        "labelStatus": "draft",
        "trainable": False,
        "scoreable": False,
        "repComplete": True,
        "completionSource": "rule_center_target_center",
        "missingPrimary": [],
        "missingStabilizer": [],
        "landmarkSchemaId": SCHEMA_ID,
        "bodyRegion": "seated_balance",
        "cameraView": "front",
        "primaryRequiredLandmarks": PRIMARY_LANDMARKS,
        "stabilizerRequiredLandmarks": STABILIZER_LANDMARKS,
        "modelInputLandmarks": MODEL_INPUT_LANDMARKS,
        "jointNames": ["trunk_shift"],
        "phaseLabels": ["rest", "moving_to_target", "target"],
        "frames": frames,
        "source": "mediapipe_pose_heavy_reference",
        "subjectId": "reference_subject_001",
        "datasetSessionId": f"dws_{Path(video).stem.lower()}",
        "repId": rep_id,
        "captureId": Path(video).stem,
        "capturedAt": None,
        "fpsEstimate": SAMPLE_FPS,
        "poseModelVariant": "heavy",
        "metadata": {
            "weakLabel": True,
            "weakLabelMethod": "dws_rule_center_target_center_v1",
            "prototypeTrainable": True,
            "clinicalReviewRequired": True,
            "prototypeSplit": split,
            "splitLineageId": rep_id,
            "sourceVideo": video,
            "sourceStartMs": int(records[0]["timestamp_ms"]),
            "sourceEndMs": int(records[-1]["timestamp_ms"]),
            "screenDirection": screen_direction,
            "anatomicalDirection": direction,
            "cameraMirrored": False,
            "tags": tags,
            "metrics": metrics,
            "featureSchemaVersion": 2,
            "targetOutcomePolicy": {
                "version": "seated_lateral_shift.v1",
                "joint": "trunk_shift",
                "phase": "target",
                "aggregate": "hold",
                "comparator": "gte",
                "reachedTargetMinDeg": TARGET_THRESHOLD_DEG,
                "restResetDeg": 1,
            },
        },
    }


def synthetic_variant(
    source: dict[str, Any],
    target_amplitude_deg: float,
    label: str,
) -> dict[str, Any] | None:
    row = copy.deepcopy(source)
    source_rep_id = source["repId"]
    source_amplitude = max(float(source["metadata"]["metrics"]["amplitudeDeg"]), 1e-6)
    if target_amplitude_deg >= source_amplitude:
        return None
    amplitude_token = str(target_amplitude_deg).replace(".", "p")
    variant_id = f"synthetic_{label}_{amplitude_token}deg"
    row["id"] = stable_id(source["metadata"]["sourceVideo"], source_rep_id, variant_id)
    row["repId"] = f"{source_rep_id}_{variant_id}"
    row["label"] = label
    row["motionLabel"] = label
    row["suggestedLabel"] = label
    row["completionSource"] = "synthetic_boundary_amplitude"
    row["source"] = "synthetic_weak_lateral_boundary_scale"
    amplitude_scale = target_amplitude_deg / source_amplitude
    neutral_frames = [frame for frame in row["frames"] if frame["phase"] == "rest"][:5]
    neutral_x = [
        float(np.mean([frame["landmarks"][index][0] for frame in neutral_frames]))
        for index in range(33)
    ]
    for frame in row["frames"]:
        for index, point in enumerate(frame["landmarks"]):
            point[0] = neutral_x[index] + amplitude_scale * (point[0] - neutral_x[index])
        frame["angles"]["trunk_shift"] *= amplitude_scale
    metrics = row["metadata"]["metrics"]
    for key in (
        "amplitudeDeg",
        "angularVelocityP95DegS",
        "returnToCenterErrorDeg",
        "shoulderRangeShoulderWidths",
        "hipRangeShoulderWidths",
    ):
        metrics[key] *= amplitude_scale
    metrics["amplitudeBand"] = (
        "boundary_reached" if label == "reached_target" else "boundary_not_reached"
    )
    row["metadata"].update({
        "synthetic": True,
        "syntheticMethod": "lateral_x_boundary_amplitude_v1",
        "syntheticScale": amplitude_scale,
        "syntheticTargetAmplitudeDeg": target_amplitude_deg,
        "syntheticSourceRepId": source_rep_id,
        "splitLineageId": source_rep_id,
    })
    row["metadata"]["tags"] = [
        tag for tag in row["metadata"]["tags"] if not tag.startswith("amplitude:")
    ] + [
        f"amplitude:{metrics['amplitudeBand']}",
        f"synthetic:boundary_{amplitude_token}deg",
        f"synthetic_label:{label}",
    ]
    return row


def main() -> int:
    args = parse_args()
    rows = []
    actual_count_by_video = {}
    for raw_path in sorted(args.analysis_output.glob("*_landmarks.jsonl")):
        stem = raw_path.name.removesuffix("_landmarks.jsonl")
        video = f"{stem}.MOV"
        raw = read_jsonl(raw_path)
        phases = read_csv(args.analysis_output / f"{stem}_phases.csv")
        if len(raw) != len(phases):
            raise ValueError(f"Frame/phase mismatch for {video}: {len(raw)} != {len(phases)}")
        segments = completed_segments(phases)
        actual_count_by_video[video] = len(segments)
        for rep_number, segment in enumerate(segments, start=1):
            start = int(segment["start"])
            end = int(segment["end"]) + 1
            rep_records = raw[start:end]
            rep_phases = phases[start:end]
            metrics = rep_metrics(rep_records, rep_phases)
            actual = build_actual_row(
                video,
                rep_number,
                rep_records,
                rep_phases,
                metrics,
                str(segment["direction"]),
            )
            rows.append(actual)
            if not args.no_synthetic_variants:
                for target_amplitude, label in SYNTHETIC_BOUNDARY_VARIANTS:
                    synthetic = synthetic_variant(actual, target_amplitude, label)
                    if synthetic is not None:
                        rows.append(synthetic)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        "\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows) + "\n",
        encoding="utf-8",
    )
    manifest = {
        "schema": "physioai.dws_rep_segmentation.v1",
        "exerciseId": EXERCISE_ID,
        "dataset": str(args.out),
        "actualReps": sum(actual_count_by_video.values()),
        "syntheticVariants": sum(row["metadata"].get("synthetic") is True for row in rows),
        "rowsByLabel": {
            label: sum(row["motionLabel"] == label for row in rows)
            for label in ("reached_target", "not_reached_target")
        },
        "totalRows": len(rows),
        "actualRepsByVideo": actual_count_by_video,
        "splitByVideo": VIDEO_SPLIT,
        "directions": {
            direction: sum(
                row["metadata"].get("anatomicalDirection") == direction
                and not row["metadata"].get("synthetic")
                for row in rows
            )
            for direction in ("left", "right")
        },
        "labelPolicy": {
            "actual": "weak reached_target from complete center-target-center rule",
            "synthetic": "weak boundary variants at 1.8/2.2/2.4 and 2.6/3.2/4.0 degrees",
            "labelStatus": "draft",
            "clinicalTrainable": False,
            "prototypeOnly": True,
        },
    }
    manifest_path = args.out.with_name("rep_manifest.json")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
