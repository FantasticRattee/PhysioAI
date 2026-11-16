#!/usr/bin/env python3
"""Evaluate a Keras PhysioAI model on a group-held-out feature split."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


FEATURE_SCHEMA = "physioai.motion_features.v2"
APPROVAL_CRITERIA = {
    "phaseAccuracy": 0.90,
    "qualityAccuracy": 0.85,
    "qualityMacroF1": 0.75,
    "perLabelRecall": 0.75,
    "falseGoodRate": 0.05,
    "targetBoundaryConfidentRecall": 0.85,
    "targetBoundaryFalseReachedRate": 0.10,
}


def load_features(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema") != FEATURE_SCHEMA:
        raise ValueError(f"Expected {FEATURE_SCHEMA} feature payload")
    if not payload.get("exerciseId"):
        raise ValueError("Feature payload is missing exerciseId")
    if not payload.get("cameraView"):
        raise ValueError("Feature payload is missing cameraView")
    if payload.get("motionFeatureSchemaVersion") != 2:
        raise ValueError("Feature payload must use motionFeatureSchemaVersion 2")
    if payload.get("windowPadding") != "repeat_first":
        raise ValueError("Feature payload must use repeat_first window padding")
    input_shape = payload.get("inputShape")
    if (
        not isinstance(input_shape, list)
        or len(input_shape) != 2
        or not all(isinstance(value, int) and value > 0 for value in input_shape)
    ):
        raise ValueError("Feature payload inputShape must be [window, feature]")
    if not payload.get("samples"):
        raise ValueError("Feature payload has no samples")
    for index, sample in enumerate(payload["samples"]):
        if sample.get("exerciseId") != payload["exerciseId"]:
            raise ValueError(f"Sample {index} belongs to a different exercise")
        if sample.get("cameraView") != payload["cameraView"]:
            raise ValueError(f"Sample {index} belongs to a different camera view")
        window = sample.get("window")
        if not isinstance(window, list) or len(window) != input_shape[0]:
            raise ValueError(f"Sample {index} window length does not match inputShape")
        if any(
            not isinstance(frame, list)
            or len(frame) != input_shape[1]
            or any(not isinstance(value, (int, float)) or not math.isfinite(value) for value in frame)
            for frame in window
        ):
            raise ValueError(f"Sample {index} feature vector does not match inputShape")
    return payload


def choose_samples(payload: dict, requested_split: str = "auto") -> tuple[str, list[dict]]:
    samples = payload["samples"]
    if requested_split == "all":
        return "all", samples
    if requested_split != "auto":
        selected = [sample for sample in samples if sample.get("split") == requested_split]
        if not selected:
            raise ValueError(f"Feature payload has no {requested_split} samples")
        return requested_split, selected
    for split in ("test", "validation"):
        selected = [sample for sample in samples if sample.get("split") == split]
        if selected:
            return split, selected
    raise ValueError("Feature payload has no held-out test or validation samples")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help=".keras model produced by train_motion_tcn_keras.py")
    parser.add_argument("--features", required=True, help="Feature v2 JSON produced by scripts/build-motion-features.mjs")
    parser.add_argument("--out", default="training/artifacts/evaluation.json")
    parser.add_argument("--split", choices=("auto", "test", "validation", "all"), default="auto")
    parser.add_argument(
        "--quality-decision-threshold",
        type=float,
        default=0.5,
        help="Reached-target probability required for the deployed safety decision.",
    )
    parser.add_argument("--use-all-samples", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def classification_report(true_ids, pred_ids, labels):
    total = len(true_ids)
    matrix = {label: {inner: 0 for inner in labels} for label in labels}
    for truth, pred in zip(true_ids, pred_ids):
        matrix[labels[int(truth)]][labels[int(pred)]] += 1
    per_label = {}
    for label in labels:
        true_positive = matrix[label][label]
        support = sum(matrix[label].values())
        predicted = sum(matrix[truth][label] for truth in labels)
        recall = true_positive / support if support else 0.0
        precision = true_positive / predicted if predicted else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        per_label[label] = {
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "support": support,
        }
    correct = sum(matrix[label][label] for label in labels)
    supported_f1 = [metrics["f1"] for metrics in per_label.values() if metrics["support"] > 0]
    return {
        "accuracy": correct / total if total else 0.0,
        "macroF1": sum(supported_f1) / len(supported_f1) if supported_f1 else 0.0,
        "perLabel": per_label,
        "confusionMatrix": matrix,
    }


def false_good_rate(matrix, qualities=None):
    labels = qualities or list(matrix.keys())
    dynamic_contract = (
        any(label.startswith("correct_") for label in labels)
        and any(label.startswith("wrong_") for label in labels)
    )
    bad_labels = [label for label in labels if label.startswith("wrong_")] if dynamic_contract else ["not_reached_target"]
    good_labels = [label for label in labels if label.startswith("correct_")] if dynamic_contract else ["reached_target"]
    bad_total = sum(sum(matrix.get(label, {}).values()) for label in bad_labels)
    false_good = sum(
        int(matrix.get(label, {}).get(predicted, 0))
        for label in bad_labels
        for predicted in good_labels
    )
    return false_good / bad_total if bad_total else 0.0


def quality_ids_at_threshold(quality_pred, qualities, threshold: float):
    if "reached_target" not in qualities or "not_reached_target" not in qualities:
        return [
            max(range(len(row)), key=lambda index: float(row[index]))
            for row in quality_pred
        ]
    if not math.isfinite(threshold) or threshold <= 0.0 or threshold > 1.0:
        raise ValueError("quality decision threshold must be in (0, 1]")
    reached_id = qualities.index("reached_target")
    not_reached_id = qualities.index("not_reached_target")
    return [
        reached_id if float(row[reached_id]) >= threshold else not_reached_id
        for row in quality_pred
    ]


def policy_threshold(policy: dict) -> float | None:
    comparator = "lte" if policy.get("comparator") == "lte" else "gte"
    value = (
        policy.get("reachedTargetMaxDeg", policy.get("maxDeg", policy.get("threshold")))
        if comparator == "lte"
        else policy.get("reachedTargetMinDeg", policy.get("minDeg", policy.get("threshold")))
    )
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def sample_joint_angle(payload: dict, sample: dict, joint: str) -> float | None:
    direct = sample.get("targetJointAngle")
    if direct is None:
        direct = (sample.get("jointAngles") or {}).get(joint)
    try:
        direct_number = float(direct)
    except (TypeError, ValueError):
        direct_number = math.nan
    if math.isfinite(direct_number):
        return direct_number

    joints = payload.get("jointNames") or []
    landmarks = payload.get("modelInputLandmarks") or []
    if joint not in joints or not sample.get("window"):
        return None
    feature_index = len(landmarks) * 4 + joints.index(joint)
    vector = sample["window"][-1]
    if feature_index >= len(vector):
        return None
    value = float(vector[feature_index]) * 180.0
    return value if math.isfinite(value) else None


def target_boundary_report(
    payload: dict,
    samples: list[dict],
    quality_pred,
    min_confidence: float = 0.75,
) -> dict | None:
    policy = payload.get("targetOutcomePolicy") or {}
    joint = policy.get("joint")
    threshold = policy_threshold(policy)
    qualities = payload.get("qualities") or []
    if not joint or threshold is None or "reached_target" not in qualities or "not_reached_target" not in qualities:
        return None

    comparator = "lte" if policy.get("comparator") == "lte" else "gte"
    training = payload.get("boundaryTraining") or {}
    below_deg = max(0.0, float(training.get("bandBelowDeg", 5.0)))
    above_deg = max(0.0, float(training.get("bandAboveDeg", 15.0)))
    reached_id = qualities.index("reached_target")
    not_reached_id = qualities.index("not_reached_target")

    def truth_id(sample):
        vector = sample.get("qualityOneHot") or []
        return max(range(len(vector)), key=lambda index: vector[index]) if vector else -1

    def prediction(index):
        row = quality_pred[index]
        predicted_id = max(range(len(row)), key=lambda item: float(row[item]))
        return predicted_id, float(row[reached_id])

    reached_indexes = []
    outside_indexes = []
    angles = {}
    for index, sample in enumerate(samples):
        if sample.get("phase") != "target":
            continue
        angle = sample_joint_angle(payload, sample, joint)
        if angle is None:
            continue
        angles[index] = angle
        if comparator == "lte":
            in_reached_band = threshold - above_deg <= angle <= threshold
            just_outside = threshold < angle <= threshold + below_deg
        else:
            in_reached_band = threshold <= angle <= threshold + above_deg
            just_outside = threshold - below_deg <= angle < threshold
        if truth_id(sample) == reached_id and in_reached_band:
            reached_indexes.append(index)
        if truth_id(sample) == not_reached_id and just_outside:
            outside_indexes.append(index)

    def reached_metrics(indexes):
        argmax_hits = 0
        confident_hits = 0
        probability_sum = 0.0
        for index in indexes:
            predicted_id, probability = prediction(index)
            argmax_hits += int(predicted_id == reached_id)
            confident_hits += int(probability >= min_confidence)
            probability_sum += probability
        support = len(indexes)
        return {
            "support": support,
            "argmaxRecall": argmax_hits / support if support else 0.0,
            "confidentRecall": confident_hits / support if support else 0.0,
            "meanReachedProbability": probability_sum / support if support else 0.0,
        }

    def false_reached_metrics(indexes):
        confident_false = 0
        probability_sum = 0.0
        for index in indexes:
            _, probability = prediction(index)
            confident_false += int(probability >= min_confidence)
            probability_sum += probability
        support = len(indexes)
        return {
            "support": support,
            "confidentFalseReachedRate": confident_false / support if support else 0.0,
            "meanReachedProbability": probability_sum / support if support else 0.0,
        }

    per_band = {}
    step = 5.0
    band_count = max(1, int(math.ceil(above_deg / step)))
    for band_index in range(band_count):
        if comparator == "lte":
            upper = threshold - band_index * step
            lower = max(threshold - above_deg, upper - step)
        else:
            lower = threshold + band_index * step
            upper = min(threshold + above_deg, lower + step)
        def in_band(index):
            if band_index == band_count - 1:
                return lower <= angles[index] <= upper
            return lower <= angles[index] < upper
        indexes = [
            index for index in reached_indexes
            if in_band(index)
        ]
        per_band[f"{lower:g}-{upper:g}"] = reached_metrics(indexes)

    return {
        "joint": joint,
        "comparator": comparator,
        "thresholdDeg": threshold,
        "reachedBandDeg": [
            threshold - above_deg if comparator == "lte" else threshold,
            threshold if comparator == "lte" else threshold + above_deg,
        ],
        "outsideBandDeg": [
            threshold if comparator == "lte" else threshold - below_deg,
            threshold + below_deg if comparator == "lte" else threshold,
        ],
        "minConfidence": min_confidence,
        "reached": reached_metrics(reached_indexes),
        "justOutside": false_reached_metrics(outside_indexes),
        "perBand": per_band,
    }


def evaluate_approval(evaluation, quality_labels):
    issues = []
    approval_phase_accuracy = evaluation.get("stablePhaseAccuracy", evaluation["phaseAccuracy"])
    if approval_phase_accuracy < APPROVAL_CRITERIA["phaseAccuracy"]:
        issues.append("phase_accuracy_below_threshold")
    if evaluation["qualityAccuracy"] < APPROVAL_CRITERIA["qualityAccuracy"]:
        issues.append("quality_accuracy_below_threshold")
    if evaluation["qualityMacroF1"] < APPROVAL_CRITERIA["qualityMacroF1"]:
        issues.append("quality_macro_f1_below_threshold")
    for label in quality_labels:
        if evaluation["perLabelRecall"].get(label, 0.0) < APPROVAL_CRITERIA["perLabelRecall"]:
            issues.append(f"recall_{label}_below_threshold")
    if evaluation["falseGoodRate"] > APPROVAL_CRITERIA["falseGoodRate"]:
        issues.append("false_good_rate_above_threshold")
    boundary = evaluation.get("targetBoundary") or {}
    reached = boundary.get("reached") or {}
    outside = boundary.get("justOutside") or {}
    if reached.get("support", 0) >= 10 and reached.get("confidentRecall", 0.0) < APPROVAL_CRITERIA["targetBoundaryConfidentRecall"]:
        issues.append("target_boundary_confident_recall_below_threshold")
    if outside.get("support", 0) >= 10 and outside.get("confidentFalseReachedRate", 0.0) > APPROVAL_CRITERIA["targetBoundaryFalseReachedRate"]:
        issues.append("target_boundary_false_reached_rate_above_threshold")
    return {"ok": not issues, "issues": issues, "criteria": APPROVAL_CRITERIA}


def main() -> None:
    args = build_arg_parser().parse_args()
    quality_decision_threshold = float(args.quality_decision_threshold)
    if not math.isfinite(quality_decision_threshold) or quality_decision_threshold <= 0.0 or quality_decision_threshold > 1.0:
        raise ValueError("quality decision threshold must be in (0, 1]")
    payload = load_features(Path(args.features))
    requested = "all" if args.use_all_samples else args.split
    evaluated_split, samples = choose_samples(payload, requested)
    train_samples = [sample for sample in payload["samples"] if sample.get("split") == "train"]
    validation_samples = [sample for sample in payload["samples"] if sample.get("split") == "validation"]
    test_samples = [sample for sample in payload["samples"] if sample.get("split") == "test"]
    summary = {
        "ok": True,
        "model": args.model,
        "features": args.features,
        "exerciseId": payload["exerciseId"],
        "cameraView": payload["cameraView"],
        "samples": len(payload["samples"]),
        "trainSamples": len(train_samples),
        "validationSamples": len(validation_samples),
        "testSamples": len(test_samples),
        "evaluatedSamples": len(samples),
        "evaluatedSplit": evaluated_split,
        "inputShape": payload["inputShape"],
        "landmarkSchemaId": payload.get("landmarkSchemaId"),
        "qualityDecisionThreshold": quality_decision_threshold,
        "qualityLabels": payload["qualities"],
        "dryRun": args.dry_run,
    }
    if args.dry_run:
        print(json.dumps(summary, indent=2))
        return

    try:
        import setuptools  # noqa: F401 - installs the Python 3.12 distutils shim before TensorFlow
        import numpy as np
        import tensorflow as tf
    except Exception as exc:  # pragma: no cover - depends on training env
        raise RuntimeError("Keras evaluation requires numpy and tensorflow in the training environment.") from exc

    model = tf.keras.models.load_model(args.model)
    x = np.asarray([sample["window"] for sample in samples], dtype="float32")
    predicted = model.predict(x, verbose=0)
    if isinstance(predicted, dict):
        phase_pred = predicted["phase"]
        quality_pred = predicted["quality"]
    elif isinstance(predicted, (list, tuple)):
        phase_pred, quality_pred = predicted
    else:
        raise ValueError("Model must expose separate phase and quality outputs")

    phase_true = np.argmax(np.asarray([sample["phaseOneHot"] for sample in samples]), axis=1)
    phase_ids = np.argmax(phase_pred, axis=1)
    phase_report = classification_report(phase_true, phase_ids, payload["phases"])
    stable_phase_indexes = [
        index for index, sample in enumerate(samples)
        if float(sample.get("phaseWeight", 1.0)) > 0
    ]
    stable_phase_samples = [samples[index] for index in stable_phase_indexes]
    stable_phase_report = None
    if stable_phase_samples:
        stable_phase_true = np.argmax(
            np.asarray([sample["phaseOneHot"] for sample in stable_phase_samples]),
            axis=1,
        )
        stable_phase_ids = np.argmax(
            np.asarray([phase_pred[index] for index in stable_phase_indexes]),
            axis=1,
        )
        stable_phase_report = classification_report(
            stable_phase_true,
            stable_phase_ids,
            payload["phases"],
        )

    quality_indexes = [index for index, sample in enumerate(samples) if float(sample.get("qualityWeight", 0.0)) > 0]
    quality_samples = [samples[index] for index in quality_indexes]
    quality_true = np.argmax(np.asarray([sample["qualityOneHot"] for sample in quality_samples]), axis=1)
    quality_probabilities = np.asarray([quality_pred[index] for index in quality_indexes])
    raw_argmax_quality_ids = np.argmax(quality_probabilities, axis=1)
    quality_ids = np.asarray(
        quality_ids_at_threshold(
            quality_probabilities,
            payload["qualities"],
            quality_decision_threshold,
        )
    )
    quality_report = classification_report(quality_true, quality_ids, payload["qualities"])
    raw_argmax_quality_report = classification_report(
        quality_true,
        raw_argmax_quality_ids,
        payload["qualities"],
    )
    per_label_recall = {
        label: metrics["recall"] for label, metrics in quality_report["perLabel"].items()
    }
    evaluation = {
        "sampleCount": len(samples),
        "qualitySampleCount": len(quality_samples),
        "stablePhaseSampleCount": len(stable_phase_samples),
        "transitionPhaseSampleCount": len(samples) - len(stable_phase_samples),
        "evaluatedSplit": evaluated_split,
        "phaseAccuracy": float(phase_report["accuracy"]),
        "phaseMacroF1": float(phase_report["macroF1"]),
        "stablePhaseAccuracy": (
            float(stable_phase_report["accuracy"]) if stable_phase_report else None
        ),
        "stablePhaseMacroF1": (
            float(stable_phase_report["macroF1"]) if stable_phase_report else None
        ),
        "qualityDecisionThreshold": quality_decision_threshold,
        "qualityAccuracy": float(quality_report["accuracy"]),
        "qualityMacroF1": float(quality_report["macroF1"]),
        "perLabelRecall": per_label_recall,
        "perLabelQualityMetrics": quality_report["perLabel"],
        "falseGoodRate": false_good_rate(quality_report["confusionMatrix"], payload["qualities"]),
        "phaseConfusionMatrix": phase_report["confusionMatrix"],
        "stablePhaseConfusionMatrix": (
            stable_phase_report["confusionMatrix"] if stable_phase_report else None
        ),
        "qualityConfusionMatrix": quality_report["confusionMatrix"],
        "rawArgmaxQuality": {
            "accuracy": float(raw_argmax_quality_report["accuracy"]),
            "macroF1": float(raw_argmax_quality_report["macroF1"]),
            "perLabelRecall": {
                label: metrics["recall"]
                for label, metrics in raw_argmax_quality_report["perLabel"].items()
            },
            "falseGoodRate": false_good_rate(raw_argmax_quality_report["confusionMatrix"], payload["qualities"]),
            "confusionMatrix": raw_argmax_quality_report["confusionMatrix"],
        },
    }
    boundary = target_boundary_report(
        payload,
        samples,
        quality_pred,
        min_confidence=quality_decision_threshold,
    )
    if boundary is not None:
        evaluation["targetBoundary"] = boundary
    summary["evaluation"] = evaluation
    summary["approval"] = evaluate_approval(evaluation, payload["qualities"])
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
