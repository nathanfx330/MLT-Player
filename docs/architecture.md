<!-- docs/architecture.md -->

# MLT Player Architecture

This document describes **the system as it exists now**.

It is the current-reference companion to the root [`README.md`](../README.md).
The POC documents in this directory are historical records of how the design was
discovered; when an older POC describes an intermediate architecture, this file
is authoritative for the current implementation.

The implementation described here is validated against **MLT 7.22.0 on Linux**.

---

## 1. The ownership model

The shortest useful description is:

```text
Flutter owns the application.
MLT owns the media.
The C bridge owns the boundary.
```

That division is deliberate.

Flutter/Dart owns:

- Explorer navigation and selection
- application layout and focus
- keyboard shortcuts
- In/Out and logical trim state
- Undo/Redo history
- layer-edit intent
- subtitle discovery, decoding, search, and presentation
- export dialogs and progress presentation
- persistent Explorer preferences, ratings, and tags

MLT owns:

- source probing and decode
- playback timing and audio
- frame production
- composition tractors, playlists, filters, and transitions
- stream metadata exposed by its producers
- export rendering and encoding
- thumbnail frame decode

The native bridge does not try to become another application framework. Its job
is to expose a narrow, testable boundary between those two owners.

---

## 2. System map

```text
Linux / GTK runner
    |
    | owns Flutter view + native texture registrar
    v
Flutter application
    |
    +-- ExplorerPage
    |     |
    |     +-- Explorer services
    |     +-- ThumbnailService
    |             |
    |             v
    |       MLT thumbnail FFI
    |
    +-- PlayerPage
          |
          +-- PlayerEngine
          |     |
          |     +-- MltBridge
          |     +-- MltLayerBridge
          |     +-- export bridges
          |
          +-- StoryboardThumbnailService
          +-- SrtSubtitleService

Dart FFI via DynamicLibrary.process()
    |
    v
libmlt_bridge.so
    |
    +-- mlt_bridge.c        playback / opaque engines / texture handoff
    +-- mlt_composition.c   shared composition construction policy
    +-- mlt_export.c        independent background export graph
    +-- mlt_thumbnail.c     independent serialized thumbnail graph
    |
    v
MLT 7.22
```

The Linux build deliberately compiles those four native translation units into
one shared bridge library. Test programs are separate; they are not part of the
runtime bridge.

---

## 3. Dart resolves the bridge from the running process

The GTK runner already links `libmlt_bridge.so`.

Dart therefore uses:

```dart
DynamicLibrary.process()
```

rather than opening another copy of the library by path.

This matters because some infrastructure is intentionally process-wide:

- the initialized MLT repository/factory state
- the Flutter texture registrar and GL texture path
- the registry/count of opaque playback engines

Playback state itself is no longer process-global, but splitting the runner and
Dart across two independently loaded bridge instances would still split the
infrastructure that those engine handles depend on.

---

## 4. Playback state lives in opaque engine handles

The native playback object is:

```c
MltBridgeEngine
```

Each handle owns its own mutable playback/composition state, including:

```text
profile
primary producer
secondary producer + playlist
tertiary producer + playlist
tractor
transitions
per-layer audio filters/gains
alpha state
geometry state
stream inspection snapshot
transport state
frame-transfer slots
preview serials
engine mutex
frame mutex
```

The public C ABI keeps compact operation names such as `mlt_bridge_open()` and
`mlt_bridge_seek_frame()`, but a calling thread first activates the engine handle
it is operating on. A GLib `GPrivate` thread-local selects that active engine.

That preserves a simple ABI without returning to process-global playback state.
Different threads can operate on different engines as long as each activates the
correct handle first.

The repository/factory remains shared infrastructure because MLT is initialized
once for the process.

---

## 5. There is one visible Flutter preview path

Opaque engines do **not** imply multiple simultaneous visible Flutter players.

The Linux runner owns one Flutter view and therefore one process-wide external
texture path. The bridge stores which opaque engine currently feeds that
texture.

The selected preview engine owns the live `sdl2_audio` consumer and the pixels
published to Flutter.

This is an important distinction:

```text
multiple native engine handles are possible
            !=
multiple simultaneous Flutter preview surfaces are currently implemented
```

Background work such as export and thumbnail generation uses independent MLT
objects and does not borrow the visible preview consumer.

---

## 6. Preview graph

For a one-layer movie, the top-level playback producer can be the primary
producer directly.

Once composition is involved, the top-level producer becomes a tractor-backed
graph. Source ownership remains explicit underneath it:

```text
Layer 1 source
Layer 2 source -> timed/held playlist
Layer 3 source -> timed/held playlist
        |
        v
      tractor
        |
        v
preview consumer (sdl2_audio)
        |
        +-- audio -> system
        |
        +-- rendered RGBA frame
                 |
                 v
           bridge frame slots
                 |
                 v
          Flutter GL texture
```

MLT renders the video. Flutter never asks MLT to create a video window.

The consumer is configured to produce RGBA frames suitable for the external
texture. The frame callback copies completed pixels into bridge-owned slots and
returns; it does not perform transport changes or UI work.

---

## 7. Frame transfer is isolated from transport locking

Each playback engine owns three RGBA frame slots:

```text
write
ready
display
```

The MLT frame callback fills the write slot, then performs a short protected
slot swap. Flutter's texture side claims the ready slot as display.

The expensive operations happen outside the small frame lock:

```text
MLT frame copy       no engine lock
OpenGL upload        no engine lock
```

The frame callback deliberately does not take the engine's main mutation mutex.
That prevents a lock inversion in which the UI holds the engine lock while MLT
waits for a callback that is itself waiting for that lock.

Transport and frame publication are separate ownership lanes.

---

## 8. Frame-native transport is the precision authority

The bridge exposes both time-oriented and frame-oriented transport:

```text
mlt_bridge_seek_frame(frame)
mlt_bridge_position_frame()

mlt_bridge_seek_ms(milliseconds)
mlt_bridge_position_ms()
```

Frame stepping and edit boundaries use the frame-native API. Millisecond
transport remains useful for time-based scrubbing and UI presentation.

This avoids the fractional-frame rounding problem that appears when exact frame
stepping is converted through milliseconds at rates such as 23.976, 29.97, and
59.94.

---

## 9. The composition model is three stable logical slots

The native slot constants are fixed and zero-based:

```text
0 = Layer 1 / base
1 = Layer 2
2 = Layer 3
```

The Dart indexed layer API uses the same identities.

That index agreement is a core invariant. A logical layer does not change its
identity because the user changes visual stacking.

Each overlay can carry:

- timeline START / END
- source IN / OUT for timed media
- opacity
- x/y position
- scale
- anchor-derived placement
- alpha interpretation
- audio gain
- still/timed-media behavior

The three-slot limit is intentional. A fourth layer is rejected rather than
silently creating an untested graph topology.

---

## 10. Logical identity and visual Z-order are separate

Visual stacking is stored as a permutation of the three logical slot indices:

```text
bottom -> middle -> top
```

That means a layer can move visually without changing every other piece of
state keyed to its logical identity.

This separation is especially important for Undo/Redo and base-role promotion.
The application can say “Layer 3 is now visually below Layer 2” without turning
Layer 3 into some new logical object.

---

## 11. Base-role promotion is a graph change, not a cosmetic reorder

Promoting a timed layer to the base role can change the composition profile,
frame-rate authority, dimensions, fitting rules, and displaced-base placement.

The bridge therefore treats role promotion as an atomic graph-changing edit.

The layer API exposes presentation barriers:

```text
preview_update_begin()
    rebuild/configure graph
preview_update_end()
```

While an update is in progress, the old Flutter texture remains visible and
intermediate frames from a partially rebuilt graph are not published.

The bridge also exposes frame/texture serials and a prewarm path so Dart can
coordinate layout changes with the arrival of replacement pixels rather than
showing a transient half-configured composition.

---

## 12. Shared composition policy lives outside preview and export

`mlt_composition.c` is the policy layer used by both graph families.

It owns reusable decisions such as:

- secondary/still base sizing
- timeline lead-in and placement
- source-trim normalization
- geometry application
- transition configuration
- alpha-filter attachment and interpretation

This separation exists specifically to stop preview and export from developing
slightly different versions of the same composition rules.

The native parity state is also index-aligned with the three logical slots. It
records derived profile, range, visual order, geometry, opacity, timing, source
trim, alpha, and audio values so tests can compare what preview and export think
the composition means.

---

## 13. Export never reuses the live playback graph

Export is intentionally independent.

When the user starts an export, the current composition state is copied into an
export job snapshot. The background worker then builds a fresh profile,
producers, playlists, tractor, transitions, and avformat consumer.

```text
live preview graph                 export graph
------------------                 ------------
opaque playback engine             immutable job snapshot
live tractor                       fresh tractor
sdl2_audio consumer                avformat consumer
Flutter texture                    output file(s)
```

The export worker owns its graph from creation through cleanup.

Only small status values cross the worker boundary:

```text
running
progress
cancel requested
success
error
```

This keeps encoding from stealing or mutating the producer currently being
viewed.

---

## 14. Export frame-rate conform is explicit

The export job stores both the source frame-rate basis and the selected output
rate.

Layer timing and source ranges are conformed deliberately rather than assuming
that a frame number has identical temporal meaning after an output-rate change.

This is tested beyond metadata comparison. The frame-rate smoke path decodes
produced output frames and checks rendered content so an off-by-one temporal
conversion cannot pass merely because two structures contain similar numbers.

---

## 15. Thumbnail generation is independent and serialized

Explorer and Storyboard do not drive the live Player through media merely to
obtain thumbnails.

Thumbnail generation creates its own MLT profile/producer objects and writes
cacheable image results.

The important native rule is stronger: thumbnail generation is serialized by a
process-wide thumbnail mutex.

That serialization was added after release builds exposed timing failures when
multiple short-lived Dart isolates allowed independent thumbnail graphs to enter
MLT/plugin/decoder stacks concurrently.

The current contract is therefore:

```text
many Dart thumbnail requests may exist
              |
              v
one native thumbnail generation lane at a time
```

This is intentionally conservative. Stable release behavior is more valuable
than maximizing parallel thumbnail decode.

Still-image thumbnails explicitly prefer `pixbuf`, with `avformat` as fallback,
so the browser does not accidentally select a Qt `qimage` path with unsuitable
thread/application assumptions.

---

## 16. Explorer and Player are persistent application views

Explorer is the application home. Player is the precision workspace.

Opening media does not destroy Explorer and returning from Player does not tear
down and reconstruct the entire application/native world.

The intended lifecycle is:

```text
Explorer state persists
    |
    +-- select/open asset
    v
Player uses persistent engine
    |
    +-- return
    v
Explorer resumes previous browsing context
```

This is why media handoff boundaries matter. The same path can arrive through a
Linux file chooser, drag/drop host channel, or Explorer selection, and those
entry points can have different desktop lifecycle timing even when they end at
the same `open(path)` operation.

---

## 17. Subtitles deliberately stay outside the MLT graph

SRT sidecars are an application feature, not part of the playback composition.

The Dart subtitle service:

- discovers a same-basename `.srt`
- decodes UTF-8 first, then Windows-1252, then Latin-1 fallback
- parses cues
- exposes cue timing/text to Flutter

Flutter owns on-screen presentation and transcript search. Clicking a cue seeks
the Player; subtitle text itself is not burned into or inserted into the MLT
preview graph.

This keeps text search, focus, visibility, and encoding policy independent from
media rendering.

---

## 18. Explorer metadata and annotations are application data

Explorer's ratings and tags are persisted outside the source media.

The current annotation identity is the source path. That is simple and useful
for a local browser, but it has an explicit limitation: moving or renaming a
file can orphan the stored annotation association.

Thumbnail cache entries are disposable and may simply regenerate. Annotations
are user data, so changing their identity model later requires a migration plan
rather than a casual cache-key refactor.

---

## 19. Validation is part of the architecture

The project learned that “passes tests” and “works under `flutter run`” are not
sufficient proof for a native desktop media application.

The current validation model is:

```text
1. flutter analyze
2. Dart regression tests
3. headless native smoke/parity tests
4. flutter run interactive behavior
5. standalone release bundle
6. launch from an unrelated working directory
7. exercise the exact desktop handoff that changed
```

Different tiers have caught different classes of failure:

- native graph/transport defects
- Flutter/native texture integration defects
- release-only producer/thread-context defects
- unsafe thumbnail timing
- file-chooser-specific handoff timing
- CI SDK deprecation drift

A successful debug run is evidence. It is not a substitute for running the
actual release artifact through the user-facing path that changed.

---

## 20. Source map for contributors

When changing the system, start with the file that owns the relevant policy.

| Concern | Primary source |
| --- | --- |
| App shell / Player UI | `lib/main.dart` |
| Explorer UI | `lib/ui/explorer_page.dart` |
| Player orchestration/edit state | `lib/services/player_engine.dart` |
| Core Dart FFI / opaque engine lifecycle | `lib/services/mlt_bridge.dart` |
| Indexed layer FFI | `lib/services/mlt_layer_bridge.dart` |
| Subtitle parsing/encoding | `lib/services/srt_subtitle_service.dart` |
| Native playback/transport/texture | `native/mlt_bridge.c` |
| Shared composition rules | `native/mlt_composition.c` |
| Background export | `native/mlt_export.c` |
| Thumbnail decode | `native/mlt_thumbnail.c` |
| Stable layer-slot constants | `native/mlt_layers.h` |
| Indexed layer ABI | `native/mlt_layer_api.h` |
| Preview/export derived parity state | `native/mlt_parity.h` |
| Linux bridge build/linking | `linux/CMakeLists.txt` |
| CI baseline | `.github/workflows/ci.yml` |

The guiding rule is simple: change the narrowest owner that actually controls
the behavior. Avoid broad refactors across the native boundary unless a concrete
feature or defect requires them.

---

## 21. Architectural invariants worth protecting

These are the assumptions most likely to prevent future regressions:

1. **Frame-exact operations stay frame-addressed.**
2. **Preview and export remain separate MLT graphs.**
3. **Preview and export share composition policy rather than duplicating it.**
4. **Logical layer indices remain stable across Dart and C.**
5. **Visual order remains separate from logical identity.**
6. **The MLT frame callback never takes the main engine mutation lock.**
7. **Only the selected engine feeds the single Flutter preview texture.**
8. **Thumbnail decode remains independent from the live Player and serialized
   until concurrency is reproven in release builds.**
9. **Graph-changing presentation is atomic from the user's point of view.**
10. **Standalone release validation is required after native-adjacent changes.**

Those invariants are more important than keeping any particular file small.
The architecture should be refactored when a real change demands it, not merely
because a large working file is aesthetically uncomfortable.