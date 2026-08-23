# MLT Player

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A desktop media player built with **Flutter** and **MLT (Media Lovin' Toolkit)**.

Flutter owns the application. MLT owns the media. The two meet through a small
C bridge, and video reaches Flutter as an OpenGL texture rather than in a
second native playback window.

The target is deliberately narrow: **recover the practical role of QuickTime
7 Pro**.

Not an NLE. Not a batch transcoder. Open a file, inspect it closely, make one
surgical change, save or export it, and close it.

---

## Current status

Built against **MLT 7.22.0** on Linux.

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
| In / Out selection | Done |
| Play Selection / Loop Selection | Done |
| Undo / Redo | Done |
| Non-destructive Trim Selection | Done |
| Background MP4 export | Done |
| Current-frame PNG export | Done |
| PNG image-sequence export | Done |
| WAV audio-only export | Done |
| Grouped Export control | Done |
| Export preset / codec selection | Next |
| Explicit output frame-rate control | Next |
| Multi-track / Add to Movie | Planned |
| MLT XML interchange | Planned |

The POC 9 export family is now proven end-to-end. The current hardening pass
standardizes output policy, strengthens sequence cleanup/validation, and adds
deterministic test media before more export options are introduced.

---

## What MLT Player is for

QuickTime 7 Pro was useful because it was not trying to be an editor.

It could open quickly, show the file, let you set In and Out, trim, step a
frame at a time, inspect streams, export a still or image sequence, extract
or export audio, and write a new movie without requiring a project workflow.

MLT Player follows that shape:

**open → inspect → do one precise operation → export/save → close**

Deliberate non-goals:

- no bins
- no giant project workflow
- no primary editing timeline
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

## Export

Export runs on a **separate MLT producer/profile/consumer graph** in a native
background thread. It does not take over the live playback producer,
`sdl2_audio` consumer, or Flutter texture.

All range exports follow the same rule:

1. marked In/Out selection, if present
2. otherwise the current trimmed clip
3. otherwise the whole active clip

The grouped Export control keeps range-export types together:

```text
Export
 ├── Export Video
 ├── Export Image Sequence
 └── Export Audio (WAV)
```

Current-frame PNG remains a separate snapshot operation.

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
Audio:       AAC when source audio exists
Pixel fmt:   yuv420p
Quality:     CRF 18
Preset:      medium
Fast start:  yes
Frames:      progressive output
MLT:         real_time = -1
```

Interlaced sources are rendered through the same deinterlacing policy used by
the viewer and PNG exports. Video-only sources do not receive a manufactured
silent AAC stream.

### Current-frame PNG

Current-frame capture snapshots the visible source frame before pausing, then
parks transport on that exact frame before opening the save dialog.

PNG exports are generated from the source graph rather than copied from the
Flutter texture.

For anamorphic sources, PNG output is written at **display dimensions with
square pixels**. For example, a 1440×1080 source with 16:9 display aspect is
written as approximately 1920×1080 rather than as a squeezed 1440×1080 PNG.

Offline PNG scaling uses Lanczos interpolation.

RGBA is currently preserved for PNG output so real source alpha is not lost.
Alpha interpretation will be handled explicitly as part of the track/
compositing work rather than guessed from codec-name strings.

### PNG image sequence

Image-sequence export writes to a fresh dedicated directory:

```text
movie_frames/
  frame_000001.png
  frame_000002.png
  frame_000003.png
  ...
```

The native bridge refuses to start a sequence export unless the supplied
destination directory exists and is empty. That makes cancellation cleanup a
native invariant rather than a Dart-only convention.

Completion validation checks the final producer position and scans the output
directory to verify:

- the expected number of owned PNG files exists
- numbering begins at 1
- numbering ends at the expected final frame
- every owned PNG is non-empty

Because directory entries are unique, matching count + minimum + maximum
proves there is no gap in the sequence.

Cancelled or failed sequence exports remove only filenames owned by the
export and remove the directory only if it becomes empty.

### WAV audio export

The fixed audio-only interchange preset is:

```text
Container:  WAV
Codec:      PCM signed 24-bit little-endian
Video:      disabled
Rate:       preserve selected source rate when available
Channels:   preserve selected source channel count when available
```

MLT renders audio as signed 32-bit integer internally for this path and FFmpeg
writes the final `pcm_s24le` samples. MLT does not have a 24-bit internal
render-buffer format.

---

## Deterministic export fixtures

`tools/generate_export_fixtures.sh` creates a small local regression set using
FFmpeg:

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

or choose a destination directory:

```bash
bash tools/generate_export_fixtures.sh /tmp/mlt-player-fixtures
```

The script prints an `ffprobe` summary after generation.

Useful POC 9 hardening checks:

```bash
# Video-only MP4 export should contain no audio stream.
ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name \
  -of default=noprint_wrappers=1 exported_video_only.mp4

# Interlaced input should produce progressive MP4 output.
ffprobe -v error -select_streams v:0 \
  -show_entries stream=field_order \
  -of default=noprint_wrappers=1 exported_interlaced.mp4

# Anamorphic current-frame PNG should be display-sized (expected 1920x1080
# for the included 1440x1080 / SAR 4:3 fixture).
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height \
  -of default=noprint_wrappers=1 exported_frame.png

# WAV export should be 24-bit PCM.
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_fmt,bits_per_raw_sample,sample_rate,channels \
  -of default=noprint_wrappers=1 exported_audio.wav
```

Also verify manually that `Ctrl+Alt+E` performs a sequence export without
changing the selected mode shown on the grouped Export control.

---

## Architecture

```text
Flutter UI
    │
    ├── PlayerEngine
    │      ├── transport
    │      ├── selection / trim / history
    │      └── export state
    │
    ├── Dart FFI ───────────────► process-linked libmlt_bridge.so
    │                                  │
    └── MethodChannel ─► GTK runner    │
                                       ▼
                                      MLT
                                       │
                ┌──────────────────────┴──────────────────────┐
                │                                             │
          playback graph                                export graph
                │                                             │
       render threads + RGBA                    independent producer/profile
                │                                + avformat consumer
       triple frame buffer                              │
                │                                       ├── MP4
       OpenGL external texture                          ├── PNG
                │                                       └── WAV
              Flutter
```

Important current architecture rules:

- Dart resolves the bridge with `DynamicLibrary.process()`.
- The GTK runner links the same bridge into the application process.
- Playback bridge state is currently process-global.
- One playback engine per process is intentional through POC 9.
- Export owns an entirely separate MLT graph.
- The MLT frame callback never takes the main engine mutex.
- Video frame transfer uses three buffers so producer and Flutter raster
  threads can own buffers independently.
- Scaling, deinterlacing, and image conversion happen on MLT render threads.

---

## Roadmap

### POC 0–5 — playback foundation — complete

- Flutter Linux shell
- MLT lifecycle
- media open/reopen
- external OpenGL texture
- audio
- seek/scrub
- fullscreen
- drag/drop
- still images
- audio-only playback
- anamorphic display handling
- smoke testing

### POC 6 — precise transport — complete

- exact frame stepping
- J/K/L shuttle
- reverse playback
- Loop
- Play All Frames
- generated timecode
- embedded source timecode

### POC 7 — inspection — complete

- codecs and streams
- frame geometry
- rate / duration / frame count
- data size / average data rate
- pixel format
- colorspace
- transfer characteristic
- color range
- source timecode

### POC 8 — selection and trim — complete

- In / Out
- Play Selection
- Loop Selection
- Undo / Redo
- non-destructive trim
- nested trims
- trim-aware transport

### POC 9 — export — feature set complete, hardening in progress

Proven:

- independent background export graph
- MP4 export
- current-frame PNG
- PNG image sequence
- WAV audio-only export
- range export from selection / trim / whole clip
- progress
- cancel
- partial-output cleanup
- grouped Export UI

Hardening now covers:

- progressive/deinterlaced MP4 policy
- no manufactured audio track for video-only MP4
- Lanczos PNG resampling
- 24-bit PCM WAV output
- one-shot image-sequence shortcut semantics
- native empty-directory sequence ownership
- complete sequence validation
- deterministic fixture generation

Next export slices:

- output preset / codec selection
- explicit output frame-rate control

### Pre-POC 10 bridge hardening

Before track work:

- replace borrowed returned strings with safe ownership/copy-out APIs
- add native frame seek / frame position API
- handle GL texture destruction only when it can be done with the correct GL
  context

### POC 10 — tracks

Planned:

- opaque engine handles
- tractor / multitrack
- second track
- time offsets
- layer order
- blend mode
- opacity
- Add to Movie
- explicit alpha interpretation

MLT RGBA is straight alpha while Flutter expects premultiplied compositing.
That needs to be solved deliberately before track compositing is considered
complete.

### POC 11 — interchange

Planned:

- save MLT XML
- open MLT XML
- open image sequences at a chosen frame rate

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

## Known technical questions

### Borrowed C string lifetimes

Several current bridge getters return pointers into shared bridge-owned storage
after releasing their mutex. Dart consumes them immediately, but the API
contract should be made explicit and safe before opaque handles and multiple
engine instances are introduced.

### OpenGL texture destruction

The external GL texture currently lives for essentially the process lifetime.
Cleanup should eventually call `glDeleteTextures`, but only from a path where
the correct GL context is known to be current.

### Alpha

PNG exports currently preserve RGBA to avoid destroying real alpha. Reliable
source-alpha detection and straight/premultiplied interpretation are deferred
to the track/compositing milestone, where the distinction becomes part of the
actual editing model.

---

## License

MIT. See [LICENSE](LICENSE).
