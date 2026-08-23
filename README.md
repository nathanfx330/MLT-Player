# MLT Player

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A desktop media player built with **Flutter** and **MLT (Media Lovin' Toolkit)**.

Flutter owns the application. MLT owns the media. The two meet through a small
C bridge, and video reaches Flutter as an OpenGL texture rather than in a
second native playback window.

The target is deliberately narrow: **recover the practical role of QuickTime
7 Pro**.

Not an NLE. Not a batch transcoder. Open a file, inspect it closely, make one
surgical change, add a layer when needed, export the result, and close it.

---

## Current status

Built and tested against **MLT 7.22.0** on Linux.

| Area | State |
| --- | --- |
| Flutter Linux application | Done |
| Native C / Dart FFI bridge | Done |
| Opaque playback-engine handles | Done |
| External OpenGL video texture | Done |
| Audio through `sdl2_audio` | Done |
| Play, pause, seek and scrub | Done |
| Exact ±1-frame stepping | Done |
| J / K / L shuttle, including reverse | Done |
| Loop / Play All Frames | Done |
| Generated + embedded source timecode | Done |
| Stream / codec inspection | Done |
| In / Out selection | Done |
| Play Selection / Loop Selection | Done |
| Undo / Redo | Done |
| Non-destructive Trim Selection | Done |
| Background MP4 export | Done |
| Current-frame PNG export | Done |
| PNG image-sequence export | Done |
| WAV audio export | Done |
| Two-layer MLT tractor | Done |
| Add to Movie at the playhead | Done |
| Layer opacity / visibility | Done |
| Per-track audio levels | Done |
| Still + alpha-capable overlay layers | Done |
| Layer replacement / order swap | Done |
| Layer position / scale / anchors | Done |
| Tractor-aware composition export | Done |
| Export preset / codec selection | Next |
| Explicit output frame-rate control | Next |
| More than two tracks | Planned |
| MLT XML interchange | Planned |

**POC 10.9 closes the current loop:** the player can preview a real two-layer
MLT composition and export that composition through a separate background
tractor graph. Export no longer falls back to rendering only the base source.

Engineering notes live in [`docs/`](docs/README.md).

---

## What MLT Player is for

QuickTime 7 Pro was useful because it was not trying to be a full editor.

It could open quickly, show the file, let you set In and Out, trim, step a
frame at a time, inspect streams, add media to the movie, export a still or
image sequence, extract audio, and write a new movie without requiring a
project workflow.

MLT Player follows that shape:

**open → inspect → make one precise change → export/save → close**

Deliberate non-goals:

- no bins
- no giant project workflow
- no conventional NLE timeline
- no batch-transcoder-centered interface
- no feature merely because MLT exposes it

---

## Precise transport

Transport is frame-aware rather than only time-aware.

- Left / Right step exactly one frame.
- `K` pauses.
- `L` cycles forward through `1×`, `2×`, `4×`, `8×`.
- `J` cycles reverse through `-1×`, `-2×`, `-4×`, `-8×`.
- Changing direction begins at `1×` in the new direction.
- Loop preserves the current shuttle magnitude.
- Play All Frames switches MLT to no-drop playback.
- Generated clip timecode starts at `00:00:00:00`.
- Embedded source timecode remains source-relative through trims.

Reverse playback depends on codec structure. Long-GOP H.264/H.265 is much
more expensive to decode backward than intra-frame media such as ProRes,
DNxHR, MJPEG, or image sequences.

---

## Inspection

The Inspector reports metadata from the media MLT actually opened.

Current readouts include:

- frame size
- display aspect
- frame rate
- duration
- frame count
- file size
- average whole-file data rate
- selected video and audio stream indices
- codec short and long names
- pixel format
- colorspace
- transfer characteristic
- color range
- source timecode when present
- complete stream list
- stream language
- stream bitrate
- video dimensions
- audio channel count
- audio sample rate

The Tracks inspector also exposes current two-layer composition state such as
track audio levels, Layer 2 opacity, visibility, alpha interpretation,
position, and scale.

Color primaries are intentionally not shown yet because the current MLT 7.22
metadata path used here does not expose an independent source-primaries value
that this implementation trusts.

---

## Selection and trim

Selection is frame-based.

- `I` sets the In frame.
- `O` sets the Out frame.
- The marked range is shown on the scrubber.
- Selection duration and inclusive frame count are displayed.
- Play Selection plays only the marked range.
- Loop + Play Selection loops In → Out → In.
- Trim Selection turns the marked range into the active clip.
- Trim is non-destructive.
- Trims can be nested.
- Clip-relative frames restart at frame 1 after a trim.
- Generated clip timecode restarts at `00:00:00:00`.
- Embedded source timecode remains tied to the original source position.

Undo and Redo are application-owned edit history:

- `Ctrl+Z` — Undo
- `Ctrl+Shift+Z` — Redo

---

## Two-layer composition

POC 10 promotes the viewer from a single producer to an MLT tractor when a
second layer is added.

```text
Layer 1 producer -----------\
                            -> tractor -> preview consumer
Layer 2 playlist/producer --/
```

### Layer 1

Layer 1 is the timed base movie.

It defines:

- the movie canvas/profile
- frame zero
- the overall movie duration

A still image cannot become Layer 1 in the current two-layer model.

### Layer 2

Layer 2 can be timed video or a still image.

Add to Movie places it at the currently parked playhead. Internally, MLT Player
builds a Layer 2 playlist with a blank lead-in so the added media begins at the
requested movie frame.

Current Layer 2 controls include:

- opacity
- show / hide
- replace source
- swap layer order when the new base remains timed video
- per-track audio level
- alpha interpretation: Auto / Straight / Premultiplied
- X / Y position
- uniform scale from 10% to 300%
- nine-position anchor grid

Still images are held from their insertion frame through the end of Layer 1.
Small stills keep native display size when they already fit the canvas; larger
stills scale down to fit.

Video compositing uses MLT's `composite` transition. Audio-bearing layers are
summed through an MLT `mix` transition after track-local `volume` filters.

---

## Export

Export still runs on a **separate native MLT graph**. The encoder never steals
or mutates the live preview tractor.

The crucial POC 10 change is that export now snapshots the current composition
and rebuilds it with fresh objects on the worker thread:

```text
preview
  Layer 1 producer
  Layer 2 playlist
  tractor
  composite / mix
  sdl2_audio consumer

export worker
  fresh Layer 1 producer
  fresh Layer 2 playlist
  fresh tractor
  fresh composite / mix
  avformat consumer
```

The export snapshot carries the second layer's placement, opacity/visibility
result, position, scale, alpha interpretation, and track audio gains.

### Export range

The grouped Export menu now has an explicit range choice:

```text
Export Video
Export Image Sequence
Export Audio (WAV)
--------------------
RANGE
  Whole Movie
  In / Out
```

**Whole Movie is the default.** For a trimmed movie it means the current active
trim bounds. `In / Out` is available when a valid marked range exists.

This is intentionally no longer an implicit "selection wins if markers happen
to exist" rule.

### Current export families

- composited MP4 video
- composited current-frame PNG
- composited PNG image sequence
- mixed WAV audio

### Keyboard shortcuts

- `Ctrl+E` — run the currently selected Export mode
- `Ctrl+Alt+E` — one-shot PNG image-sequence export
- `Ctrl+Shift+E` — export the current frame as PNG

`Ctrl+Alt+E` is a pure action: it does not change the persistent split-button
Export mode.

### MP4 preset

The fixed movie preset is currently:

```text
Container:   MP4
Video:       H.264 / libx264
Audio:       AAC when the composition has audio
Pixel fmt:   yuv420p
Quality:     CRF 18
Preset:      medium
Fast start:  yes
Frames:      progressive output
MLT:         real_time = -1
```

Interlaced sources are rendered through the same deinterlacing policy used by
the viewer and PNG exports. A composition with no audio does not receive a
manufactured silent AAC stream.

### Current-frame PNG

PNG exports are rendered from the MLT composition graph rather than copied
from the Flutter texture.

For anamorphic sources, PNG output is written at **display dimensions with
square pixels**. For example, a 1440×1080 source with 16:9 display aspect is
written as approximately 1920×1080 rather than as a squeezed 1440×1080 PNG.

Offline PNG scaling uses Lanczos interpolation and preserves RGBA.

### PNG image sequence

Image-sequence export writes to a fresh dedicated directory:

```text
movie_frames/
  frame_000001.png
  frame_000002.png
  frame_000003.png
  ...
```

The native bridge requires the destination directory to exist and be empty.
Completion validation checks the expected frame count, numbering range, and
that every owned PNG is non-empty.

Cancelled or failed sequence exports remove only filenames owned by the export
and remove the directory only if it becomes empty.

### WAV audio export

The fixed audio interchange preset is:

```text
Container:  WAV
Codec:      PCM signed 24-bit little-endian
Video:      disabled
Rate:       preserve an audio-bearing source rate when available
Channels:   preserve an audio-bearing source channel count when available
```

With two audio tracks this is now a **composition mixdown**, not merely a copy
of Layer 1 audio. Track gains and the tractor mix are rendered into the WAV.

---

## Architecture

```text
Flutter UI
    |
    +-- PlayerEngine
    |      +-- transport
    |      +-- selection / trim / history
    |      +-- Layer 2 composition state
    |      +-- export range / status
    |
    +-- Dart FFI ---------------------> libmlt_bridge.so
    |                                      |
    +-- MethodChannel -> GTK runner        |
                                           v
                                    opaque MLT engine
                                           |
                     +---------------------+---------------------+
                     |                                           |
                  preview                                      export
                     |                                           |
          Layer 1 + Layer 2 playlist                 composition snapshot
                     |                                           |
                  tractor                              fresh worker tractor
             composite + mix                           composite + mix
                     |                                           |
             sdl2_audio consumer                         avformat consumer
                     |
              render threads + RGBA
                     |
              triple frame buffer
                     |
             OpenGL external texture
                     |
                  Flutter
```

Important architecture rules:

- MLT factory/repository lifetime is process-wide.
- Playback state lives in opaque `MltBridgeEngine` handles.
- Dart resolves the bridge with `DynamicLibrary.process()`.
- The GTK runner links the same bridge into the application process.
- The Flutter texture registrar is process-wide, with one engine selected as
  its current texture source.
- The MLT frame callback never takes the main engine mutex.
- Video frame transfer uses three buffers so producer and Flutter raster
  threads can own buffers independently.
- Scaling, deinterlacing, and image conversion happen on MLT render threads.
- The visible `producer` is the primary source for one track and the tractor
  producer after Add to Movie.
- Preview and export represent the same composition but share no live
  producer/playlist/tractor objects.

---

## Deterministic testing

`tools/generate_export_fixtures.sh` creates a local regression set with FFmpeg:

```text
progressive_av.mp4
interlaced_av.mkv
video_only.mp4
anamorphic_1440x1080_16x9.mp4
pcm24.wav
```

Run:

```bash
bash tools/generate_export_fixtures.sh
```

The native smoke test also exercises the bridge without Flutter. POC 10 checks
now cover:

- independent opaque engines
- second-layer insertion at an exact frame
- blank lead-in seeks
- tractor playhead preservation
- opacity and scale clamps
- position / scale round-trips
- anchors
- per-track audio levels
- still-image overlays
- alpha detection and interpretation
- held stills through the end of Layer 1
- whole-movie two-layer MP4 export

This keeps "MLT graph problem" and "Flutter integration problem" as separate
questions during debugging.

---

## Roadmap

### POC 0–5 — playback foundation — complete

Flutter shell, MLT lifecycle, media open/reopen, OpenGL texture, audio,
seek/scrub, fullscreen, drag/drop, stills, audio-only playback, anamorphic
display handling, and smoke testing.

### POC 6 — precise transport — complete

Exact frame stepping, J/K/L shuttle, reverse playback, Loop, Play All Frames,
generated timecode, and embedded source timecode.

### POC 7 — inspection — complete

Codec/stream topology, geometry, rate/duration/frame count, data size, pixel
format, colorspace, transfer characteristic, color range, and source timecode.

### POC 8 — selection and trim — complete

In/Out, Play Selection, Loop Selection, Undo/Redo, non-destructive trim,
nested trims, and trim-aware transport.

### POC 9 — export foundation — complete

Independent background export graph, MP4, current-frame PNG, PNG sequence,
24-bit PCM WAV, progress/cancel, partial-output cleanup, grouped Export UI,
progressive output policy, Lanczos PNG scaling, deterministic fixtures, and
sequence validation.

### POC 10 — tracks and composition — current checkpoint complete through 10.9

- 10.1 — opaque engine handles
- 10.2 — tractor + second track
- 10.3 — playhead-relative track placement
- 10.4 — opacity
- 10.5 — Tracks inspector + audio levels
- 10.6 — still/alpha layer support
- 10.7 — replacement, visibility, and layer order
- 10.8 — position / scale / anchors
- 10.9 — tractor-aware composition export

### Next

- export preset / codec selection
- explicit output frame-rate control
- more than two tracks
- richer track timing/edit operations
- blend-mode exploration
- broader alpha/color policy

### POC 11 — interchange

Planned:

- save MLT XML
- open MLT XML
- open image sequences at a chosen frame rate

---

## Engineering notes

The implementation notes are intentionally written as field notes for people
embedding MLT rather than only driving it through `melt`:

- [Documentation index](docs/README.md)
- [Embedding MLT in a Flutter/Linux Desktop Player](docs/embedding-mlt-in-a-flutter-linux-app.md)
- [POC 10: Multitrack, Compositing, and Tractor-Aware Export](docs/poc-10-multitrack-compositing-and-export.md)

---

## Linux development

Typical native-change rebuild:

```bash
flutter clean
flutter pub get
flutter run -d linux
```

Dart-only changes normally need only:

```bash
flutter test
flutter run -d linux
```

Common Ubuntu development dependencies include:

```text
melt
libmlt-dev
libmlt-data
libmlt++-dev
libepoxy-dev
libgtk-3-dev
pkg-config
build-essential
```

`libmlt-data` matters because MLT service dictionaries are loaded at runtime.

---

## License

MIT. See [LICENSE](LICENSE).
