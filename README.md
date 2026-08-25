# MLT Player

[![CI](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml/badge.svg)](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A fast, frame-exact local media browser and precision player for Linux, built on
[MLT (Media Lovin' Toolkit)](https://www.mltframework.org/).

<!--
TODO: add screenshots. This is the single highest-value addition to this file.
Suggested: (1) Explorer grid with thumbnails, (2) Player with the Layers
inspector open, (3) Storyboard view.

![Explorer](docs/images/explorer.png)
![Player](docs/images/player.png)
-->

---

## What this is

Two connected applications that share one native engine:

**MLT Explorer** browses a directory the way Adobe Bridge does, with real
thumbnails decoded from the media itself, ratings, tags, sorting, and filtering.

**MLT Player** opens a single file and tells you exactly what is in it, lets you
mark frames precisely, compose up to three layers, and export.

The workflow it is built around:

```text
open a directory
  -> browse visually
  -> pick an asset
  -> inspect it precisely
  -> make one surgical change
  -> export
  -> return to the browser
```

## Why it exists

QuickTime 7 Pro occupied a specific niche: open a file, look at it closely, do
one thing to it, save, close. Nothing replaced it. Modern tools are either
players that tell you almost nothing about the file, or editors that want you to
create a project first.

MLT Player is an attempt to recover that niche on Linux, and MLT turns out to be
an unusually good engine for it: frame-exact positioning, a real composition
graph, and deterministic no-drop rendering.

Deliberate non-goals: no project or conform workflow, no NLE timeline, no bins,
no batch transcoder, and no feature added merely because MLT exposes it.

---

## Features

### Explorer

- Local directory browsing with typed classification (video, audio, image, project)
- Thumbnails decoded through MLT, not an external `ffmpeg` process, so the browser
  and the player always agree about what a file contains
- Representative frame selection that scores candidates and skips black leader,
  slates, and fades instead of blindly grabbing one fixed offset
- Persistent thumbnail cache with atomic publish and adjustable tile size
- Ratings and tags, with filters
- Filename filter, sort, navigation history, and saved locations

### Player

- Frame-exact stepping, J/K/L shuttle at 1x, 2x, 4x, 8x in both directions
- Play All Frames for deterministic no-drop review
- Clip-relative timecode plus embedded source timecode
- Deep inspection: codec, pixel format, colorspace, transfer characteristic,
  color range, source timecode, full stream list, channel layout, bitrate
- In and Out marking, Play Selection, and non-destructive Trim with full Undo and Redo
- Storyboard view at 5, 10, 30, or 60 second intervals
- Searchable SRT sidecar subtitles with UTF-8, Windows-1252, and Latin-1 handling

### Composition

- Three fixed layer slots, indexed identically on both sides of the FFI boundary
- Per-layer timeline START and END, source IN and OUT, opacity, visibility,
  position, scale, anchor, alpha interpretation, and audio gain
- Visual Z-order independent of logical slot identity
- Base-role promotion, applied as an atomic graph-changing edit
- Everything above participates in Undo and Redo

### Export

- Independent export graph. The live playback graph is never reused.
- H.264 Delivery and ProRes 422 HQ Master presets
- Current-frame PNG, PNG sequence, and WAV
- Explicit output frame rate with layer positions correctly conformed
- Background thread, progress, cancellation, and partial-file cleanup
- Preview and export derive composition from shared code and are verified against
  each other in CI

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
output validation. They are not used at runtime.

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
| `Ctrl+I` | Inspector |
| `Ctrl+E` | Export |
| `Esc` | Return to Explorer |

---

## Architecture

```text
Flutter application
  |
  +-- Explorer shell ----- ThumbnailService -----+
  |                                              |
  +-- Player view -------- PlayerEngine ---------+
  |                                              |
  +-- Dart FFI -------------------------> libmlt_bridge.so
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
split into four translation units: the engine and playback bridge, shared
composition policy, the export subsystem, and thumbnail generation. The
composition rules that preview and export both depend on live in one place and
are called from both, so the two paths cannot drift.

Explorer and Player are persistent views rather than a native lifecycle that is
destroyed and rebuilt on every navigation. Thumbnail generation uses independent
producer and profile objects and never drives the live player through a
directory.

For the full design notes, including what was learned embedding MLT in a Flutter
Linux application, see [`docs/`](docs/README.md). The embedding guide is written
for anyone attempting something similar and covers the producer and consumer
model, threading rules, frame callbacks, external texture registration, and the
failure modes that are not in the MLT API reference.

---

## Testing

```bash
flutter analyze
flutter test
tools/smoke.sh
tools/thumbnail_smoke.sh
```

CI runs all of the above on every push.

The native smoke suites are headless and cover engine guards, transport, layer
timing, source trims, layer ordering, export presets, frame-rate conform, and
preview/export parity. Parity is checked by comparing derived composition state
between the two graphs, and the frame-rate conform test goes further: it decodes
output frames and asserts the color, so a layer that lands on the wrong frame
after conversion fails rather than passing quietly.

Two native failures during Explorer development appeared only in standalone
release builds and not under `flutter run`. Release validation is therefore a
first-class tier, not an afterthought:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

A separate reproducible diagnostic for the known MLT 7.22 audio-flush PTS
warning lives in `tools/pts_diag.sh`. It is deliberately not part of CI, because
gating on a known upstream issue would make the build red for something outside
this project. It becomes a regression gate when the MLT baseline moves to a
version containing the fix.

---

## Status and roadmap

Complete: playback foundation, precise transport, inspection, selection and trim,
the export subsystem, the hardened three-layer composition model, and the
Explorer through ratings and tag filters.

Next:

- **Interchange.** MLT XML save and open. The composition can be built but not
  yet saved, which is the largest gap in the current design.
- Image sequences treated as single browsable items rather than thousands of files
- Richer layer timing and ordering rules
- Blend modes and a broader alpha and color policy

Layer 4 is deliberately rejected rather than silently creating an untested
topology. The three-slot model is indexed and generalized, so adding a slot is a
feature decision rather than a refactor.

---

## License

MLT Player's own source is MIT licensed. See [`LICENSE`](LICENSE).

That covers code authored for this repository. It does not cover MLT, FFmpeg,
codec libraries, or other third-party components used at runtime or bundled into
a binary package. MLT Player dynamically links `mlt-framework-7`, which is
LGPL-2.1, but individual MLT modules carry different licenses and some build
configurations enable GPL components. FFmpeg is normally LGPL-2.1-or-later, and
becomes GPL when components such as `libx264` are enabled.

Anyone distributing prebuilt binaries should audit the exact MLT modules, FFmpeg
configuration, and codec libraries being shipped, then satisfy the obligations
that actually apply. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for
the distribution checklist and upstream references.

---

Built and tested against MLT 7.22.0 on Linux.