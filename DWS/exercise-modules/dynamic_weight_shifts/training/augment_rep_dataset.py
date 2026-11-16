#!/usr/bin/env python3
"""Build a leakage-safe, per-rep synthetic Dynamic Weight Shifts dataset.

The source dataset contains weak labels extracted from one reference subject.
This script deliberately keeps every generated row in draft/prototype status.
Stochastic camera, pose-noise, mirror, and speed augmentations are restricted to
the training video lineage. Validation/test remain real-only in the main output;
their deterministic boundary variants are written to a separate diagnostic set.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import random
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


EXERCISE_ID = "cust_dynamic_weight_shifts"
TARGET_DEG = 2.5
REST_DEG = 1.0
TRAIN_AMPLITUDES = (1.8, 2.2, 2.4, 2.6, 2.8, 3.2, 4.0, 5.0)
TRAIN_SPEED_FACTORS = (0.70, 0.85, 1.00, 1.15, 1.30)
DIAGNOSTIC_AMPLITUDES = (2.2, 2.4, 2.6, 2.8)
LEFT_RIGHT_PAIRS = (
    (1, 4), (2, 5), (3, 6), (7, 8), (9, 10),
    (11, 12), (13, 14), (15, 16), (17, 18),
    (19, 20), (21, 22), (23, 24), (25, 26),
    (27, 28), (29, 30), (31, 32),
)


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[3]
    dataset_dir = (
        root / "data" / "local" / "exercises"
        / "dynamic_weight_shifts__cust_dynamic_weight_shifts"
    )
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=dataset_dir / "dataset.jsonl")
    parser.add_argument(
        "--out",
        type=Path,
        default=dataset_dir / "dataset_augmented_v3.jsonl",
    )
    parser.add_argument(
        "--diagnostic-out",
        type=Path,
        default=dataset_dir / "dataset_boundary_diagnostic_v3.jsonl",
    )
    parser.add_argument(
        "--diagnostic-eval-out",
        type=Path,
        default=dataset_dir / "dataset_augmented_v3_diagnostic_eval.jsonl",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=dataset_dir / "synthetic_augmented_v3_manifest.json",
    )
    parser.add_argument(
        "--audit",
        type=Path,
        default=dataset_dir / "synthetic_augmented_v3_audit.json",
    )
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows)
        + "\n",
        encoding="utf-8",
    )


def stable_seed(*parts: object) -> int:
    digest = hashlib.sha256("|".join(map(str, parts)).encode("utf-8")).hexdigest()
    return int(digest[:16], 16)


def stable_id(*parts: object) -> str:
    digest = hashlib.sha256("|".join(map(str, parts)).encode("utf-8")).hexdigest()[:16]
    return f"ds_{EXERCISE_ID}_{digest}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def frame_angle(frame: dict[str, Any]) -> float:
    return abs(float(frame.get("angles", {}).get("trunk_shift", 0.0)))


def row_peak_angle(row: dict[str, Any]) -> float:
    return max((frame_angle(frame) for frame in row.get("frames", [])), default=0.0)


def linear(a: float, b: float, fraction: float) -> float:
    return a + (b - a) * fraction


def interpolate_frame(left: dict[str, Any], right: dict[str, Any], fraction: float) -> dict[str, Any]:
    frame = copy.deepcopy(left)
    frame["landmarks"] = [
        [linear(float(a), float(b), fraction) for a, b in zip(left_point, right_point)]
        for left_point, right_point in zip(left["landmarks"], right["landmarks"])
    ]
    frame["angles"] = {
        "trunk_shift": linear(frame_angle(left), frame_angle(right), fraction),
    }
    frame["visibilityScore"] = linear(
        float(left.get("visibilityScore", 0)),
        float(right.get("visibilityScore", 0)),
        fraction,
    )
    return frame


def resample_frames(frames: list[dict[str, Any]], speed_factor: float, fps: float) -> list[dict[str, Any]]:
    if len(frames) < 2:
        return copy.deepcopy(frames)
    output_count = max(8, round((len(frames) - 1) / speed_factor) + 1)
    output = []
    for output_index in range(output_count):
        position = output_index * (len(frames) - 1) / max(output_count - 1, 1)
        left_index = int(math.floor(position))
        right_index = min(left_index + 1, len(frames) - 1)
        output.append(interpolate_frame(frames[left_index], frames[right_index], position - left_index))
    reset_timestamps(output, fps)
    return output


def reset_timestamps(frames: list[dict[str, Any]], fps: float) -> None:
    step_ms = 1000.0 / max(fps, 1.0)
    for index, frame in enumerate(frames):
        frame["t"] = round(index * step_ms)


def neutral_x(frames: list[dict[str, Any]]) -> list[float]:
    candidates = [frame for frame in frames if frame_angle(frame) <= REST_DEG][:5]
    if not candidates:
        candidates = frames[: min(5, len(frames))]
    return [
        sum(float(frame["landmarks"][index][0]) for frame in candidates) / len(candidates)
        for index in range(33)
    ]


def scale_amplitude(frames: list[dict[str, Any]], desired_peak: float) -> tuple[list[dict[str, Any]], float]:
    output = copy.deepcopy(frames)
    source_peak = max(row_peak_angle({"frames": output}), 1e-6)
    factor = desired_peak / source_peak
    centers = neutral_x(output)
    for frame in output:
        for index, point in enumerate(frame["landmarks"]):
            point[0] = centers[index] + factor * (float(point[0]) - centers[index])
        frame["angles"]["trunk_shift"] = frame_angle(frame) * factor
    return output, factor


def apply_camera_affine(
    frames: list[dict[str, Any]],
    scale: float,
    translate_x: float,
    translate_y: float,
) -> None:
    for frame in frames:
        for point in frame["landmarks"]:
            point[0] = 0.5 + scale * (float(point[0]) - 0.5) + translate_x
            point[1] = 0.5 + scale * (float(point[1]) - 0.5) + translate_y
            point[2] = scale * float(point[2])


def apply_mirror(frames: list[dict[str, Any]]) -> None:
    for frame in frames:
        for point in frame["landmarks"]:
            point[0] = 1.0 - float(point[0])
        for left_index, right_index in LEFT_RIGHT_PAIRS:
            frame["landmarks"][left_index], frame["landmarks"][right_index] = (
                frame["landmarks"][right_index],
                frame["landmarks"][left_index],
            )


def apply_smooth_landmark_jitter(
    frames: list[dict[str, Any]],
    rng: random.Random,
    sigma: float,
) -> None:
    """Apply tiny AR(1) landmark noise; visibility and stored angle stay unchanged."""
    previous = [[0.0, 0.0, 0.0] for _ in range(33)]
    for frame in frames:
        for index, point in enumerate(frame["landmarks"]):
            for axis, axis_scale in ((0, 1.0), (1, 1.0), (2, 0.35)):
                noise = 0.82 * previous[index][axis] + rng.gauss(0.0, sigma * axis_scale)
                previous[index][axis] = noise
                point[axis] = float(point[axis]) + noise


def ensure_reached_hold(frames: list[dict[str, Any]], fps: float) -> list[dict[str, Any]]:
    reached = [index for index, frame in enumerate(frames) if frame_angle(frame) >= TARGET_DEG]
    if len(reached) >= 2:
        return frames
    peak_index = max(range(len(frames)), key=lambda index: frame_angle(frames[index]))
    duplicate = copy.deepcopy(frames[peak_index])
    output = frames[:peak_index + 1] + [duplicate] + frames[peak_index + 1:]
    reset_timestamps(output, fps)
    return output


def assign_phases(frames: list[dict[str, Any]], label: str) -> None:
    if not frames:
        return
    for frame in frames:
        frame["phase"] = "rest" if frame_angle(frame) <= REST_DEG else "moving_to_target"
    if label == "reached_target":
        for frame in frames:
            if frame_angle(frame) >= TARGET_DEG:
                frame["phase"] = "target"
        return
    peak_index = max(range(len(frames)), key=lambda index: frame_angle(frames[index]))
    # For a failed attempt, target means the endpoint/plateau of the attempt,
    # not that the 2.5-degree success threshold was reached.
    for index in range(max(0, peak_index - 1), min(len(frames), peak_index + 2)):
        if frame_angle(frames[index]) < TARGET_DEG:
            frames[index]["phase"] = "target"


def direction_after_mirror(direction: str) -> str:
    return {"left": "right", "right": "left"}.get(direction, direction)


def screen_direction_after_mirror(direction: str) -> str:
    return {"screen_left": "screen_right", "screen_right": "screen_left"}.get(direction, direction)


def safe_tags(row: dict[str, Any]) -> list[str]:
    return list(row.get("metadata", {}).get("tags", []))


def prepare_real_row(source: dict[str, Any]) -> dict[str, Any]:
    row = copy.deepcopy(source)
    row["metadata"]["evaluationRole"] = (
        "primary_real_evaluation"
        if row["metadata"]["prototypeSplit"] in {"validation", "test"}
        else "real_reference_train"
    )
    row["metadata"]["augmentationVersion"] = "per_rep_v3"
    assign_phases(row["frames"], row["motionLabel"])
    row["metadata"]["tags"] = safe_tags(row) + [
        f"evaluation_role:{row['metadata']['evaluationRole']}",
        "augmentation:real_unmodified_landmarks",
    ]
    return row


def make_synthetic(
    source: dict[str, Any],
    desired_peak: float,
    speed_factor: float,
    *,
    stochastic: bool,
    diagnostic: bool,
) -> dict[str, Any]:
    source_rep_id = source["repId"]
    label = "reached_target" if desired_peak >= TARGET_DEG else "not_reached_target"
    seed = stable_seed(source_rep_id, desired_peak, speed_factor, "per_rep_v3")
    rng = random.Random(seed)
    frames, amplitude_scale = scale_amplitude(source["frames"], desired_peak)
    fps = float(source.get("fpsEstimate") or 10.0)
    frames = resample_frames(frames, speed_factor, fps)

    mirrored = False
    camera_scale = 1.0
    translate_x = 0.0
    translate_y = 0.0
    jitter_sigma = 0.0
    if stochastic:
        mirrored = rng.random() < 0.5
        camera_scale = rng.uniform(0.94, 1.06)
        translate_x = rng.uniform(-0.025, 0.025)
        translate_y = rng.uniform(-0.020, 0.020)
        jitter_sigma = rng.uniform(0.00035, 0.00090)
        apply_camera_affine(frames, camera_scale, translate_x, translate_y)
        if mirrored:
            apply_mirror(frames)
        apply_smooth_landmark_jitter(frames, rng, jitter_sigma)

    if label == "reached_target":
        frames = ensure_reached_hold(frames, fps)
    assign_phases(frames, label)

    amplitude_token = str(desired_peak).replace(".", "p")
    speed_token = str(speed_factor).replace(".", "p")
    role = "synthetic_boundary_diagnostic" if diagnostic else "synthetic_train_augmentation"
    variant_token = f"amp_{amplitude_token}_speed_{speed_token}_{'stochastic' if stochastic else 'fixed'}"
    row = copy.deepcopy(source)
    row["id"] = stable_id(source_rep_id, variant_token)
    row["repId"] = f"{source_rep_id}_{variant_token}"
    row["label"] = label
    row["motionLabel"] = label
    row["suggestedLabel"] = label
    row["completionSource"] = "synthetic_attempt_endpoint"
    row["source"] = "synthetic_weak_per_rep_augmentation_v3"
    row["frames"] = frames
    row["labelStatus"] = "draft"
    row["trainable"] = False
    row["scoreable"] = False
    row["metadata"].update({
        "weakLabel": True,
        "prototypeTrainable": True,
        "clinicalReviewRequired": True,
        "synthetic": True,
        "syntheticMethod": "per_rep_amplitude_speed_camera_v3",
        "augmentationVersion": "per_rep_v3",
        "augmentationSeed": seed,
        "augmentationStochastic": stochastic,
        "evaluationRole": role,
        "syntheticSourceRepId": source_rep_id,
        "splitLineageId": source["metadata"].get("splitLineageId", source_rep_id),
        "syntheticTargetAmplitudeDeg": desired_peak,
        "syntheticAmplitudeScale": amplitude_scale,
        "syntheticSpeedFactor": speed_factor,
        "syntheticMirror": mirrored,
        "syntheticCameraScale": camera_scale,
        "syntheticTranslateX": translate_x,
        "syntheticTranslateY": translate_y,
        "syntheticJitterSigma": jitter_sigma,
    })
    if mirrored:
        row["metadata"]["anatomicalDirection"] = direction_after_mirror(
            row["metadata"].get("anatomicalDirection", "unknown")
        )
        row["metadata"]["screenDirection"] = screen_direction_after_mirror(
            row["metadata"].get("screenDirection", "unknown")
        )
    row["metadata"]["metrics"] = copy.deepcopy(row["metadata"].get("metrics", {}))
    row["metadata"]["metrics"].update({
        "amplitudeDeg": desired_peak,
        "amplitudeBand": "boundary_reached" if label == "reached_target" else "boundary_not_reached",
    })
    row["metadata"]["tags"] = [
        tag
        for tag in safe_tags(row)
        if not tag.startswith(("amplitude:", "speed:", "direction:", "screen_direction:"))
    ] + [
        f"direction:{row['metadata'].get('anatomicalDirection', 'unknown')}",
        f"screen_direction:{row['metadata'].get('screenDirection', 'unknown')}",
        f"amplitude:{row['metadata']['metrics']['amplitudeBand']}",
        f"speed_factor:{speed_factor:.2f}",
        f"synthetic_label:{label}",
        f"evaluation_role:{role}",
        "augmentation:per_rep_v3",
        f"augmentation_mirror:{str(mirrored).lower()}",
    ]
    return row


def quality_target_angles(row: dict[str, Any]) -> list[float]:
    return [frame_angle(frame) for frame in row.get("frames", []) if frame.get("phase") == "target"]


def audit_rows(main_rows: list[dict[str, Any]], diagnostic_rows: list[dict[str, Any]]) -> dict[str, Any]:
    all_rows = main_rows + diagnostic_rows
    failures: list[str] = []
    ids = [row["id"] for row in all_rows]
    if len(ids) != len(set(ids)):
        failures.append("duplicate row ids")

    lineage_splits: dict[str, set[str]] = defaultdict(set)
    source_variant_counts: Counter[str] = Counter()
    target_frame_counts: Counter[str] = Counter()
    for row in all_rows:
        metadata = row.get("metadata", {})
        lineage = metadata.get("splitLineageId", row.get("repId"))
        split = metadata.get("prototypeSplit")
        lineage_splits[lineage].add(split)
        if metadata.get("synthetic"):
            source_variant_counts[metadata.get("syntheticSourceRepId", "missing")] += 1
        if row.get("labelStatus") != "draft" or row.get("trainable") is not False:
            failures.append(f"{row['repId']}: unsafe trainable/label status")
        if row.get("scoreable") is not False:
            failures.append(f"{row['repId']}: scoreable must remain false")
        if metadata.get("clinicalReviewRequired") is not True:
            failures.append(f"{row['repId']}: clinical review flag missing")
        target_angles = quality_target_angles(row)
        target_frame_counts[row["motionLabel"]] += len(target_angles)
        if not target_angles:
            failures.append(f"{row['repId']}: no quality target frames")
        elif row["motionLabel"] == "not_reached_target" and max(target_angles) >= TARGET_DEG:
            failures.append(f"{row['repId']}: not_reached target >= {TARGET_DEG}")
        elif row["motionLabel"] == "reached_target" and min(target_angles) < TARGET_DEG:
            failures.append(f"{row['repId']}: reached target < {TARGET_DEG}")

    crossing = {key: sorted(value) for key, value in lineage_splits.items() if len(value) != 1}
    if crossing:
        failures.append(f"split lineage crossing: {crossing}")
    stochastic_outside_train = [
        row["repId"] for row in all_rows
        if row.get("metadata", {}).get("augmentationStochastic") is True
        and row.get("metadata", {}).get("prototypeSplit") != "train"
    ]
    if stochastic_outside_train:
        failures.append("stochastic augmentation outside train split")
    synthetic_main_eval = [
        row["repId"] for row in main_rows
        if row.get("metadata", {}).get("synthetic") is True
        and row.get("metadata", {}).get("prototypeSplit") in {"validation", "test"}
    ]
    if synthetic_main_eval:
        failures.append("main validation/test is not real-only")
    incorrect_diagnostic_role = [
        row["repId"] for row in diagnostic_rows
        if row.get("metadata", {}).get("evaluationRole") != "synthetic_boundary_diagnostic"
    ]
    if incorrect_diagnostic_role:
        failures.append("diagnostic row missing diagnostic role")

    return {
        "schema": "physioai.synthetic_augmentation_audit.v3",
        "ok": not failures,
        "failures": failures,
        "thresholdDeg": TARGET_DEG,
        "mainRows": len(main_rows),
        "diagnosticRows": len(diagnostic_rows),
        "uniqueIds": len(set(ids)),
        "lineages": len(lineage_splits),
        "splitLineageCrossings": crossing,
        "stochasticOutsideTrainCount": len(stochastic_outside_train),
        "syntheticRowsInMainValidationTest": len(synthetic_main_eval),
        "qualityTargetFramesByLabel": dict(target_frame_counts),
        "sourceVariantCounts": dict(sorted(source_variant_counts.items())),
        "constraints": {
            "notReachedTargetFrameMaxExclusiveDeg": TARGET_DEG,
            "reachedTargetFrameMinInclusiveDeg": TARGET_DEG,
            "mainValidationTest": "real-only",
            "randomAugmentationSplit": "train-only",
            "clinicalStatus": "draft prototype only",
        },
    }


def counts(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "total": len(rows),
        "real": sum(not row.get("metadata", {}).get("synthetic") for row in rows),
        "synthetic": sum(row.get("metadata", {}).get("synthetic") is True for row in rows),
        "bySplit": dict(Counter(row["metadata"]["prototypeSplit"] for row in rows)),
        "byLabel": dict(Counter(row["motionLabel"] for row in rows)),
        "byEvaluationRole": dict(Counter(row["metadata"]["evaluationRole"] for row in rows)),
    }


def main() -> int:
    args = parse_args()
    source_rows = read_jsonl(args.input)
    actual_rows = [
        row for row in source_rows
        if row.get("exerciseId") == EXERCISE_ID and not row.get("metadata", {}).get("synthetic")
    ]
    if not actual_rows:
        raise ValueError("No real source reps found")

    main_rows: list[dict[str, Any]] = [prepare_real_row(row) for row in actual_rows]
    diagnostic_rows: list[dict[str, Any]] = []
    for source in actual_rows:
        split = source["metadata"]["prototypeSplit"]
        if split == "train":
            for amplitude in TRAIN_AMPLITUDES:
                for speed in TRAIN_SPEED_FACTORS:
                    main_rows.append(make_synthetic(
                        source, amplitude, speed, stochastic=True, diagnostic=False,
                    ))
        elif split in {"validation", "test"}:
            for amplitude in DIAGNOSTIC_AMPLITUDES:
                diagnostic_rows.append(make_synthetic(
                    source, amplitude, 1.0, stochastic=False, diagnostic=True,
                ))

    audit = audit_rows(main_rows, diagnostic_rows)
    if not audit["ok"]:
        raise ValueError("Augmentation audit failed: " + "; ".join(audit["failures"][:10]))

    write_jsonl(args.out, main_rows)
    write_jsonl(args.diagnostic_out, diagnostic_rows)
    # This combined artifact exists only so the standard feature builder can
    # build train + held-out boundary diagnostics in one schema. Primary
    # validation/test metrics must still filter to evaluationRole=primary_real_evaluation.
    write_jsonl(args.diagnostic_eval_out, main_rows + diagnostic_rows)
    args.audit.write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest = {
        "schema": "physioai.synthetic_per_rep_dataset.v3",
        "exerciseId": EXERCISE_ID,
        "sourceDataset": str(args.input),
        "sourceActualReps": len(actual_rows),
        "mainDataset": str(args.out),
        "boundaryDiagnosticDataset": str(args.diagnostic_out),
        "diagnosticEvaluationDataset": str(args.diagnostic_eval_out),
        "audit": str(args.audit),
        "main": counts(main_rows),
        "diagnostic": counts(diagnostic_rows),
        "augmentationPlan": {
            "trainOnly": {
                "amplitudesDeg": TRAIN_AMPLITUDES,
                "speedFactors": TRAIN_SPEED_FACTORS,
                "cameraScaleRange": [0.94, 1.06],
                "translationXRange": [-0.025, 0.025],
                "translationYRange": [-0.020, 0.020],
                "smoothJitterSigmaRange": [0.00035, 0.00090],
                "mirrorProbability": 0.5,
                "reproducibleSeed": "sha256(sourceRepId, amplitude, speed, per_rep_v3)",
            },
            "validationTest": {
                "mainDataset": "real-only",
                "diagnosticAmplitudesDeg": DIAGNOSTIC_AMPLITUDES,
                "diagnosticTransforms": "deterministic amplitude only",
            },
        },
        "labelSemantics": {
            "reachedTarget": "target frames are all >= 2.5 degrees",
            "notReachedTarget": "target frames mark attempt apex and are all < 2.5 degrees",
            "phaseRecomputedAfterTransform": True,
        },
        "safety": {
            "labelStatus": "draft",
            "trainable": False,
            "scoreable": False,
            "weakLabel": True,
            "clinicalReviewRequired": True,
            "publishBlocked": True,
            "singleReferenceSubject": True,
        },
        "sha256": {
            "mainDataset": sha256_file(args.out),
            "boundaryDiagnosticDataset": sha256_file(args.diagnostic_out),
            "diagnosticEvaluationDataset": sha256_file(args.diagnostic_eval_out),
        },
    }
    args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "manifest": manifest, "audit": audit}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
