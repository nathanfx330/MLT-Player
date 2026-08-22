<!-- docs/embedding-mlt-in-a-flutter-linux-app.md -->

# Embedding MLT in a Flutter/Linux Desktop Player

## Field notes from building MLT Player

This document records how I embedded **MLT (Media Lovin' Toolkit)** inside a
Flutter Linux desktop application and turned it into a responsive media
inspection tool.

It is not an attempt to replace the MLT API reference. It is the document I
wanted while building the application: which objects I created, which
properties mattered, when those properties had to be set, what lived on which
thread, what broke, and what finally worked.

The implementation described here was developed and tested against
**MLT 7.22.0** on Linux.

The application is
[MLT Player](https://github.com/nathanfx330/MLT-Player).

The high-level design is:

```text
Flutter owns the application.
MLT owns the media.
A small C bridge owns the boundary between them.
```

The useful lesson is that MLT is not difficult because it lacks capability.
It is difficult because much of its behavior is expressed through properties,
service metadata and lifecycle timing rather than through obviously named API
calls.

If you are embedding MLT rather than driving it through `melt`, reading the
headers is not enough. You will also end up reading service YAML and selected
framework/module source.

---

# 1. The mental model that made MLT understandable

MLT is easiest to reason about as a **pull-based frame graph**.

At the simplest level:

```text
Producer  ─────────►  Consumer
```

A producer produces MLT `Frame` objects. A consumer requests those frames.

Filters and other services can sit between them:

```text
Producer  ─►  Filter  ─►  Filter  ─►  Consumer
```

MLT uses lazy evaluation. A frame can exist before its image or audio has
actually been decoded. The expensive work happens when something downstream
asks the frame for its image or audio.

This matters enormously when embedding MLT.

If you call `mlt_frame_get_image()` in the wrong place, you can accidentally
move decoding, scaling and colorspace conversion onto the thread that is also
trying to maintain playback timing.

My successful architecture was based on this rule:

> Configure the consumer so the frame is already rendered in the form the UI
> needs before the frame-show callback runs.

That one decision fixed most of the early playback behavior.

MLT's own framework documentation describes the same producer/consumer pull
model and lazy image/audio evaluation:

- https://www.mltframework.org/docs/framework/

---

# 2. The application architecture I used

The final preview path looks like this:

```text
Flutter UI
    │
    │ Dart FFI
    ▼
libmlt_bridge.so
    │
    ▼
MLT
    │
    ├── avformat producer
    │      └── demux/decode source media
    │
    ├── MLT render threads
    │      └── scale + deinterlace + convert to RGBA
    │
    └── sdl2_audio consumer
            │
            ├── audio ─────────────► speakers
            │
            └── consumer-frame-show
                       │
                       ▼
                 bridge RGBA cache
                       │
                 triple-buffer slots
                       │
                       ▼
                  OpenGL texture
                       │
                       ▼
                Flutter Texture
```

The application does **not** ask MLT to create a video window.

MLT decodes and renders the frames. I take the rendered RGBA frame and upload
it into a Flutter external OpenGL texture.

Audio stays with MLT's `sdl2_audio` consumer.

This split worked extremely well:

- MLT owns decode timing.
- MLT owns audio.
- Flutter owns layout and controls.
- GTK owns the native Flutter texture registration.
- The bridge only moves image bytes and transport commands.

---

# 3. Build and linking

On Linux I link the native bridge against:

```text
mlt-framework-7
gtk+-3.0
epoxy
Flutter Linux
```

The relevant CMake shape is approximately:

```cmake
pkg_check_modules(
  MLT
  REQUIRED
  IMPORTED_TARGET
  mlt-framework-7
)

pkg_check_modules(
  GTK
  REQUIRED
  IMPORTED_TARGET
  gtk+-3.0
)

pkg_check_modules(
  EPOXY
  REQUIRED
  IMPORTED_TARGET
  epoxy
)

add_library(
  mlt_bridge
  SHARED
  "../native/mlt_bridge.c"
)

target_link_libraries(
  mlt_bridge
  PRIVATE
  PkgConfig::MLT
  PkgConfig::GTK
  PkgConfig::EPOXY
  flutter
)
```

I compile the bridge with strict warnings:

```text
-Wall
-Wextra
-Wshadow
-Werror
```

That caught real bugs. One example was a local `stream_count` variable
shadowing the global stream-inspection state.

## Important package gotcha: `libmlt-data`

Installing the development headers alone is not enough.

MLT service discovery depends on its data/service files. A machine can compile
perfectly and then have `mlt_factory_producer()` fail to create useful
services because the service dictionaries are not installed.

On Ubuntu/Debian my dependency set includes:

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

If every producer or consumer mysteriously fails to instantiate, verify the
MLT data package before debugging your code.

---

# 4. Initialize MLT once

My bridge owns one repository and one playback profile:

```c
static mlt_repository repository = NULL;
static mlt_profile profile = NULL;
```

Initialization is fundamentally:

```c
repository = mlt_factory_init(NULL);
profile = mlt_profile_init(NULL);
```

I expose this to Dart as a small lifecycle API:

```c
int mlt_bridge_init(void);
void mlt_bridge_shutdown(void);
```

The current application keeps one playback engine per process.

That is a deliberate limitation, not an MLT limitation. Before adding
multi-track editing I plan to replace file-scope playback state with opaque
bridge handles.

## Shutdown ordering matters

Do not destroy MLT while another thread is still using it.

My shutdown path first cancels and joins any export thread, then stops and
closes playback objects, then closes the profile/repository.

Likewise, the Flutter external texture is unregistered before bridge shutdown
so nothing can attempt to mark a destroyed texture as having a new frame.

---

# 5. Opening media: probe, derive the profile, reopen

One of the most useful patterns I adopted was a two-stage open.

The basic idea:

```text
1. Create a temporary producer.
2. Probe it.
3. Derive an MLT profile from that producer.
4. Close the temporary producer.
5. Reopen the source against the derived profile.
```

Conceptually:

```c
mlt_profile profile = mlt_profile_init(NULL);

mlt_producer probe =
    mlt_factory_producer(
        profile,
        NULL,
        path
    );

mlt_producer_probe(probe);
mlt_profile_from_producer(profile, probe);

mlt_producer_close(probe);

mlt_producer producer =
    mlt_factory_producer(
        profile,
        NULL,
        path
    );

mlt_producer_probe(producer);
```

This gave the playback graph the source's natural dimensions, frame rate and
display aspect instead of forcing every source through an arbitrary default
profile.

I use the same pattern in the export worker.

---

# 6. Do not assume every producer is timed video

MLT can successfully open things that are not useful timed media.

My bridge classifies the producer before exposing it to the player.

I explicitly distinguish:

```text
timed media
still image
unsupported/non-media
```

Still images deserve special treatment because MLT may assign an arbitrary
default producer length to a still. In my environment this can be thousands
of frames, but that does not mean the image actually has a timeline.

The application therefore has an explicit `is_still` flag and suppresses timed
transport behavior for stills.

I also inspect `video_index` and `audio_index` to determine whether the
selected producer has usable video and audio streams.

---

# 7. Why I used `sdl2_audio` as the playback consumer

I wanted MLT to own audio timing, but I did not want MLT to own the video
window.

The consumer that worked for that arrangement was:

```c
consumer =
    mlt_factory_consumer(
        profile,
        "sdl2_audio",
        NULL
    );
```

I then deliberately leave video processing enabled on that consumer:

```c
mlt_properties_set_int(
    properties,
    "video_off",
    0
);
```

and listen for rendered frames:

```c
mlt_events_listen(
    properties,
    NULL,
    "consumer-frame-show",
    (mlt_listener)on_consumer_frame_show
);
```

This gives me MLT-paced audio plus access to the video frames without opening
an SDL video surface.

---

# 8. Render the format you actually want

The preview target is a Flutter OpenGL texture.

That means the bridge ultimately wants RGBA.

The important consumer property is:

```c
mlt_properties_set(
    properties,
    "mlt_image_format",
    "rgba"
);
```

I also configure scaling and deinterlacing on the consumer:

```c
mlt_properties_set(
    properties,
    "rescale",
    "bilinear"
);

mlt_properties_set(
    properties,
    "deinterlacer",
    "onefield"
);

mlt_properties_set_int(
    properties,
    "top_field_first",
    -1
);

mlt_properties_set_int(
    properties,
    "progressive",
    1
);
```

The important lesson is **where** these properties are set.

I set them before starting the consumer.

MLT copies consumer requirements onto frames before the render workers process
them. By the time `consumer-frame-show` fires, a matching
`mlt_frame_get_image()` is normally retrieving the rendered image rather than
starting the entire decode/scale/deinterlace chain on the timing callback.

My callback begins with:

```c
mlt_image_format format = mlt_image_rgba;
uint8_t *image = NULL;

int width = target_width;
int height = target_height;

int error =
    mlt_frame_get_image(
        frame,
        &image,
        &format,
        &width,
        &height,
        0
    );
```

The callback then copies the bytes and returns.

That was the difference between a smooth player and an architecture where
video processing fought the audio clock.

---

# 9. Do not assume `width * height * 4`

Even with RGBA, I do not hard-code the byte count.

I ask MLT:

```c
const int size =
    mlt_image_format_size(
        format,
        width,
        height,
        NULL
    );
```

Then copy exactly that amount.

This is a small defensive decision that prevents a future alignment/format
change from turning into a silent over-read.

---

# 10. The frame callback should be boring

My `consumer-frame-show` callback intentionally does very little:

```text
1. Get frame position.
2. Ignore duplicate position.
3. Get already-rendered RGBA.
4. Copy it into a bridge-owned buffer.
5. Publish the ready slot.
6. Notify Flutter.
7. Return.
```

It does **not**:

```text
decode
seek
change transport
create consumers
take the playback engine mutex
perform UI work
upload OpenGL directly
```

That last group is where integration bugs become deadlocks and playback
stutters.

---

# 11. Lock design: the MLT callback never takes the engine mutex

I have one main mutex protecting playback/MLT mutation:

```c
static GMutex engine_mutex;
```

Transport operations such as open, close, seek, speed changes and consumer
creation use it.

The frame callback does not.

Instead, the callback has its own tiny frame-state mutex:

```c
static GMutex frame_mutex;
```

and only uses it to exchange slot indices.

This is a crucial rule:

> Do not let the MLT callback acquire a lock that a Dart/GUI transport call can
> hold while calling back into MLT.

Otherwise it is easy to create the classic inversion:

```text
UI thread:
engine lock → calls MLT → waits for consumer thread

MLT thread:
frame callback → waits for engine lock
```

Deadlock.

Keep the render handoff independent of transport mutation.

---

# 12. Triple buffering the RGBA frames

I use three bridge-owned image slots:

```text
write
ready
display
```

Each slot is owned by one party at a time.

The MLT callback writes into `write`.

When the copy is complete, a short lock swaps:

```text
write → ready
old ready → write
```

The Flutter raster/OpenGL side similarly claims `ready` as `display`.

The expensive operations happen with no frame lock held:

```text
MLT memcpy               no lock
OpenGL texture upload    no lock
```

Only the integer slot swap is locked.

For this integration, three buffers were enough to keep the producer side and
texture upload side from waiting on each other.

---

# 13. Flutter external texture registration

The Flutter Linux runner owns the `FlTextureRegistrar`.

The bridge exposes functions like:

```c
int64_t mlt_bridge_register_flutter_texture(
    FlTextureRegistrar *registrar
);

void mlt_bridge_unregister_flutter_texture(void);
```

The texture itself subclasses `FlTextureGL`.

During `populate`, I bind/create a GL texture and upload the most recent
display slot.

The GTK runner registers that native texture and sends the resulting texture
ID to Dart over a host `MethodChannel`.

Dart renders it using Flutter's normal:

```dart
Texture(textureId: id)
```

## Startup race I hit

Texture registration was too early during runner construction on some starts.

The stable approach was:

```text
start Flutter
render the first Flutter frame
register the external texture
push texture ID to Dart
also let Dart query/retry the ID
```

I use both a push and a short retry because either side can win the startup
race.

This is not an MLT problem. It is a Flutter Linux texture-registration timing
issue that happened to look like an MLT video failure.

Symptom:

```text
audio plays
UI says waiting for texture
video never appears
```

If audio is playing, investigate texture registration before rewriting the
decoder.

---

# 14. Notify Flutter on the correct thread

The MLT consumer callback does not run on Flutter's platform thread.

I therefore do not call Flutter texture-registrar functions directly from
the MLT callback.

Instead I coalesce notifications and marshal them through GLib's main
context:

```c
g_main_context_invoke(
    NULL,
    mark_flutter_texture_frame,
    NULL
);
```

Then the platform-thread callback calls:

```c
fl_texture_registrar_mark_texture_frame_available(
    registrar,
    FL_TEXTURE(texture)
);
```

Coalescing matters because a new video frame can arrive before the previous
main-loop notification has run. There is no value in filling the GTK main
queue with redundant notifications when the texture always presents the
newest completed slot.

---

# 15. Why Dart uses `DynamicLibrary.process()`

This was one of my most important FFI integration decisions.

The GTK runner links `libmlt_bridge.so`.

The Dart side must talk to **that same loaded bridge instance**, because the
bridge currently owns process-global state:

```text
repository
profile
producer
consumer
texture
frame slots
```

Therefore Dart resolves symbols with:

```dart
final library = DynamicLibrary.process();
```

not:

```dart
DynamicLibrary.open("/some/path/libmlt_bridge.so");
```

Opening the `.so` by path can appear to work while creating a second loaded
instance under some deployment/path conditions.

The nightmare failure mode is:

```text
GTK runner owns bridge instance A
    └── texture registered there

Dart owns bridge instance B
    └── producer opened there
```

Everything individually looks valid, but the video never reaches the texture.

If your native host executable already links the bridge, resolving it from the
current process is the safer model for shared global state.

---

# 16. Opening media without freezing Flutter

MLT open/probe is synchronous.

It can be slow enough that doing it directly on Flutter's main Dart isolate
makes the spinner freeze.

I moved native open to a Dart helper isolate.

However, my native bridge has one engine mutex, and `open()` holds it while
probing/rebuilding the playback graph.

That created another rule:

> Do not poll bridge getters while an open is in progress.

Every getter also needs the engine mutex. Polling from the main isolate during
open would simply block the UI waiting for the helper isolate and defeat the
whole point.

My `PlayerEngine` therefore suspends its normal 100 ms native poll while the
open flag is set.

---

# 17. Transport: producer position and visible position are not always the same

During active playback the producer can be ahead of the frame the consumer has
actually shown.

This becomes obvious when implementing shuttle controls.

If the user is playing forward at `4×` and taps `J`, changing the producer
speed in place can make the visible image jump because the producer has already
advanced beyond the displayed frame.

My speed-change path first anchors to the consumer-visible position:

```c
position =
    mlt_consumer_position(consumer);

if (current_speed > 0.0) {
    position += 1;
} else {
    position -= 1;
}

mlt_consumer_purge(consumer);
mlt_producer_seek(producer, position);
mlt_producer_set_speed(producer, new_speed);
```

The exact `+1`/`-1` compensation was empirical for my consumer/position
semantics, but the larger lesson is general:

> When changing trick-play direction or magnitude, decide whether you mean
> producer position or displayed position.

They are not automatically identical.

---

# 18. J / K / L shuttle

MLT accepts arbitrary producer speed:

```c
mlt_producer_set_speed(
    producer,
    speed
);
```

I built the familiar shuttle behavior at the application layer:

```text
K = pause

L:
+1×
+2×
+4×
+8×

J:
-1×
-2×
-4×
-8×
```

Changing direction starts at `1×` in the new direction.

Negative speed works, but reverse performance depends strongly on the media.

Intra-frame formats are friendly.

Long-GOP H.264/H.265 can be expensive because reverse access repeatedly seeks
to earlier keyframes and decodes forward.

That is a codec/container cost, not evidence that negative MLT speed is
broken.

---

# 19. Frame stepping: beware millisecond round-trips

My bridge originally exposed seek in milliseconds:

```c
mlt_bridge_seek_ms(...)
```

but the UI needed exact ±1 frame stepping.

Until I add a native frame-seek function, I work around floating-point /
fractional-rate boundaries by aiming at the **middle of the target frame's
time interval**:

```dart
final targetMs =
    (((targetFrame + 0.5) * 1000.0) / fps).floor();
```

This avoids seeking to an exact nominal boundary that can truncate back onto
the preceding frame at rates such as:

```text
23.976
29.97
59.94
```

It is a good workaround, but a true frame-addressed bridge API would be
cleaner.

---

# 20. Pause should park the visible frame

For speed zero I do not treat pause as merely:

```c
mlt_producer_set_speed(producer, 0);
```

My pause path takes care to anchor the producer to the visible consumer
position, purge stale consumer frames and invalidate the bridge's duplicate
frame cache.

The desired user-visible behavior is:

```text
press K
the image that was visible remains the parked frame
left/right moves exactly one frame from there
```

This sounds trivial until producer read-ahead is involved.

---

# 21. Loop belongs above raw MLT transport

I implemented Loop in my application/bridge behavior rather than trying to
make every producer permanently loop.

At a boundary:

```text
forward speed + EOF
    → restart at frame 0 with same positive speed

negative speed + frame 0
    → restart at final frame with same negative speed
```

The magnitude is preserved:

```text
+4× loops as +4×
-2× loops as -2×
```

When the application has an active trimmed clip or Play Selection range, the
application applies the same idea to those logical bounds.

That separation turned out to be useful:

```text
MLT source remains the source
application decides what "the current clip" means
```

---

# 22. `real_time`: the property that gave me Play All Frames

This property is unusually important.

MLT's consumer implementation has a `real_time` setting.

The avformat consumer metadata describes positive values as enabling frame
dropping and negative values as disabling frame dropping.

For preview I use:

```text
real_time = 1
```

for normal real-time playback.

For QuickTime-style **Play All Frames** I use:

```text
real_time = -1
```

That means MLT does not discard video frames merely to preserve wall-clock
playback speed. If the machine cannot render quickly enough, playback slows
instead.

Upstream references:

- https://github.com/mltframework/mlt/blob/master/src/framework/mlt_consumer.c
- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/consumer_avformat.yml

## The gotcha: changing the property while running was not enough

This was one of the least obvious behaviors I encountered.

MLT copies `real_time` into consumer-private state when the consumer starts.

So this:

```c
mlt_properties_set_int(
    MLT_CONSUMER_PROPERTIES(consumer),
    "real_time",
    -1
);
```

does not necessarily reconfigure the already-running scheduling behavior.

My solution is:

```text
remember visible position
remember producer speed
stop/close only the consumer
recreate consumer with new real_time
seek producer back to visible position
restore speed
start consumer
```

I do **not** reopen the source.

If a consumer property appears to have no effect at runtime, inspect the
consumer's start path before assuming the property is wrong.

---

# 23. Other playback consumer properties I relied on

My preview consumer currently uses these important properties:

| Property | Value | Why |
| --- | --- | --- |
| `real_time` | `1` or `-1` | normal playback vs Play All Frames |
| `terminate_on_pause` | `0` | keep consumer alive at speed zero |
| `scrub_audio` | `0` | do not produce scrub audio |
| `volume` | `0.0..1.0` | playback volume |
| `rescale` | `bilinear` | preview scaling |
| `deinterlacer` | `onefield` | deinterlace method used in this build |
| `top_field_first` | `-1` | allow field-order handling |
| `progressive` | `1` | texture output is progressive |
| `video_off` | `0` | render video even though using `sdl2_audio` |
| `mlt_image_format` | `rgba` | match the Flutter texture upload |

These are not random FFmpeg options. They influence MLT's consumer/render
pipeline.

---

# 24. Metadata: MLT's avformat producer is a gold mine

The Inspector was where I most strongly felt the lack of centralized
documentation.

The data was present, but the most reliable documentation was the avformat
producer source itself.

Useful properties include:

```text
meta.media.nb_streams
meta.media.N.stream.type

meta.media.N.codec.name
meta.media.N.codec.long_name
meta.media.N.codec.bit_rate

meta.media.N.codec.width
meta.media.N.codec.height
meta.media.N.codec.pix_fmt
meta.media.N.codec.colorspace
meta.media.N.codec.color_trc

meta.media.N.codec.sample_fmt
meta.media.N.codec.sample_rate
meta.media.N.codec.channels

meta.attr.N.stream.<metadata-key>.markup
meta.attr.<container-key>.markup
```

The selected absolute stream indices are available through:

```text
video_index
audio_index
```

Upstream avformat producer source:

- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/producer_avformat.c

The source currently shows MLT populating `meta.media.nb_streams`, per-stream
type/codec information and stream metadata from FFmpeg dictionaries.

## Snapshot metadata once

I do not ask the producer for all this information on every Flutter rebuild.

After opening the producer I copy the inspection data into bridge-owned
storage:

```text
stream count
selected video/audio indices
codec labels
per-stream fields
pixel format
colorspace
transfer
color range
source timecode
```

Dart then constructs an immutable `MediaInfo` object.

That keeps UI inspection read-only and removes producer-property traffic from
the playback loop.

---

# 25. Stream types are not equally reliable across versions/services

In my MLT 7.22 work, video and audio were the important guaranteed cases.

I chose not to invent labels for stream types the producer did not explicitly
identify.

If a stream remained enumerable but had no useful type, my UI called it:

```text
Other
```

The general lesson is:

> Treat MLT metadata as observed data, not a schema you are entitled to
> assume is fully populated.

Check for property existence before converting values.

---

# 26. Source timecode

FFmpeg metadata is passed through by MLT as `meta.attr.*.markup`.

I search for source timecode in this order:

```text
1. selected video stream
2. container metadata
3. any other stream
```

For a selected video stream `N`:

```text
meta.attr.N.stream.timecode.markup
```

Container fallback:

```text
meta.attr.timecode.markup
```

Then I scan other stream-level timecode keys.

If no timecode exists, the application displays no source timecode.

I do not manufacture one and call it source metadata.

Separately, the UI can generate a clip-relative transport timecode from frame
number and FPS. Those two concepts should not be conflated:

```text
source timecode
    comes from the media

clip timecode
    comes from the current application timeline
```

---

# 27. Color metadata: report only what you really have

For the selected video stream I read:

```text
meta.media.N.codec.pix_fmt
meta.media.N.codec.colorspace
meta.media.N.codec.color_trc
meta.media.color_range
```

I deliberately did **not** show color primaries in the MLT 7.22 version of
the Inspector because my metadata path did not give me an independent value
I trusted enough to label as source primaries.

This is a good documentation rule in general:

> Missing metadata is better than plausible-looking invented metadata.

Newer MLT versions have expanded color metadata APIs, so applications should
re-evaluate this against the exact MLT version they ship.

---

# 28. File size and average data rate did not need MLT

Not every Inspector field should be forced through the media framework.

I get file size from the filesystem.

Average data rate is simply:

```text
file_size_bytes × 8 / duration_seconds
```

That intentionally represents the whole file:

```text
video
audio
container overhead
other streams
```

rather than claiming to be the selected video stream's encoder bitrate.

---

# 29. Selection and trim: I kept the source producer intact

My first In/Out and trim model is application-owned.

The user can define:

```text
In frame
Out frame
active clip In
active clip Out
```

Trim changes the **logical active clip bounds** in `PlayerEngine`; it does not
rewrite the source and does not need to rebuild the MLT producer.

That gives me:

```text
non-destructive trim
nested trims
Undo
Redo
clip-relative frame numbering
clip-relative generated timecode
source timecode preserved
```

The live source remains unchanged underneath.

This was simpler and safer than mutating the playback producer while the
selection/edit model was still evolving.

---

# 30. Undo/Redo belongs to the application, not MLT

MLT provides media objects and editing primitives.

It does not provide the application command history I wanted.

My edit history stores small snapshots:

```text
active clip In
active clip Out
selection In
selection Out
```

An edit is:

```text
before state
after state
```

Undo restores the previous snapshot.

Redo restores the next one.

This worked for selection/trim and gives me a foundation for later playlist
operations.

The useful separation is:

```text
MLT = media graph
application = editing intent/history
```

---

# 31. Export: do not steal the playback graph

The first export implementation is deliberately independent of preview.

I do **not** take the currently playing producer and attach an encoder to it.

Instead a background worker creates:

```text
new profile
new producer
new avformat consumer
```

for the export job.

Architecture:

```text
live playback graph
    ├── playback producer
    └── sdl2_audio preview consumer

background export graph
    ├── export producer
    └── avformat file consumer
```

They share MLT's initialized factory, but they are separate graphs.

That means the user can continue viewing while the export runs.

---

# 32. Export also uses probe → profile → reopen

The background worker repeats the source-profile derivation:

```c
export_profile = mlt_profile_init(NULL);

probe_producer =
    mlt_factory_producer(
        export_profile,
        NULL,
        source_path
    );

mlt_producer_probe(probe_producer);
mlt_profile_from_producer(
    export_profile,
    probe_producer
);

mlt_producer_close(probe_producer);

export_producer =
    mlt_factory_producer(
        export_profile,
        NULL,
        source_path
    );
```

That keeps the encoder graph aligned to the source instead of inheriting the
preview application's UI assumptions.

---

# 33. Exporting an inclusive In/Out range

My UI selection is frame-inclusive.

If the user marks:

```text
In  = frame 10
Out = frame 19
```

the selection is ten frames.

The export worker passes those absolute source-frame bounds to:

```c
mlt_producer_set_in_and_out(
    export_producer,
    in_frame,
    out_frame
);
```

After setting the producer In/Out, I seek the export producer to position
zero:

```c
mlt_producer_seek(
    export_producer,
    0
);

mlt_producer_set_speed(
    export_producer,
    1.0
);
```

In my export graph, position zero is then the first frame of the requested
cut.

This was cleaner than trying to export the entire producer and throw frames
away at the consumer.

---

# 34. The first proven avformat export preset

I intentionally started with one fixed preset rather than building a codec
chooser before proving the render path.

The first successful configuration is:

```c
mlt_properties_set(properties, "f", "mp4");
mlt_properties_set(properties, "vcodec", "libx264");
mlt_properties_set(properties, "acodec", "aac");
mlt_properties_set(properties, "pix_fmt", "yuv420p");
mlt_properties_set(properties, "preset", "medium");
mlt_properties_set_int(properties, "crf", 18);
mlt_properties_set(properties, "movflags", "+faststart");

mlt_properties_set_int(properties, "real_time", -1);
mlt_properties_set_int(properties, "terminate_on_pause", 1);
```

The important architectural choice is not H.264.

It is:

```text
prove one complete output path first
then expose codecs/presets
```

MLT's avformat consumer passes many matching properties through to FFmpeg
options. The upstream implementation and service metadata are the best
references:

- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/consumer_avformat.c
- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/consumer_avformat.yml

---

# 35. Export progress

For the first implementation I poll the export producer's current position
from the worker:

```c
const int64_t position =
    mlt_producer_position(
        export_producer
    );

const double progress =
    (double)(position + 1) /
    (double)total_frames;
```

The worker publishes that percentage into a small mutex-protected export-state
block.

Dart polls the bridge and updates the UI.

This avoids sending callbacks from the encoder thread directly into Dart.

---

# 36. Export cancellation

Cancellation is cooperative.

The UI sets a bridge cancel flag.

The export worker checks it while the consumer is running:

```c
if (export_cancel_was_requested()) {
    mlt_consumer_stop(export_consumer);
    break;
}
```

Then cleanup closes:

```text
consumer
producer
profile
```

If the export did not succeed, I remove the partial destination file.

This gives cancellation a simple promise:

```text
success → finished file remains
failure/cancel → partial file is removed
```

---

# 37. Stop the consumer even when it stopped itself

At export EOF, the consumer may already report itself as stopped.

I still call:

```c
mlt_consumer_stop(export_consumer);
```

before closing it.

In my use, this is important because stop/join gives the encoder a clean
chance to finish worker threads and flush its output trailer before the object
is destroyed.

This is one of those lifecycle details that matters more than the number of
lines of code suggests.

---

# 38. Consumer properties are often lifecycle properties

A recurring pattern throughout the project:

```text
property exists
property value is correct
application still does not change
```

The reason is often not the property name.

The reason is **when the service reads it**.

Examples include scheduling/threading configuration that is copied into
consumer-private state during start.

When debugging MLT properties, ask these questions in order:

```text
1. Does this service define/read the property?
2. Does it read it continuously or only at initialization/start?
3. Does changing it require restart/recreation?
4. Is a framework-level property copied onto frames before my callback?
5. Is a module translating the property into another library's option?
```

That mindset saved far more time than trying random property names.

---

# 39. Invalidate cached frames after discontinuities

My bridge suppresses duplicate frame positions to avoid redundant texture
uploads.

That means any operation that intentionally causes a discontinuity must
invalidate that cache:

```text
seek
pause/re-anchor
open a new file
consumer rebuild
certain speed-direction changes
```

Otherwise the new frame can legitimately have a position equal to the last
cached one and be incorrectly ignored.

If your transport command succeeded but the texture appears frozen, inspect
your own frame cache before blaming MLT.

---

# 40. A headless bridge test is worth the effort

I built a small native smoke test that drives the bridge without Flutter.

It exercises things such as:

```text
initialize
open
play
seek
pause
volume
play to end
replay
reopen
still-image classification
invalid-media rejection
shutdown
```

Run with a dummy SDL audio device when necessary.

This lets me answer:

```text
Is MLT/bridge broken?
or
Is Flutter integration broken?
```

That distinction is incredibly valuable when the visible symptom is simply
"no video."

---

# 41. Things that looked like MLT bugs but were not

## Audio plays, no video

Cause in my case:

```text
Flutter external texture was not registered yet
```

Not a decode problem.

## UI freezes during open

Cause:

```text
synchronous producer probe/open on the main Dart isolate
```

Move open to a helper isolate and stop polling locked getters during open.

## New consumer property does nothing

Cause:

```text
property copied into private state at consumer start
```

Restart/recreate the consumer.

## Shuttle changes jump several frames

Cause:

```text
producer position was ahead of visible consumer position
```

Anchor to visible position before speed changes.

## First frame after seek/open does not refresh

Cause:

```text
my duplicate-frame cache still considered the position already displayed
```

Invalidate the cache.

## Inspector metadata appears incomplete

Cause may simply be:

```text
that MLT version/service did not expose the field
```

Do not fill missing values with guesses.

## Reverse is very slow on H.264

Cause:

```text
long-GOP decode structure
```

Test with intra-frame media before redesigning reverse transport.

---

# 42. Things I intentionally did not make MLT responsible for

It was tempting to put every application feature into the media graph.

I did not.

These stay in Flutter/Dart application state:

```text
overlay visibility
keyboard mapping
clip-relative timecode
In/Out selection UI
active trimmed bounds
Undo/Redo history
selection looping policy
file-size calculation
average whole-file data rate
```

MLT remains responsible for:

```text
opening media
probing
decode
audio
frame production
scaling/deinterlacing
transport position/speed
stream metadata
encoding/export
```

This boundary kept the bridge manageable.

---

# 43. What I would change if starting again

A few improvements are obvious now.

## Add a native frame seek immediately

Do not make exact frame stepping round-trip through milliseconds if your
application cares about frame precision.

Expose:

```text
seek_frame(frame)
position_frame()
```

alongside millisecond convenience methods.

## Use opaque playback handles earlier if multiple graphs are on the roadmap

Process-global state is excellent for proving one player.

It becomes technical debt the moment you need:

```text
multiple players
tracks
parallel preview graphs
comparison viewers
```

## Keep an MLT property notebook from day one

For each property, record:

```text
service
property name
value type
tested MLT version
when it is read
whether restart is required
source file where behavior was verified
```

MLT is property-driven enough that this becomes part of your effective API
documentation.

---

# 44. Quick property/reference sheet from my implementation

## Preview consumer

```text
service                sdl2_audio
real_time               1 normal / -1 Play All Frames
terminate_on_pause       0
scrub_audio              0
volume                   0.0 .. 1.0
rescale                  bilinear
deinterlacer             onefield
top_field_first          -1
progressive              1
video_off                0
mlt_image_format         rgba
event                    consumer-frame-show
```

## Producer inspection

```text
video_index
audio_index

meta.media.nb_streams

meta.media.N.stream.type

meta.media.N.codec.name
meta.media.N.codec.long_name
meta.media.N.codec.bit_rate
meta.media.N.codec.width
meta.media.N.codec.height
meta.media.N.codec.pix_fmt
meta.media.N.codec.colorspace
meta.media.N.codec.color_trc
meta.media.N.codec.sample_fmt
meta.media.N.codec.sample_rate
meta.media.N.codec.channels

meta.attr.N.stream.<key>.markup
meta.attr.<key>.markup
```

## Export consumer

```text
service                  avformat
f                        mp4
vcodec                   libx264
acodec                   aac
pix_fmt                  yuv420p
preset                   medium
crf                      18
movflags                 +faststart
real_time                -1
terminate_on_pause       1
```

---

# 45. Source files I found most useful

When the high-level docs did not answer a question, these were the upstream
files that most often did.

## Framework model

MLT framework documentation:

- https://www.mltframework.org/docs/framework/

## Consumer scheduling and `real_time`

- https://github.com/mltframework/mlt/blob/master/src/framework/mlt_consumer.c

This is where you can see default consumer behavior and how `real_time` is
copied into consumer-private state during start.

## avformat producer metadata

- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/producer_avformat.c

This is the most useful source for discovering which `meta.media.*` and
`meta.attr.*` keys are actually populated.

## avformat consumer options

- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/consumer_avformat.yml
- https://github.com/mltframework/mlt/blob/master/src/modules/avformat/consumer_avformat.c

The YAML is useful for service properties; the C source shows how properties
are applied to FFmpeg.

## Release notes

- https://github.com/mltframework/mlt/blob/master/NEWS
- https://github.com/mltframework/mlt/releases/tag/v7.22.0

When behavior differs from examples you find online, check the version first.

---

# 46. Version warning

The source links above point to current upstream files because they are easy to
browse and search.

This document describes behavior I **tested on MLT 7.22.0**.

MLT continues to evolve. For production work, always compare the relevant
source against the tag/version actually installed on the target machine.

Useful first command:

```bash
pkg-config --modversion mlt-framework-7
```

Then read the matching MLT release/tag when a property or metadata field is
important to correctness.

---

# 47. Final lessons

After embedding MLT in a real desktop application, these are the lessons I
would give another developer first:

1. **Think in producers, frames and consumers, not files and players.**

2. **Expect lazy evaluation.**
   Where you ask for the image determines where expensive work happens.

3. **Configure render requirements before the consumer starts.**

4. **Keep the frame-show callback tiny.**

5. **Do not take your main engine lock from the MLT frame callback.**

6. **Use separate ownership for frame transfer and transport state.**

7. **Treat consumer properties as lifecycle-sensitive until proven otherwise.**

8. **Read `producer_avformat.c` when you need metadata.**

9. **Do not invent metadata that MLT did not actually expose.**

10. **Producer position can be ahead of the visible consumer frame.**

11. **Long-GOP reverse is expensive by nature.**

12. **Keep export on a separate MLT graph from preview.**

13. **Join encoder threads before shutting down MLT.**

14. **Use a native smoke test to separate MLT problems from UI integration
    problems.**

15. **Document every property you prove.**
    In an MLT integration, those properties are a large part of your real API.

MLT gave me nearly every capability I needed for a QuickTime-style inspection
tool. The difficult part was not implementing decoding, audio, transport or
encoding.

The difficult part was discovering the exact contract between those pieces.

Hopefully this document removes some of that discovery cost for the next
person.
