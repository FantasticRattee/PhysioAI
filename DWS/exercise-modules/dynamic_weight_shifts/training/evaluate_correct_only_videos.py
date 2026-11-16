#!/usr/bin/env python3

"""Evaluate external Dynamic Weight Shifts videos with a Correct-only model."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

from experiment_correct_only_left import novelty_score, rep_embedding


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Folder containing MP4 reps")
    parser.add_argument("--model", required=True, help="Correct-only model.json")
    parser.add_argument("--pose-model", required=True, help="MediaPipe Pose Landmarker .task")
    parser.add_argument("--out", required=True, help="Evaluation JSON output")
    parser.add_argument("--target-start", type=float, default=5.0)
    parser.add_argument("--target-end", type=float, default=10.0)
    parser.add_argument("--sample-hz", type=float, default=10.0)
    return parser.parse_args()


def video_duration_seconds(capture: cv2.VideoCapture) -> float:
    fps = float(capture.get(cv2.CAP_PROP_FPS) or 0)
    frames = float(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    return frames / fps if fps > 0 and frames > 0 else 0.0


def detect_target_frames(
    landmarker: vision.PoseLandmarker,
    video_path: Path,
    target_start: float,
    target_end: float,
    sample_hz: float,
) -> tuple[list[dict], dict]:
    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise RuntimeError("video_open_failed")
    duration = video_duration_seconds(capture)
    start = min(max(0.0, target_start), max(0.0, duration - 0.001))
    end = min(max(start + 0.001, target_end), duration)
    sample_count = max(1, int(np.floor((end - start) * sample_hz)) + 1)
    frames = []
    attempted = 0
    try:
        for index in range(sample_count):
            seconds = min(end - 0.001, start + index / sample_hz)
            if seconds < 0:
                continue
            capture.set(cv2.CAP_PROP_POS_MSEC, seconds * 1000)
            ok, bgr = capture.read()
            if not ok or bgr is None:
                continue
            attempted += 1
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            timestamp_ms = int(round(seconds * 1000))
            result = landmarker.detect_for_video(image, timestamp_ms)
            pose_groups = getattr(result, "pose_landmarks", None) or []
            if not pose_groups:
                continue
            landmarks = [
                [
                    float(point.x),
                    float(point.y),
                    float(point.z),
                    float(getattr(point, "visibility", 1.0)),
                ]
                for point in pose_groups[0]
            ]
            frames.append({
                "t": timestamp_ms,
                "phase": "target",
                "boundaryStatus": "inside",
                "landmarks": landmarks,
            })
    finally:
        capture.release()
    return frames, {
        "durationSeconds": duration,
        "targetStartSeconds": start,
        "targetEndSeconds": end,
        "sampleHz": sample_hz,
        "attemptedFrames": attempted,
        "detectedFrames": len(frames),
        "detectionRate": len(frames) / attempted if attempted else 0,
    }


def main() -> None:
    args = parse_args()
    input_dir = Path(args.input).resolve()
    output_path = Path(args.out).resolve()
    with Path(args.model).open(encoding="utf-8") as handle:
        model = json.load(handle)
    references = np.asarray(
        [item["embedding"] for item in model["referenceEmbeddings"]],
        dtype=np.float64,
    )
    threshold = float(model["threshold"])
    neighbors = int(model["neighbors"])
    options = vision.PoseLandmarkerOptions(
        base_options=python.BaseOptions(model_asset_path=str(Path(args.pose_model).resolve())),
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
        min_pose_detection_confidence=0.5,
        min_pose_presence_confidence=0.5,
        min_tracking_confidence=0.5,
    )
    results = []
    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        for video_path in sorted(input_dir.rglob("*.mp4")):
            try:
                frames, detection = detect_target_frames(
                    landmarker,
                    video_path,
                    args.target_start,
                    args.target_end,
                    args.sample_hz,
                )
                embedding = rep_embedding({"frames": frames})
                if embedding is None:
                    results.append({
                        "file": str(video_path),
                        "expected": "wrong_left",
                        "predicted": "unscorable",
                        "error": "insufficient_pose_frames",
                        "detection": detection,
                    })
                    continue
                score = novelty_score(embedding, references, neighbors)
                results.append({
                    "file": str(video_path),
                    "expected": "wrong_left",
                    "predicted": "correct_left" if score <= threshold else "wrong_left",
                    "score": score,
                    "threshold": threshold,
                    "thresholdRatio": score / threshold if threshold else None,
                    "detection": detection,
                })
            except Exception as error:
                results.append({
                    "file": str(video_path),
                    "expected": "wrong_left",
                    "predicted": "unscorable",
                    "error": f"{type(error).__name__}: {error}",
                })
            print(f"{video_path.name}: {results[-1]['predicted']}", flush=True)

    scorable = [item for item in results if item["predicted"] != "unscorable"]
    rejected = [item for item in scorable if item["predicted"] == "wrong_left"]
    report = {
        "schema": "physioai.correct_only_video_evaluation.v1",
        "evaluatedAt": datetime.now(timezone.utc).isoformat(),
        "model": str(Path(args.model).resolve()),
        "poseModel": str(Path(args.pose_model).resolve()),
        "input": str(input_dir),
        "policy": "External wrong_left videos are evaluation-only and never update the Correct-only model or threshold.",
        "targetWindowSeconds": [args.target_start, args.target_end],
        "sampleHz": args.sample_hz,
        "metrics": {
            "videoCount": len(results),
            "scorableCount": len(scorable),
            "unscorableCount": len(results) - len(scorable),
            "wrongRejected": len(rejected),
            "wrongRejectionRate": len(rejected) / len(scorable) if scorable else None,
        },
        "results": results,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps(report["metrics"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
