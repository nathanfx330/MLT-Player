<!-- README.md -->

# MLT Player

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**MLT Player** is a Flutter/Linux media utility built on the **MLT (Media Lovin' Toolkit)**.

The project now has two deliberately connected parts:

- **MLT Explorer** — an Adobe Bridge-style local media browser.
- **MLT Player** — a QuickTime 7 Pro-style precision player and small composition/export tool.

The product goal is not to become a conventional NLE or a large digital-asset-management system.

It is a fast local-media workflow:

```text
open a directory
→ browse media visually
→ choose an asset
→ inspect it precisely
→ make one surgical change when needed
→ export/save
→ return to the browser
```

Flutter owns the application and UI. MLT owns media playback, compositing, metadata, and export. Video reaches Flutter through an OpenGL texture rather than a second native playback window.

Built and tested against **MLT 7.22.0 on Linux**.

---

## Current checkpoint

MLT Player has completed the hardened player/composition phase and the first working **MLT Explorer** shell.

At the Phase 11.1 Explorer checkpoint:

- `flutter analyze` is clean.
- the Flutter suite reports **21 passing tests**.
- all native smoke groups report zero failures.
- the Explorer builds and runs successfully on Linux.
- directory browsing → media selection → existing MLT Player → return to Explorer is interactively proven.

### Current status

| Area | State |
| --- | --- |
| Flutter Linux application | Done |
| Native C / Dart FFI bridge | Done |
| Opaque playback-engine handles | Done |
| External OpenGL video texture | Done |
| Audio through `sdl2_audio` | Done |
| Precise transport / frame stepping / shuttle | Done |
| Stream / codec inspection | Done |
| In / Out / Trim / Undo / Redo | Done |
| H.264 / ProRes / PNG / sequence / WAV export | Done |
| Three-layer MLT tractor | Done |
| Layer START / END | Done |
| Timed-overlay SOURCE IN / SOURCE OUT | Done |
| Layer geometry / opacity / visibility / alpha / audio | Done |
| Generalized Layer 1 / 2 / 3 visual ordering | Done |
| Timed-video base-role promotion across all three slots | Done |
| Cross-aspect displaced-base fitting | Done |
| Cross-frame-rate role conversion | Done |
| Atomic graph-changing presentation | Done |
| Preview / export parity harness | Done |
| No-active-engine guard regression | Done |
| Explicit output frame-rate conform | Done |
| MLT Explorer application home | Done |
| Open Folder / folder navigation | Done |
| Supported-media directory scan | Done |
| Explorer → persistent Player handoff | Done |
| Explorer selection / keyboard navigation foundation | Done |
| Real image/video thumbnails | Planned |
| Persistent thumbnail cache | Planned |
| Rich Explorer metadata pane | Planned |
| Search / ratings / tags | Not currently a goal |
| Blend-mode exploration | Planned |
| Broader alpha / color policy | Planned |
| MLT XML interchange | Planned |

Engineering notes live in [`docs/`](docs/README.md).

---

# MLT Explorer

The application now launches into **MLT Explorer** rather than an empty player.

Phase 11.1 intentionally establishes the browser/navigation architecture before thumbnail generation.

```text
Launch MLT Player
      ↓
   MLT Explorer
      ↓
   Open Folder
      ↓
folder + media grid
      ↓
select / double-click
      ↓
existing MLT Player
      ↓
Back / Esc
      ↓
same Explorer directory and selection
```

## What Explorer does today

Explorer can:

- open a local directory
- scan that directory non-recursively
- show folders and supported media
- filter unsupported files
- sort folders before media
- sort items alphabetically
- enter folders
- navigate to the parent folder
- select an item
- open media by double-click, Enter, or **Open in Player**
- return from Player to the same Explorer state
- open a single media file directly with the existing file chooser

The first browser cards use media-type placeholders rather than generated thumbnails.

That is deliberate. The browser shell and Player lifecycle were proven first so the next phase can add asynchronous thumbnail workers without coupling them to the interactive preview engine.

## Explorer shortcuts

Current browser-oriented shortcuts include:

- `Ctrl+Shift+O` — Open Folder
- `Ctrl+O` — Open media directly
- `Enter` — open selected folder/media
- `Backspace` — parent folder
- double-click — open selected folder/media
- `Esc` from Player — return to Explorer when not fullscreen

---

# Player

The Player preserves the original QuickTime 7 Pro-inspired goal:

**open → inspect → make one precise change → export/save → close**

It is intentionally not a conventional editor.

Deliberate non-goals include:

- no giant project workflow
- no traditional NLE timeline
- no batch-transcoder-centered interface
- no feature merely because MLT exposes it

## Precise transport

Transport is frame-aware.

- Left / Right step exactly one frame.
- `K` pauses.
- `L` cycles forward through `1×`, `2×`, `4×`, `8×`.
- `J` cycles reverse through `-1×`, `-2×`, `-4×`, `-8×`.
- changing direction restarts at `1×`
- Loop preserves the current shuttle magnitude
- Play All Frames switches MLT to no-drop playback
- generated clip timecode starts at `00:00:00:00`
- embedded source timecode remains source-relative through trims

Reverse playback depends heavily on codec structure. Long-GOP H.264/H.265 is much more expensive to decode backward than intra-frame media such as ProRes, DNxHR, MJPEG, or image sequences.

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
- selected video/audio stream indices
- codec names
- pixel format
- colorspace
- transfer characteristic
- color range
- source timecode
- complete stream list
- language
- bitrate
- video dimensions
- audio channel count
- audio sample rate

The **Layers** inspector exposes the current composition state for Layers 1–3.

---

# Selection and trim

Selection is frame-based.

- `I` sets the In frame.
- `O` sets the Out frame.
- Play Selection plays only the marked range.
- Loop + Play Selection loops In → Out → In.
- Trim Selection turns the marked range into the active clip.
- Trim is non-destructive and participates in Undo / Redo.
- clip-relative frames restart at frame 1 after a trim
- generated clip timecode restarts at `00:00:00:00`
- embedded source timecode remains tied to the original source position

Undo / Redo:

- `Ctrl+Z` — Undo
- `Ctrl+Shift+Z` — Redo

---

# Three-layer composition

The player supports a fixed three-slot composition:

```text
slot 0 = Layer 1 / base
slot 1 = Layer 2
slot 2 = Layer 3
```

A fourth layer is currently rejected rather than silently creating an untested topology.

## Overlay state

Layers 2 and 3 can be timed video or held still images.

They can carry independent:

- timeline START / END
- timed-video SOURCE IN / SOURCE OUT
- opacity
- visibility
- source replacement
- X / Y
- scale
- nine-position anchors
- alpha interpretation
- per-track audio gain

There is no implicit speed change or time stretch when source trim and timeline placement differ.

## Visual order versus base authority

MLT Player explicitly separates:

```text
media identity
≠
logical layer role
≠
visual Z-order
```

Visual Move Up / Move Down ordering can place Layer 1, Layer 2, or Layer 3 anywhere in the displayed stack while preserving the media-owned state.

Crossing the **base-role boundary** is different.

A timed video from Layer 2 or Layer 3 can become the true Layer 1/base authority.

The promoted source then owns:

- movie profile/canvas
- frame zero
- frame rate
- duration

The displaced former base is rebuilt as a fresh overlay so it receives a correct fit against the new canvas rather than inheriting an unrelated transform.

A still image cannot become Layer 1.

## Three-layer base-role promotion

Base promotion is generalized across all three current slots.

Examples:

```text
A = current base
B = Layer 2
C = Layer 3
```

Layer 2 promotion:

```text
before:  A(base), B, C
after:   B(base), A, C
```

Layer 3 promotion:

```text
before:  A(base), B, C
after:   C(base), B, A
```

Layer 2/3 state that survives a promotion keeps its media-owned properties.

When the new base has a different frame rate, timeline and timed-source boundaries are converted through time rather than copied as raw frame numbers.

Inclusive END / SOURCE OUT values are converted through their exclusive boundary (`END + 1`) and converted back afterward.

## Atomic graph-changing edits

Graph rebuilds are treated as presentation transactions.

The implementation combines:

```text
Dart notification batching
native frame-publication freeze
final-frame readiness barrier
double-buffered OpenGL textures
Flutter Texture.freeze
alternate-profile texture prewarming
```

The user sees:

```text
old completed composition
        ↓
new completed composition
```

rather than the intermediate graph being assembled.

---

# Export

Export runs on a **separate native MLT graph**.

Preview and export share indexed scalar/path composition state but do not share live producer, playlist, tractor, transition, filter, or consumer objects.

Current output families include:

- H.264 / MP4
- ProRes 422 HQ / MOV
- composited current-frame PNG
- composited PNG image sequence
- mixed WAV audio

## Video presets

### H.264 Delivery

```text
Container:   MP4
Video:       H.264 / libx264
Audio:       AAC when audio is present
Pixel fmt:   yuv420p
Quality:     CRF 18
Preset:      medium
Fast start:  yes
Frames:      progressive
```

### ProRes 422 HQ Master

```text
Container:   MOV
Video:       prores_ks
Profile:     HQ
Pixel fmt:   yuv422p10le
Audio:       PCM signed 24-bit little-endian when audio is present
Frames:      progressive
```

## Explicit output frame rate

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

The export profile is changed before the independent export graph is built. Timeline and source boundaries are converted by time.

The deterministic frame-rate smoke test includes a rendered three-layer 25 → 29.97 fixture and samples the encoded output around expected transition frames.

## Known MLT 7.22 audio-flush warning

Successful encoded video exports with audio can emit:

```text
Timestamps are unset in a packet for stream 1
Encoder did not produce proper pts, making some up.
```

The deterministic tests prove successful export despite this known MLT 7.22 warning. It is tracked separately from export correctness.

---

# Architecture

```text
Flutter application
    |
    +-- Explorer shell
    |      |
    |      +-- ExplorerService
    |      |      +-- local directory scan
    |      |      +-- supported-media classification
    |      |
    |      +-- ExplorerPage
    |      +-- persistent browser state
    |
    +-- Player view
    |      |
    |      +-- PlayerEngine
    |             +-- transport / selection / trim
    |             +-- composition history
    |             +-- Layer 1 / 2 / 3 indexed state
    |             +-- visual Z-order
    |             +-- role promotion
    |             +-- layer timing + source trims
    |             +-- export state
    |             +-- atomic presentation transactions
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
             indexed composition                               indexed snapshot
                      |                                                   |
                   tractor                                      fresh tractor
                      |                                                   |
              preview consumer                                  avformat consumer
                      |
               CPU frame buffers
                      |
          double-buffered OpenGL textures
                      |
             Flutter Texture widget
```

Explorer and Player are maintained as persistent application views rather than repeatedly destroying and recreating the native Player lifecycle when the user returns to the browser.

Thumbnail generation will be a separate background subsystem. It will **not** drive the live PlayerEngine through every asset in a directory.

---

# Deterministic testing

Primary commands:

```bash
flutter analyze
flutter test
tools/smoke.sh
```

At the Phase 11.1 Explorer checkpoint:

```text
Flutter analyze: clean
Flutter tests:   21 passed
Native smoke:    all groups passed, 0 failures
```

The native safety net covers:

1. no-active-engine guards
2. native transport/composition smoke
3. preview/export parity
4. bounded Layer START / END
5. timed-overlay SOURCE IN / SOURCE OUT
6. generalized layer ordering
7. video export presets
8. layered output frame-rate conform

The Explorer service has Flutter tests covering directory scanning, supported-media filtering, and ordering behavior.

---

# Roadmap

## POC 0–9 — complete

Playback foundation, precise transport, inspection, selection/trim, and independent background export.

## POC 10 — composition — complete current three-layer model

Completed:

- opaque engine handles
- three-layer tractor composition
- still / alpha overlays
- independent geometry / opacity / visibility / audio
- Layer 2 / Layer 3 START / END
- timed-overlay SOURCE IN / SOURCE OUT
- composition-aware Undo / Redo
- layer removal / restoration
- preview/export parity
- H.264 + ProRes presets
- explicit output-rate conform
- generalized three-layer visual order
- true base-role promotion through Layers 1–3
- cross-frame-rate boundary conversion
- cross-aspect displaced-base fitting
- atomic graph-changing presentation
- double-buffered GL handoff
- Flutter texture freeze
- alternate-profile prewarming

## POC 11 — MLT Explorer — current

### Phase 11.1 — complete

- Explorer is the application home
- Open Folder
- directory scan
- folder/media grid
- media classification
- selection
- folder navigation
- Explorer → persistent Player handoff
- Player → Explorer return

### Phase 11.2 — next

- asynchronous real thumbnails
- video representative frames
- image thumbnails
- cancellation/prioritization for visible grid items
- persistent thumbnail cache keyed by source identity/change state

Likely follow-on Explorer work:

- richer selection metadata
- thumbnail-size control
- navigation history
- optional favorites / locations
- performance work for very large directories

## POC 12 — interchange / file-oriented extensions

Potential later work:

- save MLT XML
- open MLT XML
- open image sequences at a chosen frame rate

---

# Engineering notes

- [Documentation index](docs/README.md)
- [Embedding MLT in a Flutter/Linux Desktop Player](docs/embedding-mlt-in-a-flutter-linux-app.md)
- [POC 9: Export Formats and Hardening](docs/poc-9-export-formats-and-hardening.md)
- [POC 10: Multitrack, Compositing, and Tractor-Aware Export](docs/poc-10-multitrack-compositing-and-export.md)
- [POC 10 continuation: Layer Ordering, Role Promotion, and Atomic Presentation](docs/poc-10-layer-ordering-and-atomic-role-swaps.md)
- [POC 11: MLT Explorer Foundation](docs/poc-11-mlt-explorer-foundation.md)

---

# Linux development

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
