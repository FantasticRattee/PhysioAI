# Dynamic Weight Shift training workspace

This workspace contains the code and artifacts needed to prepare, train,
evaluate and export the DWS model used by PhysioAI Final. Run its commands from
`DWS/`. The app's active iOS SDK and compiled model remain under
[`../iOS/Modules/PhysioAIDynamicWeightShiftSDK`](../iOS/Modules/PhysioAIDynamicWeightShiftSDK).

## Included files

| Path | Contents |
| --- | --- |
| `exercise-modules/dynamic_weight_shifts/training/` | Feature building, TCN architecture, trainers, profiles, dataset repair and augmentation tools |
| `exercise-modules/training/`, `shared/`, `scripts/` | The complete local import dependencies and evaluation/fixture tools |
| `training/` | Shared Keras trainer/evaluator, TFJS and Core ML exporters, pinned Python requirements |
| `data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/datasets/` | 122 original stored records plus their index; 53 therapist-reference and 69 synthetic-review records |
| `data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs/left-tcn-v3/` | Frozen 1,759 feature windows, final/best `.keras` checkpoints and evaluation records |
| `shared/models/cust_dynamic_weight_shifts-left-tcn-v3/` | The deployed TensorFlow.js graph, weights, manifest and evaluation |
| `artifact-manifest.json` | SHA-256 inventory for the datasets, frozen run and shipped model resources |
| `tests/` | Dataset/feature contract tests and checks against the native fixture |

The complete historical dataset collection, including older experiments and
additional diagnostic arrays, is also available in
[Dataset / Dynamic Weight Shift / DWS_Dataset_All](https://drive.google.com/drive/folders/1x_X7IddGnG-69jHgij7mOO6mx6CcA2lb).
The committed frozen run identifies the model used by the app; historical
feature files from other runs are retained in that Drive collection.

## Model contract

- Version: `cust_dynamic_weight_shifts-left-tcn-v3`.
- Input: 30 frames × 23 features (16 shoulder/hip coordinates and visibility
  values, plus seven torso-geometry features).
- Phase head: `rest`, `target`; form head: `correct_left`, `wrong_left`.
- Hip-centred normalization, `screen.v1` landmark slots and `mirrorX: false`.
- Synthetic variants retain their source lineage and stay in training splits.

The frozen run has 93 selected records (89 train, two validation, two test),
with 1,759 correlated windows. The stored collection now contains additional
records: rebuilding it selects 110 records and creates 1,994 windows. Use the
frozen features to replay the shipped model; use a new run name when training
on the current collection. The runner rejects writes to `left-tcn-v3`.

The JavaScript helpers retain their development-workspace policies. The
native runtime contract (including its 7° shoulder-tilt limit) is documented
in [the integration record](../Docs/DynamicWeightShiftV300Integration.md).
Training/export commands write candidate artifacts and do not replace the
native app's compiled model. Automatic candidate publication remains blocked.

## Install and verify

Node.js 22+ and Python 3.11/3.12 are required. Core ML execution requires macOS;
the JavaScript tests and Keras workflows can run without Xcode.

```bash
cd DWS
npm ci --ignore-scripts --no-audit --no-fund
python3.12 -m venv .venv
.venv/bin/python -m pip install -r training/requirements-export.txt
.venv/bin/python -m pip install --no-deps tensorflowjs==4.22.0
npm test
npm run verify
```

The TFJS exporter uses its SavedModel converter. JAX is pinned for the
converter's imports. Installing the TFJS wheel separately preserves the pinned
TensorFlow 2.17.1 stack; the exporter isolates the unused forest integration.
For training alone, install `training/requirements.txt` instead.

## Replay the shipped checkpoint

```bash
DWS_RUN=data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs/left-tcn-v3
mkdir -p artifacts
.venv/bin/python training/evaluate_motion_tcn_keras.py \
  --model "$DWS_RUN/motion-tcn-left-tcn-v3.best.keras" \
  --features "$DWS_RUN/features.json" --split test \
  --out artifacts/frozen-evaluation.json

# macOS: compare the checkpoint with the exact compiled model in the iOS app.
.venv/bin/python scripts/verify_dataset_coreml.py \
  --keras "$DWS_RUN/motion-tcn-left-tcn-v3.best.keras" \
  --features "$DWS_RUN/features.json" --split test \
  --coreml ../iOS/Modules/PhysioAIDynamicWeightShiftSDK/Resources/PhysioAIDynamicWeightShiftTCN.mlmodelc \
  --out artifacts/bundled-coreml-parity.json
```

The import verification reproduced the stored held-out evaluation and compared
33 windows against the bundled Core ML model. The largest absolute output
difference was `6.258487701416016e-7` on macOS CPU. This checks model conversion;
it does not exercise the iPhone camera, UI or repetition workflow.

## Train a new candidate

```bash
# Inspect commands and paths first.
npm run model -- --run experiment-01 --stage plan --python .venv/bin/python

# Prepare features, train, evaluate, export TFJS and evaluate the candidate.
npm run model -- --run experiment-01 --stage all --python .venv/bin/python
```

Individual stages are `features`, `train`, `evaluate`, `export` and `hybrid`.
New run outputs and candidate exports are ignored by Git. The four-class and
correct-only experimental scripts are retained for provenance; the app's
shipped model uses `run_left.mjs` / `train_left.py`.

## Export Core ML and fixtures

```bash
DWS_RUN=data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs/left-tcn-v3
.venv/bin/python training/export_keras_to_coreml.py \
  --model "$DWS_RUN/motion-tcn-left-tcn-v3.best.keras" \
  --manifest shared/models/cust_dynamic_weight_shifts-left-tcn-v3/manifest.json \
  --out artifacts/DynamicWeightShift.mlpackage

.venv/bin/python scripts/verify_dataset_coreml.py \
  --keras "$DWS_RUN/motion-tcn-left-tcn-v3.best.keras" \
  --features "$DWS_RUN/features.json" --split test \
  --coreml artifacts/DynamicWeightShift.mlpackage

node scripts/generate_feature_fixture.mjs --out artifacts/dws_feature_parity.json
.venv/bin/python scripts/generate_dataset_fixture.py \
  --keras "$DWS_RUN/motion-tcn-left-tcn-v3.best.keras" \
  --features "$DWS_RUN/features.json" --split test \
  --out artifacts/dws_dataset_replay.json
```

Core ML export defaults to Float16; `--float32` retains Float32 precision.
To prepare a candidate for a native build, use Xcode's
`xcrun coremlcompiler compile artifacts/DynamicWeightShift.mlpackage artifacts/`.
Review the conversion report before updating the app's model and fixtures.

## Data and provenance

The source datasets and frozen artifacts were copied byte-for-byte from the
existing DWS workspace on 29 October 2026. Original labels, identifiers,
timestamps and review flags are retained. Records without an eligible reviewed
label remain excluded by the feature builder. Archived feature windows and
synthetic variants must not be counted as additional independent recordings.

Shared helper modules are included so the training imports resolve locally.
The training commands use local files; backend credentials are not required.
No trained candidate from the import smoke test replaces the shipped weights.
