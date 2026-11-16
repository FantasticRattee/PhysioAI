# Bottle Grab: Handedness Instability in Live Camera

**Document version:** 1.0.0

**Version label / intended tag:** `bottle-grab-handedness-instability-doc-v1.0.0`

**Observed app version:** PhysioAI App V8.0.2 (`app:v8.0.2`, `build:3`)

**Recorded:** 2026-08-31 (Asia/Bangkok)
**Status:** Confirmed risk in live-camera behavior; documented but not fixed

## Summary

Bottle Grab can report the same physical hand as alternating `Left` and
`Right` across adjacent live-camera frames. The available evidence points to
frame-by-frame handedness resolution changing between Pose wrist association
and the detector-label fallback when confidence is near a threshold.

This behavior was not introduced by the recent Supabase, Therapist Web, or
project-configuration work. No handedness implementation was changed during
this investigation.

## Evidence captured

1. At the time of inspection, these handedness and camera-path files had no
   Git diff:

   - `iOS/PhysioAINative/MediaPipePipeline.swift`
   - `iOS/PhysioAINative/CameraSession.swift`
   - `iOS/PhysioAINative/NativeBottleGrabEngine.swift`
   - `iOS/PhysioAINative/NativePracticeView.swift`

2. Six handedness tests passed, including a 5,000-iteration stress test.
   Those tests use deterministic, stable landmarks. They confirm consistency
   for clean inputs but do not reproduce confidence changes, wrist occlusion,
   hand crossing, or detector-label jitter from a live camera.

3. The current resolver evaluates handedness again for every candidate on
   every frame. There is no retained stable side, temporal smoothing, grace
   period, or hysteresis across frames.

## Current decision path

The following line references describe the code as inspected on 2026-08-31
and may move after later edits.

- `MediaPipePipeline.swift:39-50` normalizes the detector label and swaps
  `Left` ↔ `Right` when the input buffer is unmirrored. MediaPipe handedness
  labels are defined for mirrored/selfie input, so this swap is an intentional
  anatomical correction for the rear-camera buffer.
- `MediaPipePipeline.swift:72-101` falls back to the corrected detector label
  when the hand landmarks, Pose landmarks, or both Pose wrists are unusable.
- `MediaPipePipeline.swift:120-178` accepts a Pose wrist association only when
  one wrist is a sufficiently clear match. The required distance gap between
  the two wrist candidates is `0.025`.
- `MediaPipePipeline.swift:187-189` considers a Pose wrist valid only when its
  visibility is finite and at least `0.5`.
- `MediaPipePipeline.swift:310-349` resolves and selects candidates for the
  current frame independently; it does not use the previous frame's side.
- `CameraSession.swift:1240-1255` mirrors front-camera connections and keeps
  rear-camera connections unmirrored.
- `CameraSession.swift:1284-1287` reads the actual mirroring state from the
  video connection for each captured frame and passes that state into the
  inference path.

## How the oscillation can occur

| Frame | Pose evidence | Resolver source | Possible reported side |
| --- | --- | --- | --- |
| A | Left wrist visible; association gap exceeds `0.025` | Pose wrist association | `Left` |
| B | Visibility drops below `0.5`, or both wrist distances are too similar | Corrected detector fallback | `Right` |
| C | Pose wrist becomes valid and unambiguous again | Pose wrist association | `Left` |

For an unmirrored rear-camera frame, the fallback swaps the raw detector label
to obtain an anatomical label. If the detector label itself changes while the
Pose association is unavailable or ambiguous, the resolver can alternate
`Left → Right → Left` even though the patient continues using the same hand.
The swap alone is not necessarily incorrect; the instability comes from
switching evidence sources without temporal continuity while their confidence
is fluctuating.

## Conditions likely to expose the issue

- The working wrist is briefly occluded or leaves a clean full-body view.
- Pose wrist visibility moves above and below `0.5` on adjacent frames.
- A hand crosses the torso or approaches the image center.
- Left and right wrist association distances differ by `0.025` or less.
- Motion blur or partial landmarks cause detector handedness to jitter.
- The resolver alternates between `pose_*` and
  `detector_unmirrored_swapped` sources.

## Why the existing tests do not disprove it

The passing tests establish deterministic correctness for fixed landmarks and
camera-mirroring inputs. Repeating the same stable case 5,000 times does not
simulate a time sequence that crosses the `0.5` visibility or `0.025`
association boundaries. A live-camera stability test needs a sequence of
frames with controlled noise, occlusion, center crossing, and detector-label
changes.

## Useful diagnostics for the next investigation

Capture these values together for consecutive frames:

- final resolved side and decision source;
- raw detector label and corrected anatomical detector side;
- `inputIsMirrored`;
- left and right Pose wrist visibility;
- left/right wrist distances and association limits;
- selected candidate index and detector confidence;
- transitions between `pose_*` and detector fallback sources.

The most useful reproduction trace will show several seconds before and after
the first incorrect side transition, rather than only the final displayed
label.

## Possible future mitigation directions

These are investigation options, not implemented changes:

1. Retain the last high-confidence anatomical side for a short grace window
   when Pose visibility drops briefly.
2. Require multiple consecutive frames before accepting a side change.
3. Use separate enter/exit thresholds around the visibility and association
   boundaries to add hysteresis.
4. Add sequence-based tests that deliberately cross both thresholds and
   verify that one physical hand retains one anatomical side.
5. Keep the decision source visible in DEBUG telemetry so a label transition
   can be tied to a Pose-to-detector fallback transition.

## Change status

No smoothing, hysteresis, handedness correction, threshold, camera-mirroring,
or candidate-selection code was changed as part of this documentation task.
Any fix should be handled as a separate change with live-camera reproduction
evidence and sequence-based regression tests.
