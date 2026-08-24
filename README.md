<!-- README.md -->

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
| Background video export | Done |
| Current-frame PNG export | Done |
| PNG image-sequence export | Done |
| WAV audio export | Done |
| Three-layer MLT tractor | Done |
| Add to Movie at the playhead | Done |
| Layer 2 + Layer 3 opacity / visibility | Done |
| Independent layer position / scale / anchors | Done |
| Still + alpha-capable overlay layers | Done |
| Per-track audio levels | Done |
| Layer source replacement | Done |
| Two-layer base/overlay order swap | Done |
| Layer removal + composition Undo / Redo | Done |
| Seamless Layer 3 remove / Undo restore | Done |
| Tractor-aware three-layer composition export | Done |
| Preview / export parity harness | Done |
| No-active-engine guard regression | Done |
| Linux CI smoke + parity | Done |
| Export preset / codec selection | Done |
| Explicit output frame-rate control | Done |
| Layer START / END timing | Done |
| Timed-overlay SOURCE IN / SOURCE OUT trimming | Done |
| Generalized Layer 1 / 2 / 3 reordering | Next |
| Blend-mode exploration | Planned |
| Broader alpha / color policy | Planned |
| MLT XML interchange | Planned |

The current checkpoint is a **hardened three-layer composition and timing
system**. Layer 1 is the timed base movie. Layers 2 and 3 can be timed video or
held stills and carry independent geometry, opacity, visibility, alpha
interpretation, audio gain, timeline placement, and—in the case of timed
video—independent source In/Out trims.

Preview and export rebuild the same indexed composition state on separate MLT
graphs. Export policy is independently selectable from composition state:
current video presets include **H.264 Delivery** and **ProRes 422 HQ Master**,
and the output frame rate can follow the source or conform to an explicit
supported rate.

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

The **Layers** inspector exposes the current composition state for Layers 1–3.

Overlay controls include:

- opacity
- show / hide
- replace source
- per-track audio level
- alpha interpretation
- X / Y position
- uniform scale
- nine-position anchors
- timeline START / END
- timed-video SOURCE IN / SOURCE OUT

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

Composition edits participate in the same history. Explicit layer removal is
undoable. Layer timing and source-trim edits rebuild the composition as edit
transactions, preserving prior history and rolling back when a rebuild fails.

Adding Layer 2 or Layer 3 establishes a new composition baseline, so walking
backward through later property edits does not accidentally un-add the layer.

---

## Three-layer composition

The player begins with one producer. Adding media promotes the visible movie to
an MLT tractor.

```text
Layer 1 producer ------------------+
                                   |
Layer 2 playlist / producer -------+--> tractor --> preview consumer
                                   |
Layer 3 playlist / producer -------+
```

Layer slots are stable and indexed internally:

```text
slot 0 = Layer 1 / base movie
slot 1 = Layer 2 / overlay
slot 2 = Layer 3 / overlay
```

A fourth layer is currently rejected rather than silently changing topology.

### Layer 1

Layer 1 is the timed base movie. It defines:

- the movie canvas/profile
- frame zero
- the overall movie duration

A still image cannot become Layer 1 in the current model.

### Layers 2 and 3

Layers 2 and 3 can be timed video or still images.

Add to Movie places a new overlay at the currently parked playhead. Internally,
MLT Player builds a playlist with a blank lead-in so the added media starts at
the requested movie frame.

Overlay presentation controls include:

- opacity
- show / hide
- replace source
- per-track audio level
- alpha interpretation: Auto / Straight / Premultiplied
- X / Y position
- uniform scale from 10% to 300%
- nine-position anchor grid

Video compositing uses MLT `composite` transitions. Audio-bearing tracks are
summed with MLT `mix` transitions after track-local `volume` filters.

### Timeline START / END

Layers 2 and 3 can be bounded independently on the movie timeline.

```text
Layer 1  |----------------------------------------|
Layer 2        |-------------------|
Layer 3                    |------------|
               ^ START     ^ END
```

The Layers inspector exposes START and END as frame-accurate timecode with
±1-frame and ±10-frame controls.

START cannot cross END and END cannot cross START. A layer can therefore be
moved or shortened without producing an invalid placement range.

For still images, START / END controls the duration of the hold. A still no
longer has to remain visible through the final frame of Layer 1.

### Timed-video SOURCE IN / SOURCE OUT

Timed overlays have a second, independent range inside their source media:

```text
SOURCE MEDIA
|---------|=====================|---------|
          SRC IN                SRC OUT

MOVIE TIMELINE
      |------------- Layer 2 -------------|
      START                              END
```

There is no implicit speed change or time stretch.

- If the timeline window is shorter than the selected source range, MLT Player
  uses only the beginning of the selected source range.
- If the selected source range is shorter than the timeline window, the layer
  naturally ends when the selected source range runs out.
- Still images do not expose SOURCE IN / SOURCE OUT because their source is a
  held image rather than timed media.

SOURCE IN / SOURCE OUT edits participate in Undo / Redo, Layer 3 restoration,
preview/export parity, and output-frame-rate conform.

### Current ordering rule

The existing Layer 1 / Layer 2 swap remains a two-layer operation. It is
disabled while Layer 3 exists; remove the top layer first rather than
implicitly reindexing the stack.

Generalized three-layer **Move Up / Move Down** behavior is the next composition
milestone.

### Seamless Layer 3 removal and Undo

Layer 3 removal and history restoration use a small preview transaction.

During the graph rebuild, native frame publication is frozen and Dart
`ChangeNotifier` updates are batched. The last valid texture remains on screen
until the replacement graph and all saved Layer 3 properties are ready. The
transaction then publishes one final state.

That prevents the viewer from flashing through intermediate Layer 1 / Layer 2
rebuild states during Remove or Undo.

---

## Export

Export runs on a **separate native MLT graph**. The encoder never steals or
mutates the live preview tractor.

The bridge snapshots the indexed composition state and rebuilds it with fresh
objects on the worker thread:

```text
preview
  Layer 1 producer
  Layer 2 playlist
  Layer 3 playlist (when present)
  tractor
  composite / mix transitions
  sdl2_audio consumer

export worker
  fresh Layer 1 producer
  fresh Layer 2 playlist
  fresh Layer 3 playlist (when present)
  fresh tractor
  fresh composite / mix transitions
  avformat consumer
```

The snapshot carries presence, placement, source range, still/timed
classification, geometry, opacity/visibility result, alpha interpretation,
audio presence, and audio gain for each indexed layer.

### Export range

The grouped Export menu has an explicit range choice:

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

The range is fail-closed: In / Out export requires a complete valid pair. A
completed In/Out pair can select the In / Out mode automatically until the user
explicitly chooses a range mode; an explicit Whole Movie choice remains sticky.

### Current export families

- composited H.264 / MP4 video
- composited ProRes / MOV master video
- composited current-frame PNG
- composited PNG image sequence
- mixed WAV audio

### Keyboard shortcuts

- `Ctrl+E` — run the currently selected Export mode
- `Ctrl+Alt+E` — one-shot PNG image-sequence export
- `Ctrl+Shift+E` — export the current frame as PNG

`Ctrl+Alt+E` is a pure action: it does not change the persistent split-button
Export mode.

### Video presets

#### H.264 Delivery

```text
Container:   MP4
Video:       H.264 / libx264
Audio:       AAC when the composition has audio
Pixel fmt:   yuv420p
Quality:     CRF 18
Preset:      medium
Fast start:  yes
Frames:      progressive output
```

#### ProRes 422 HQ Master

```text
Container:   MOV
Video:       prores_ks
Profile:     HQ
Pixel fmt:   yuv422p10le
Audio:       PCM signed 24-bit little-endian when audio is present
Frames:      progressive output
```

Codec preset and output frame rate are independent choices.

### Explicit output frame rate

Video export can follow the source rate or conform to one of the currently
supported explicit rates:

- Source
- 23.976 (`24000/1001`)
- 24
- 25
- 29.97 (`30000/1001`)
- 30
- 50
- 59.94 (`60000/1001`)
- 60

The implementation changes the **MLT export profile before the independent
export graph is built**. It is therefore a real render/timeline conform rather
than merely writing different encoder metadata.

Frame boundaries are converted by time. Export In/Out and Layer 2/3 START/END
therefore keep their temporal positions when the output rate differs from the
source rate.

The source ranges inside timed overlays remain source-media frame ranges; their
timeline placement is what is conformed to the output profile.

### Known MLT 7.22 audio-flush warning

On MLT 7.22, successful encoded video exports with an audio stream can emit:

```text
Timestamps are unset in a packet for stream 1
Encoder did not produce proper pts, making some up.
```

Current deterministic coverage shows successful completion despite this known
warning. The warning is tracked separately from export correctness so it does
not mask new failures.

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

With multiple audio-bearing layers this is a **composition mixdown**, not merely
a copy of Layer 1 audio. Track gains and tractor mixes are rendered into the WAV.

---

## Architecture

```text
Flutter UI
    |
    +-- PlayerEngine
    |      +-- transport
    |      +-- selection / trim
    |      +-- composition history
    |      +-- Layer 1 / 2 / 3 indexed state
    |      +-- layer timing + source trims
    |      +-- export range / preset / rate / status
    |
    +-- Dart FFI --------------------------> libmlt_bridge.so
    |                                           |
    +-- MethodChannel -> GTK runner             |
                                                v
                                         opaque MLT engine
                                                |
                      +-------------------------+-------------------------+
                      |                                                   |
                   preview                                              export
                      |                                                   |
          indexed 1–3 layer composition                     indexed snapshot
                      |                                                   |
                   tractor                                      fresh tractor
            composite + mix fields                        composite + mix fields
                      |                                                   |
              sdl2_audio consumer                           avformat consumer
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
- Public media/transport/property entry points fail closed when no engine is
  active.
- Dart resolves the bridge with `DynamicLibrary.process()`.
- The GTK runner links the same bridge into the application process.
- The Flutter texture registrar is process-wide, with one engine selected as
  its current texture source.
- The MLT frame callback never takes the main engine mutex.
- Video frame transfer uses three buffers so producer and Flutter raster
  threads can own buffers independently.
- Scaling, deinterlacing, and image conversion happen on MLT render threads.
- Retired OpenGL texture names are deleted only while Flutter has a valid GL
  context, rather than from arbitrary teardown code.
- Preview and export represent the same indexed composition but share no live
  producer/playlist/tractor objects.
- Graph-rebuilding composition edits can freeze frame publication temporarily
  so history operations become visually atomic.
- Timeline and source-range edits are application-owned state and are rebuilt
  transactionally into MLT graphs.

---

## Deterministic testing

The main native safety net is:

```bash
tools/smoke.sh
```

It builds the bridge and runs independent checks for:

1. **no-active-engine guards** — deliberately destroys the active engine and
   verifies public calls fail closed and return safe sentinel values.
2. **native smoke** — transport, engine isolation, composition, still/alpha
   behavior, audio levels, export, reopen/reset, and teardown.
3. **preview/export parity** — derives state from the live preview graph and a
   freshly constructed export graph, then compares them.
4. **layer timing** — verifies explicit START / END boundaries for Layer 2 and
   Layer 3 and rejects reversed ranges without damaging the composition.
5. **layer source trim** — verifies independent timeline and SOURCE IN / SOURCE
   OUT ranges for timed Layer 2 and Layer 3.
6. **video export presets** — validates H.264 Delivery and ProRes 422 HQ Master
   policy.
7. **video export frame rate** — verifies a 25 fps source conforms to
   `30000/1001` without changing one-second duration and produces 30 output
   frames.
8. **MP4 PTS diagnosis** — tracks the known MLT 7.22 encoded-audio timestamp
   warning separately from export success.

Parity coverage includes:

- timed Layer 2
- held-still Layer 2
- timed/audio Layer 3
- held-alpha Layer 3
- exact insertion frames
- bounded timeline START / END
- timed-video SOURCE IN / SOURCE OUT
- layer counts
- output profile dimensions and frame rate
- composition length and export range
- still/timed classification
- alpha mode
- presentation geometry and opacity
- per-track audio presence and gain
- rejection of a fourth layer without damaging the three-layer tractor

The deterministic export fixture generator is also available:

```bash
bash tools/generate_export_fixtures.sh
```

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

### POC 10 — tracks and composition — hardened three-layer checkpoint

The original POC 10 progression established opaque engine handles, a second
track, playhead-relative placement, opacity, track audio, still/alpha support,
replacement/visibility/order, geometry, and tractor-aware export.

The hardening and Layer 3 work added:

- shared preview/export timing helpers
- export diagnostics and range-state hardening
- native module split (`bridge`, `composition`, `export`)
- preview/export parity instrumentation
- Linux CI for analyzer + smoke/parity
- MLT 7.22 PTS diagnosis
- composition-aware Undo/Redo and explicit layer removal
- macro-alias cleanup
- no-active-engine guards
- safe OpenGL texture retirement/deletion
- indexed three-slot composition snapshots
- real third tractor track in preview and export
- Layer 3 Flutter/FFI and Layers inspector controls
- atomic frame + notification transactions for seamless Layer 3 remove/Undo

The completed export/timing milestone added:

- H.264 Delivery and ProRes 422 HQ Master video presets
- independently selectable output frame rate
- rational 23.976 / 29.97 / 59.94 support
- real MLT profile frame-rate conform
- time-preserving export-range and layer-boundary conversion
- explicit Layer 2 / Layer 3 timeline START / END
- bounded still holds
- timed-overlay SOURCE IN / SOURCE OUT
- independent source-range versus timeline-window semantics
- Undo/Redo and rollback for graph-rebuilding timing edits
- Layer 3 restoration of timing and source trims
- deterministic native coverage for presets, frame rate, layer timing, and
  source trimming

### Next — generalized layer ordering

The next isolated composition milestone is generalized Layer 1 / Layer 2 /
Layer 3 reordering.

Target behavior:

- Move Up / Move Down across the three-layer stack
- preserve each layer's source, timing, source trim, geometry, visibility,
  opacity, alpha interpretation, and audio gain
- preserve the base-movie/profile authority rules explicitly rather than
  accidentally changing them during a visual-order move
- make reordering undoable
- verify preview/export parity after reorder
- retire the current special-case two-layer-only swap once the generalized path
  is proven

After that:

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
- [POC 9: Export Formats and Hardening](docs/poc-9-export-formats-and-hardening.md)
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
flutter analyze
flutter run -d linux
```

Full regression pass:

```bash
flutter analyze
flutter test
tools/smoke.sh
```

---

## License

MIT License

Copyright (c) 2026 nathanfx330

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
