# Local Rule JSON Tools

These tools run only on the local machine. They do not call Railway, a
Dashboard, an API, or any cloud service.

## Read a result in Terminal

```bash
node read-rule-json.mjs /path/to/rule-based-session.json
```

The reader validates the V8 JSON contract, rejects raw landmark/image fields,
and prints a compact summary plus every repetition's outcome.

## Visualize a result in a browser

Serve this folder locally, then drop the JSON file or paste its contents. The
visualizer imports the same validator as the terminal reader, so it should be
opened through this local HTTP server rather than directly as a `file://` URL:

```bash
cd Patient/native-ios/PhysioAIFaultEvidenceKit/Tools
python3 -m http.server 8099
# Open http://localhost:8099/rule-json-visualizer.html
```

The visualizer displays total/correct/incorrect/cannot-assess counts, incorrect
repetition totals by body region and rule-evidence severity, plus a
per-repetition table. It gives a human-readable answer to:

- how many completed repetitions were supplied by the host counter;
- which repetition was rule-flagged, with its tag and body region; and
- whether the rule emitted low/medium/high evidence severity.

Severity is only the relative severity of the host-qualified rule evidence. It
is not clinical severity, a diagnosis, or proof that a repetition succeeded or
failed functionally.

## Reproduce the frozen Rule-Wrap replay measurement

```bash
node validate-rule-wrap-replay.mjs \
  --replay /path/to/unseen_calibration3_rule_wrap_hybrid_v1.json \
  --sessionOut /tmp/rule-based-session.json \
  --validationOut /tmp/rule-based-validation.json
```

The replay adapter uses `predictedTags` as the frozen engine output. It compares
`expectedTags` only after the session JSON is built, so labels never become a
runtime input. The validation is decision-tag evidence; its repetition
boundaries are inherited from the frozen replay and do not prove live counter
accuracy.
