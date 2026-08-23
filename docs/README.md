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
   — the move from a single producer to opaque engine handles, a two-layer MLT
   tractor, live layer controls, alpha handling, audio mixing, geometry, and
   export of the actual composition.

Taken together, these documents cover the project's MLT journey from embedding
one producer in a Flutter/Linux player through a tested two-layer composition
that can be reproduced in offline export.

## Current checkpoint

The project is now beyond the original single-source player architecture.
POC 10 has proven a two-layer composition in preview and in offline export.
Layer 1 remains the timed base movie and defines the movie duration. Layer 2
can be video or a still image, can begin at the parked playhead, and can be
moved, scaled, hidden, reordered, given opacity and audio level, and interpreted
for alpha. MP4, PNG-frame, PNG-sequence, and WAV exports rebuild that composition
on a separate worker graph instead of exporting only the base source.

The next work is refinement rather than proving the basic tractor path: broader
preset/output controls, deeper track editing, and eventual MLT XML interchange.

All implementation notes currently describe behavior tested against **MLT
7.22.0 on Linux** unless a section says otherwise.
