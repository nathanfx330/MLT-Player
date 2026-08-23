# MLT Player engineering notes

These notes document the implementation journey behind MLT Player rather than
trying to replace the upstream MLT API reference.

## Reading order

1. [Embedding MLT in a Flutter/Linux Desktop Player](embedding-mlt-in-a-flutter-linux-app.md)
   — the foundational journey: MLT lifecycle, playback, Flutter texture
   integration, threading, precise transport, inspection, selection/trim, and
   the first independent background-export proof.
2. [POC 9: Export Formats and Hardening](poc-9-export-formats-and-hardening.md)
   — the point where the first MP4 proof became a dependable output system:
   current-frame PNG, display-correct anamorphic PNGs, image sequences, WAV,
   output policy, progress/cancel, filesystem ownership, completion validation,
   and deterministic regression fixtures.
3. [POC 10: Multitrack, Compositing, and Tractor-Aware Export](poc-10-multitrack-compositing-and-export.md)
   — the move from a single producer to opaque engine handles, MLT tractors,
   playhead-relative layers, alpha/audio/geometry controls, independent
   composition export, preview/export parity, native hardening, a real third
   layer, composition history, and seamless Layer 3 Remove/Undo restoration.

Taken together, these documents cover the project's MLT journey from embedding
one producer in a Flutter/Linux player through a hardened three-layer
composition that can be reproduced independently in offline export.

## Current checkpoint

POC 10 now has a tested **three-layer** composition model.

Layer 1 remains the timed base movie and defines the profile and duration.
Layers 2 and 3 can be timed video or held still images. Each overlay can begin
at the parked playhead and carry independent opacity, visibility, position,
scale, anchors, alpha interpretation, source replacement, and audio gain.

MP4, current-frame PNG, PNG-sequence, and WAV exports rebuild the indexed
composition on a separate worker graph rather than exporting only the base
source.

The native safety net now includes:

- no-active-engine guard regression tests
- the main transport/composition smoke test
- preview/export parity for two- and three-layer scenarios
- a focused MLT 7.22 MP4 audio PTS diagnostic

Composition Undo/Redo includes explicit layer removal. Adding Layer 2 or Layer 3
establishes a new history baseline, while explicit removal remains undoable.
Layer 3 Remove/Undo is visually atomic: native frame publication and Dart model
notifications are held until the replacement graph is fully restored.

The current model deliberately stops at three layers. A fourth layer is rejected
rather than silently creating an untested topology. Broader ordering/timing
operations and MLT XML interchange remain future work.

All implementation notes currently describe behavior tested against **MLT
7.22.0 on Linux** unless a section says otherwise.
