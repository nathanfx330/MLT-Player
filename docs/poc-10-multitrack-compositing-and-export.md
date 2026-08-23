<!-- docs/poc-10-multitrack-compositing-and-export.md -->

# POC 10: Multitrack, Compositing, and Tractor-Aware Export

## Field notes from taking MLT Player beyond one source

POC 9 proved that MLT Player could open one source, inspect it, trim it, and
export it on a background MLT graph.

POC 10 changed the problem.

The player stopped being only:

```text
one producer -> one preview consumer
```

and became:

```text
Layer 1 producer -----------\
                            -> MLT tractor -> preview consumer
Layer 2 playlist/producer --/
```

The important milestone was not merely drawing a second picture over the first.
The real milestone was getting the same editable composition to survive all the
way through:

```text
open
add layer
place it in time
change opacity
change audio level
interpret alpha
move / scale / hide / reorder it
preview the result
export the same result
```

This document records the architecture that finally made that work.

The implementation described here was developed and tested against **MLT
7.22.0 on Linux**.

---

# 1. The POC 10 progression

The work landed in small proofs rather than one large rewrite:

```text
POC 10.1  opaque engine handles
POC 10.2  tractor + second track
POC 10.3  add second track at the parked playhead
POC 10.4  live layer opacity
POC 10.5  Tracks inspector + per-track audio levels
POC 10.6  alpha-capable still/video layers
POC 10.7  layer replacement, visibility, and layer-order swap
POC 10.8  layer position, scale, and anchors
POC 10.9  tractor-aware composition export
```

That order mattered. Every step made one new part of the graph observable before
adding the next source of complexity.

---

# 2. Opaque engine handles came before multitrack

The original bridge used one process-global playback engine. That was ideal for
proving playback, but it was the wrong ownership model once multiple graphs were
on the roadmap.

The bridge now exposes an opaque engine object:

```c
MltBridgeEngine *mlt_bridge_engine_create(void);
int mlt_bridge_engine_activate(MltBridgeEngine *engine);
void mlt_bridge_engine_destroy(MltBridgeEngine *engine);
```

Each engine owns its own playback state:

```text
profile
current top-level producer
preview consumer
primary producer
secondary producer
secondary playlist
tractor
video composite transition
audio mix transition
track-local filters
frame buffers
transport state
stream inspection state
```

The MLT repository/factory remains process-wide.

The Flutter texture registrar is also process-wide because the Linux runner owns
one Flutter view, but the bridge records which engine currently feeds that
texture.

One useful implementation trick is thread-local engine activation. The public C
ABI keeps compact function names while the active opaque engine is selected with
a `GPrivate` key. That let the existing bridge code move away from process-global
playback state without rewriting every helper signature at once.

The smoke test explicitly creates a second engine, opens the same media in it,
seeks independently, then reactivates the first engine and verifies that its
playhead did not move.

The lesson:

> If multiple MLT graphs are even moderately likely, separate factory lifetime
> from playback-engine lifetime early.

---

# 3. Source producers and the top-level producer are now different concepts

With one track, the top-level producer is simply the primary source producer.

With two tracks, transport and preview must operate on the tractor producer.

That means the bridge now distinguishes:

```text
primary_producer
secondary_producer
secondary_playlist
tractor
producer              <- what transport/preview sees
```

For a one-layer movie:

```text
producer == primary_producer
```

After Add to Movie:

```text
producer == mlt_tractor_producer(tractor)
```

This distinction is foundational.

If transport keeps seeking the original source producer after the tractor has
become the visible movie, preview and edit state immediately diverge.

---

# 4. Add to Movie rebuilds the preview graph around an MLT tractor

Layer 1 stays the base movie.

Layer 2 is opened as a fresh producer and placed into a playlist. The tractor
then receives:

```text
track 0 = Layer 1 producer
track 1 = Layer 2 playlist producer
```

The tractor field receives the transitions that combine them.

Conceptually:

```text
Layer 1 producer ------------------------------+
                                                |
                                                v
                                         [ composite ] -> tractor producer
                                                ^
                                                |
blank lead-in -> Layer 2 producer -> playlist -+

Layer 1 audio ---------------------------------+
                                                |
                                                v
                                              [ mix ]
                                                ^
                                                |
Layer 2 audio ---------------------------------+
```

The bridge uses MLT's `composite` transition for video and `mix` for audio.

The resulting tractor producer becomes the preview source and is connected to
the same `sdl2_audio` consumer architecture that already powered the one-source
player.

That continuity was useful: the Flutter texture path did not need to know
whether its frames came from one producer or a tractor.

---

# 5. The second layer starts at the parked playhead

Add to Movie is playhead-relative.

Before rebuilding the graph, the bridge captures the viewer-visible position.
If playback is active, it prefers the consumer-visible frame rather than blindly
trusting producer read-ahead.

Layer 2 is then placed into an MLT playlist with a blank lead-in:

```text
frame 0                             insertion frame
|---------------------------------------|
|               blank                   | Layer 2 ...
```

The playlist shape is approximately:

```c
if (secondary_start > 0) {
    mlt_playlist_blank(
        secondary_playlist,
        secondary_start - 1
    );
}

mlt_playlist_append_io(
    secondary_playlist,
    secondary_producer,
    0,
    secondary_out
);
```

This is much cleaner than trying to offset the producer with ad-hoc frame math
on every request.

After the tractor is built, the bridge seeks the new tractor producer back to
the saved playhead and keeps it paused.

The edit therefore changes the movie graph without turning into a transport
command.

---

# 6. Layer 1 defines the movie duration

A multitrack graph introduces an immediate policy question:

> If Layer 2 is longer than Layer 1, how long is the movie?

For this QuickTime-style workflow the answer is deliberately simple:

```text
Layer 1 is authoritative.
```

The bridge sets the tractor producer's In/Out to the primary movie length even
though MLT's multitrack refresh logic may otherwise report the longest connected
track.

Layer 2 is clipped to the remaining available time in the base movie.

A still image is held from its insertion frame through the end of Layer 1.

This gives the composition a stable identity:

```text
Layer 1 = movie
Layer 2 = added layer inside that movie
```

That policy is also reused by export.

---

# 7. Still-image layers needed their own import path

A still image is not just a very short video producer.

For Layer 2 stills the bridge prefers MLT's `pixbuf` producer and falls back to
`avformat` when necessary.

That avoided letting the generic loader select a Qt/QImage path from the helper
isolate and gave the project a dependable RGBA-capable still producer.

The bridge also verifies that the still can produce composite-safe image data
before accepting it into the graph.

For sizing, stills follow a slightly different rule from timed video:

```text
timed video:
    fit to the base canvas, including upscaling if needed

still image:
    keep native display size when it already fits
    scale down only when it exceeds the base canvas
```

That keeps a small logo from being automatically blown up to fill the movie.

---

# 8. Per-track audio is applied before the tractor mix

Each audio-bearing track gets a track-local MLT `volume` filter.

The filter gain is stored independently for Layer 1 and Layer 2:

```text
Layer 1 producer -> volume filter --+
                                    |
                                    +-> mix transition
                                    |
Layer 2 playlist -> volume filter --+
```

The mix transition is configured as an always-active summing mix.

This separation matters because a global consumer volume control and a track
mix level are different user intents.

```text
consumer volume = listening level
track gain       = composition state
```

Composition export snapshots and reapplies the track gains.

---

# 9. Opacity belongs to the composite geometry

The MLT `composite` transition carries position, size, and opacity together in
its geometry rectangle.

The bridge therefore treats them as one state bundle instead of three unrelated
properties.

The current geometry string is written in the form:

```text
x/y:widthxheight:opacity
```

For example, conceptually:

```text
48/24:640x360:0.60
```

A key bug-prevention rule emerged here:

> Changing opacity must rewrite the current geometry, not a default full-frame
> geometry.

Otherwise a user can move/scale a layer, touch opacity, and accidentally snap
it back to its original rectangle.

The bridge now routes opacity updates through the same geometry writer used by
position and scale.

Opacity is clamped to:

```text
0.0 .. 1.0
```

Scale is currently clamped to:

```text
0.10 .. 3.00
```

The smoke test checks both clamps and verifies that opacity changes preserve
position and scale.

---

# 10. Position, scale, and anchors are live tractor edits

POC 10.8 made Layer 2 geometry editable without rebuilding the tractor.

Coordinates are base-frame pixels measured from the top-left corner.

The bridge stores an explicit 100% presentation size for Layer 2, then computes:

```text
visible_width  = base_width  * scale
visible_height = base_height * scale
```

Nine anchors are available through a 3 x 3 grid:

```text
top-left      top-center      top-right
middle-left   center          middle-right
bottom-left   bottom-center   bottom-right
```

The anchor calculation uses the *scaled visible rectangle*, not the source's
unscaled dimensions.

This is another small detail that is easy to get wrong when media geometry and
UI geometry meet.

---

# 11. Visibility is a render switch, not destructive state

Hiding Layer 2 does not destroy its requested opacity.

The Dart engine keeps the user's opacity value and temporarily sends native
opacity zero as the render switch.

When the layer is shown again, its previous opacity is restored.

That gives visibility the expected semantics:

```text
hide != set opacity permanently to zero
```

Because native opacity is what the composition graph actually uses, a hidden
layer also remains hidden when the composition is exported.

---

# 12. Layer-order swap is implemented as a graph rebuild

The current two-layer model has semantic slots:

```text
Layer 1 = timed base
Layer 2 = overlay
```

Swapping order exchanges which media occupies those slots and rebuilds the
pair. It is deliberately not presented as a timeline edit.

A still image is not allowed to become Layer 1 because Layer 1 defines the timed
movie.

The rebuild preserves the important composition controls where they still make
sense, including the Layer 2 insertion time, opacity, visibility, geometry, and
audio levels.

If the swap fails, the application attempts to rebuild the previous composition
rather than leaving a half-mutated graph behind.

That rollback behavior is worth keeping in any graph editor:

> Build the new graph first; only publish it as current state after the whole
> operation succeeds.

---

# 13. Alpha needed an explicit interpretation control

MLT can expose alpha through image formats and frame alpha planes, but the
source's RGB values may still need interpretation.

MLT Player currently exposes three modes for Layer 2:

```text
Auto
Straight
Premultiplied
```

Auto and Straight preserve MLT's native decode path.

Premultiplied enables a small bridge-owned filter that requests RGBA,
unpremultiplies RGB by alpha, then converts back to the image format requested by
the downstream MLT service.

That final conversion is important. The composite transition may request YUV422;
returning RGBA from the filter while claiming the caller's old format would make
the downstream service interpret the wrong byte layout.

The useful lesson is broader than alpha:

> A custom MLT image filter must honor the downstream image-format contract,
> not merely produce pixels that look correct in isolation.

The project also detects likely source alpha from codec pixel-format metadata and
from an actual source frame.

---

# 14. The first export architecture was correct, but no longer sufficient

POC 9 made the right decision by giving export its own MLT graph.

Originally that graph was:

```text
fresh profile
fresh source producer
avformat consumer
```

That was safe for a single-source movie, but after POC 10 it had a fatal logical
problem:

```text
preview = tractor composition
export  = reopened base source only
```

The export could succeed technically while being wrong editorially.

That is the difference between **source export** and **composition export**.

POC 10.9 fixes that distinction.

---

# 15. Composition export snapshots state, then rebuilds fresh MLT objects

The live preview tractor is still never handed to the encoder thread.

Instead, when export begins, the bridge snapshots the composition state needed
to reconstruct it:

```text
primary source path
secondary source path
Layer 2 insertion frame
Layer 1 audio gain
Layer 2 audio gain
Layer 2 opacity / visibility result
Layer 2 x / y
Layer 2 scale
Layer 2 alpha interpretation
whether Layer 2 is a still
whether each layer has audio
requested export range
export kind
```

The worker then creates a completely new graph:

```text
fresh export profile
fresh Layer 1 producer
fresh Layer 2 producer
fresh Layer 2 playlist
fresh tractor
fresh composite transition
fresh audio mix transition
fresh avformat consumer
```

This preserves the most important POC 9 rule:

```text
preview graph and export graph share no live producer/tractor objects
```

The only shared MLT object is the initialized factory/repository.

---

# 16. The export worker recreates the tractor, not a visual approximation

The worker follows the same structural rules as preview:

```text
track 0 = fresh primary producer
track 1 = fresh Layer 2 playlist with blank lead-in
```

It plants a fresh `composite` transition between tracks 0 and 1 and writes the
saved geometry:

```text
x/y:(base_width * scale)x(base_height * scale):opacity
```

If Layer 2 has audio, it plants a fresh `mix` transition as well.

Per-track volume filters and the saved alpha interpretation are also rebuilt.

Finally:

```c
graph->export_top =
    mlt_tractor_producer(graph->export_tractor);
```

The encoder connects to that producer.

This is the point where two-layer export became real: the consumer is no longer
rendering a file that happens to be part of the composition; it is pulling
frames from the rebuilt composition graph itself.

---

# 17. Whole Movie is now an explicit export range mode

Before composition export, range behavior implicitly preferred a marked
selection whenever one existed.

That became surprising once the app started behaving more like a movie with
layers.

The export UI now has an explicit range choice:

```text
RANGE
  Whole Movie
  In / Out
```

`Whole Movie` is the default.

For a trimmed movie, Whole Movie means the current active trim bounds.

`In / Out` is available when a valid marked range exists.

This is a UI decision, but it simplified the engine contract too: export no
longer has to guess whether the mere presence of markers means the user intended
to restrict the render.

---

# 18. All export families now use the composition path

The tractor-aware start function is shared by:

```text
MP4 video
current-frame PNG
PNG image sequence
WAV audio
```

That means a Layer 2 logo, alpha video, opacity change, position/scale change,
hidden layer, or second audio track is no longer a preview-only feature.

The same composition snapshot feeds every offline output type.

The existing POC 9 output policies still apply:

```text
MP4      H.264 / AAC when composition has audio
PNG      square-pixel display geometry, progressive, Lanczos
sequence validated frame-for-frame
WAV      24-bit PCM output
real_time = -1 for offline export
partial outputs removed on failure/cancel
```

---

# 19. Audio-only export is now a mixdown

Once two tracks can contain audio, WAV export can no longer ask only whether the
base source has an audio stream.

The composition reports audio if either layer has audio.

The worker chooses an audio-bearing source for metadata such as sample rate and
channel count, but the actual frames come from the tractor, including the
track-local gains and the planted mix transition.

So the WAV operation has changed semantically from:

```text
extract/export source audio
```

into:

```text
render composition audio mix
```

That is exactly the kind of semantic change that should be documented when a
player grows editing capability.

---

# 20. Export completion is still validated at the top-level producer

The POC 9 lifecycle rules survived the move to tractors:

```text
start consumer
poll top-level export producer position
allow cooperative cancellation
stop consumer even after EOF
join/flush worker threads
validate output
clean partial output on failure
```

The only important substitution is:

```text
old progress source = single export producer
new progress source = export tractor producer
```

For a requested inclusive range:

```text
frames = out - in + 1
```

The worker continues to publish progress without calling back directly into
Dart from the encoder thread.

---

# 21. The smoke test now exercises the editing graph, not only transport

The headless bridge test has become much more valuable during POC 10.

In addition to playback transport, it now verifies things such as:

```text
second opaque engine isolation
add Layer 2 at an exact insertion frame
blank lead-in seeks
tractor playhead preservation
opacity round-trip and clamps
position / scale round-trip and clamps
anchor calculations
per-track audio gain
still-image Layer 2
alpha detection and interpretation
held still surviving to the final base-movie frame
whole-movie layered MP4 export
non-empty layered export output
```

That is the right place to prove MLT graph behavior.

Flutter tests can then focus on application state and UI behavior instead of
trying to diagnose every graph failure through pixels on screen.

---

# 22. The architecture at the POC 10 checkpoint

```text
Flutter UI
    |
    +-- PlayerEngine
    |      +-- transport / selection / trim
    |      +-- Layer 2 state and inspector controls
    |      +-- explicit export range mode
    |      +-- export status
    |
    +-- Dart FFI
           |
           v
    opaque MltBridgeEngine
           |
           +---------------- preview ----------------+
           |                                         |
           |   Layer 1 producer                      |
           |          \                              |
           |           +-> tractor -> sdl2_audio ----+-> RGBA cache
           |          /                                  -> OpenGL texture
           |   Layer 2 playlist                         -> Flutter Texture
           |      + composite transition
           |      + audio mix transition
           |
           +---------------- export -----------------+
                                                     |
                    snapshot composition state       |
                             |                       |
                             v                       |
                    background worker                |
                             |                       |
                    fresh Layer 1 producer            |
                    fresh Layer 2 playlist            |
                    fresh tractor                     |
                    fresh composite / mix             |
                             |                       |
                    avformat consumer ----------------+
```

The major rule is still the same as POC 9:

> Preview and export may represent the same movie, but they do not share live
> MLT graph objects.

---

# 23. What POC 10 proved

At this checkpoint MLT Player has proven that an embedded Flutter/MLT desktop
application can:

1. keep playback engines independently owned,
2. promote a one-source viewer into a two-track tractor,
3. place a second video/still layer at an exact movie frame,
4. composite that layer with opacity and alpha,
5. move and scale it live,
6. mix track audio independently,
7. hide, replace, and reorder the overlay,
8. keep Layer 1 authoritative for movie duration,
9. preserve the existing Flutter texture playback architecture, and
10. rebuild and export the same composition on a separate MLT worker graph.

The last point is the one that closes the loop.

A compositing feature is not really finished when it appears in preview.
It is finished when the offline render is driven by the same composition model.

---

# 24. What comes next

The current graph is intentionally still small.

The next useful work is refinement and generalization rather than another proof
that MLT can composite two things.

Likely directions include:

```text
more than two tracks
richer track timing/edit operations
output preset / codec selection
explicit output frame-rate control
blend-mode exploration
more complete alpha/color policy
MLT XML save/open
image-sequence import at explicit frame rate
```

The important architectural pieces are now in place:

```text
opaque engine ownership
tractor as the visible movie
distinct source-vs-top-level producer model
application-owned edit intent
worker-owned export graph
composition snapshot -> graph reconstruction
```

That is a much stronger base than trying to grow multitrack behavior around a
single process-global producer.
