# PhysioAI Fault Evidence Kit

Foundation-only Swift Package for the App V8.0.0 local fault-evidence
contract. It is designed to be embedded by a native iOS host or imported by a
friend's app without importing MediaPipe, AVFoundation, SwiftUI, Core ML, or
network dependencies.

## Contract

The package accepts only two derived inputs:

1. `FrameInput`: timestamp, capture-QC state/reason, camera-source generation,
   and the existing repetition total.
2. `QualifiedSignal`: a semantic fault/comment signal already qualified by an
   upstream engine, with body region, landmark *references*, and derived
   metric metadata.

Repeated contiguous signals aggregate into one observation. A later assessable
frame without the signal closes it. A camera/lens source-generation change
closes active observations so callbacks from an old source cannot merge into a
new source. `cannot_assess` frames increase coverage and are never faults.

`repetitionSummary` reports the highest observed `totalReps`, distinct
comment-flagged repetition indexes/count, and nullable correctness counts.
Until a fault-producing engine exists, correctness is explicitly encoded as
`null` with `correctnessStatus: "unavailable_no_fault_engine"`.

## Live snapshots and finalization

```swift
let recorder = FaultEvidenceRecorder(exerciseID: "bottle_grab")
recorder.ingest(frame: frameInput, signal: qualifiedComment)

let live = recorder.currentRecord()             // does not close active event
let liveJSON = try recorder.encodedCurrentRecord()
let final = recorder.finalizedRecord()          // closes active events once
let finalJSON = try recorder.encodedFinalizedRecord()
```

`localRecord()` and `encodedLocalRecord()` remain compatibility aliases with
finalizing semantics. Use `currentRecord()` for a developer HUD or any live
validation path.

For hosts where camera/frame admission and engine callbacks arrive separately,
use the explicit two-stage contract. Coverage is counted once, while delayed
signals can arrive one or more times before the host closes that frame:

```swift
recorder.ingestFrame(frameInput)                         // coverage once
recorder.ingestSignals(for: frameInput, signals: poseSignals)
recorder.ingestSignals(for: frameInput, signals: handSignals)
recorder.finishSignalEvaluation(for: frameInput)        // close missing events
```

`ingestSignals(for:signals:)` never increments `observedFrames` and never
closes an active event. This explicit completion call prevents a first delayed
callback from prematurely closing evidence while another engine callback for
the same frame is still in flight. The convenience `ingest(frame:signals:)`
performs all three steps for a single combined callback.

## Privacy boundary

The public API has no type for image bytes, raw landmarks, pixel coordinates,
patient identifiers, or network clients. The output contains only derived
semantic references and aggregate timing/count metadata. This package is
process-local; it does not write files, call a backend, send an LLM request, or
connect a Therapist Dashboard.

The machine-readable contract is [fault-evidence.schema.json](Sources/PhysioAIFaultEvidenceKit/Resources/fault-evidence.schema.json).

## Rule-based completed-repetition JSON

`RuleBasedSessionRecorder` is the separate local V8 measurement contract for a
host that needs a per-repetition result. The host still owns Camera/MediaPipe,
Capture-QC and repetition boundaries; it submits one completed repetition with
its already-qualified `fault_observation` signals.

```swift
let rules = RuleBasedSessionRecorder(exerciseID: "bottle_grab")
try rules.recordCompletedRepetition(
  RuleBasedRepetitionInput(
    repIndex: 1,
    assessableFrameCount: 8,
    skippedFrameCount: 0,
    faultSignals: qualifiedFaultSignals,
  )
)
let json = try rules.encodedCurrentRecord()
```

The result schema is
`physioai.rule_based_bottle_grab_session.v1`. It reports total, correct,
incorrect, cannot-assess and incomplete repetition counts, fault tags, body
regions and rule-evidence severity. `cannot_assess` is never counted as
incorrect. This remains experimental visible-fault evidence, not clinical
correctness, contact/grip truth, or patient-facing approval.

For a native host whose counter restarts at zero on a new camera-source
generation, the V8 adapter maintains a separate derived-session offset so
completed JSON indices continue in order. The package never changes the host
counter itself; a non-native host may choose its own session-boundary policy.

Use [rule-based-session.schema.json](Sources/PhysioAIFaultEvidenceKit/Resources/rule-based-session.schema.json)
for a non-Swift host and the local [Tools README](Tools/README.md) for the
terminal JSON reader, browser visualizer, and frozen replay adapter.

## Plug into another Swift/iOS app

The package can be added in Xcode as a local package by selecting this folder,
or as a remote package after it is published to GitHub. It has no MediaPipe,
AVFoundation, SwiftUI, model, API, or signing dependency.

Use [BottleGrabEvidenceHostAdapter.swift](Examples/BottleGrabEvidenceHostAdapter.swift)
as the host-side mapping example. Its key ordering is intentional:

1. Send each already-derived counter/Capture-QC result through
   `ingestCounterFrame` exactly once.
2. When the host has received all signal callbacks for that same timestamp,
   call `finishHandCommentEvaluation` once, with an empty signal list when no
   comment is qualified.
3. Read `currentJSON()` during a live session; call `finalizedJSON()` only at
   a deliberate session end.
4. For the per-repetition rule JSON, call
   `recordCompletedRuleBasedRep(...)` only after the host counter has completed
   that repetition, then read `currentRuleBasedJSON()`. Pass only derived
   assessable/skipped coverage and qualified `fault_observation` signals.

The host owns MediaPipe/model execution and decides how an already-derived,
de-identified JSON record is transported. This package itself never sends it.

## GitHub publication boundary

Publish **this package directory** as its own repository, rather than exposing
the entire PhysioAI application as a dependency. This folder is intentionally
free of signing identity, camera/model dependencies, backend URLs, credentials,
and generated SwiftPM build output. Before any push, run `swift test`, check
that `.build/` remains ignored, and run the repository's staged secret/signing
scrub. A consuming iOS app still chooses its own Apple Team and bundle ID.

## Verify

```bash
swift test
```
