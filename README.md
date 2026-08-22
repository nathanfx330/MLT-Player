# MLT Player

[![CI](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml/badge.svg)](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A desktop media player built with **Flutter** and **MLT (Media Lovin' Toolkit)**.

Flutter owns the application. MLT owns the media. The two meet at a single C
bridge of about twenty functions, and video arrives in the interface as an
OpenGL texture rather than in a window of its own.

The player works. The target now is a specific one: **the capabilities of
QuickTime 7 Pro**.

---

## Why QuickTime 7 Pro

QuickTime 7 Pro was not an editor. That is the whole point of it.

It opened in under a second, showed you the file, and let you do one surgical
thing to it: set an in and an out, trim, paste a clip in parallel as a second
track, offset that track in time, check how the alpha was being interpreted,
step a frame at a time to find the exact cut, export a PNG sequence, save a
reference movie that pointed at the media instead of copying it. Then it
closed. No project file, no import, no conform, no render queue.

For anyone working in post between roughly 2005 and 2015, that was the tool
open all day next to the real application.

It is gone. Apple ended QuickTime for Windows support in 2016, and macOS
Catalina's removal of 32-bit application support in 2019 finished the job on
the Mac. Nothing has replaced the shape of it. VLC plays and will not edit.
FFmpeg transforms and will not show you what you are doing. Shotcut, Kdenlive
and Resolve are project-based editors, which is a different tool for a
different day. The gap is the one QuickTime 7 Pro filled: **open, look
closely, do one thing, save, close.**

MLT is the right engine for it. It is the same engine underneath Shotcut and
Kdenlive, it is LGPL, it is packaged everywhere, and its object model
(producers, playlists, tractors, filters, transitions, consumers) already
contains every operation QuickTime 7 Pro exposed. Most of the work below is
not implementing capability. It is choosing which small part of MLT's surface
to expose, and refusing the rest.

---

## Status

Playback is done and dependable.

| Area | State |
| --- | --- |
| Flutter Linux app, native C bridge, Dart FFI | Done |
| Embedded video via native OpenGL texture | Done |
| Play, pause, seek, position, duration, frame rate | Done |
| Audio via the `sdl2_audio` consumer | Done |
| Volume, mute, end of file, replay | Done |
| Auto-hiding overlay, rolling info panel, keyboard control | Done |
| Fullscreen, drag and drop, open during playback | Done |
| Anamorphic display aspect | Done |
| Stills, audio-only files, refusal of non-media | Done |
| Thread-safe engine, headless smoke test | Done |

Built against **MLT 7.22.0**.

---

## The target

What follows is QuickTime 7 Pro's feature set, item by item, with the MLT
mechanism that reaches it and where this project stands. Everything named in
the middle column exists in MLT 7.22.0 and was checked against the installed
headers and service metadata rather than recalled.

Status words: **Done**, shipping. **Next**, the current milestone. **Mapped**,
the mechanism is identified and the remaining work is interface. **Open**,
there is a real technical question still to answer.

Every function named below was confirmed present in `libmlt-7.so.7`, and every
property name was read back off a probed producer rather than recalled.

### Playback and transport

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| Play, pause, scrub | `mlt_producer_set_speed`, `mlt_producer_seek` | Done |
| Half, actual, double size | Flutter layout | Mapped |
| Full screen, Present Movie | GTK window state over the host channel | Done |
| Loop | Seek to zero at end of file | Mapped |
| Loop back and forth | Flip the speed sign at each boundary | Mapped |
| Play selection only | Producer in and out points | Next |
| **Play All Frames** | Consumer `real_time`: `1` drops frames, `-1` does not, `0` is fully synchronous | Next |
| Frame forward, frame back | Seek by one frame with speed at zero | Next |
| Variable speed, jog shuttle | `mlt_producer_set_speed` takes any double, including negative | Next |
| Speed with pitch-corrected audio | `timewarp` producer, which wraps another producer | Mapped |
| Audio balance, bass, treble | `panner` and `volume` filters | Mapped |
| Video brightness, contrast, colour, tint | `brightness`, `gamma`, `lift_gamma_gain`, `rgblut` filters | Mapped |

`real_time` is worth naming, because it is the exact QuickTime checkbox.
MLT's own header documents it as: `1` for asynchronous with frame dropping,
`-1` for asynchronous without, `0` to disable asynchrony entirely. Playing
all frames is a property change, not a feature.

### Inspection

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| Movie Inspector: source, format, size | `meta.media.*` on the producer | Done |
| Frame rate, duration, frame count | Producer properties | Done |
| Current size against normal size | Profile versus `meta.media.width` | Done |
| Display aspect, anamorphic flag | `mlt_profile` display aspect | Done |
| Data size and data rate | `meta.media.N.codec.bit_rate` plus the file size | Next |
| Codec name per stream | `meta.media.N.codec.name` | Next |
| Timecode | `avformat` exposes the source timecode | Next |
| Full stream list | `meta.media.N.stream.type` | Next |
| Colour space and pixel format | `meta.media.N.codec.colorspace`, `.pix_fmt` | Next |

### Selection and editing

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| In and out points on the scrubber | `mlt_producer_set_in_and_out` | Next |
| Trim to selection | Producer in and out, non-destructive | Next |
| Cut, copy, delete a selection | `mlt_playlist_split_at`, `mlt_playlist_remove` | Mapped |
| Paste at the playhead | `mlt_playlist_insert_at` | Mapped |
| Add to end | `mlt_playlist_append_io` | Mapped |
| Undo | An operation stack over the playlist | Open |

MLT's playlist API is the QuickTime edit model almost exactly: `append`,
`insert`, `remove`, `move`, `split`, `split_at`, `join`, `remove_region`,
`blank`, `repeat_clip`. Nothing here needs inventing.

### Tracks and layers

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| **Add to Movie** (paste in parallel, not in sequence) | `mlt_tractor` plus `mlt_multitrack` | Mapped |
| Enable and disable a track | The `hide` property on a track | Mapped |
| Layer ordering | Track order in the tractor | Mapped |
| Track offset in time | A blank at the head of the track's playlist | Mapped |
| Track size, position, rotate, flip | `affine` or `qtblend` transition | Mapped |
| Graphics modes and blending | `composite`, `qtblend`, `luma`, `matte`, `mix` | Mapped |
| Track mask from an image | `mask_start` and `mask_apply` filters | Mapped |
| **Transparency: straight or premultiplied** | See the known questions below | Open |
| Extract tracks into a new movie | Build a tractor from the chosen tracks | Mapped |
| Per-track audio volume and balance | `volume` and `panner` on the track | Mapped |
| Audio track selection | `audio_index` on the `avformat` producer | Next |

### Export

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| Export a movie with codec settings | `avformat` consumer, `vcodec` and `acodec` | Mapped |
| ProRes, Animation, PNG, H.264 | Whatever the local FFmpeg build carries | Mapped |
| Export the current frame as a still | Single-frame `avformat` or `qimage` consumer | Next |
| **Export an image sequence** | `avformat` consumer writing `frame-%05d.png` | Mapped |
| Export audio only | `avformat` consumer with video disabled | Mapped |
| Export the selection only | Producer in and out feed the consumer | Mapped |
| Conform the frame rate on export | The consumer profile is independent of the source | Mapped |
| Progress and cancel | `consumer-frame-show` already reports position | Mapped |

### Interchange

| QuickTime 7 Pro | Mechanism in MLT | Status |
| --- | --- | --- |
| **Save as a reference movie** | MLT XML, which is exactly a reference movie | Mapped |
| Save self-contained | `avformat` consumer | Mapped |
| **Open an image sequence at a chosen frame rate** | `pixbuf` producer (LGPL) or `qimage` (GPL): `shot-%04d.png?begin=1001`, or the `/.all.png` form | Next |
| Hold each frame for N frames | `ttl` on the image sequence producer | Mapped |
| Open a URL | The `avformat` producer takes one | Mapped |
| Chapter and text tracks | Not investigated | Open |

Two of these carry more weight than the rest, because they are why people
kept QuickTime 7 Pro installed years after it stopped being supported.

**Image sequences.** The `pixbuf` producer opens `shot-%04d.png` directly,
takes a `begin` for sequences that do not start at frame one, computes its
own length, and honours the profile's frame rate. Opening a render as a movie
at 23.976 without transcoding it first is a first-class operation here, not a
workaround.

**Reference movies.** MLT XML is a better version of what QuickTime called a
reference movie: a small text file naming the sources, the in and out points,
the track structure and the filters, with no media copied. It is also
readable by Shotcut, Kdenlive and `melt`, which a QuickTime reference movie
never was.

---

## Roadmap by proofs

The project is built in narrow proofs, each answering one technical question
before anything is built on top of it. Zero through five are complete.
Everything below is scoped the same way.

### POC 6: Precise transport

*Can the player land on an exact frame and hold it?*

Frame stepping, source timecode, variable and reverse speed, loop, loop back
and forth, and `real_time` control so that playing all frames means what it
says. This is the milestone that turns a player into an instrument for
looking at a shot.

### POC 7: Inspection parity

*Can it tell you everything the Movie Inspector told you?*

Per-stream codecs, data rate, colour metadata, the full stream list. Read
only, with no editing anywhere near it.

### POC 8: Selection

*Can it hold a selection without touching the file?*

In and out points on the scrubber, play selection only, trim to selection,
export selection only. Non-destructive throughout: nothing is written to disk
unless an export is asked for.

### POC 9: Export

*Can it write the file back out correctly, without blocking the interface?*

The `avformat` consumer, image sequences, stills, audio, progress and cancel.
Export runs on its own consumer against its own profile, so the playback
consumer is untouched.

### POC 10: Tracks

*Can two pieces of media exist in parallel and be positioned against each
other?*

A tractor, a second track, offset in time, layer order, blend mode, opacity.
This is QuickTime's Add to Movie, and it is where the alpha question below
has to be answered properly.

### POC 11: Interchange

*Can a session leave and come back?*

Save and open MLT XML. Open image sequences at a chosen frame rate.

---

## Known technical questions

An honest list, kept here rather than discovered later.

**Alpha is straight, Flutter wants premultiplied.** MLT's `mlt_image_rgba`
carries straight, non-premultiplied alpha. Flutter composites external
textures as premultiplied. For opaque video the two are identical and nothing
is wrong today, which is exactly why it needs writing down before the first
file with a real alpha channel arrives. The fix is a premultiply step between
the MLT image and the texture upload, or a shader on the Flutter side.
QuickTime 7 Pro exposed this as a per-track choice between straight alpha,
premultiplied white and premultiplied black, so parity means offering the
interpretation rather than silently picking one.

**Reverse playback is only as good as the container.**
`mlt_producer_set_speed` accepts negative values, but reverse through
`avformat` is bounded by keyframe spacing. Long-GOP H.264 will not behave like
ProRes. This may end up meaning honesty about which files scrub backwards
rather than pretending all of them do.

**Undo has no natural home yet.** MLT provides an object model, not a command
history. An operation stack over the playlist is the obvious approach, but
what belongs on it, edits only or transport too, is a design question rather
than an implementation one.

**Export codec availability is not ours to decide.** ProRes, DNxHD and the
rest depend on how the local FFmpeg was built. The player should report what
is actually present rather than offering a fixed list and failing at write
time.

**One player per process.** The bridge is still file-scope state. That is
fine for a player and wrong for tracks. Converting to an opaque handle is a
precondition for POC 10, not an optional cleanup.

---

## Non-goals

Stated plainly, because the value of QuickTime 7 Pro was as much in what it
refused as in what it did.

- **Not a non-linear editor.** No timeline as the primary interface, no bins,
  no project files, no conform. Shotcut and Kdenlive exist, run on the same
  engine, and are better at that than this will ever be.
- **Not a transcoder.** Export exists to get one file back out, not to run
  batches. That is what FFmpeg is for.
- **Not a colour tool.** The image adjustments are QuickTime's A/V Controls:
  a look at a shot, not a grade. No claim of colour management.
- **No plugin API.** The dependency surface is MLT, GTK and Flutter, and it
  stays that way.
- **No new file format.** MLT XML is the session format. There will not be a
  second one.

---

## Architecture

```text
Flutter UI
    │
    │ Dart FFI                        Method channel
    ▼                                       │
libmlt_bridge.so ◄──────── GTK runner ◄─────┘
    │                          │
    ▼                          └── texture registration, window, drag and drop
MLT
    │
    ├── Producer
    │     └── media decoding
    │
    ├── Render threads
    │     └── RGBA image, scaled and deinterlaced, rendered ahead
    │
    └── sdl2_audio consumer
          │
          ├── audio ───────────────► speakers
          │
          └── consumer-frame-show
                    │
                    ▼
              cached RGBA image
                    │
              triple-buffered slot
                    │
                    ▼
              OpenGL texture
                    │
                    ▼
          Flutter Texture widget
```

The image is rendered ahead of the timing thread rather than on it. The
consumer carries `mlt_image_format=rgba` and `video_off=0`, so MLT's render
threads produce the image in the exact format the texture upload wants, and
the frame-show callback does a cache lookup and a copy rather than a decode
and a convert. Scaling, deinterlacing and field order are set on the consumer
for the same reason: the framework copies them onto each frame as `consumer.*`
properties before handing it to a render thread, which happens long before the
frame is shown.

All engine state is guarded by a single mutex, and the MLT frame callback
deliberately never takes it: the callback runs on MLT's own thread while
transport calls arrive from Dart, and locking in both directions is a deadlock
waiting to happen. Video frames move through three buffer slots so that the
copy out of MLT and the upload into OpenGL never block each other.

---

## Project structure

```text
mlt_player/
├── lib/
│   └── main.dart                  Flutter UI and FFI bindings
│
├── native/
│   ├── mlt_bridge.c               the media engine bridge
│   ├── mlt_bridge.h               its public interface
│   └── mlt_smoke.c                headless test, no Flutter involved
│
├── linux/
│   ├── CMakeLists.txt             Flutter, MLT, GTK, epoxy, the bridge
│   └── runner/
│       └── my_application.cc      GTK runner, texture, host channel
│
├── tools/
│   └── smoke.sh                   builds and runs the headless test
│
├── .github/workflows/ci.yml       build and smoke test on every push
├── pubspec.yaml
├── analysis_options.yaml
├── CHANGES.md
├── LICENSE
└── README.md
```

---

## Requirements

Linux, with Flutter desktop support enabled.

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

`libmlt-data` is not optional. MLT's loader producer reads its service
dictionary from the data directory, and without it `mlt_factory_producer`
returns NULL for every path with no diagnostic at all. The `melt` package
normally pulls it in, so this only bites on machines where the development
packages were installed on their own.

Check the MLT development install:

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

Changes to C, CMake or the Linux runner need a clean rebuild. Hot reload
covers Dart only.

```bash
flutter clean && flutter pub get && flutter run -d linux
```

---

## Headless smoke test

`native/mlt_smoke.c` drives the bridge with no Flutter and no window, on a
GLib main loop, through the same sequence the interface does: open, play,
seek while playing, pause, seek while paused, volume, play to end, replay,
reopen during playback, reject a non-media file, classify a still image, tear
down.

```bash
tools/smoke.sh                  # generates a test clip with ffmpeg
tools/smoke.sh /path/clip.mp4   # or bring your own
```

It answers one question and only one: is the problem in MLT and the bridge,
or in the Flutter integration. Run it before debugging the interface.

---

## Player controls

| Key | Action |
| --- | --- |
| Space, K | Play / pause |
| Left, Right | Seek 5 seconds (Shift for 10) |
| J, L | Seek 10 seconds |
| Up, Down | Volume |
| Home, End | Start, end |
| M | Mute |
| F, double click | Fullscreen |
| Escape | Leave fullscreen |
| I | File information |
| O | Open |

Controls float over the video behind a gradient scrim and hide themselves
after a few seconds of stillness, taking the mouse cursor with them. They
stay up whenever hiding them would be wrong: paused, no media, pointer over
the controls, mid-scrub, or an error showing. File information rolls up out
of the control bar when asked for and rolls back down when dismissed. It
starts closed and never opens by itself.

---

## License

MIT. See [LICENSE](LICENSE).

This covers the source in this repository. The libraries it builds against
carry their own terms: MLT's framework is LGPL-2.1, and so are the modules the
player currently loads (`avformat`, `sdl2`, `core`). Some other MLT modules are
GPL, notably the Qt module, so anyone distributing a built binary should check
which modules that binary actually pulls in.

---

## Development philosophy

Each capability answers one narrow technical question before anything is built
on top of it. That keeps failures isolated and stops large abstractions
forming around assumptions nobody has tested.

The corollary matters more: a capability is not claimed until it has been run.
Every mechanism named in the target tables was checked against the installed
MLT headers and service metadata rather than recalled, and the things that
remain unproven are listed as unproven.
