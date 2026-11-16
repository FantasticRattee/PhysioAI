#!/usr/bin/env python3
"""Compare Keras and Core ML TCN outputs on deterministic motion windows."""

from __future__ import annotations

import argparse
import json
import os


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keras", required=True)
    parser.add_argument("--coreml", required=True)
    parser.add_argument("--samples", type=int, default=8)
    parser.add_argument("--tolerance", type=float, default=0.01)
    args = parser.parse_args()

    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import setuptools  # noqa: F401
    import coremltools as ct
    import numpy as np
    import tensorflow as tf

    keras_model = tf.keras.models.load_model(args.keras, compile=False)
    coreml_model = ct.models.MLModel(args.coreml, compute_units=ct.ComputeUnit.CPU_ONLY)
    input_shape = tuple(int(value) for value in keras_model.input_shape[-2:])
    if len(input_shape) != 2 or input_shape[0] != 30:
        raise ValueError(f"Unsupported motion input shape {keras_model.input_shape!r}")
    rng = np.random.default_rng(1337)
    worst_delta = 0.0
    comparisons = []

    for index in range(max(1, args.samples)):
        window = rng.normal(0, 0.7, size=(1, *input_shape)).astype(np.float32)
        raw_keras = keras_model(window, training=False)
        if isinstance(raw_keras, dict):
            keras_phase = np.asarray(raw_keras["phase"])[0]
            keras_quality = np.asarray(raw_keras["quality"])[0]
        else:
            keras_phase = np.asarray(raw_keras[0])[0]
            keras_quality = np.asarray(raw_keras[1])[0]
        raw_coreml = coreml_model.predict({"motion_window": window})
        coreml_phase = np.asarray(raw_coreml["Identity"])[0]
        coreml_quality = np.asarray(raw_coreml["Identity_1"])[0]
        phase_delta = float(np.max(np.abs(keras_phase - coreml_phase)))
        quality_delta = float(np.max(np.abs(keras_quality - coreml_quality)))
        worst_delta = max(worst_delta, phase_delta, quality_delta)
        comparisons.append({
            "sample": index,
            "phaseMaxAbsDelta": phase_delta,
            "qualityMaxAbsDelta": quality_delta,
        })

    result = {
        "ok": worst_delta <= args.tolerance,
        "samples": len(comparisons),
        "tolerance": args.tolerance,
        "worstMaxAbsDelta": worst_delta,
        "comparisons": comparisons,
    }
    print(json.dumps(result, indent=2))
    if not result["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
