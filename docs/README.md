<!-- docs/README.md -->

# MLT Player engineering notes

These notes document the implementation journey behind MLT Player rather than
trying to replace the upstream MLT API reference.

The project now has two connected product surfaces:

```text
MLT Explorer
    ↓
MLT Player
```

Explorer is the application home and local-media browser. Player is the
precision playback, inspection, composition, and export workspace.

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

4. [POC 10 continuation: Layer Ordering, Role Promotion, and Atomic Presentation](poc-10-layer-ordering-and-atomic-role-swaps.md)
   — explicit three-layer visual Z-order, true timed-video base-role promotion
   across all three slots, cross-frame-rate boundary conversion, cross-aspect
   displaced-base fitting, and the presentation barriers that prevent users
   from seeing a graph rebuild happen.

5. [POC 11: MLT Explorer Foundation](poc-11-mlt-explorer-foundation.md)
   — the product pivot from a standalone precision player to an Adobe
   Bridge-style local media browser whose selected asset opens in the existing
   persistent MLT Player.

## Current checkpoint

The current checkpoint is **Phase 11.1: MLT Explorer foundation** on top of the
completed three-layer Player architecture.

The Player has a tested three-layer composition model with:

- Layer 2 / Layer 3 timed video or held stills
- opacity / visibility
- position / scale / anchors
- alpha interpretation
- source replacement
- per-track audio gain
- timeline START / END
- timed-video SOURCE IN / SOURCE OUT
- explicit visual Z-order
- timed-video base-role promotion through Layers 1–3
- cross-frame-rate role conversion
- cross-aspect displaced-base fitting
- atomic graph-changing presentation
- preview/export parity
- H.264 / ProRes / PNG / sequence / WAV export
- explicit output-rate conform

The Explorer now provides:

- application-home entry point
- Open Folder
- non-recursive local directory scan
- supported-media classification
- folders-before-media alphabetical ordering
- folder navigation
- item selection
- double-click / Enter opening
- Explorer → persistent Player handoff
- Player → Explorer return without tearing down the native Player lifecycle

The first Explorer cards intentionally use placeholders. Real image/video
thumbnails and persistent caching are the next phase.

At this checkpoint:

```text
flutter analyze     clean
flutter test        21 passed
tools/smoke.sh      all native groups passed
```

All implementation notes currently describe behavior tested against **MLT
7.22.0 on Linux** unless a section says otherwise.

## Product boundary

MLT Player remains intentionally narrower than both a conventional NLE and a
full DAM.

The intended workflow is:

```text
browse
→ select
→ inspect
→ make one precise change when necessary
→ export/save
→ return to browsing
```

The Explorer does not change the Player's core design principle. It gives that
precision tool the media-browsing entry point it was originally built to serve.
