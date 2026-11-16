#!/usr/bin/env python3

"""Train and evaluate a left-side Correct-only phase + form detector.

This experiment is deliberately isolated from the web runtime and production
model pipeline.  Only reviewed ``correct_left`` reps fit the model and its
thresholds. Rest and Target from those correct reps train the phase head;
Target trains the form novelty head. Reviewed ``wrong_left`` reps are
evaluation-only.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np


LANDMARK_NAMES = [
    "nose", "left_eye_inner", "left_eye", "left_eye_outer",
    "right_eye_inner", "right_eye", "right_eye_outer",
    "left_ear", "right_ear", "mouth_left", "mouth_right",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_pinky", "right_pinky",
    "left_index", "right_index", "left_thumb", "right_thumb",
    "left_hip", "right_hip", "left_knee", "right_knee",
    "left_ankle", "right_ankle", "left_heel", "right_heel",
    "left_foot_index", "right_foot_index",
]
INDEX = {name: index for index, name in enumerate(LANDMARK_NAMES)}
MODEL_LANDMARKS = ["left_shoulder", "right_shoulder", "left_hip", "right_hip"]
BILATERAL_PAIRS = [
    ("left_eye_inner", "right_eye_inner"),
    ("left_eye", "right_eye"),
    ("left_eye_outer", "right_eye_outer"),
    ("left_ear", "right_ear"),
    ("mouth_left", "mouth_right"),
    ("left_shoulder", "right_shoulder"),
    ("left_elbow", "right_elbow"),
    ("left_wrist", "right_wrist"),
    ("left_pinky", "right_pinky"),
    ("left_index", "right_index"),
    ("left_thumb", "right_thumb"),
    ("left_hip", "right_hip"),
    ("left_knee", "right_knee"),
    ("left_ankle", "right_ankle"),
    ("left_heel", "right_heel"),
    ("left_foot_index", "right_foot_index"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Directory containing dataset JSON rows")
    parser.add_argument("--out", required=True, help="Isolated experiment output directory")
    parser.add_argument("--threshold-quantile", type=float, default=0.95)
    parser.add_argument("--neighbors", type=int, default=3)
    return parser.parse_args()


def point(value) -> np.ndarray:
    if isinstance(value, list):
        values = value[:4]
    elif isinstance(value, dict):
        values = [value.get("x"), value.get("y"), value.get("z", 0), value.get("visibility", 1)]
    else:
        values = []
    values = values + [0] * (4 - len(values))
    return np.asarray([float(item or 0) for item in values[:4]], dtype=np.float64)


def normalize_screen_sides(landmarks: list) -> list[np.ndarray]:
    normalized = [point(item) for item in landmarks]
    if len(normalized) < len(LANDMARK_NAMES):
        normalized.extend([np.zeros(4)] * (len(LANDMARK_NAMES) - len(normalized)))
    evidence = []
    for left, right in [
        ("left_shoulder", "right_shoulder"),
        ("left_hip", "right_hip"),
        ("left_knee", "right_knee"),
        ("left_ankle", "right_ankle"),
        ("left_ear", "right_ear"),
    ]:
        delta = normalized[INDEX[left]][0] - normalized[INDEX[right]][0]
        if abs(delta) > 1e-5:
            evidence.append(delta)
    if evidence and float(np.median(evidence)) > 0:
        source = list(normalized)
        for left, right in BILATERAL_PAIRS:
            normalized[INDEX[left]] = source[INDEX[right]]
            normalized[INDEX[right]] = source[INDEX[left]]
    return normalized


def usable(value: np.ndarray) -> bool:
    return bool(np.isfinite(value[:3]).all() and value[3] > 0)


def distance(a: np.ndarray, b: np.ndarray) -> float:
    if not usable(a) or not usable(b):
        return 0.0
    return float(np.linalg.norm(a[:3] - b[:3]))


def frame_vector(frame: dict) -> np.ndarray | None:
    landmarks = normalize_screen_sides(frame.get("landmarks") or [])
    selected = [landmarks[INDEX[name]] for name in MODEL_LANDMARKS]
    if not all(usable(item) for item in selected):
        return None
    left_shoulder, right_shoulder, left_hip, right_hip = selected
    shoulder_center = (left_shoulder[:3] + right_shoulder[:3]) / 2
    hip_center = (left_hip[:3] + right_hip[:3]) / 2
    spread = max(float(np.linalg.norm(item[:3] - hip_center)) for item in selected)
    scales = [
        distance(left_shoulder, right_shoulder),
        distance(left_hip, right_hip),
        float(np.linalg.norm(shoulder_center - hip_center)),
        spread,
    ]
    scale = next((value for value in scales if np.isfinite(value) and value >= 0.03), 1.0)
    values = []
    for item in selected:
        values.extend(((item[:3] - hip_center) / scale).tolist())
        values.append(float(item[3]))
    return np.asarray(values, dtype=np.float64)


def rep_embedding(row: dict, phase: str = "target") -> np.ndarray | None:
    vectors = [
        frame_vector(frame)
        for frame in row.get("frames") or []
        if frame.get("phase") == phase
    ]
    vectors = [vector for vector in vectors if vector is not None]
    if len(vectors) < 3:
        return None
    matrix = np.stack(vectors)
    median = np.median(matrix, axis=0)
    interquartile_range = np.quantile(matrix, 0.75, axis=0) - np.quantile(matrix, 0.25, axis=0)
    return np.concatenate([median, interquartile_range])


def robust_scaler(embeddings: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    center = np.median(embeddings, axis=0)
    mad = np.median(np.abs(embeddings - center), axis=0) * 1.4826
    standard_deviation = np.std(embeddings, axis=0)
    scale = np.where(mad > 1e-5, mad, np.where(standard_deviation > 1e-5, standard_deviation, 1.0))
    return center, scale


def novelty_score(candidate: np.ndarray, references: np.ndarray, neighbors: int) -> float:
    center, scale = robust_scaler(references)
    candidate_z = (candidate - center) / scale
    reference_z = (references - center) / scale
    distances = np.sqrt(np.mean(np.square(reference_z - candidate_z), axis=1))
    k = max(1, min(neighbors, len(distances)))
    return float(np.mean(np.partition(distances, k - 1)[:k]))


def quantile_higher(values: np.ndarray, q: float) -> float:
    try:
        return float(np.quantile(values, q, method="higher"))
    except TypeError:
        return float(np.quantile(values, q, interpolation="higher"))


def row_id(row: dict) -> str:
    return str(row.get("repId") or row.get("id") or "unknown")


def reference_model(rows_and_embeddings: list[tuple[dict, np.ndarray]], threshold: float, neighbors: int) -> dict:
    matrix = np.stack([embedding for _, embedding in rows_and_embeddings])
    center, scale = robust_scaler(matrix)
    return {
        "neighbors": neighbors,
        "threshold": threshold,
        "center": center.tolist(),
        "scale": scale.tolist(),
        "referenceEmbeddings": [
            {"repId": row_id(row), "embedding": embedding.tolist()}
            for row, embedding in rows_and_embeddings
        ],
    }


def load_rows(directory: Path) -> list[dict]:
    rows = []
    for path in sorted(directory.glob("*.json")):
        if path.name == "index.json":
            continue
        with path.open(encoding="utf-8") as handle:
            rows.append(json.load(handle))
    return rows


def main() -> None:
    args = parse_args()
    input_dir = Path(args.input).resolve()
    output_dir = Path(args.out).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    rows = load_rows(input_dir)
    eligible = [
        row for row in rows
        if row.get("exerciseId") == "cust_dynamic_weight_shifts"
        and row.get("labelStatus") == "reviewed"
        and row.get("trainable") is True
        and row.get("dataQuality") == "usable"
        and row.get("metadata", {}).get("synthetic") is not True
    ]
    correct_rows = [row for row in eligible if (row.get("classLabel") or row.get("label")) == "correct_left"]
    wrong_rows = [row for row in eligible if (row.get("classLabel") or row.get("label")) == "wrong_left"]
    correct = [(row, rep_embedding(row, "target")) for row in correct_rows]
    correct_rest = [(row, rep_embedding(row, "rest")) for row in correct_rows]
    wrong = [(row, rep_embedding(row, "target")) for row in wrong_rows]
    correct = [(row, embedding) for row, embedding in correct if embedding is not None]
    correct_rest = [(row, embedding) for row, embedding in correct_rest if embedding is not None]
    wrong = [(row, embedding) for row, embedding in wrong if embedding is not None]
    if len(correct) < 5:
        raise RuntimeError(f"At least 5 usable correct_left reps are required; found {len(correct)}")
    if len(correct_rest) < 5:
        raise RuntimeError(f"At least 5 usable correct_left Rest windows are required; found {len(correct_rest)}")

    correct_matrix = np.stack([embedding for _, embedding in correct])
    leave_one_out_scores = []
    for index, (row, embedding) in enumerate(correct):
        references = np.delete(correct_matrix, index, axis=0)
        leave_one_out_scores.append({
            "repId": row_id(row),
            "score": novelty_score(embedding, references, args.neighbors),
            "targetFrames": sum(frame.get("phase") == "target" for frame in row.get("frames") or []),
        })
    score_values = np.asarray([item["score"] for item in leave_one_out_scores])
    threshold = quantile_higher(score_values, args.threshold_quantile)
    for item in leave_one_out_scores:
        item["predicted"] = "correct_left" if item["score"] <= threshold else "wrong_left"

    rest_matrix = np.stack([embedding for _, embedding in correct_rest])
    rest_leave_one_out_scores = []
    for index, (row, embedding) in enumerate(correct_rest):
        references = np.delete(rest_matrix, index, axis=0)
        rest_leave_one_out_scores.append({
            "repId": row_id(row),
            "score": novelty_score(embedding, references, args.neighbors),
            "restFrames": sum(frame.get("phase") == "rest" for frame in row.get("frames") or []),
        })
    rest_score_values = np.asarray([item["score"] for item in rest_leave_one_out_scores])
    rest_threshold = quantile_higher(rest_score_values, args.threshold_quantile)

    target_by_id = {row_id(row): embedding for row, embedding in correct}
    rest_by_id = {row_id(row): embedding for row, embedding in correct_rest}
    phase_evaluation = []
    for rep_id in sorted(set(target_by_id) & set(rest_by_id)):
        target_embedding = target_by_id[rep_id]
        rest_embedding = rest_by_id[rep_id]
        target_references = np.stack([
            embedding for row, embedding in correct if row_id(row) != rep_id
        ])
        rest_references = np.stack([
            embedding for row, embedding in correct_rest if row_id(row) != rep_id
        ])
        rest_as_rest = novelty_score(rest_embedding, rest_references, args.neighbors) / rest_threshold
        rest_as_target = novelty_score(rest_embedding, target_references, args.neighbors) / threshold
        target_as_rest = novelty_score(target_embedding, rest_references, args.neighbors) / rest_threshold
        target_as_target = novelty_score(target_embedding, target_references, args.neighbors) / threshold
        phase_evaluation.extend([
            {
                "repId": rep_id,
                "actual": "rest",
                "predicted": "rest" if rest_as_rest <= rest_as_target else "target",
                "restRatio": rest_as_rest,
                "targetRatio": rest_as_target,
            },
            {
                "repId": rep_id,
                "actual": "target",
                "predicted": "rest" if target_as_rest <= target_as_target else "target",
                "restRatio": target_as_rest,
                "targetRatio": target_as_target,
            },
        ])

    wrong_scores = []
    for row, embedding in wrong:
        score = novelty_score(embedding, correct_matrix, args.neighbors)
        wrong_scores.append({
            "repId": row_id(row),
            "score": score,
            "predicted": "correct_left" if score <= threshold else "wrong_left",
            "targetFrames": sum(frame.get("phase") == "target" for frame in row.get("frames") or []),
        })

    correct_accepted = sum(item["predicted"] == "correct_left" for item in leave_one_out_scores)
    wrong_rejected = sum(item["predicted"] == "wrong_left" for item in wrong_scores)
    correct_recall = correct_accepted / len(leave_one_out_scores)
    wrong_rejection = wrong_rejected / len(wrong_scores) if wrong_scores else None
    total = len(leave_one_out_scores) + len(wrong_scores)
    accuracy = (correct_accepted + wrong_rejected) / total if total else None
    balanced_accuracy = ((correct_recall + wrong_rejection) / 2) if wrong_rejection is not None else None
    trained_at = datetime.now(timezone.utc).isoformat()
    center, scale = robust_scaler(correct_matrix)
    feature_names = [
        f"target_{summary}_{landmark}_{axis}"
        for summary in ["median", "iqr"]
        for landmark in MODEL_LANDMARKS
        for axis in ["x", "y", "z", "visibility"]
    ]
    model = {
        "schema": "physioai.correct_only_phase_knn.v2",
        "trainedAt": trained_at,
        "exerciseId": "cust_dynamic_weight_shifts",
        "direction": "left",
        "acceptedClass": "correct_left",
        "rejectedClass": "wrong_left",
        "landmarkSchemaId": "seated_balance.v2",
        "modelInputLandmarks": MODEL_LANDMARKS,
        "trainingPhases": ["rest", "target"],
        "trainingClassCounts": {"correct_left": len(correct), "wrong_left": 0},
        "neighbors": args.neighbors,
        "threshold": threshold,
        "thresholdSource": f"correct_left_leave_one_out_q{args.threshold_quantile}",
        "featureNames": feature_names,
        "center": center.tolist(),
        "scale": scale.tolist(),
        "referenceEmbeddings": [
            {"repId": row_id(row), "embedding": embedding.tolist()}
            for row, embedding in correct
        ],
        "phaseModel": {
            "phases": ["rest", "target"],
            "confidenceMethod": "relative_novelty_margin_v1",
            "rest": reference_model(correct_rest, rest_threshold, args.neighbors),
            "target": reference_model(correct, threshold, args.neighbors),
        },
    }
    report = {
        "schema": "physioai.correct_only_phase_evaluation.v2",
        "evaluatedAt": trained_at,
        "policy": "Train phase Rest/Target and Target form novelty with correct_left only; wrong_left is evaluation-only.",
        "dataset": {
            "correctTrainableReal": len(correct),
            "wrongEvaluationReal": len(wrong),
            "syntheticUsed": 0,
            "mirroredUsed": 0,
        },
        "threshold": threshold,
        "metrics": {
            "accuracy": accuracy,
            "balancedAccuracy": balanced_accuracy,
            "correctRecall": correct_recall,
            "wrongRejectionRate": wrong_rejection,
            "correctAccepted": correct_accepted,
            "correctTotal": len(leave_one_out_scores),
            "wrongRejected": wrong_rejected,
            "wrongTotal": len(wrong_scores),
            "phaseAccuracy": sum(item["actual"] == item["predicted"] for item in phase_evaluation) / len(phase_evaluation),
        },
        "phase": {
            "restThreshold": rest_threshold,
            "targetThreshold": threshold,
            "samples": phase_evaluation,
        },
        "correctLeaveOneOut": leave_one_out_scores,
        "wrongHoldout": wrong_scores,
        "limitations": [
            "All rows come from one subject.",
            "Only two real wrong_left reps are available, so wrong rejection has very high uncertainty.",
            "Most correct_left rows share one recording session.",
            "This experiment is validation-only and must not be used by the patient runtime.",
        ],
    }
    with (output_dir / "model.json").open("w", encoding="utf-8") as handle:
        json.dump(model, handle, ensure_ascii=False, indent=2)
    with (output_dir / "evaluation.json").open("w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
