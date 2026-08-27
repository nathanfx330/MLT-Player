<!-- docs/README.md -->

# MLT Player engineering notes

This directory has three different kinds of documentation. They are intentionally
separate so there is only one source of truth for each job.

- The repository [`README.md`](../README.md) describes **what MLT Player is now**:
  product scope, features, build instructions, shortcuts, testing, and roadmap.
- [`architecture.md`](architecture.md) describes **how the current system is put
  together now**.
- [`redleaf-workspace.md`](redleaf-workspace.md) describes the **current
  authenticated Redleaf workspace integration**: workspace identity, SRT
  discovery, catalog filtering, media relationships, and the read-only boundary.
- [`embedding-mlt-in-a-flutter-linux-app.md`](embedding-mlt-in-a-flutter-linux-app.md)
  is a **standalone engineering guide for other developers embedding MLT** in a
  Flutter/Linux desktop application.

The remaining POC documents are the historical engineering record. They explain
how the architecture was discovered, which approaches failed, and why later
choices were made. They are snapshots of their respective stages and should not
be treated as current reference documentation when they conflict with
`architecture.md`, `redleaf-workspace.md`, or the root README.

## Start here

### Current architecture

[**MLT Player Architecture**](architecture.md)

A present-tense map of the application: Flutter/Dart ownership, opaque native
engine handles, the four native translation units, the indexed three-slot
composition model, preview/export separation, shared composition policy,
serialized thumbnail generation, Explorer/Player lifecycle, and the validation
boundaries that protect the native path.

### Redleaf workspace integration

[**Redleaf Workspace Integration**](redleaf-workspace.md)

The current authenticated Redleaf path: Redleaf as a Project source rather than
a third top-level tab, namespaced workspace identity, session authentication,
canonical Redleaf `doc_id` handling, explicit-SRT discovery, media relationship
semantics, user-created catalog discovery and filtering, and the current
read-only boundary before Player handoff.

### Reusable MLT embedding guide

[**Embedding MLT in a Flutter/Linux Desktop Player**](embedding-mlt-in-a-flutter-linux-app.md)

Field notes from building the player, organized by the problems an embedding
engineer actually encounters: producer/consumer mental model, lazy frame
rendering, callback threading, external textures, transport, metadata,
lifecycle-sensitive properties, export, smoke testing, and symptoms that looked
like MLT bugs but were not.

This guide stands on its own; it is not chapter one of the POC history.

## Historical implementation record

1. [POC 9: Export Formats and Hardening](poc-9-export-formats-and-hardening.md)
   — turning the first MP4 proof into dependable PNG, sequence, WAV, and movie
   export with progress/cancel, filesystem ownership, completion validation,
   and deterministic regression fixtures.

2. [POC 10: Multitrack, Compositing, and Tractor-Aware Export](poc-10-multitrack-compositing-and-export.md)
   — the move from a single producer to opaque engine handles and tractors,
   timed layers, alpha/audio/geometry controls, independent composition export,
   preview/export parity, Layer 3, and composition history.

3. [POC 10 continuation: Layer Ordering, Role Promotion, and Atomic Presentation](poc-10-layer-ordering-and-atomic-role-swaps.md)
   — explicit visual Z-order, base-role promotion, cross-frame-rate conversion,
   cross-aspect fitting, and presentation barriers around graph rebuilds.

4. [POC 11: MLT Explorer Foundation](poc-11-mlt-explorer-foundation.md)
   — the product pivot from a standalone precision player to an Adobe
   Bridge-style local browser feeding the persistent Player.

5. [POC 11 continuation: Explorer Growth, MLT-Native Thumbnails, and Release Hardening](poc-11-explorer-growth-thumbnail-hardening.md)
   — real MLT-native thumbnails, metadata, navigation, ratings/tags/filtering,
   and the release-only failures that established standalone-build validation as
   a first-class proof tier.

6. [POC 12: Storyboard, Searchable Subtitles, and the Last Mile of Release Hardening](poc-12-storyboard-subtitles-and-last-mile-hardening.md)
   — exact-frame Storyboard generation, SRT sidecars and transcript search,
   Windows-1252 handling, keyboard/focus ownership, file-chooser handoff
   debugging, CI compatibility, and the final stability rules.

Unless a document explicitly says otherwise, the implementation history here
was developed against **MLT 7.22.0 on Linux**.
