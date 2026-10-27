# Migration Review Lessons

## Root Causes

Correct characters do not prove correct product rows. Actual5-degree fixtures exposed weak deskew estimation combined with a12px row cap, splitting names/quantities from SKUs. Separately, the UI45s timeout did not stop active native inference, so timed-out work could block the serial lane. These are geometry and lifecycle contract gaps.

## Prevention

- Added actual noisy box coordinates to Kotlin tests, rather than only ideal equal-angle data.
- Propagated deadlines to per-request ORT RunOptions; joined cancellation watchdog; verified same-engine recovery.
- Released detector output before recognition. Bounded dimensions, box count and line width, with errors rather than partial success.
- Recorded source/model/runtime hashes and numerical conversion equivalence. Actual-model fixtures execute the production C++ core.
- Migrated .trellis/spec/frontend/quality-guidelines.md to v6 tensor/dictionary/lifecycle/packaging contracts. No src/templates/markdown/spec directory exists here to synchronize.

## Remaining Evidence

Host fixtures and successful APK compilation cannot prove phone PSS/latency or accuracy across real layouts. Existing Dart quantity guessing, defaults and brand filters remain sample-review risks; this engine migration does not silently change inventory rules.
