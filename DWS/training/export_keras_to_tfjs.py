#!/usr/bin/env python3
"""Export a Keras PhysioAI motion model to TFJS with v3 manifest metadata."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import types
from pathlib import Path


TCN_PHASES = ["rest", "moving_to_target", "target"]
TCN_QUALITIES = ["reached_target", "not_reached_target"]


def load_json(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_features(path: str | Path) -> dict:
    payload = load_json(path)
    if payload.get("schema") != "physioai.motion_features.v2":
        raise ValueError("Expected physioai.motion_features.v2 feature payload")
    if not payload.get("exerciseId"):
        raise ValueError("Feature payload is missing exerciseId")
    if not payload.get("cameraView"):
        raise ValueError("Feature payload is missing cameraView")
    if not payload.get("landmarkSchemaId"):
        raise ValueError("Feature payload is missing landmarkSchemaId")
    if payload.get("motionFeatureSchemaVersion") != 2:
        raise ValueError("Feature payload must use motionFeatureSchemaVersion 2")
    if payload.get("windowPadding") != "repeat_first":
        raise ValueError("Feature payload must use repeat_first window padding")
    if not isinstance(payload.get("inputShape"), list) or len(payload["inputShape"]) != 2:
        raise ValueError("Feature payload is missing inputShape [window, feature]")
    return payload


def load_evaluation(path: str | Path | None) -> tuple[dict | None, dict | None]:
    if not path:
        return None, None
    payload = load_json(path)
    return payload.get("evaluation", payload), payload.get("approval")


def build_manifest(
    features: dict,
    evaluation: dict | None,
    approval: dict | None,
    version: str,
    validation_only: bool = False,
    model_format: str = "tfjs-layers-model",
    architecture_id: str | None = None,
    architecture_version: int | None = None,
) -> dict:
    manifest = {
        "name": "motion-tcn",
        "version": version,
        "modelPath": "./model.json",
        "exerciseId": features["exerciseId"],
        "cameraView": features["cameraView"],
        "landmarkSchemaId": features["landmarkSchemaId"],
        "bodyRegion": features.get("bodyRegion"),
        "modelInputLandmarks": features.get("modelInputLandmarks", []),
        "primaryRequiredLandmarks": features.get("primaryRequiredLandmarks", []),
        "stabilizerRequiredLandmarks": features.get("stabilizerRequiredLandmarks", []),
        "jointNames": features.get("jointNames", []),
        "inputShape": features["inputShape"],
        "motionFeatureSchemaVersion": features.get("motionFeatureSchemaVersion", 2),
        "windowPadding": features.get("windowPadding", "repeat_first"),
        "phases": features.get("phases") or TCN_PHASES,
        "qualities": features.get("qualities") or TCN_QUALITIES,
        "targetOutcomePolicy": features.get("targetOutcomePolicy"),
        "boundaryTraining": features.get("boundaryTraining"),
        "phasePurityThreshold": features.get("phasePurityThreshold"),
        "phaseTrainingSamples": features.get("phaseTrainingSamples"),
        "phaseFeatureMode": "full_motion_tcn",
        "qualityTrainingPhases": features.get("qualityTrainingPhases", ["target"]),
        "qualityDecisionMode": features.get("qualityDecisionMode", "target_pose_joint_angle_classifier"),
        "featureContract": features.get("featureContract"),
        "derivedFeatureContract": features.get("derivedFeatureContract"),
        "derivedFeatureNames": features.get("derivedFeatureNames", []),
        "formGeometryContract": features.get("formGeometryContract"),
        "classContract": features.get("classContract"),
        "trainingDirection": features.get("trainingDirection"),
        "trainingPhasePolicy": features.get("trainingPhasePolicy"),
        "formEvaluationPhases": features.get("formEvaluationPhases", ["target"]),
        "exposeHeadConfidences": features.get("exposeHeadConfidences", False),
        "augmentationPolicy": features.get("augmentationPolicy"),
        "splitCoverage": features.get("splitCoverage"),
        "evaluation": evaluation,
        "approval": approval,
        "approved": False,
        "validationOnly": validation_only,
        "modelFormat": model_format,
    }
    if architecture_id:
        manifest["architectureId"] = architecture_id
    if architecture_version is not None:
        manifest["architectureVersion"] = architecture_version
    if evaluation and evaluation.get("qualityDecisionThreshold") is not None:
        manifest["qualityDecisionThreshold"] = float(evaluation["qualityDecisionThreshold"])
    return manifest


def convert_keras_model(model_path: str, out: Path) -> None:
    # TFJS imports TensorFlow Decision Forests even for ordinary Keras models.
    # Avoid loading its incompatible native ops into the TensorFlow 2.17 trainer.
    sys.modules["tensorflow_decision_forests"] = types.ModuleType("tensorflow_decision_forests")
    try:
        import setuptools  # noqa: F401 - installs the Python 3.12 distutils shim before TensorFlow
        from tensorflowjs.converters.converter import convert
    except Exception as exc:  # pragma: no cover - depends on converter environment
        raise RuntimeError(
            "TFJS export requires tensorflowjs and tf-keras in the active training environment."
        ) from exc
    source = Path(model_path)
    if source.suffix != ".keras":
        convert(["--input_format", "keras", str(source), str(out)])
        return

    try:
        import tensorflow as tf
    except Exception as exc:  # pragma: no cover - depends on converter environment
        raise RuntimeError("Loading a .keras model for TFJS export requires TensorFlow.") from exc
    with tempfile.TemporaryDirectory(prefix="physioai-tfjs-") as temp_dir:
        saved_model = Path(temp_dir) / "saved_model"
        model = tf.keras.models.load_model(source)
        model.export(saved_model)
        convert([
            "--input_format", "tf_saved_model",
            "--output_format", "tfjs_graph_model",
            "--signature_name", "serve",
            "--saved_model_tags", "serve",
            str(saved_model),
            str(out),
        ])


def graph_output_map(out: Path) -> dict | None:
    model_path = out / "model.json"
    if not model_path.exists():
        return None
    payload = load_json(model_path)
    outputs = payload.get("signature", {}).get("outputs", {})
    resolved = {}

    # Some converter versions preserve the SavedModel dictionary keys, while
    # others expose generic Identity tensors and keep the semantic head name
    # only in the source node (for example .../phase_1/Softmax).
    for role in ("phase", "quality"):
        direct = outputs.get(role, {})
        if isinstance(direct, dict) and direct.get("name"):
            resolved[role] = direct["name"]

    nodes = payload.get("modelTopology", {}).get("node", [])
    nodes_by_name = {
        node.get("name"): node
        for node in nodes
        if isinstance(node, dict) and node.get("name")
    }
    role_pattern = re.compile(r"(?:^|[/_])(phase|quality)(?=[:/_]|$)", re.IGNORECASE)
    for output_key, output_spec in outputs.items():
        if not isinstance(output_spec, dict):
            continue
        tensor_name = output_spec.get("name") or output_key
        node_name = str(tensor_name).split(":", 1)[0]
        node = nodes_by_name.get(node_name, {})
        hints = [output_key, tensor_name, node_name, *(node.get("input") or [])]
        for hint in hints:
            match = role_pattern.search(str(hint))
            if match:
                resolved.setdefault(match.group(1).lower(), tensor_name)

    if resolved.get("phase") and resolved.get("quality"):
        return {"phase": resolved["phase"], "quality": resolved["quality"]}
    return None


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help=".keras model produced by train_motion_tcn_keras.py")
    parser.add_argument("--features", required=True, help="Feature JSON produced by npm run features:tcn")
    parser.add_argument("--evaluation", default=None, help="Evaluation JSON produced by npm run evaluate:tcn:keras")
    parser.add_argument("--out", required=True, help="Output TFJS model directory")
    parser.add_argument("--version", required=True, help="Manifest version/model id")
    parser.add_argument("--architecture-id", default=None, help="Exercise-owned model architecture id")
    parser.add_argument("--architecture-version", type=int, default=None, help="Exercise-owned model architecture version")
    parser.add_argument("--validation-only", action="store_true", help="Allow this unapproved artifact only in Therapist Validate")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main() -> None:
    args = build_arg_parser().parse_args()
    features = load_features(args.features)
    evaluation, approval = load_evaluation(args.evaluation)
    model_format = "tfjs-graph-model" if Path(args.model).suffix == ".keras" else "tfjs-layers-model"
    manifest = build_manifest(
        features,
        evaluation,
        approval,
        args.version,
        args.validation_only,
        model_format,
        args.architecture_id,
        args.architecture_version,
    )
    summary = {
        "ok": True,
        "model": args.model,
        "features": args.features,
        "evaluation": args.evaluation,
        "out": args.out,
        "version": args.version,
        "dryRun": args.dry_run,
        "manifest": manifest,
    }
    if args.dry_run:
        print(json.dumps(summary, indent=2))
        return

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    convert_keras_model(args.model, out)
    if manifest["modelFormat"] == "tfjs-graph-model":
        manifest["outputMap"] = graph_output_map(out)
        if not manifest["outputMap"]:
            raise ValueError("Converted graph model is missing named phase/quality outputs")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if evaluation is not None:
        (out / "evaluation.json").write_text(
            json.dumps({"evaluation": evaluation, "approval": approval}, indent=2) + "\n",
            encoding="utf-8",
        )
    print(json.dumps({**summary, "dryRun": False}, indent=2))


if __name__ == "__main__":
    main()
