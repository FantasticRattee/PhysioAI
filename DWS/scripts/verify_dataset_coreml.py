#!/usr/bin/env python3
"""Replay held-out DWS feature windows through Keras and Core ML."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def argmax(row) -> int:
    return max(range(len(row)), key=lambda index: float(row[index]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keras", required=True)
    parser.add_argument("--coreml", required=True)
    parser.add_argument("--features", required=True)
    parser.add_argument("--split", default="test")
    parser.add_argument("--tolerance", type=float, default=0.015)
    parser.add_argument("--out", help="Optional JSON verification report")
    args = parser.parse_args()

    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import setuptools  # noqa: F401
    import coremltools as ct
    import numpy as np
    import tensorflow as tf

    payload = json.loads(Path(args.features).read_text(encoding="utf-8"))
    samples = [sample for sample in payload["samples"] if sample.get("split") == args.split]
    if not samples:
        raise ValueError(f"No samples for split {args.split!r}")
    windows = np.asarray([sample["window"] for sample in samples], dtype=np.float32)
    keras_model = tf.keras.models.load_model(args.keras, compile=False)
    raw_keras = keras_model(windows, training=False)
    if isinstance(raw_keras, dict):
        keras_phase = np.asarray(raw_keras["phase"])
        keras_form = np.asarray(raw_keras["quality"])
    else:
        keras_phase = np.asarray(raw_keras[0])
        keras_form = np.asarray(raw_keras[1])
    model_class = ct.models.CompiledMLModel if Path(args.coreml).suffix == ".mlmodelc" else ct.models.MLModel
    coreml_model = model_class(args.coreml, compute_units=ct.ComputeUnit.CPU_ONLY)

    phase_correct = 0
    stable_phase_correct = 0
    stable_phase_count = 0
    form_correct = 0
    form_count = 0
    false_good = 0
    wrong_count = 0
    worst_delta = 0.0
    phase_labels = payload["phases"]
    form_labels = payload["qualities"]
    for index, sample in enumerate(samples):
        output = coreml_model.predict({"motion_window": windows[index:index + 1]})
        phase = np.asarray(output["Identity"])[0]
        form = np.asarray(output["Identity_1"])[0]
        worst_delta = max(
            worst_delta,
            float(np.max(np.abs(phase - keras_phase[index]))),
            float(np.max(np.abs(form - keras_form[index]))),
        )
        predicted_phase = phase_labels[argmax(phase)]
        predicted_form = form_labels[argmax(form)]
        phase_correct += int(predicted_phase == sample["phase"])
        if not sample.get("phaseTransitionWindow"):
            stable_phase_count += 1
            stable_phase_correct += int(predicted_phase == sample["phase"])
        if sample["phase"] == "target":
            form_count += 1
            form_correct += int(predicted_form == sample["quality"])
            if sample["quality"] == "wrong_left":
                wrong_count += 1
                false_good += int(predicted_form == "correct_left")

    if not stable_phase_count or not form_count:
        raise ValueError("The selected split must contain stable-phase and target-form samples")
    result = {
        "ok": (
            worst_delta <= args.tolerance
            and phase_correct / len(samples) >= 0.90
            and stable_phase_correct / stable_phase_count >= 0.99
            and form_correct / form_count >= 0.99
            and false_good == 0
        ),
        "split": args.split,
        "samples": len(samples),
        "kerasCoreMLWorstMaxAbsDelta": worst_delta,
        "tolerance": args.tolerance,
        "phaseAccuracy": phase_correct / len(samples),
        "stablePhaseAccuracy": stable_phase_correct / stable_phase_count,
        "formAccuracyAtTarget": form_correct / form_count,
        "wrongFormSamples": wrong_count,
        "falseGoodCount": false_good,
    }
    print(json.dumps(result, indent=2))
    if args.out:
        output = Path(args.out)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if not result["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
