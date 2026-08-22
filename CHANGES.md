# Changes

Every item from the review, plus the overlay work. Files touched:
`native/mlt_bridge.c`, `native/mlt_bridge.h`, `native/mlt_smoke.c`,
`lib/main.dart`, `linux/runner/my_application.cc`, `linux/CMakeLists.txt`.

No new Dart dependencies. `flutter/services` is part of Flutter, and
`file_selector` and `ffi` were already there.

Native code changed, so the first build has to be a clean one:

```bash
flutter clean && flutter pub get && flutter run -d linux
```

---

## Native bridge

**One copy of the state, guaranteed.** Dart now resolves the bridge with
`DynamicLibrary.process()` instead of opening
`$executableDir/lib/libmlt_bridge.so` by path. The runner links the library
as a normal dependency, so it is already in the process by the time Dart
runs, and process-scope lookup cannot land on a second copy. Verified: built
the bridge with `-fvisibility=hidden`, linked it as a `DT_NEEDED` dependency
of a test binary, and resolved `mlt_bridge_version` through `RTLD_DEFAULT`.
It came back at the identical address as the direct call, and all 25 exported
symbols survived the hidden default because of the existing
`MLT_BRIDGE_EXPORT` attribute.

**The image is rendered before the timing thread needs it.** The consumer now
carries `mlt_image_format=rgba` and `video_off=0`, so MLT's render threads
produce the RGBA image ahead of time and `mlt_frame_get_image` inside
`consumer-frame-show` is a lookup instead of a decode and convert. This is
also why `rescale`, `deinterlacer`, `top_field_first` and `progressive` moved
from the frame properties to the consumer properties: the framework copies
those onto each frame as `consumer.*` when it hands the frame to a render
thread, which happens well before the show event. Setting them in the
callback was too late to affect anything once prefetch was on.

**`consumer.progressive` is now set.** Naming a deinterlacer without it had no
effect, so interlaced sources were passing through combed. The method itself
is a single `#define` at the top of the file, and now that deinterlacing
happens on the render threads rather than the audio thread, `yadif` or
`bwdif` are affordable if you want them.

**Locking.** One `engine_mutex` guards the producer, the consumer, the
profile, and every transport call. The frame callback deliberately never
takes it: it runs on MLT's thread while transport runs on a Dart thread, and
taking two locks in two directions is how you get a deadlock at 2am. What the
callback needs (the target width and height) is published as an atomic
instead. The texture pointers have their own small lock, and
`mark_texture_frame_available` now takes a reference across the call so the
texture cannot be unregistered out from under it.

**Triple buffered frames.** Three slots, each owned outright by one party:
the MLT callback owns the write slot, the raster thread owns the display
slot, and the third is the handoff. Only the index swap is under a lock, so
the copy out of MLT and the upload into OpenGL no longer serialise against
each other. The remaining per-frame copy could be removed entirely by holding
a reference to the `mlt_frame` and uploading from its image directly, which
is the next thing worth doing if 4K stutters.

**Buffer size comes from MLT.** `mlt_image_format_size()` instead of
`width * height * 4`, and the returned format is checked rather than assumed.

**Media classification.** This one is entirely down to running the code. A
`.txt` file does not fail to open: MLT's loader hands back a **pango**
producer, a text renderer with a default length of 15000 frames. Your player
would have shown a ten minute title card. A `.png` comes back as **pixbuf**,
also 15000 frames, which is where the absurd still-image duration came from.
A nonexistent path is the only case that returns NULL. So the bridge now
classifies by service name into timed media, still, or unsupported, and the
error text names the service it actually got:

```
MLT opened this as a 'pango' resource, which is not playable media.
```

Stills report zero duration and set `mlt_bridge_is_still()`, and the UI drops
the transport for them.

**Seeking no longer restarts the consumer.** Purge plus `refresh` is the
supported path. `mlt_consumer_start` is now called only when the consumer has
genuinely stopped, and it is preceded by a `stop` so the threads get joined.
Without that, every replay after end of file leaked a thread.

**Position reporting.** The consumer position while playing, the producer
position while paused or seeking. The old code keyed off `consumer_started`,
which stays true through a pause, so a seek while paused reported the stale
position until playback resumed.

**New API.** `mlt_bridge_set_volume` / `mlt_bridge_volume` (volume persists
across opens, since the consumer is rebuilt each time), `mlt_bridge_has_audio`,
`mlt_bridge_is_eof`, `mlt_bridge_is_still`, `mlt_bridge_display_aspect`.

**Still a singleton.** Everything is still file-scope state, one player per
process. Converting to an opaque handle is the right move before this grows
into tractors and multitrack, but it changes every signature and the runner
alongside them, so it belongs in its own pass rather than buried in this one.

---

## Runner

A method channel, `mlt_player/host`, replaces the texture id poll:

- `getTextureId` so Dart can ask on startup
- `textureRegistered` pushed from `first-frame` so Dart does not have to guess
- `setFullscreen` which also hides the header bar, since a client-side
  titlebar otherwise stays on screen through the transition
- `openPath` for drag and drop, wired with `gtk_drag_dest_add_uri_targets`
  on the `FlView`, first URI only

Shutdown now unregisters the texture before stopping MLT, so nothing can be
marked available while the engine is being torn down.

---

## Flutter

**Overlay.** The controls float over the video behind a gradient scrim and
auto-hide after 2.6 seconds, taking the mouse cursor with them. They stay up
whenever hiding them would be wrong: paused, no media loaded, pointer over
the controls, mid-scrub, info panel open, or an error showing. Any pointer
movement or keypress brings them back. When faded they stop hit testing, so
an invisible control bar cannot swallow a click meant for the video, and the
control bar absorbs its own taps so clicking the scrim next to a button does
not pause playback.

**Info panel.** Starts closed, always. It is anchored to the bottom of a clip
rect, so opening rolls it up out of the control bar and closing rolls it back
down behind it, 240ms up and 200ms down on an ease-out cubic. Opening a new
file rolls it shut. It never opens on its own, and the auto-hide timer is
suspended while it is open so it cannot vanish mid-read.

**Keyboard.** The whole control bar sits inside `ExcludeFocus`, which is what
makes this work: without it, clicking the seek bar hands it focus and it eats
the arrow keys. The tradeoff is that the controls are mouse-only and are not
reachable by tab, which for a media player is the right side of the trade.

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
| I | Info panel |
| O | Open |

**Aspect ratio.** The viewport uses the display aspect from the profile
rather than `width / height`, so anamorphic sources are no longer squeezed.
The info panel flags anamorphic material explicitly.

**Opening no longer freezes the UI.** The open runs on a helper isolate via
`Isolate.run`, which works because both isolates resolve the same
process-global bridge and the native side serialises the call. The polling
loop suspends for the duration, which matters more than it looks: every
native getter takes the engine lock that `open` holds, so polling through an
open would have blocked the main isolate anyway and undone the whole point.

**Also.** Audio-only files show a placeholder instead of an unpopulated
texture. End of file turns the play button into a replay button. Errors show
inline in the overlay with a dismiss button instead of being wedged into the
layout. Volume and mute with a slider, hidden for files with no audio track.

---

## What was verified, and how

I installed MLT 7.22.0, GTK 3.24, and libepoxy in a sandbox, which matches
your reported version exactly, and built and ran against them.

- **Bridge compiles clean** at `-Wall -Wextra -Wshadow -Werror`, and links
  with `-Wl,--no-undefined` against libmlt, GTK, epoxy and
  `libflutter_linux_gtk.so` from your tree.
- **Runner compiles and links clean** at `-Wall -Werror`, C++14, with a stub
  plugin registrant.
- **`native/mlt_smoke.c` is rewritten as a real test** and passes 30 of 30
  checks against a generated clip: open, metadata, starts paused, play,
  position advances, seek while playing, pause, position stable while paused,
  seek while paused, volume round trip and clamp, play to end, EOF detection,
  replay from EOF, reopen during playback, junk file rejected with a useful
  message, still image classified with no timeline, clean teardown.
- **Concurrency**: six threads issuing random play, pause, seek, volume and
  query calls for 15 seconds while playing, then a clean shutdown. No
  deadlock, no crash.

Not verified, because the sandbox has no Flutter SDK and no display:

- `lib/main.dart` has not been compiled. I have read it back and fixed the
  things that would have stopped it (`MethodCall.method` rather than `.name`,
  a raw string that ended in a backslash, one `FocusNode` shared across
  several widgets, which asserts at runtime). Treat the first
  `flutter analyze` as the real check.
- The GL upload path in `mlt_video_texture_populate` compiles and links but
  has never had a context under it here.
- Drag and drop on an `FlView`. If a future engine version claims the drop
  target itself, that handler is where to look.

## One thing worth knowing about deployment

MLT's loader producer needs its data directory. With `libmlt-dev` alone,
`mlt_factory_producer` returned NULL for every path and the failure was
completely silent. Installing `libmlt-data` fixed it. On a normal desktop the
`melt` package drags it in, which is why your machine works, but it is worth
naming in the requirements before someone installs the dev packages alone and
concludes the bridge is broken.
