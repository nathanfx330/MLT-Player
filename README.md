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
| Generalized Layer 1 / 2 / 3 visual reordering | Done |
| True two-layer base / overlay role swap | Done |
| Cross-aspect role-swap fitting | Done |
| Atomic role-swap / timing presentation | Done |
| Three-layer arbitrary base-role promotion | Planned |
| Blend-mode exploration | Planned |
| Broader alpha / color policy | Planned |
| MLT XML interchange | Planned |

The current checkpoint is a **hardened three-layer composition, timing,
ordering, and export system**.

Layers 2 and 3 can be timed video or held stills and carry independent
geometry, opacity, visibility, alpha interpretation, audio gain, timeline
START/END, and—in the case of timed video—independent SOURCE IN/SOURCE OUT.

Visual Z-order is explicit state. Layer 1, Layer 2, and Layer 3 can participate
in Move Up / Move Down ordering without losing their indexed composition state.
Preview and export carry the same order permutation.

With exactly two layers, moving timed Layer 2 into the Layer-1 role performs a
**true role swap**: Layer 2 becomes the new base/profile authority and the
former base becomes a normal editable Layer 2. Cross-frame-rate boundaries are
converted through time, and cross-aspect sources are fitted against the new
canvas rather than inheriting an unrelated overlay transform.

Graph-changing edits are presented atomically. The player combines Dart
notification batching, native frame-publication freeze, a final-frame readiness
barrier, double-buffered OpenGL textures, Flutter `Texture.freeze`, and a
first-swap hidden-texture prewarm. The goal is simple: keep the old completed
composition on screen until the new completed composition is ready.

Current video presets include **H.264 Delivery** and **ProRes 422 HQ Master**,
and output frame rate can follow the source or conform to an explicit supported
rate.

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

Current readouts include frame size, display aspect, frame rate, duration,
frame count, file size, average whole-file data rate, selected video/audio
stream indices, codec names, pixel format, colorspace, transfer characteristic,
color range, source timecode, complete stream list, language, bitrate, video
dimensions, audio channel count, and audio sample rate.

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
- Trim is non-destructive and can be nested.
- Clip-relative frames restart at frame 1 after a trim.
- Generated clip timecode restarts at `00:00:00:00`.
- Embedded source timecode remains tied to the original source position.

Undo and Redo are application-owned edit history:

- `Ctrl+Z` — Undo
- `Ctrl+Shift+Z` — Redo

Composition edits participate in the same history. Explicit layer removal is
undoable. Timing/source-trim edits rebuild transactionally and roll back when a
rebuild fails.

Adding Layer 2 or Layer 3 establishes a new composition baseline so walking
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

The logical slots remain stable and indexed internally:

```text
slot 0 = Layer 1
slot 1 = Layer 2
slot 2 = Layer 3
```

A fourth layer is currently rejected rather than silently changing topology.

### Layer 1

Layer 1 is the timed base movie. It defines:

- movie canvas/profile
- frame zero
- overall movie duration

A still image cannot become Layer 1 in the current model.

### Layers 2 and 3

Layers 2 and 3 can be timed video or still images.

Add to Movie places a new overlay at the currently parked playhead. Internally,
MLT Player builds a playlist with a blank lead-in so the added media starts at
the requested movie frame.

Overlay presentation controls include opacity, visibility, source replacement,
per-track audio level, alpha interpretation, X/Y position, scale from 10% to
300%, and a nine-position anchor grid.

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

START cannot cross END and END cannot cross START. For still images, START / END
controls the hold duration.

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

- If the timeline window is shorter than the selected source range, only the
  beginning of the selected source range is used.
- If the selected source range is shorter than the timeline window, the layer
  naturally ends when the selected source range runs out.
- Still images do not expose SOURCE IN / SOURCE OUT.

SOURCE IN / SOURCE OUT edits participate in Undo / Redo, Layer 3 restoration,
preview/export parity, and output-frame-rate conform.

### Visual ordering

Visual Z-order is independent state. Move Up / Move Down can reorder the three
present logical layers without swapping their source/timing/geometry/audio
state.

The Layers inspector displays the actual visual stack, and export reconstructs
the same order on its independent graph.

### Two-layer base-role swapping

With exactly Layer 1 + Layer 2, crossing the Layer-1 boundary is stronger than a
visual reorder.

If Layer 2 is timed video, it can become the new Layer 1/base. The displaced
former base becomes a normal Layer 2 and gains the full overlay control set.

The swap converts timing/playhead values through seconds when frame rates
differ. When aspect ratios differ, the displaced source is fitted to the new
base canvas using its own media characteristics rather than inheriting the
promoted clip's old overlay transform.

A still image cannot be promoted to the base role.

Arbitrary three-layer **base-role promotion** remains a separate future product
decision. Three-layer visual ordering and two-layer role swapping are explicit,
distinct behaviors.

### Atomic graph-changing edits

Layer 3 Remove/Undo, timing/source-trim rebuilds, and two-layer role swaps are
presented as transactions rather than visible assembly sequences.

The presentation path combines:

```text
Dart notification batching
native frame publication freeze
final-frame readiness barrier
double-buffered OpenGL texture names
Flutter Texture.freeze
first-swap alternate-profile prewarming
```

The old completed texture stays visible while the replacement graph is built.
Cross-aspect swaps allocate the new-size texture off-screen. The UI and texture
are released only when the finished replacement state is ready.

---

## Export

Export runs on a **separate native MLT graph**. The encoder never steals or
mutates the live preview tractor.

The bridge snapshots the indexed composition state—including timing, source
ranges, presentation state, audio state, and visual order—and rebuilds it with
fresh MLT objects on the worker thread.

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
trim bounds. In / Out requires a complete valid pair and fails closed before
native work begins when the range is invalid.

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

Video export can follow the source rate or conform to:

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
export graph is built**. Frame boundaries are converted by time so export
In/Out and Layer 2/3 START/END keep their temporal positions when output rate
differs from the source rate.

The deterministic frame-rate smoke test also renders a three-layer 25 → 29.97
fixture and samples the encoded output around the expected transition frames.
That regression covers overlay START/END together with timed-video SOURCE IN /
SOURCE OUT instead of testing frame-rate conform only on a one-layer movie.

### Known MLT 7.22 audio-flush warning

Successful encoded video exports with audio can emit:

```text
Timestamps are unset in a packet for stream 1
Encoder did not produce proper pts, making some up.
```

Deterministic coverage shows successful completion despite this known MLT 7.22
warning. It is tracked separately from export correctness.

### Current-frame PNG

PNG exports are rendered from the MLT composition graph rather than copied from
the Flutter texture. Anamorphic sources are written at display dimensions with
square pixels, using Lanczos scaling and preserving RGBA.

### PNG image sequence

Image-sequence export writes deterministic owned filenames into a fresh empty
directory:

```text
movie_frames/
  frame_000001.png
  frame_000002.png
  frame_000003.png
  ...
```

Completion validation checks expected count, numbering range, and non-empty
output. Failed/cancelled jobs remove only files owned by that export.

### WAV audio export

The fixed audio interchange preset is 24-bit PCM WAV with video disabled. With
multiple audio-bearing layers this is a **composition mixdown**, not merely a
copy of Layer 1 audio.

---

## Architecture

```text
Flutter UI
    |
    +-- PlayerEngine
    |      +-- transport / selection / trim
    |      +-- composition history
    |      +-- Layer 1 / 2 / 3 indexed state
    |      +-- visual Z-order
    |      +-- layer timing + source trims
    |      +-- export range / preset / rate / status
    |      +-- atomic presentation transactions
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
                CPU frame buffers
                      |
          double-buffered OpenGL textures
                      |
             Flutter Texture widget
```

Important architecture rules:

- MLT factory/repository lifetime is process-wide.
- Playback state lives in opaque `MltBridgeEngine` handles.
- Public media/transport/property entry points fail closed when no engine is
  active.
- Dart resolves the bridge with `DynamicLibrary.process()`.
- The Flutter texture registrar is process-wide, with one engine selected as
  its current texture source.
- Preview and export represent the same indexed composition but share no live
  producer/playlist/tractor objects.
- Visual order is composition state and is reproduced in export.
- Graph-rebuilding edits freeze both model publication and rendered-frame
  presentation until the replacement state is complete.
- The currently displayed GL texture is not resized in place during an atomic
  cross-aspect swap; a hidden back texture is prepared first.
- The alternate-size texture path is prewarmed before the first role swap so
  the first visible transition uses the same hot path as later swaps.

---

## Deterministic testing

The main native safety net is:

```bash
tools/smoke.sh
```

It covers:

1. no-active-engine guards
2. native transport/composition smoke
3. preview/export parity
4. bounded layer START / END
5. timed-overlay SOURCE IN / SOURCE OUT
6. generalized layer ordering
7. video export presets
8. video export frame-rate conform, including rendered layered START/END and
   SOURCE IN/SOURCE OUT coverage across 25 → 29.97

Parity coverage includes two- and three-layer compositions, still/timed media,
exact placement, source trim, geometry/opacity, alpha, audio gain, visual order,
profile dimensions/rate, composition length, and export range.

The current Flutter suite is also run with:

```bash
flutter analyze
flutter test
```

At the ordering/role-swap checkpoint, the Flutter suite reports **17 passing
tests** and the native smoke groups report zero failures.

---

## Roadmap

### POC 0–9 — complete

Playback foundation, precise transport, inspection, selection/trim, and the
independent background-export system are complete.

### POC 10 — tracks and composition — current hardened checkpoint

Completed milestones now include:

- opaque engine handles
- three-layer tractor composition
- playhead-relative layers
- still/alpha support
- independent geometry / opacity / visibility / audio gain
- Layer 2 / Layer 3 timeline START / END
- timed-overlay SOURCE IN / SOURCE OUT
- composition-aware Undo / Redo and layer removal
- seamless Layer 3 Remove / Undo
- H.264 Delivery + ProRes 422 HQ Master presets
- explicit output-rate conform
- preview/export parity
- generalized three-layer visual Z-order
- true two-layer base-role swapping
- cross-aspect displaced-base fitting
- atomic timing/source-trim/role-swap presentation
- double-buffered GL texture handoff
- Flutter `Texture.freeze` presentation boundary
- first-swap alternate-profile prewarming

### Next composition work

Likely next steps:

- arbitrary three-layer base-role promotion, if the product needs it
- blend-mode exploration
- broader alpha / color policy

### POC 11 — interchange

Planned:

- save MLT XML
- open MLT XML
- open image sequences at a chosen frame rate

---

## Engineering notes

- [Documentation index](docs/README.md)
- [Embedding MLT in a Flutter/Linux Desktop Player](docs/embedding-mlt-in-a-flutter-linux-app.md)
- [POC 9: Export Formats and Hardening](docs/poc-9-export-formats-and-hardening.md)
- [POC 10: Multitrack, Compositing, and Tractor-Aware Export](docs/poc-10-multitrack-compositing-and-export.md)
- [POC 10 continuation: Layer Ordering, Role Swaps, and Atomic Presentation](docs/poc-10-layer-ordering-and-atomic-role-swaps.md)

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

MLT Player's own source code is licensed under the MIT License. The MIT badge
and [`LICENSE`](LICENSE) describe the license for code authored for this
repository; they do not replace the licenses of MLT, FFmpeg, codec libraries,
or other third-party components used at runtime or included in a binary
package.

### Third-party licensing

MLT Player dynamically links the installed `mlt-framework-7`. The MLT project
licenses its framework/client libraries under LGPL-2.1, while modules/plugins
can carry different licenses and some MLT build configurations enable GPL
components. FFmpeg is normally LGPL-2.1-or-later, but its effective license can
become GPL when GPL components or external libraries such as `libx264` are
enabled.

Anyone distributing prebuilt MLT Player binaries should audit the exact MLT
modules, FFmpeg build configuration, codec libraries, and other dependencies
being shipped, then satisfy the notices and distribution obligations that
actually apply. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the
project's distribution checklist and upstream references.

### MIT License

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