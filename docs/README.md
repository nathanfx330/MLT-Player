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
4. [POC 10 continuation: Layer Ordering, Role Swaps, and Atomic Presentation](poc-10-layer-ordering-and-atomic-role-swaps.md)
   — generalized three-layer visual Z-order, true two-layer base-role swapping,
   cross-aspect fitting, atomic graph-changing edits, double-buffered OpenGL
   textures, Flutter `Texture.freeze`, and first-swap profile prewarming.

Taken together, these documents cover the project's MLT journey from embedding
one producer in a Flutter/Linux player through a hardened three-layer
composition whose ordering and two-layer base-role changes can be reproduced
independently in offline export without exposing intermediate rebuild states.

## Current checkpoint

POC 10 now has a tested **three-layer composition, timing, ordering, and export
model**.

Layers 2 and 3 can be timed video or held still images and carry independent
opacity, visibility, position, scale, anchors, alpha interpretation, source
replacement, audio gain, timeline START/END, and—when timed—SOURCE IN/OUT.

Visual Z-order is explicit state. Layer 1, Layer 2, and Layer 3 can participate
in Move Up / Move Down ordering while preview and export carry the same order
permutation.

With exactly two layers, moving timed Layer 2 into the Layer-1 role performs a
true base-role swap: the promoted source becomes the new profile/frame-zero/
duration authority and the displaced former base becomes a normal editable
Layer 2. Cross-frame-rate boundaries are converted through time and cross-aspect
sources are fitted against the new base canvas rather than inheriting an
unrelated transform.

Graph-changing edits are presented atomically. The implementation combines
Dart notification batching, native frame publication freeze, a final-frame
readiness barrier, double-buffered OpenGL texture names, Flutter
`Texture.freeze`, and a first-swap hidden-texture prewarm so the user sees the
old completed composition until the new completed composition is ready.

MP4, ProRes/MOV, current-frame PNG, PNG-sequence, and WAV exports rebuild the
indexed composition on a separate worker graph. Video export also supports an
explicit output-rate conform policy.

The native safety net includes:

- no-active-engine guard regression tests
- the main transport/composition smoke test
- preview/export parity for two- and three-layer scenarios
- bounded layer START/END coverage
- timed-overlay SOURCE IN/OUT coverage
- generalized layer-order coverage
- video export preset coverage
- video export frame-rate conform coverage
- the known MLT 7.22 encoded-audio PTS warning tracked separately from export
  correctness

The current model deliberately stops at three layers. A fourth layer is
rejected rather than silently creating an untested topology. Visual ordering is
generalized across all three layers; arbitrary three-layer **base-role
promotion** remains a separate future product decision. Layer 3 is still
removed before Layer 2.

All implementation notes currently describe behavior tested against **MLT
7.22.0 on Linux** unless a section says otherwise.
