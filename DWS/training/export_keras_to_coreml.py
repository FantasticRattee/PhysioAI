#!/usr/bin/env python3
"""Export a PhysioAI Keras motion TCN as an on-device Core ML package."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="Source .keras checkpoint")
    parser.add_argument("--manifest", required=True, help="Published PhysioAI model manifest")
    parser.add_argument("--out", required=True, help="Destination .mlpackage")
    parser.add_argument(
        "--float32",
        action="store_true",
        help="Keep Float32 weights instead of the default Float16 Core ML storage",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

    # Python 3.12 no longer bundles distutils. Importing setuptools first
    # installs the compatibility shim expected by TensorFlow 2.17.
    import setuptools  # noqa: F401
    import coremltools as ct
    import tensorflow as tf

    manifest_path = Path(args.manifest)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    input_shape = manifest.get("inputShape")
    supported_shapes = {
        "cust_mrhhkile": [30, 20],
        "cust_dynamic_weight_shifts": [30, 23],
    }
    exercise_id = manifest.get("exerciseId")
    expected_shape = supported_shapes.get(exercise_id)
    if expected_shape is None:
        raise ValueError(f"Unsupported Core ML exercise {exercise_id!r}")
    if input_shape != expected_shape:
        raise ValueError(f"Expected {exercise_id} inputShape {expected_shape}, got {input_shape!r}")
    if manifest.get("motionFeatureSchemaVersion") != 2:
        raise ValueError("Core ML runtime requires motion feature schema v2")

    keras_model = tf.keras.models.load_model(args.model, compile=False)
    precision = ct.precision.FLOAT32 if args.float32 else ct.precision.FLOAT16
    coreml_model = ct.convert(
        keras_model,
        source="tensorflow",
        inputs=[ct.TensorType(name="motion_window", shape=(1, *input_shape))],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=precision,
    )
    coreml_model.author = "PhysioAI"
    descriptions = {
        "cust_mrhhkile": "On-device TCN phase and target-quality inference for lateral right-arm raise.",
        "cust_dynamic_weight_shifts": "On-device TCN phase and form inference for seated Dynamic Weight Shifts.",
    }
    coreml_model.short_description = descriptions[exercise_id]
    coreml_model.version = str(manifest.get("version") or "unknown")
    coreml_model.user_defined_metadata.update({
        "com.physioai.exerciseId": manifest["exerciseId"],
        "com.physioai.landmarkSchemaId": manifest["landmarkSchemaId"],
        "com.physioai.motionFeatureSchemaVersion": str(manifest["motionFeatureSchemaVersion"]),
        "com.physioai.windowPadding": manifest["windowPadding"],
        "com.physioai.phaseLabels": json.dumps(manifest["phases"]),
        "com.physioai.qualityLabels": json.dumps(manifest["qualities"]),
    })

    output_path = Path(args.out)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(output_path)
    spec = coreml_model.get_spec()
    summary = {
        "ok": True,
        "model": str(Path(args.model)),
        "manifest": str(manifest_path),
        "out": str(output_path),
        "inputs": [item.name for item in spec.description.input],
        "outputs": [item.name for item in spec.description.output],
        "precision": "float32" if args.float32 else "float16",
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
