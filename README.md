<!-- README.md -->

# MLT Player

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**MLT Player** is a Flutter/Linux media utility built on the **MLT (Media Lovin' Toolkit)**.

The project has two deliberately connected parts:

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

Flutter owns the application and UI. MLT owns media playback, compositing, metadata, export, and Explorer thumbnail decoding. Video reaches Flutter through an OpenGL texture rather than a second native playback window.

Built and tested against **MLT 7.22.0 on Linux**.

---

## Current checkpoint

MLT Player has completed the hardened three-layer Player/composition phase and the first substantial **MLT Explorer** phase through **11.8**, followed by a dedicated MLT-native thumbnail hardening pass.

At the current checkpoint:

```text
flutter analyze          clean
flutter test             64 passed
tools/smoke.sh           all native groups passed, 0 failures
tools/thumbnail_smoke.sh PASS, 0 failures
flutter run -d linux     interactively proven
standalone release       interactively proven
```

The standalone release proof is now a first-class validation tier because two separate native failures appeared only outside `flutter run` during Explorer development.

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
| Navigation history / Home / Favorites / Recent | Done |
| Supported-media directory scan | Done |
| Explorer → persistent Player handoff | Done |
| Explorer selection / keyboard navigation | Done |
| Real image/video thumbnails | Done |
| Persistent thumbnail cache | Done |
| MLT-native representative-frame thumbnails | Done |
| Release-safe still-image producer policy | Done |
| Rich Explorer metadata pane | Done |
| Thumbnail size / view density | Done |
| Filename filtering | Done |
| Name / Modified / Size / Type sorting | Done |
| Persistent ratings / tags | Done |
| Rating / tag filtering | Done |
| Blend-mode exploration | Planned |
| Broader alpha / color policy | Planned |
| MLT XML interchange | Planned |

Engineering notes live in [`docs/`](docs/README.md).

---

# MLT Explorer

The application launches into **MLT Explorer** rather than an empty player.

```text
Launch MLT Player
      ↓
   MLT Explorer
      ↓
   Open Folder
      ↓
visual folder/media browser
      ↓
select / inspect / filter
      ↓
double-click / Enter
      ↓
existing MLT Player
      ↓
Back / Esc
      ↓
same Explorer context
```

## What Explorer does today

Explorer can:

- open a local directory
- scan that directory non-recursively
- show folders and supported media
- generate persistent image/video thumbnails
- choose representative video frames rather than assuming the first second is useful
- show selected-file metadata in the right pane
- navigate Back / Forward / Up / Home
- maintain Favorites and Recent locations
- preserve directory/selection context when entering Player
- change thumbnail size and view density
- filter the current folder by filename
- sort by Name, Modified, Size, or Type
- reverse sort direction while keeping folders above media
- assign 0–5 star ratings
- assign persistent free-form tags
- filter by minimum rating
- filter by exact tag
- combine filename + rating + tag filters with AND semantics
- open media by double-click, Enter, or **Open in Player**
- return from Player to the same Explorer state
- open a single media file directly with the existing file chooser

The Explorer intentionally remains a fast local browser rather than a recursive catalog/database system.

## Explorer annotations

Ratings and tags are sidecar metadata owned by MLT Player, not by the source media.

They are stored under the user configuration directory, normally:

```text
~/.config/mlt_player/explorer_annotations.json
```

Ratings are clamped to 0–5. Tags are trimmed and deduplicated case-insensitively while preserving display casing.

The annotation catalog stays sparse: an asset with no rating and no tags has no persisted record.

## Explorer filters

Current filtering is scoped to the open folder:

```text
filename text
AND
minimum rating
AND
exact tag
```

Annotation filters hide directories because folders do not carry ratings or tags. Clearing the annotation filters restores normal folder visibility.

Filter state is session-local. Ratings and tags themselves persist.

## Explorer shortcuts

Current browser-oriented shortcuts include:

- `Ctrl+Shift+O` — Open Folder
- `Ctrl+O` — Open media directly
- `Ctrl+F` — focus filename filter
- `Alt+Left` — Back
- `Alt+Right` — Forward
- `Alt+Home` — Home
- `Backspace` — parent directory
- `Enter` — open selected folder/media
- double-click — open selected folder/media
- `Esc` from Player — return to Explorer when not fullscreen

---

# MLT-native thumbnails

Explorer thumbnails originally began as an asynchronous cache backed by an external `ffmpeg` executable. The surrounding cache architecture was sound, but the decoder choice was not ideal for this project.

The hardened architecture is now:

```text
Explorer ThumbnailService
        ↓
Dart worker isolate
        ↓
MltThumbnailBridge
        ↓
serialized native thumbnail lane
        ↓
private MLT producer/profile
        ↓
representative-frame selection
        ↓
480 × 270 JPEG cache entry
```

The application does **not** shell out to `ffmpeg` to render runtime thumbnails.

## Representative video frames

Timed video samples three strategic positions:

```text
15%
50%
85%
```

Candidate frames are scored for visual variance/contrast with a penalty for near-black imagery. The strongest candidate is rendered into the cache.

This avoids the common “wall of black thumbnails” failure caused by always taking frame zero or a fixed one-second frame from media with slates, fade-ins, or black leaders.

The focused thumbnail smoke fixture contains a two-second black leader and proves that representative-frame selection skips it.

## Still-image producer policy

Still images use an explicit safe producer order:

```text
pixbuf
→ avformat fallback
```

The runtime avoids implicit `qimage` selection for this path.

That producer policy was established after a standalone-release failure exposed a Qt image-producer/thread-context problem that was not reproducible under `flutter run`.

## Thumbnail cache

The persistent cache normally lives under:

```text
~/.cache/mlt_player/thumbnails/
```

Cache identity uses:

```text
cache version
+ absolute path
+ file size
+ modification timestamp
```

The current cache version identifies the MLT representative-frame implementation, so older ffmpeg-generated thumbnails invalidate cleanly.

The cache preserves:

- in-flight deduplication
- atomic temp-file publish + rename
- pause/drain during Explorer → Player handoff
- bounded background work
- cache hits without regeneration

Native MLT thumbnail generation itself is serialized. That restriction is deliberate and release-proven.

---

# Two release-only failures that changed the test strategy

Explorer development exposed an important distinction:

```text
works under flutter run
≠
works as the installed standalone release bundle
```

Two unrelated native problems demonstrated this.

## Release issue 1: primary still images and `qimage`

The first issue appeared when opening still images from the standalone release build.

The same application path worked under `flutter run`, but release execution could select MLT's Qt `qimage` producer in a worker context. Diagnostics pointed to Qt application/thread assumptions, and the release process could fail even though normal debug testing was green.

The fix was to make still-image producer selection explicit:

```text
still extension
→ pixbuf
→ avformat fallback
→ do not rely on qimage auto-selection
```

That made standalone MP4 and PNG opening behave consistently with the tested Player architecture.

## Release issue 2: in-process MLT thumbnail concurrency

The second issue appeared later, after runtime thumbnail decoding moved from external ffmpeg subprocesses into the application process through MLT.

All of the following were green:

- Flutter analysis
- Flutter tests
- single native thumbnail smoke
- full Player/native smoke
- interactive `flutter run`

But the optimized standalone release still crashed while browsing thumbnails.

The architectural difference was concurrency. The original ffmpeg thumbnail workers were isolated in subprocesses. The new implementation allowed more than one Dart worker isolate to enter in-process MLT thumbnail decoding at the same time.

The final fix was deliberately conservative:

```text
one active Explorer thumbnail worker
+
process-wide native thumbnail mutex
```

A new native regression test launches multiple thumbnail callers concurrently and proves that they all complete safely through the serialized lane.

The release bundle was then rebuilt and interactively tested against the folder that had previously crashed. It remained stable.

## Resulting validation tiers

Native-heavy changes now deserve four distinct proofs:

```text
1. Flutter static/unit tests
2. headless native smoke tests
3. flutter run interactive behavior
4. standalone release-bundle interactive behavior
```

A green debug run is no longer treated as evidence that packaging, producer choice, optimized scheduling, and native thread behavior are release-safe.

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

Visual Move Up / Move Down ordering can place Layer 1, Layer 2, or Layer 3 anywhere in the displayed stack while preserving media-owned state.

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

Layer state that survives a promotion keeps its media-owned properties.

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
    |      +-- navigation/history/preferences
    |      +-- annotation service
    |      +-- sort/filter service
    |      +-- metadata service
    |      |
    |      +-- ThumbnailService
    |             +-- persistent cache
    |             +-- in-flight dedupe
    |             +-- pause/drain handoff
    |             +-- one active worker
    |             +-- MltThumbnailBridge
    |                    ↓
    |             serialized native MLT thumbnail lane
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

Thumbnail generation uses independent producer/profile objects and never drives the live Player through every file in the directory.

---

# Deterministic testing

Primary commands:

```bash
flutter analyze
flutter test
tools/thumbnail_smoke.sh
tools/smoke.sh
```

Current automated checkpoint:

```text
Flutter analyze:       clean
Flutter tests:         64 passed
Thumbnail native smoke: PASS, 0 failures
Native smoke groups:   all passed, 0 failures
```

The native Player safety net covers:

1. no-active-engine guards
2. native transport/composition smoke
3. preview/export parity
4. bounded Layer START / END
5. timed-overlay SOURCE IN / SOURCE OUT
6. generalized layer ordering
7. video export presets
8. layered output frame-rate conform

The focused thumbnail safety net covers:

1. MLT-native timed-video generation
2. persistent output creation
3. black-leader representative-frame selection
4. requested thumbnail dimensions
5. MLT-native still generation
6. missing-media failure
7. explicit native diagnostic propagation
8. concurrent callers safely serialized through the native thumbnail lane

## Release validation

Native-heavy Explorer changes are not complete until the installed-style bundle is exercised:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

At minimum, release testing should browse a thumbnail-heavy folder and open both a timed-video file and a still image through Explorer.

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

### Phase 11.1 — Explorer foundation — complete

- Explorer becomes application home
- Open Folder
- directory scan
- folder/media grid
- media classification
- selection
- folder navigation
- persistent Explorer ↔ Player shell

### Phase 11.2 — real thumbnails + release still hardening — complete

- asynchronous real video/image thumbnails
- persistent thumbnail cache
- Explorer → Player thumbnail pause/drain handoff
- release-safe still-image producer policy
- `pixbuf` primary still path with `avformat` fallback
- standalone release MP4/PNG proof

### Phase 11.3 — selection metadata — complete

- right-side selected-file metadata pane
- file size / modified / type / format
- selected image dimensions
- metadata caching without scanning every asset through MLT

### Phase 11.4 — navigation + locations — complete

- Back / Forward / Up / Home
- keyboard history shortcuts
- Favorites
- Recent locations
- persisted location state

### Phase 11.5 — thumbnail size + density — complete

- Compact / Small / Standard / Large / Extra Large
- grid geometry changes together
- persisted view preferences

### Phase 11.6 — sort + current-folder filename filter — complete

- case-insensitive filename filtering
- `Ctrl+F`
- Name / Modified / Size / Type sorts
- ascending / descending
- folders remain above media
- sort preferences persist

### Phase 11.7 — ratings + tags — complete

- persistent 0–5 star ratings
- persistent tags
- case-insensitive tag dedupe
- sparse annotation catalog
- source media remains untouched

### Phase 11.8 — rating + tag filters — complete

- minimum-star filter
- exact-tag filter populated from current folder
- filename + rating + tag AND semantics
- clear-all filters
- selection remains path-stable when an edited asset leaves the current result set

### Thumbnail architecture hardening — complete

- removed runtime external ffmpeg thumbnail dependency
- dedicated MLT-native thumbnail FFI path
- representative video frame selection
- MLT still-image producer policy aligned with Player behavior
- serialized native thumbnail lane
- release-only concurrency crash regression coverage
- cache-version migration from the earlier generator

Likely follow-on Explorer work should remain bounded and workflow-driven rather than expanding automatically into a full DAM.

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
- [POC 11 continuation: Explorer Growth, MLT-Native Thumbnails, and Release Hardening](docs/poc-11-explorer-growth-thumbnail-hardening.md)

---

# Linux development

Typical native-change rebuild:

```bash
flutter clean
flutter pub get
flutter build linux --debug
flutter run -d linux
```

Dart-only changes normally need only:

```bash
flutter analyze
flutter run -d linux
```

Full automated regression pass:

```bash
flutter analyze
flutter test
tools/thumbnail_smoke.sh
tools/smoke.sh
```

For native or packaging-sensitive changes, add the standalone release proof:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
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

Runtime Explorer thumbnail generation no longer shells out to the `ffmpeg`
command-line executable. MLT can still use FFmpeg-backed modules internally,
and the build/test tooling uses ffmpeg/ffprobe for deterministic fixture
creation and encoded-output validation.

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
