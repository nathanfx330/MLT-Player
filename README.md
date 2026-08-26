# MLT Player

[![CI](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml/badge.svg)](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A fast, frame-exact local media browser, project organizer, and precision player
for Linux, built on
[MLT (Media Lovin' Toolkit)](https://www.mltframework.org/).

<!--
TODO: add screenshots. Suggested:
(1) Explorer grid with thumbnails and Project/Catalog controls
(2) Project overview dashboard
(3) Player with the Layers inspector open
(4) Storyboard or Bookmarks view

![Explorer](docs/images/explorer.png)
![Project](docs/images/project.png)
![Player](docs/images/player.png)
-->

---

## What this is

MLT Player is built around three connected workspaces:

**Explorer** is a filesystem-first media browser. Open a directory directly,
browse real media thumbnails, filter and sort, organize files into Catalogs,
and open an asset without importing it into a media database first.

**Project** is the organizational layer. It summarizes Catalogs, ratings, tags,
color labels, and bookmarks for the active Project and turns those summaries
into project-wide smart views.

**Player** opens a single file for frame-exact inspection, exact-frame
bookmarks, selection and trim, three-layer composition, and export.

The basic workflow remains deliberately direct:

```text
open a directory or media file
  -> browse visually
  -> organize only if useful
  -> inspect precisely
  -> make one surgical change
  -> export
  -> return to the browser
```

The filesystem remains primary throughout.

> **The filesystem owns the media. Projects organize it. MLT plays and
> transforms it.**

## Why it exists

QuickTime 7 Pro occupied a specific niche: open a file, look at it closely, do
one thing to it, save, close. Nothing replaced it cleanly. Modern tools are
often either players that tell you almost nothing about the file, or editors
that require an ingest-and-project workflow before useful work can begin.

MLT Player tries to recover that directness on Linux while adding the pieces
that become necessary once a media collection grows: visual browsing,
persistent annotations, lightweight Projects, Catalogs, and precise playback.

Projects do **not** sit between you and your files. You can still open a
directory or individual media file directly. A Project scopes organization and
metadata; it does not take ownership of the media.

Catalogs are intentionally lightweight. They are bin-like in the useful sense:
a media file can belong to one or more named collections, including nested
Catalogs, without being copied, moved, or imported into a proprietary project
store. Catalog membership and Project metadata are organizational state layered
over ordinary filesystem paths.

That distinction is deliberate.

Non-goals remain: no NLE timeline, no conform workflow, no mandatory ingest
database, no batch transcoder, and no feature added merely because MLT exposes
it.

---

## Features

### Explorer

- Filesystem-first local browsing with typed classification for video, audio,
  image, and project-like files
- Thumbnails decoded through MLT rather than an external `ffmpeg` process, so
  Explorer and Player agree about what a file contains
- Representative-frame selection that scores candidates and skips black leader,
  slates, and fades instead of blindly grabbing one fixed offset
- Persistent thumbnail cache with atomic publish and adjustable tile size
- Filename filtering, sorting, navigation history, Home, Up, Back, Forward,
  and saved favorite folders
- Direct Open File and Open Folder workflows
- Compact Settings access from Explorer

### Projects and Catalogs

- Multiple Projects with create, rename, switch, and delete
- Per-Project Favorites
- Nested Catalogs
- Many-to-many Catalog membership: one media file may belong to multiple
  Catalogs without being duplicated
- Catalog browsing through the same Explorer grid, thumbnail, filter, and open
  pipeline used for normal folders
- Project-wide dashboard with Catalog and metadata counts
- Clickable Project dashboard rows that open Explorer directly into the
  corresponding Catalog or smart view

A **Catalog** is intentional membership: you explicitly put media into it.

A **smart view** is computed from Project metadata: ratings, tags, colors, and
bookmarks can produce a project-wide view without changing Catalog membership.

### Project metadata and smart views

Project metadata is scoped to the active Project rather than stored as one
global annotation layer.

- 0–5 star ratings
- Exact rating filters such as `Exactly 4★`
- Minimum rating filters such as `4★ or better`
- Tags
- Color labels
- Exact-frame bookmarks
- Project-wide smart views for ratings, tags, colors, and bookmarked media
- Combined filtering: filename, rating, tag, and color filters can be layered
  together
- Project Bookmarks view containing only media that currently has one or more
  bookmarks

Bookmarks are soft screenshots: they store exact source-frame positions rather
than creating image files.

### Redleaf interoperability

MLT Player understands Redleaf `.rlink` files as virtual folders.

An `.rlink` points at an external directory while preserving a virtual browsing
path inside Explorer. Media stays on the external filesystem; MLT Player does
not copy it into the Project.

This is useful for large archives, removable storage, and collections already
organized for Redleaf because the same external tree can remain the source of
truth.

Current `.rlink` support includes:

- `.rlink` entries displayed as virtual folders
- virtual breadcrumbs while browsing linked media
- physical path resolution only when actual filesystem or media access is
  required
- disconnected links remaining visible instead of silently disappearing
- normal Player, thumbnail, and export access to resolved media

`.rlink` support is implemented and tested at the application level. Real
removable-drive workflows are still being field-verified, so portable media
identity beyond the current path-based model is intentionally not claimed yet.

### Player

- Frame-exact stepping
- J/K/L shuttle at 1x, 2x, 4x, and 8x in both directions
- Play All Frames for deterministic no-drop review
- Clip-relative timecode plus embedded source timecode
- Deep inspection including codec, pixel format, colorspace, transfer
  characteristic, color range, source timecode, full stream list, channel
  layout, and bitrate
- In and Out marking
- Play Selection
- Non-destructive Trim with full Undo and Redo
- Storyboard view at 5, 10, 30, or 60 second intervals
- Exact-frame Bookmarks with generated frame previews
- Searchable SRT sidecar subtitles with UTF-8, Windows-1252, and Latin-1
  handling
- Floating transcript sidebar with search-to-seek behavior

### Composition

- Three fixed layer slots, indexed identically on both sides of the FFI boundary
- Per-layer timeline START and END
- Per-layer source IN and OUT
- Opacity, visibility, position, scale, anchor, alpha interpretation, and audio
  gain
- Visual Z-order independent of logical slot identity
- Base-role promotion applied as an atomic graph-changing edit
- Composition edits participate in Undo and Redo

Layer 4 is deliberately rejected rather than silently creating an untested
topology. The three-slot model is indexed and generalized, so adding another
slot is a feature decision rather than a hidden topology change.

### Export

- Independent export graph; the live playback graph is never reused
- H.264 Delivery preset
- ProRes 422 HQ Master preset
- Current-frame PNG
- PNG sequence
- WAV
- Explicit output frame rate with layer positions correctly conformed
- Background export thread
- Progress and cancellation
- Partial-file cleanup
- Preview and export derive composition from shared policy code and are checked
  against each other in CI

---

## Requirements

Linux with MLT **7.22.x**. Other series may work but are not validated.

```bash
sudo apt-get install -y \
  libepoxy-dev \
  libgtk-3-dev \
  libmlt-data \
  libmlt-dev \
  pkg-config \
  ffmpeg
```

`libmlt-data` is required, not optional. MLT service discovery depends on the
installed service dictionaries, and the application fails in confusing ways
without them.

`ffmpeg` and `ffprobe` are used by the test tooling for fixture generation and
output validation. They are not used as the application's runtime media engine.

Flutter with Linux desktop support enabled is also required.

## Build and run

```bash
flutter pub get
flutter run -d linux
```

After changing anything under `native/`:

```bash
flutter clean
flutter pub get
flutter run -d linux
```

Release build:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

---

## Keyboard shortcuts

### Explorer

| Key | Action |
| --- | --- |
| `Ctrl+Shift+O` | Open folder |
| `Ctrl+O` | Open media directly |
| `Ctrl+F` | Focus the filename filter |
| `Alt+Left` / `Alt+Right` | Back / Forward |
| `Alt+Home` | Home |
| `Backspace` | Parent directory |
| `Enter` or double-click | Open the selection |

### Player

| Key | Action |
| --- | --- |
| `Left` / `Right` | Step one frame |
| `J` / `K` / `L` | Reverse shuttle / pause / forward shuttle |
| `I` / `O` | Set In / Set Out |
| `Shift+Space` | Play Selection |
| `Ctrl+T` | Trim Selection |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / Redo |
| `C` | Toggle subtitles |
| `Ctrl+F` | Open/focus transcript search |
| `Ctrl+I` | Inspector |
| `Ctrl+E` | Export |
| `Esc` | Return to Explorer |

---

## Architecture

```text
Flutter application
  |
  +-- Explorer workspace
  |     |
  |     +-- filesystem / .rlink browsing
  |     +-- Catalog browsing
  |     +-- Project smart views
  |     +-- ThumbnailService ---------------------+
  |                                               |
  +-- Project workspace                           |
  |     |                                         |
  |     +-- ProjectCatalogService                 |
  |     +-- ProjectMediaMetadataService           |
  |                                               |
  +-- Player view -------- PlayerEngine ----------+
  |                                               |
  +-- Dart FFI --------------------------> libmlt_bridge.so
                                                   |
                                            opaque MLT engine
                                                   |
                            +----------------------+----------------------+
                            |                                             |
                         preview                                       export
                            |                                             |
                   indexed composition                          indexed snapshot
                            |                                             |
                         tractor                                  fresh tractor
                            |                                             |
                   preview consumer                            avformat consumer
                            |
                    OpenGL texture -> Flutter Texture widget
```

Flutter owns the application. MLT owns the media. A small C bridge connects them,
split into translation units for engine/playback, shared composition policy,
export, and thumbnail generation.

Explorer and Project share the same Project Catalog and metadata services, so
the Project dashboard is an overview of the same live state Explorer works
against rather than a separate database or duplicated browser.

Explorer and Player are persistent views rather than native lifecycles that are
destroyed and rebuilt on every navigation. Thumbnail generation uses independent
producer and profile objects and never drives the live player through a
directory.

Preview and export intentionally build separate MLT graphs. The composition
rules both paths depend on live in shared code so they cannot quietly drift.

For the broader engineering record, see
[`docs/architecture.md`](docs/architecture.md).

### Building on MLT yourself?

The standalone engineering guide
**[Embedding MLT in a Flutter/Linux Desktop Player: Field Notes from Building MLT Player](docs/embedding-mlt-in-a-flutter-linux-app.md)**
is written for developers embedding MLT rather than driving it through `melt`.

It covers the producer/consumer model, lazy rendering, threading and lock
boundaries, external Flutter textures, frame-exact transport, metadata,
consumer lifecycle properties, background export, and failures that looked like
MLT bugs but were not.

The chronological POC documents remain available as the project's historical
engineering record in [`docs/`](docs/README.md).

---

## Data model

MLT Player deliberately separates media from organizational state.

```text
filesystem
  |
  +-- media files
  +-- directories
  +-- Redleaf .rlink pointers

Project
  |
  +-- Favorites
  +-- Catalogs
  |     +-- nested Catalogs
  |     +-- media memberships
  |
  +-- media metadata
        +-- rating
        +-- tags
        +-- color label
        +-- bookmark frames
```

Deleting a Catalog does not delete the media file. Assigning media to a Catalog
does not move or copy it. A media file may be represented in more than one
Catalog while still having one ordinary filesystem location.

That separation is the reason Projects and Catalogs fit the original
filesystem-first design rather than replacing it.

---

## Testing

```bash
flutter analyze
flutter test
tools/smoke.sh
tools/thumbnail_smoke.sh
```

CI runs the automated suites on every push.

The native smoke suites are headless and cover engine guards, transport, layer
timing, source trims, layer ordering, export presets, frame-rate conform, and
preview/export parity. Parity is checked by comparing derived composition state
between the two graphs, and the frame-rate conform test goes further: it decodes
output frames and asserts the color, so a layer that lands on the wrong frame
after conversion fails rather than passing quietly.

Some failures during Explorer development appeared only in standalone release
builds and not under `flutter run`. Release validation is therefore a
first-class tier rather than an afterthought:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

A separate reproducible diagnostic for the known MLT 7.22 audio-flush PTS
warning lives in `tools/pts_diag.sh`. It is deliberately not part of CI because
gating on a known upstream issue would make the build red for something outside
this project. It becomes a regression gate when the MLT baseline moves to a
version containing the fix.

---

## Status and roadmap

### Implemented

- Playback foundation and Linux external-texture preview
- Frame-exact transport and inspection
- Selection, trim, Undo, and Redo
- Storyboard and exact-frame bookmarks
- Searchable SRT sidecars and transcript navigation
- Three-layer composition model
- H.264, ProRes, PNG, PNG-sequence, and WAV export
- Filesystem Explorer with MLT representative thumbnails
- Projects and nested Catalogs
- Per-Project Favorites
- Project-scoped ratings, tags, color labels, and bookmarks
- Exact and minimum rating filters
- Project dashboard
- Project-wide rating, tag, color, and bookmark smart views
- Redleaf `.rlink` virtual-folder support

### Next

- **Interchange:** MLT XML save and open. The composition can be built but not
  yet saved, which remains the largest interchange gap.
- Real removable-drive field verification for `.rlink`
- Portable media identity only after real `.rlink` behavior is proven
- Image sequences treated as single browsable items rather than thousands of
  files
- Richer layer timing and ordering rules
- Blend modes and a broader alpha/color policy

The roadmap deliberately favors capabilities that preserve MLT Player's
file-first character rather than turning it into a conventional NLE.

---

## License

MLT Player's own source is MIT licensed. See [`LICENSE`](LICENSE).

That covers code authored for this repository. It does not cover MLT, FFmpeg,
codec libraries, or other third-party components used at runtime or bundled into
a binary package.

MLT Player dynamically links `mlt-framework-7`, which is LGPL-2.1, but
individual MLT modules carry different licenses and some build configurations
enable GPL components. FFmpeg is normally LGPL-2.1-or-later and becomes GPL when
components such as `libx264` are enabled.

Anyone distributing prebuilt binaries should audit the exact MLT modules,
FFmpeg configuration, and codec libraries being shipped, then satisfy the
obligations that actually apply. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the distribution
checklist and upstream references.

---

Built and tested against MLT 7.22.0 on Linux.
