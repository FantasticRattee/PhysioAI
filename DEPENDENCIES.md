# Combination V1 Change-Impact Map

Current release identity verified: 2026-09-10. Earlier runtime-map claims
remain dated to their original investigations.

This map covers the current Combination V1 repository. It is an impact checklist,
not a statement that every planned connection is live.

## Artifact inventory

| Area | Current artifact | Authority / role |
| --- | --- | --- |
| Native patient app | `iOS/PhysioAINative/` | Runtime behavior and session UI |
| Current version and rollback | `iOS/STABLE_VERSION.md`; `Docs/CombinationV1V8017CleanUIRelease.md`; V8.0.16 rollback branch at `b9b0d52` | V8.0.17 is the user-approved clean-UI variant; local V8.0.16 rollback is read-only and cloud backup retains the original commit; older V8.0.15 tag remains preserved |
| Fault Detector contract | `iOS/PhysioAIFaultEvidenceKit/` | Privacy-safe rule evidence schema and Bottle Grab aggregation |
| Sit-to-Stand Fault Detector | `iOS/PhysioAINative/NativeSitToStandRuleBasedEvidenceV12Module.swift` | Existing persistent per-repetition Sit-to-Stand rules |
| Dynamic Weight Shift | `iOS/Modules/PhysioAIDynamicWeightShiftSDK/`; upstream `dws-ios@v3.0.0` | Isolated front-camera Pose Heavy + Core ML TCN runtime and UI |
| Native tests | `iOS/NativeTests/` | App integration and regression evidence |
| Session persistence | `iOS/PhysioAINative/NativeModels.swift` and Supabase `exercise_sessions` | Aggregate session fields only |
| Therapist web | `TherapistWeb/` | Reads saved session aggregates and requests AI review |
| V8.0.13 design | `Docs/CombinationV1V8013FaultScoringDesign.md` | Approved scoring and Summary behavior |
| V8.0.15 posture/count repair | `Docs/CombinationV1V8015SitToStandPostureRepair.md` | Current image-plane counter observation and posture-aware guided start |
| Integration diagram | FigJam node `47:168` | Current and future system-flow visualization |
| Prior V8.0.12 port | `Docs/CombinationV1V8PortDesign.md` | Historical port boundary and rollback context |

## Runtime dependency graph

```text
Camera frames
  -> exercise-specific runtime boundary
       -> DWS: dedicated DWSPoseCameraRuntime -> Pose Heavy + TCN + safety gate
       -> Bottle Grab / Sit-to-Stand: legacy MediaPipe Pose / Hand measurements
  -> existing exercise engine + authoritative repetition counter + TTS
       -> Sit-to-Stand V8.0.15: image-plane leg spans -> seated/standing posture
          -> seated baseline, rise, qualified standing hold, seated return
       -> posture/readiness -> calm guided-start card and TTS
  -> observer-only Fault Detector, finalized at the same completed-rep boundary
  -> RuleBasedSessionRecord JSON (local, derived, no raw frames or landmarks)
  -> NativeEvidenceExport validation
  -> NativeRuleBasedSessionScoreV13
       -> NativeSessionSummary and Summary UI
       -> existing exercise_sessions aggregate columns
            -> Therapist history score
            -> existing automatic AI-review request

RuleBasedSessionRecord JSON
  -> DEBUG local Export Evidence JSON
  -/-> detailed Therapist evidence delivery (future; not connected)
```

## Change-impact matrix

| If this changes | Update / verify | Also synchronize |
| --- | --- | --- |
| Practice-layer visibility (2026-09-09) | `NativePracticeView.swift`; `NativePracticePresentationTests.swift`; rendered simulator check | `Docs/CombinationV1V8017CleanUIRelease.md`; no model/counter/TTS/data-contract or diagram-flow change |
| V8.0.13 score formula, severity deduction, evidence gate | `NativeRuleBasedSessionScoreV13.swift`; scorer tests; Summary copy | V8.0.13 design, this map, FigJam score node, mistake record |
| Sit-to-Stand V8.0.15 posture/count/guidance | `NativeSitToStandV72AIModule.swift`; `NativeV812CoachingPolicy.swift`; `NativePracticeView.swift`; `NativeSitToStandV72Tests.swift`; current module/evidence manifests | V8.0.15 design, current counter mistake record, Info/profile/version tests, device validation |
| Bottle Grab or Sit-to-Stand Fault Detector rules | Owning detector module and detector tests | Score-category mapping, evidence manifest/README, design, FigJam runtime labels |
| DWS camera, model, thresholds, or layout | Local DWS pod, `DWSPracticeScreen`, imported DWS tests | `dws-ios@v3.0.0` provenance, hashes, catalog migration, minimum iOS 17 |
| Summary metrics or fault breakdown | `NativeSummaryView.swift`; view/source tests | Design acceptance criteria and screenshots used for release validation |
| Aggregate session persistence | `NativeModels.finishPractice`; `NativeSessionRecord`; Supabase session schema; save/fetch tests | Therapist history and AI-review payload consumers |
| Detailed evidence delivery | New explicit API/storage contract and privacy review | Supabase migration, Railway API, TherapistWeb, RLS, retention policy, FigJam FX-01 path |
| App version/build identity | `Info.plist`; `NativeAppBuildProfile.swift`; `STABLE_VERSION.md`; README; version tests | Relevant manifests and release/handoff documents |

## V8.0.15 aggregate data contract

| Native V8.0.15 value | Existing session field | Delivery state |
| --- | --- | --- |
| Overall rule score | `overall_score` | Existing session save path |
| Form Quality | `pose_score` | Existing session save path |
| Motion score | `motion_score` | Remains `null`; V8.0.13 does not invent it |
| Flagged repetition count | `invalid_reps` | Existing session save path |
| Consistency | none | Local Summary only |
| Evidence Coverage | none | Local Summary only |
| Per-repetition signals / fault breakdown | none | Local JSON/export only |

## DWS training and model conversion

The self-contained [DWS workspace](DWS/README.md) includes Node dependency
locks, Python requirements, original landmark datasets, the frozen
`left-tcn-v3` features/checkpoints and the deployed TFJS model. It uses
TensorFlow 2.17.1, Keras 3.15.0, NumPy 1.26.4, TFJS 4.22.0 and Core ML Tools
8.3.0. See `DWS/training/requirements-export.txt` for the converter setup.
These development dependencies are separate from the Therapist Web package.

`DWS/artifact-manifest.json` records SHA-256 hashes for its frozen artifacts
and the existing native DWS model resources. The training commands create
candidate outputs; the app continues to load its bundled native model.

## Known synchronization boundaries

- The preserved older user-selected baseline is Combination V1 - V8.0.15 at tag
  `combination-v1-v8.0.15-baseline`. Do not move the tag when applying future
  fixes. Baseline designation and readiness to merge into main are separate.
- The pending-evidence carryover issue from an abandoned STS attempt remains
  open in this baseline; its trace is in the scoring mistake record.

- Full Fault Evidence Delivery to Therapist Dashboard is not connected. It must
  remain visually and verbally labeled as future until an explicit backend and
  privacy contract is implemented.
- The existing automatic AI review can consume saved aggregate session fields;
  it does not receive V8.0.13 per-repetition evidence.
- Score comparisons are meaningful only within the same exercise and rule-set
  version. Bottle Grab and Sit-to-Stand do not have equivalent rule coverage.
- Evidence Coverage uses the exercise counter's completed total as denominator;
  a shorter evidence record must reduce coverage rather than inflate a score.
- Release identity and engine provenance are separate: the App is V8.0.17/build
  17, while `portedEngineVersion` remains V8.0.12. V8.0.17 retains V8.0.16's
  DWS integration and all model/evidence manifests unchanged. The STS wrapper is
  `1.3.0-dev-image-plane-posture`; its counter input and guided start changed.
  NN features, weights, evidence rules, and score formula retain their definitions.
- FigJam node `47:168` continues to mark V8.0.13 aggregate scoring as current;
  V8.0.15 does not activate FX-01 detailed evidence delivery, which remains
  future/not connected.
