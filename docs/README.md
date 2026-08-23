# MLT Player engineering notes

These notes document the implementation journey behind MLT Player rather than
trying to replace the upstream MLT API reference.

## Reading order

1. [Embedding MLT in a Flutter/Linux Desktop Player](embedding-mlt-in-a-flutter-linux-app.md)
   — the playback, texture, transport, inspection, selection, trim, and first
   background-export foundation through POC 9.
2. [POC 10: Multitrack, Compositing, and Tractor-Aware Export](poc-10-multitrack-compositing-and-export.md)
   — the move from a single producer to opaque engine handles, a two-layer MLT
   tractor, live layer controls, alpha handling, audio mixing, and export of the
   actual composition.

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
