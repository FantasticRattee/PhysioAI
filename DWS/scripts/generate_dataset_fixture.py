#!/usr/bin/env python3
"""Create the native held-out DWS replay fixture with Keras reference outputs."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keras", required=True)
    parser.add_argument("--features", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--split", default="test")
    args = parser.parse_args()

    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import setuptools  # noqa: F401 - provides distutils compatibility for TensorFlow
    import numpy as np
    import tensorflow as tf

    payload = json.loads(Path(args.features).read_text(encoding="utf-8"))
    selected = [sample for sample in payload["samples"] if sample.get("split") == args.split]
    if not selected:
        raise ValueError(f"No samples in split {args.split!r}")
    windows = np.asarray([sample["window"] for sample in selected], dtype=np.float32)
    model = tf.keras.models.load_model(args.keras, compile=False)
    raw = model(windows, training=False)
    if isinstance(raw, dict):
        phase_output = np.asarray(raw["phase"])
        form_output = np.asarray(raw["quality"])
    else:
        phase_output = np.asarray(raw[0])
        form_output = np.asarray(raw[1])

    fixture = {
        "schema": "physioai.dws_native_dataset_replay.v1",
        "source": str(Path(args.features)),
        "split": args.split,
        "inputShape": payload["inputShape"],
        "phaseLabels": payload["phases"],
        "formLabels": payload["qualities"],
        "samples": [],
    }
    for index, sample in enumerate(selected):
        fixture["samples"].append({
            "id": sample.get("repId") or f"sample-{index}",
            "phase": sample["phase"],
            "form": sample["quality"],
            "phaseTransitionWindow": bool(sample.get("phaseTransitionWindow")),
            "window": windows[index].tolist(),
            "kerasPhase": phase_output[index].astype(float).tolist(),
            "kerasForm": form_output[index].astype(float).tolist(),
        })
    destination = Path(args.out)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
    print(json.dumps({"ok": True, "samples": len(selected), "out": str(destination)}, indent=2))


if __name__ == "__main__":
    main()
