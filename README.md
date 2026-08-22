# MLT Player

[![CI](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml/badge.svg)](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A desktop media player built with **Flutter** and **MLT (Media Lovin' Toolkit)**.

Flutter owns the application. MLT owns the media. The two meet through a small
C bridge, and video arrives in the interface as an OpenGL texture rather than
in a window of its own.

The target is specific: **recover the practical role of QuickTime 7 Pro**.

Not an NLE. Not a batch transcoder. A tool for opening a file, looking closely,
making one surgical change, saving or exporting it, and closing it.

---

## Why QuickTime 7 Pro

QuickTime 7 Pro was not an editor. That is the point.

It opened quickly, showed you the file, and let you do one precise thing to
it: set an In and an Out, trim, step a frame at a time, inspect the streams,
play a selection, paste another clip as a parallel track, offset it, inspect
alpha, export an image sequence, or save a reference movie.

Then it closed.

No bins. No project conform. No primary editing timeline. No render queue as
the center of the application.

For post-production work, it lived beside the real editor.

That shape of tool largely disappeared. VLC plays but does not edit. FFmpeg
transforms but does not let you work visually. Shotcut, Kdenlive and Resolve
are project-based editors, which is a different job.

The gap is:

**open, look closely, do one thing, save, close.**

MLT is a good engine for that job. Its producers, playlists, tractors,
filters, transitions and consumers already contain most of the underlying
operations. The work here is not to expose all of MLT. It is to expose the
small subset that belongs in this kind of tool and deliberately refuse the
rest.

---

## Current status

The player, precise transport, inspection, non-destructive selection/trim and
the first background export path are all working.

Built against **MLT 7.22.0**.

| Area | State |
| --- | --- |
| Flutter Linux application | Done |
| Native C / Dart FFI bridge | Done |
| External OpenGL video texture | Done |
| Audio through `sdl2_audio` | Done |
| Play, pause, seek and scrub | Done |
| Exact ±1-frame stepping | Done |
| J / K / L shuttle, including reverse | Done |
| Loop | Done |
| Play All Frames | Done |
| Generated clip timecode | Done |
| Embedded source timecode when present | Done |
| Stream / codec inspection | Done |
| Data size and average data rate | Done |
| Pixel format / colorspace / transfer / range | Done |
| Full container stream list | Done |
| In / Out selection | Done |
| Play Selection | Done |
| Loop Selection | Done |
| Undo / Redo | Done |
| Non-destructive Trim Selection | Done |
| Background MP4 export | Done |
| Selection / active-clip export | Done |
| Export progress and cancel | Done |
| Image-sequence / still / audio export options | Next |
| Multi-track / Add to Movie | Planned |
| MLT XML interchange | Planned |

---

## What works now

### Precise transport

Transport is frame-aware rather than only time-aware.

- Left / Right step exactly one frame.
- `K` pauses.
- `L` cycles forward through `1×`, `2×`, `4×`, `8×`.
- `J` cycles reverse through `-1×`, `-2×`, `-4×`, `-8×`.
- Changing direction begins at `1×` in the new direction.
- Loop preserves the current shuttle magnitude.
- Play All Frames switches MLT between real-time frame-dropping playback and
  asynchronous no-drop playback.
- The transport readout can show either frame number or generated clip-relative
  timecode.
- Source timecode is shown separately when the source actually contains it.

Reverse playback is supported, but codec structure still matters. Long-GOP
H.264/H.265 media is inherently much more expensive to decode backward than
ProRes, DNxHR, MJPEG or image sequences.

### Inspection

The Inspector reports the media MLT actually opened rather than guessing from
the filename.

Current readouts include:

- frame size
- display aspect
- frame rate
- duration
- frame count
- file size
- average data rate
- selected video stream
- selected audio stream
- codec short and long names
- pixel format
- colorspace
- transfer characteristic
- color range
- source timecode when present
- full stream list
- stream language
- stream bitrate
- video dimensions
- audio channel count and sample rate

The Inspector is scrollable and intentionally read-only.

### Selection and trim

Selection is frame-based.

- `I` sets the In frame.
- `O` sets the Out frame.
- The marked range is shown directly on the scrubber.
- Selection duration and inclusive frame count are displayed.
- Play Selection plays only the marked range.
- With Loop enabled, Play Selection loops In → Out → In.
- Trim Selection turns the marked range into the active clip.
- Trim is non-destructive: the source file and source producer remain intact.
- The trimmed clip gets its own clip-relative frame count and timecode starting
  at frame 1 / `00:00:00:00`.
- Embedded source timecode continues to refer to the original source position.
- Trims can be nested.

Undo and Redo are application-owned edit history:

- `Ctrl+Z` — Undo
- `Ctrl+Shift+Z` — Redo

In/Out marker changes and trims both participate in the same history stack.

### Export

POC 9 now has a working first export path.

Export runs on a **separate MLT producer/profile/consumer graph** in a native
background thread. It does not commandeer the live playback producer,
`sdl2_audio` consumer or Flutter texture.

Current export behavior:

- `Ctrl+E` or **EXPORT**
- exports the marked In/Out selection when one exists
- otherwise exports the current active trimmed clip
- progress is reported in the interface
- export can be cancelled
- failed or cancelled renders remove the partial file
- playback remains independent while export is running

The first proven preset is intentionally fixed:

```text
Container: MP4
Video:     H.264 / libx264
Audio:     AAC
Pixel fmt: yuv420p
Quality:   CRF 18
MLT:       real_time = -1
```

The next export work is to make output type a user choice: movie presets,
image sequence, still frame and audio-only.

---

## QuickTime 7 Pro feature map

### Playback and transport

| QuickTime 7 Pro | MLT / application mechanism | Status |
| --- | --- | --- |
| Play, pause, scrub | producer speed + seek | Done |
| Full screen / Present Movie | GTK host channel | Done |
| Loop | boundary restart | Done |
| Play selection only | frame selection + bounded transport | Done |
| Play All Frames | consumer `real_time = -1` | Done |
| Frame forward / frame back | frame-derived seek | Done |
| Variable speed / shuttle | `mlt_producer_set_speed` | Done |
| Reverse playback | negative producer speed | Done |
| Source timecode | avformat metadata through MLT | Done |
| Half / actual / double size | Flutter layout | Mapped |
| Pitch-corrected speed | `timewarp` producer | Mapped |
| Audio balance / bass / treble | `panner`, `volume`, filters | Mapped |
| Video image controls | MLT image filters | Mapped |

### Inspection

| QuickTime 7 Pro | MLT / application mechanism | Status |
| --- | --- | --- |
| Movie Inspector | producer `meta.media.*` | Done |
| Frame rate / duration / frame count | producer properties | Done |
| Display aspect / anamorphic flag | profile + media metadata | Done |
| Data size | filesystem size | Done |
| Average data rate | file bits / duration | Done |
| Codec per stream | `meta.media.N.codec.*` | Done |
| Source timecode | stream/container metadata | Done |
| Full stream list | `meta.media.N.*` | Done |
| Pixel format | `.codec.pix_fmt` | Done |
| Colorspace | `.codec.colorspace` | Done |
| Transfer characteristic | `.codec.color_trc` | Done |
| Color range | `meta.media.color_range` | Done |

Color primaries are intentionally not presented yet because the current MLT
7.22 metadata path used by the Inspector does not expose an independent,
reliable source-primaries value through this implementation.

### Selection and editing

| QuickTime 7 Pro | Mechanism | Status |
| --- | --- | --- |
| In / Out points | frame-based application selection | Done |
| Play selection | bounded transport | Done |
| Trim to selection | active non-destructive clip bounds | Done |
| Undo / Redo | application edit-state history | Done |
| Cut / copy / delete | MLT playlist operations | Mapped |
| Paste at playhead | `mlt_playlist_insert_at` | Mapped |
| Add to end | playlist append | Mapped |

### Tracks and layers

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| Add to Movie | tractor + multitrack | Planned |
| Enable / disable track | track `hide` | Mapped |
| Layer ordering | track order | Mapped |
| Track offset | leading playlist blank | Mapped |
| Position / scale / rotate / flip | affine / blend transition | Mapped |
| Graphics modes / blending | composite / qtblend / luma / matte / mix | Mapped |
| Track mask | mask filters | Mapped |
| Straight / premultiplied alpha interpretation | bridge / compositing work required | Open |
| Extract tracks | new tractor from selected tracks | Mapped |
| Per-track volume / balance | `volume` / `panner` | Mapped |

### Export

| QuickTime 7 Pro | Mechanism | Status |
| --- | --- | --- |
| Export movie | separate `avformat` consumer | Done |
| H.264 / AAC MP4 | `libx264` + AAC | Done |
| Export selection | independent export producer bounded to selection | Done |
| Export trimmed clip | active clip bounds | Done |
| Progress | native export position polling | Done |
| Cancel | native worker cancellation | Done |
| Export current frame | single-frame consumer | Next |
| Image sequence | `avformat` filename sequence | Next |
| Audio only | video-disabled consumer | Next |
| ProRes / DNxHR / other codecs | local FFmpeg capability | Planned |
| Frame-rate conform | independent export profile | Mapped |

### Interchange

| QuickTime 7 Pro | Mechanism | Status |
| --- | --- | --- |
| Reference movie | MLT XML | Planned |
| Save self-contained | export consumer | In progress |
| Open image sequence at chosen FPS | image-sequence producer + chosen profile | Planned |
| Hold each image for N frames | producer `ttl` | Mapped |
| Open URL | `avformat` producer | Mapped |
| Chapter / text tracks | Not investigated | Open |

---

## Roadmap by proofs

Development is organized as narrow proofs. A capability is not marked done
until it has actually been run.

### POC 0–5: Playback foundation — complete

The application shell, MLT lifecycle, media open, audio, external texture,
threading model, viewport, seek, fullscreen, drag/drop and core playback path.

### POC 6: Precise transport — complete

*Can the player behave like an inspection instrument rather than a generic
media player?*

Proven:

- exact frame stepping
- live frame readout
- J/K/L shuttle
- reverse
- Loop
- Play All Frames
- source timecode
- generated clip-relative timecode

Whole-file ping-pong was tested and deliberately removed. It was not useful
enough to justify the long-GOP reverse behavior it exposed.

### POC 7: Inspection parity — complete

*Can it tell you what the old Movie Inspector told you?*

Proven:

- codec metadata
- selected stream indices
- full stream list
- data size
- average data rate
- pixel format
- colorspace
- transfer characteristic
- color range
- source timecode

### POC 8: Selection and trim — complete

*Can it hold and edit a selection without touching the source file?*

Proven:

- In / Out points
- visual selection range
- duration / frame-count readout
- Play Selection
- Loop Selection
- Undo / Redo
- non-destructive Trim Selection
- nested trims
- clip-relative transport after trim
- source timecode preserved across trim

### POC 9: Export — in progress

*Can it write the current clip back out without blocking or stealing the
viewer?*

Proven first slice:

- independent export producer/profile/consumer
- native background render thread
- H.264/AAC MP4
- export selection
- export active trimmed clip
- progress
- cancel
- partial-output cleanup
- playback remains independent

Next:

- export presets / codec selection
- image sequences
- current-frame stills
- audio-only export
- explicit output frame-rate control

### POC 10: Tracks

*Can two pieces of media exist in parallel and be positioned against each
other?*

Planned:

- opaque-handle bridge refactor first
- tractor / multitrack
- second track
- time offset
- layer order
- blend mode
- opacity
- alpha interpretation

The opaque-handle bridge is a precondition. The current bridge intentionally
keeps one playback engine in process-global state.

### POC 11: Interchange

*Can a session leave and come back?*

Planned:

- save MLT XML
- open MLT XML
- image sequences at a chosen frame rate

---

## Known technical questions

**Alpha is straight, Flutter wants premultiplied.**

MLT's `mlt_image_rgba` carries straight, non-premultiplied alpha. Flutter's
external-texture path expects premultiplied compositing. Opaque media hides
the difference, so it must be solved before track compositing becomes a real
feature.

QuickTime 7 Pro exposed alpha interpretation explicitly. MLT Player should do
the same rather than silently guessing.

**Reverse playback depends on codec structure.**

MLT accepts negative producer speed, but reverse decoding through avformat is
bounded by keyframe spacing. Long-GOP H.264/H.265 can be slow. Intra-frame
media behaves much better.

**Export codec availability belongs to the local FFmpeg build.**

The first export preset is proven, but future ProRes, DNxHR and other choices
must be discovered from what the installed FFmpeg/MLT stack actually supports
rather than presented as a fixed fantasy list.

**One playback engine per process.**

The bridge still owns playback state at file scope. That is simple and correct
for the current single-player application. It is not sufficient for POC 10,
where multiple producers/tracks need independent ownership. The bridge must
move to opaque handles before tracks.

---

## Non-goals

The value of this project depends as much on what it refuses as on what it
adds.

- **Not a non-linear editor.** No bins, no primary editing timeline, no
  project-conform workflow.
- **Not a batch transcoder.** Export is for the file in front of you.
- **Not a grading application.** Inspection and simple viewing controls are
  not color management.
- **No plugin API.**
- **No new session format.** MLT XML will be the interchange/session format.
- **No feature merely because MLT exposes it.** The UI stays small.

---

## Architecture

### Playback path

```text
Flutter UI
    │
    ├── PlayerEngine
    │      ├── transport / selection / trim / history
    │      └── export state
    │
    ├── Dart FFI ───────────────► libmlt_bridge.so
    │                                  │
    └── MethodChannel ─► GTK runner    │
                         │              ▼
                         │             MLT
                         │              │
                         │              ├── playback producer
                         │              │
                         │              ├── render threads
                         │              │      └── scaled/deinterlaced RGBA
                         │              │
                         │              └── sdl2_audio consumer
                         │                     │
                         │                     ├── audio ─► speakers
                         │                     │
                         │                     └── consumer-frame-show
                         │                              │
                         │                              ▼
                         │                        cached RGBA
                         │                              │
                         │                        triple buffer
                         │                              │
                         └── texture registration ◄────┘
                                        │
                                        ▼
                                  OpenGL texture
                                        │
                                        ▼
                               Flutter Texture widget
```

The frame callback is intentionally cheap. Rendering, scaling, deinterlacing
and RGBA conversion happen ahead on MLT's render threads. The callback mostly
claims the already-rendered frame, copies it into the bridge-owned buffer
rotation, and notifies Flutter that a texture frame is available.

The MLT callback never takes the main engine mutex. Transport calls and engine
mutation are serialized separately, preventing the callback/transport lock
inversion that would otherwise make deadlocks easy.

Video uses three rotating buffers so MLT's copy and Flutter's OpenGL upload do
not have to block one another.

### Export path

```text
Current source path
       │
       ▼
background export worker
       │
       ├── independent MLT profile
       ├── independent producer
       └── independent avformat consumer
                 │
                 ├── H.264 / AAC encode
                 ├── progress
                 └── cancel / cleanup
```

Export does not reuse the live playback producer or audio consumer. Playback
can remain active while the export graph renders.

---

## Project structure

```text
mlt_player/
├── lib/
│   ├── main.dart
│   ├── models/
│   │   └── media_info.dart
│   ├── services/
│   │   ├── host_channel.dart
│   │   ├── mlt_bridge.dart
│   │   └── player_engine.dart
│   └── ui/
│       └── widgets/
│           └── media_inspector.dart
│
├── native/
│   ├── mlt_bridge.c
│   ├── mlt_bridge.h
│   └── mlt_smoke.c
│
├── linux/
│   ├── CMakeLists.txt
│   └── runner/
│       └── my_application.cc
│
├── tools/
│   └── smoke.sh
│
├── .github/workflows/ci.yml
├── pubspec.yaml
├── analysis_options.yaml
├── CHANGES.md
├── LICENSE
└── README.md
```

`DynamicLibrary.process()` in `mlt_bridge.dart` is intentional. The GTK runner
already links the native bridge, and Dart must resolve that same loaded image
so both sides share one process-global engine state. Opening another copy by
path risks producing two independent bridge states.

---

## Requirements

Linux with Flutter desktop support enabled.

```bash
sudo apt install \
  melt \
  libmlt-dev \
  libmlt-data \
  libmlt++-dev \
  libepoxy-dev \
  libgtk-3-dev \
  pkg-config \
  build-essential
```

`libmlt-data` is required. MLT's loader producer reads its service dictionary
from the data directory.

Check MLT:

```bash
pkg-config --modversion mlt-framework-7
```

Check Flutter:

```bash
flutter doctor
```

---

## Building

```bash
git clone https://github.com/nathanfx330/MLT-Player.git
cd MLT-Player
flutter pub get
flutter run -d linux
```

Changes to C, CMake or the Linux runner may require a clean rebuild:

```bash
flutter clean
flutter pub get
flutter run -d linux
```

Dart-only changes normally do not.

---

## Headless smoke test

`native/mlt_smoke.c` drives the bridge without Flutter and without a window.
It exists to separate MLT/bridge failures from Flutter integration failures.

```bash
tools/smoke.sh
tools/smoke.sh /path/to/clip.mp4
```

---

## Player controls

| Key | Action |
| --- | --- |
| Space | Play / pause |
| K | Pause |
| Left / Right | Previous / next frame |
| J | Reverse shuttle: -1× → -2× → -4× → -8× |
| L | Forward shuttle: 1× → 2× → 4× → 8× |
| Up / Down | Volume |
| Home / End | Start / end of active clip |
| M | Mute |
| F / double click | Fullscreen |
| Escape | Leave fullscreen |
| I | Set In |
| O | Set Out |
| Shift+Space | Play Selection |
| Ctrl+T | Trim Selection |
| Ctrl+Z | Undo |
| Ctrl+Shift+Z | Redo |
| Ctrl+I | Inspector |
| Ctrl+O | Open media |
| Ctrl+E | Export / cancel active export |

Loop and Play All Frames are also available directly in the transport UI.

Controls float over the video and hide during uninterrupted viewing. They stay
visible when hiding would be wrong: paused, no media, pointer over controls,
scrubbing, Inspector open, or an error state.

---

## License

MIT. See [LICENSE](LICENSE).

This repository's source is MIT. The libraries it builds against retain their
own licenses. MLT's framework is LGPL-2.1, and individual MLT modules can have
different licensing requirements. Anyone distributing a binary should inspect
the modules actually linked or loaded.

---

## Development philosophy

Each capability answers one narrow technical question before anything larger
is built on top of it.

A feature is not marked done because an API appears to support it. It is marked
done when the implementation has been built and run.

That rule has shaped the project so far:

- transport was proven before selection
- selection was proven before trim
- Undo/Redo existed before trim depended on it
- export began with one fixed, working preset before adding a preset system
- multi-track work waits until the bridge ownership model can support it

The goal is not to turn MLT into a giant Flutter surface.

The goal is to rebuild the small, fast, precise tool that used to live beside
the editor.