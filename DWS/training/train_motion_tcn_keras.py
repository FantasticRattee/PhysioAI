#!/usr/bin/env python3
"""Train a residual Keras TCN from PhysioAI motion feature v2 artifacts."""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter
from pathlib import Path


FEATURE_SCHEMA = "physioai.motion_features.v2"


def load_features(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema") != FEATURE_SCHEMA:
        raise ValueError(f"Expected {FEATURE_SCHEMA} feature payload")
    for key in ("exerciseId", "cameraView", "landmarkSchemaId", "inputShape", "phases", "qualities"):
        if not payload.get(key):
            raise ValueError(f"Feature payload is missing {key}")
    if payload.get("motionFeatureSchemaVersion") != 2:
        raise ValueError("Feature payload must use motionFeatureSchemaVersion 2")
    if payload.get("windowPadding") != "repeat_first":
        raise ValueError("Feature payload must use repeat_first window padding")
    input_shape = payload["inputShape"]
    if (
        not isinstance(input_shape, list)
        or len(input_shape) != 2
        or not all(isinstance(value, int) and value > 0 for value in input_shape)
    ):
        raise ValueError("Feature payload inputShape must be [window, feature]")
    samples = payload.get("samples") or []
    if not samples:
        raise ValueError("Feature payload has no samples")
    phase_size = len(payload["phases"])
    quality_size = len(payload["qualities"])
    for index, sample in enumerate(samples):
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
        if len(sample.get("phaseOneHot") or []) != phase_size:
            raise ValueError(f"Sample {index} phaseOneHot does not match phases")
        if len(sample.get("qualityOneHot") or []) != quality_size:
            raise ValueError(f"Sample {index} qualityOneHot does not match qualities")
        phase_weight = float(sample.get("phaseWeight", 1.0))
        if not math.isfinite(phase_weight) or phase_weight < 0.0:
            raise ValueError(f"Sample {index} phaseWeight must be a finite non-negative number")
        if sample.get("exerciseId") != payload["exerciseId"]:
            raise ValueError(f"Sample {index} belongs to a different exercise")
        if sample.get("cameraView") != payload["cameraView"]:
            raise ValueError(f"Sample {index} belongs to a different camera view")
    return payload


def samples_for_split(payload: dict, split: str) -> list[dict]:
    return [sample for sample in payload["samples"] if sample.get("split", "train") == split]


def joint_angle_feature_range(payload: dict, allow_empty: bool = False) -> tuple[int, int]:
    landmark_count = len(payload.get("modelInputLandmarks") or [])
    joint_count = len(payload.get("jointNames") or [])
    feature_size = int(payload["inputShape"][1])
    start = landmark_count * 4
    end = start + joint_count
    if landmark_count < 1 or start < 0 or end > feature_size:
        raise ValueError("Feature payload cannot resolve the joint-angle feature range")
    if joint_count < 1:
        if allow_empty:
            return start, start
        raise ValueError("Feature payload cannot resolve the joint-angle feature range")
    return start, end


def balanced_sample_weights(
    samples: list[dict],
    label_key: str,
    mask_key: str | None = None,
    balance_power: float = 1.0,
):
    active = [
        sample for sample in samples
        if mask_key is None or float(sample.get(mask_key, 0.0)) > 0.0
    ]
    counts = Counter(sample.get(label_key) for sample in active)
    class_count = max(1, len(counts))
    total = max(1, sum(counts.values()))
    weights = {
        label: math.pow(total / (class_count * count), max(0.0, balance_power))
        for label, count in counts.items()
        if label and count
    }
    return [
        float(sample.get(mask_key, 1.0)) * float(weights.get(sample.get(label_key), 0.0))
        for sample in samples
    ]


def outside_boundary_multiplier(sample: dict, multiplier: float) -> float:
    if (
        sample.get("boundaryFocused")
        and sample.get("quality") == "not_reached_target"
        and float(sample.get("targetBoundaryDistanceDeg", 0.0)) < 0.0
    ):
        return max(0.0, multiplier)
    return 1.0


def quality_sample_weights(
    samples: list[dict],
    balance_power: float = 0.5,
    outside_multiplier: float = 1.0,
) -> list[float]:
    weights = balanced_sample_weights(
        samples,
        "quality",
        mask_key="qualityWeight",
        balance_power=balance_power,
    )
    return [
        weight * outside_boundary_multiplier(sample, outside_multiplier)
        for sample, weight in zip(samples, weights)
    ]


def phase_sample_weights(samples: list[dict]) -> list[float]:
    return balanced_sample_weights(samples, "phase", mask_key="phaseWeight")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--features", required=True, help="Feature v2 JSON from scripts/build-motion-features.mjs")
    parser.add_argument("--out", default="training/artifacts/motion-tcn.keras")
    parser.add_argument("--epochs", type=int, default=120)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--filters", type=int, default=48)
    parser.add_argument("--dropout", type=float, default=0.15)
    parser.add_argument("--patience", type=int, default=15)
    parser.add_argument("--phase-loss-weight", type=float, default=0.5)
    parser.add_argument("--quality-loss-weight", type=float, default=1.0)
    parser.add_argument("--class-balance-power", type=float, default=0.5)
    parser.add_argument("--outside-boundary-multiplier", type=float, default=2.0)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument(
        "--initial-model",
        help="Optional compatible Keras checkpoint used to initialize a real fine-tuning run.",
    )
    parser.add_argument(
        "--freeze-phase",
        action="store_true",
        help="Freeze the independent phase head while fine-tuning target quality weights.",
    )
    parser.add_argument(
        "--checkpoint-monitor",
        choices=("quality", "phase", "combined"),
        default="quality",
        help="Validation objective used for checkpointing, early stopping, and LR scheduling.",
    )
    parser.add_argument("--seed", type=int, default=1337)
    parser.add_argument("--deterministic", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def residual_tcn_block(tf, inputs, filters: int, dilation: int, dropout: float, name: str):
    residual = inputs
    hidden = tf.keras.layers.Conv1D(
        filters,
        3,
        padding="causal",
        dilation_rate=dilation,
        use_bias=False,
        name=f"{name}_conv1",
    )(inputs)
    hidden = tf.keras.layers.LayerNormalization(name=f"{name}_norm1")(hidden)
    hidden = tf.keras.layers.Activation("relu", name=f"{name}_relu1")(hidden)
    hidden = tf.keras.layers.SpatialDropout1D(dropout, name=f"{name}_drop1")(hidden)
    hidden = tf.keras.layers.Conv1D(
        filters,
        3,
        padding="causal",
        dilation_rate=dilation,
        use_bias=False,
        name=f"{name}_conv2",
    )(hidden)
    hidden = tf.keras.layers.LayerNormalization(name=f"{name}_norm2")(hidden)
    hidden = tf.keras.layers.Activation("relu", name=f"{name}_relu2")(hidden)
    hidden = tf.keras.layers.SpatialDropout1D(dropout, name=f"{name}_drop2")(hidden)
    if int(inputs.shape[-1]) != filters:
        residual = tf.keras.layers.Conv1D(filters, 1, padding="same", name=f"{name}_residual")(residual)
    return tf.keras.layers.Activation("relu", name=f"{name}_out")(
        tf.keras.layers.Add(name=f"{name}_add")([residual, hidden])
    )


def build_model(tf, payload: dict, filters: int, dropout: float):
    input_shape = tuple(payload["inputShape"])
    angle_start, angle_end = joint_angle_feature_range(payload)
    inputs = tf.keras.Input(shape=input_shape, name="motion_window")
    phase_sequence = tf.keras.layers.LayerNormalization(name="phase_input_normalization")(inputs)
    for dilation in (1, 2, 4, 8):
        phase_sequence = residual_tcn_block(
            tf,
            phase_sequence,
            filters=max(8, filters),
            dilation=dilation,
            dropout=max(0.0, min(0.5, dropout)),
            name=f"phase_tcn_d{dilation}",
        )
    phase_context = tf.keras.layers.Cropping1D(
        cropping=(max(0, input_shape[0] - 1), 0),
        name="phase_last_timestep",
    )(phase_sequence)
    phase_context = tf.keras.layers.Flatten(name="phase_motion_context")(phase_context)
    phase_context = tf.keras.layers.Dropout(
        max(0.0, min(0.5, dropout)),
        name="phase_dropout",
    )(phase_context)
    phase = tf.keras.layers.Dense(
        len(payload["phases"]),
        activation="softmax",
        name="phase",
    )(phase_context)
    raw_last = tf.keras.layers.Cropping1D(
        cropping=(max(0, input_shape[0] - 1), 0),
        name="raw_last_timestep",
    )(inputs)
    raw_last = tf.keras.layers.Flatten(name="raw_last_features")(raw_last)
    last_feature_axis = tf.keras.layers.Reshape(
        (input_shape[1], 1),
        name="raw_last_feature_axis",
    )(raw_last)
    last_angles = tf.keras.layers.Cropping1D(
        cropping=(angle_start, input_shape[1] - angle_end),
        name="quality_joint_angle_slice",
    )(last_feature_axis)
    last_angles = tf.keras.layers.Flatten(name="quality_joint_angles")(last_angles)
    angle_context = tf.keras.layers.Dense(
        max(16, len(payload["jointNames"]) * 8),
        activation="relu",
        name="quality_angle_context",
    )(last_angles)
    quality_context = tf.keras.layers.Dense(
        max(16, filters // 2),
        activation="relu",
        kernel_regularizer=tf.keras.regularizers.L2(1e-4),
        name="quality_context",
    )(angle_context)
    quality_context = tf.keras.layers.Dropout(
        max(0.0, min(0.3, dropout / 2)),
        name="quality_dropout",
    )(quality_context)
    quality = tf.keras.layers.Activation(
        "softmax",
        name="quality",
    )(tf.keras.layers.Dense(
        len(payload["qualities"]),
        name="quality_logits",
    )(quality_context))
    return tf.keras.Model(
        inputs=inputs,
        outputs={"phase": phase, "quality": quality},
        name="physioai_motion_tcn_v2",
    )


def main(
    model_builder=None,
    architecture_id: str = "shared_motion_tcn.v2",
    architecture_version: int = 2,
    expected_exercise_id: str | None = None,
    expected_camera_view: str | None = None,
    expected_landmark_schema_id: str | None = None,
) -> None:
    args = build_arg_parser().parse_args()
    payload = load_features(Path(args.features))
    expected_contract = {
        "exerciseId": expected_exercise_id,
        "cameraView": expected_camera_view,
        "landmarkSchemaId": expected_landmark_schema_id,
    }
    for field, expected in expected_contract.items():
        if expected is not None and payload.get(field) != expected:
            raise ValueError(
                f"Architecture {architecture_id} requires {field}={expected}, "
                f"got {payload.get(field) or 'missing'}"
            )
    angle_start, angle_end = joint_angle_feature_range(payload, allow_empty=model_builder is not None)
    train_samples = samples_for_split(payload, "train")
    validation_samples = samples_for_split(payload, "validation")
    test_samples = samples_for_split(payload, "test")
    if not train_samples:
        raise ValueError("Feature payload has no train samples")
    summary = {
        "ok": True,
        "features": args.features,
        "out": args.out,
        "architectureId": architecture_id,
        "architectureVersion": architecture_version,
        "architectureContract": {
            field: expected for field, expected in expected_contract.items() if expected is not None
        },
        "exerciseId": payload["exerciseId"],
        "cameraView": payload["cameraView"],
        "samples": len(payload["samples"]),
        "trainSamples": len(train_samples),
        "validationSamples": len(validation_samples),
        "testSamples": len(test_samples),
        "inputShape": payload["inputShape"],
        "landmarkSchemaId": payload["landmarkSchemaId"],
        "motionFeatureSchemaVersion": payload.get("motionFeatureSchemaVersion"),
        "phases": payload["phases"],
        "qualities": payload["qualities"],
        "targetOutcomePolicy": payload.get("targetOutcomePolicy"),
        "boundaryTraining": payload.get("boundaryTraining"),
        "boundaryFocusSamples": payload.get("boundaryFocusSamples"),
        "phasePurityThreshold": payload.get("phasePurityThreshold"),
        "phaseTrainingSamples": payload.get("phaseTrainingSamples"),
        "lossWeights": {
            "phase": max(0.0, args.phase_loss_weight),
            "quality": max(0.0, args.quality_loss_weight),
        },
        "qualityJointAngleFeatureRange": None if angle_start == angle_end else [angle_start, angle_end],
        "qualityTrainingPhases": payload.get("qualityTrainingPhases", ["target"]),
        "phaseFeatureMode": "full_motion_tcn",
        "qualityDecisionMode": payload.get("qualityDecisionMode", "target_pose_joint_angle_classifier"),
        "featureContract": payload.get("featureContract"),
        "derivedFeatureContract": payload.get("derivedFeatureContract"),
        "derivedFeatureNames": payload.get("derivedFeatureNames", []),
        "formGeometryContract": payload.get("formGeometryContract"),
        "augmentationPolicy": payload.get("augmentationPolicy"),
        "classContract": payload.get("classContract"),
        "trainingDirection": payload.get("trainingDirection"),
        "classBalancePower": max(0.0, args.class_balance_power),
        "outsideBoundaryMultiplier": max(0.0, args.outside_boundary_multiplier),
        "learningRate": max(0.0, args.learning_rate),
        "initialModel": args.initial_model,
        "freezePhase": args.freeze_phase,
        "checkpointMonitor": args.checkpoint_monitor,
        "seed": args.seed,
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
        raise RuntimeError("Keras training requires numpy and tensorflow in the training environment.") from exc

    tf.keras.utils.set_random_seed(args.seed)
    if args.deterministic:
        tf.config.experimental.enable_op_determinism()

    def tensors(samples):
        return (
            np.asarray([sample["window"] for sample in samples], dtype="float32"),
            {
                "phase": np.asarray([sample["phaseOneHot"] for sample in samples], dtype="float32"),
                "quality": np.asarray([sample["qualityOneHot"] for sample in samples], dtype="float32"),
            },
        )

    x, y = tensors(train_samples)
    validation_data = None
    if validation_samples:
        validation_x, validation_y = tensors(validation_samples)
        validation_data = (
            validation_x,
            validation_y,
            {
                "phase": np.asarray(phase_sample_weights(validation_samples), dtype="float32"),
                "quality": np.asarray(
                    quality_sample_weights(
                        validation_samples,
                        balance_power=args.class_balance_power,
                        outside_multiplier=args.outside_boundary_multiplier,
                    ),
                    dtype="float32",
                ),
            },
        )

    quality_weights = quality_sample_weights(
        train_samples,
        balance_power=args.class_balance_power,
        outside_multiplier=args.outside_boundary_multiplier,
    )
    sample_weight = {
        "phase": np.asarray(phase_sample_weights(train_samples), dtype="float32"),
        "quality": np.asarray(quality_weights, dtype="float32"),
    }
    resolved_model_builder = model_builder or build_model
    model = resolved_model_builder(tf, payload, args.filters, args.dropout)
    if args.initial_model:
        initial_model = tf.keras.models.load_model(args.initial_model, compile=False)
        if initial_model.input_shape != model.input_shape:
            raise ValueError("Initial model input shape does not match the training architecture")
        if initial_model.output_names != model.output_names:
            raise ValueError("Initial model output contract does not match the training architecture")
        try:
            model.set_weights(initial_model.get_weights())
        except ValueError as exc:
            raise ValueError("Initial model weights do not match the training architecture") from exc
    if args.freeze_phase:
        for layer in model.layers:
            if layer.name == "phase" or layer.name.startswith("phase_"):
                layer.trainable = False
        summary["frozenPhaseLayers"] = [
            layer.name for layer in model.layers if not layer.trainable
        ]
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=max(1e-7, args.learning_rate)),
        loss={"phase": "categorical_crossentropy", "quality": "categorical_crossentropy"},
        loss_weights={
            "phase": max(0.0, args.phase_loss_weight),
            "quality": max(0.0, args.quality_loss_weight),
        },
        metrics={"phase": ["categorical_accuracy"], "quality": ["categorical_accuracy"]},
    )
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    best_path = out_path.with_name(f"{out_path.stem}.best.keras")
    monitor_metric = {
        "quality": "quality_loss",
        "phase": "phase_loss",
        "combined": "loss",
    }[args.checkpoint_monitor]
    monitor = f"val_{monitor_metric}" if validation_data else monitor_metric
    summary["checkpointMonitorMetric"] = monitor
    callbacks = [
        tf.keras.callbacks.TerminateOnNaN(),
        tf.keras.callbacks.ModelCheckpoint(
            best_path,
            monitor=monitor,
            mode="min",
            save_best_only=True,
        ),
        tf.keras.callbacks.EarlyStopping(
            monitor=monitor,
            mode="min",
            patience=max(2, args.patience),
            restore_best_weights=True,
        ),
        tf.keras.callbacks.ReduceLROnPlateau(
            monitor=monitor,
            mode="min",
            factor=0.5,
            patience=max(1, args.patience // 3),
            min_lr=1e-5,
        ),
    ]
    history = model.fit(
        x,
        y,
        sample_weight=sample_weight,
        epochs=max(1, args.epochs),
        batch_size=max(1, args.batch_size),
        shuffle=True,
        validation_data=validation_data,
        callbacks=callbacks,
        verbose=2,
    )
    model.save(out_path)
    summary["bestCheckpoint"] = str(best_path)
    summary["history"] = {key: [float(value) for value in values] for key, values in history.history.items()}
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
