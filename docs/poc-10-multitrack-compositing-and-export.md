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

and became a composition system:

```text
Layer 1 producer ------------------+
                                   |
Layer 2 playlist / producer -------+--> MLT tractor --> preview consumer
                                   |
Layer 3 playlist / producer -------+
```

The important milestone was never merely drawing another picture over the
first. The real milestone was making one editable composition survive all the
way through:

```text
open
add layers
place them in time
change opacity
change audio levels
interpret alpha
move / scale / hide them
remove / restore them
preview the result
export the same result
```

This document records the architecture that made that work and the hardening
that followed once the first two-layer proof was already functional.

The implementation described here was developed and tested against **MLT
7.22.0 on Linux**.

---

# 1. The POC 10 progression

POC 10 landed in small proofs rather than one large rewrite:

```text
10.1  opaque engine handles
10.2  tractor + second track
10.3  add second track at the parked playhead
10.4  live layer opacity
10.5  Layers/Tracks inspector + per-track audio levels
10.6  alpha-capable still/video layers
10.7  layer replacement, visibility, and two-layer order swap
10.8  layer position, scale, and anchors
10.9  tractor-aware composition export
```

At 10.9 the two-layer feature loop was complete, but the architecture still
needed to prove that it could be trusted and extended.

The work after 10.9 therefore concentrated on two things:

1. **hardening the existing preview/export path**, and
2. **generalizing the composition model to a real third layer without forking
   preview and export behavior**.

That second phase added:

- shared preview/export placement helpers
- export diagnostics and explicit range state
- native module separation
- preview/export parity instrumentation
- Linux CI
- MLT 7.22 PTS diagnosis
- composition-aware Undo/Redo and explicit layer removal
- macro-alias cleanup
- no-active-engine guards
- OpenGL texture retirement cleanup
- indexed three-slot composition snapshots
- a real Layer 3 in both preview and export
- Layer 3 Dart/FFI and inspector controls
- atomic preview transactions for seamless Layer 3 Remove/Undo

The order mattered. Layer 3 was not allowed into the UI until preview and export
could independently derive and compare the same three-layer state.

---

# 2. Factory lifetime and playback-engine lifetime are separate

The original bridge used one process-global playback engine. That was ideal for
proving playback, but it was the wrong ownership model once multiple graphs were
on the roadmap.

The bridge exposes an opaque engine object:

```c
MltBridgeEngine *mlt_bridge_engine_create(void);
int mlt_bridge_engine_activate(MltBridgeEngine *engine);
void mlt_bridge_engine_destroy(MltBridgeEngine *engine);
```

The MLT repository/factory remains process-wide. Playback state lives in the
engine handle.

Each engine owns its own media and composition state, including the current
top-level producer, source producers/playlists, tractor, transitions, filters,
frame buffers, transport state, and inspection state.

The Flutter texture registrar is process-wide because the Linux runner owns one
Flutter view, but the bridge records which engine currently feeds that texture.

Thread-local engine activation lets the public C ABI stay compact while keeping
playback state out of process globals.

The smoke suite explicitly creates a second engine, opens media in it, seeks it
independently, reactivates the primary engine, and verifies that the primary
playhead did not move.

The lesson:

> Separate process-wide MLT lifetime from graph/player lifetime before
> multigraph features depend on it.

---

# 3. The top-level producer is not the same thing as a source producer

With one layer, the visible producer is simply the Layer 1 source.

Once a composition exists, transport and preview operate on the tractor
producer instead.

Conceptually:

```text
one layer:
    visible producer == Layer 1 producer

multiple layers:
    visible producer == mlt_tractor_producer(tractor)
```

That distinction is foundational.

If transport keeps seeking the original source after the tractor has become the
visible movie, preview and edit state diverge immediately.

Layer 1 remains the composition authority for canvas, frame zero, and duration,
but it is not necessarily the object the preview consumer is connected to.

---

# 4. Composition state now uses stable indexed slots

The two-layer implementation began with names such as `primary` and
`secondary`. That was understandable while only one overlay existed, but it
became an architectural trap as soon as Layer 3 was planned.

The hardened model uses three stable slots:

```text
slot 0 = Layer 1 / base movie
slot 1 = Layer 2 / overlay
slot 2 = Layer 3 / overlay
```

Shared native headers define the slot count and indexed layer structures. The
export boundary also uses indexed layer snapshots rather than a one-off bundle
of `base_*` and `layer2_*` fields.

This matters because preview and export can now reason about composition state
with the same vocabulary.

A fourth layer is currently rejected explicitly. The current product supports
three layers; it does not silently grow an untested graph topology.

---

# 5. Add to Movie is playhead-relative

A new overlay starts at the parked playhead.

Before rebuilding the graph, the bridge captures the viewer-visible frame. If
playback is active, it prefers the consumer-visible position instead of blindly
trusting producer read-ahead.

A timed overlay is placed into an MLT playlist with a blank lead-in:

```text
frame 0                         insertion frame
|------------------------------------|
|               blank                | media ...
```

The playlist shape is approximately:

```c
if (start_frame > 0) {
    mlt_playlist_blank(playlist, start_frame - 1);
}

mlt_playlist_append_io(
    playlist,
    source,
    0,
    source_out
);
```

After the tractor is built, the bridge seeks the new top-level producer back to
the saved playhead and preserves the transport state.

The same placement policy is used for Layer 2 and Layer 3 and is reproduced by
the export graph.

---

# 6. Layer 1 defines movie duration

A multitrack graph immediately raises a policy question:

> If an overlay is longer than the base movie, how long is the movie?

For this QuickTime-style workflow the answer is deliberately simple:

```text
Layer 1 is authoritative.
```

The tractor is constrained to Layer 1's movie length even if an overlay source
is longer.

Timed overlays are clipped to the available remaining span. Still images are
held from their insertion frame through the end of Layer 1.

This gives the composition a stable identity:

```text
Layer 1 = movie
Layers 2/3 = media placed inside that movie
```

Export follows the same rule.

---

# 7. Still-image layers need different treatment from timed media

A still image is not simply a one-frame video.

For overlay stills the bridge prefers an RGBA-capable MLT still path and verifies
that the producer can supply composite-safe image data.

Sizing also differs intentionally:

```text
timed video:
    100% = fitted presentation size for the base canvas

still image:
    keep native presentation size when it already fits
    scale down only when it exceeds the base canvas
```

That keeps a small logo from being automatically enlarged to fill the movie.

A held still remains present through the final Layer 1 frame. Both the native
smoke test and preview/export parity harness verify that behavior for Layer 2
and Layer 3 scenarios.

---

# 8. Geometry and opacity are one render-state bundle

MLT's `composite` transition carries position, size, and opacity together in
its geometry rectangle.

The bridge therefore treats those properties as one state bundle rather than
independent unrelated controls.

Conceptually the geometry is expressed as:

```text
x/y:widthxheight:opacity
```

A crucial rule emerged early:

> Changing opacity must rewrite the current geometry, not default geometry.

Otherwise touching opacity after moving/scaling an overlay would snap it back
to its original rectangle.

Current clamps are:

```text
opacity  0.0 .. 1.0
scale    0.10 .. 3.00
```

Nine anchors use the scaled visible rectangle:

```text
top-left      top-center      top-right
middle-left   center          middle-right
bottom-left   bottom-center   bottom-right
```

Layer 2 and Layer 3 each carry independent X/Y, scale, opacity, and anchor
behavior.

---

# 9. Visibility is not destructive opacity

Hiding an overlay does not destroy the user's requested opacity.

The Dart engine keeps the requested opacity as composition state and sends zero
to the native render path while the layer is hidden. Showing the layer again
restores the requested value.

Therefore:

```text
hide != permanently set opacity to zero
```

Because the native render result is what export snapshots, a hidden layer also
remains hidden in offline output.

---

# 10. Alpha interpretation is explicit

MLT can expose alpha through decoded image data, but source RGB values may still
need interpretation.

Overlay layers expose three modes:

```text
Auto
Straight
Premultiplied
```

Auto and Straight keep the native decode path.

Premultiplied uses a bridge-owned alpha filter that requests RGBA,
unpremultiplies RGB by alpha, and then converts back to the downstream format
requested by MLT.

That final conversion is essential: a custom image filter must honor the
requested downstream image format rather than simply returning pixels that look
correct in isolation.

The project detects likely alpha from codec pixel-format metadata and from
actual frame data. Layer 2 and Layer 3 carry independent alpha modes.

---

# 11. Track gain is composition state; consumer volume is monitoring state

Each audio-bearing track gets a track-local MLT `volume` filter before tractor
mixing.

Conceptually with three audio-bearing layers:

```text
Layer 1 -> volume --+
                    |
Layer 2 -> volume --+--> tractor mix
                    |
Layer 3 -> volume --+
```

The exact tractor field can require more than one `mix` transition as layers are
added, but the user-facing policy remains simple: each layer has an independent
composition gain.

That is different from global consumer volume:

```text
consumer volume = listening level
track gain       = movie/composition state
```

Export snapshots and reapplies the per-track gains.

---

# 12. Layer 3 is a real tractor track, not a preview-only overlay

The critical Layer 3 rule was that it had to land in preview and export at the
same time.

Adding Layer 3 rebuilds the preview tractor as three tracks:

```text
track 0 = Layer 1
track 1 = Layer 2 playlist
track 2 = Layer 3 playlist
```

Before publishing the new tractor, the bridge recreates Layer 2's live
composition state on the new field and then plants Layer 3 above it.

If Layer 3 insertion fails, the previous two-layer graph and playhead are
restored instead of leaving a half-rebuilt movie.

That rollback rule is important:

> Do not publish a replacement composition until the replacement graph is
> complete enough to become the current movie.

The smoke/parity tests also deliberately attempt a fourth layer and verify that
rejection does not disturb the valid three-layer tractor.

---

# 13. Two-layer order swapping remains intentionally limited

Layer 1 has special semantics: it is the timed base and duration authority.

The original two-layer order swap exchanges the media occupying Layer 1 and
Layer 2, with the restriction that the resulting Layer 1 must remain timed
media.

Once Layer 3 exists, that operation is disabled.

The app requires the top layer to be removed first rather than inventing an
implicit three-way reindex/reorder policy.

This is a product decision as much as an engineering decision. The application
is intentionally avoiding a conventional NLE timeline until there is a clear,
precise interaction model for broader reordering.

---

# 14. Export is composition reconstruction, not source export

POC 9 correctly gave export an independent background MLT graph.

The first export graph was simply:

```text
fresh profile
fresh source producer
avformat consumer
```

That became editorially wrong as soon as preview became a tractor.

A successful export of only Layer 1 would still be the wrong movie.

POC 10 therefore treats export as **composition reconstruction**.

The preview tractor is never handed to the encoder thread. Instead the bridge
snapshots indexed composition state and the worker builds fresh producers,
playlists, filters, transitions, and a fresh tractor.

The preview and export graphs share no live producer/playlist/tractor objects.
They share only process-wide MLT infrastructure and copied state.

---

# 15. The export snapshot is indexed

The current snapshot describes up to three stable layer slots.

For each layer it can carry the information needed to rebuild offline output,
including:

```text
present / absent
source path
start frame
still / timed classification
alpha mode
has audio
requested audio gain
opacity / visibility render result
x / y
scale
```

Layer 1 remains the profile/duration authority.

The export worker then reconstructs the same topology preview uses.

That indexed boundary was the architectural prerequisite for Layer 3. It avoids
creating a second export implementation made from `layer3_*` special cases.

---

# 16. All export families use the composition path

The composition-aware graph feeds:

```text
MP4 video
current-frame PNG
PNG image sequence
WAV audio
```

That means overlay position, opacity, alpha, visibility, still holding, and
track audio gain are not preview-only effects.

The output policies established in POC 9 still apply:

```text
MP4      H.264 / libx264, AAC when composition has audio
PNG      display-correct square-pixel output
sequence deterministic owned filenames
WAV      24-bit PCM composition mixdown
```

The exporter also writes a JSON telemetry sidecar while MP4 export runs. It
tracks requested/completed frames, throughput, wall time, CPU usage, graph and
consumer setup, and final result state.

That diagnostic proved an apparent "slow export" bug was actually a range-state
bug: the encoder was rendering the whole movie rather than the intended marked
range.

---

# 17. Export range selection is explicit and fail-closed

The export UI separates output type from range intent:

```text
RANGE
  Whole Movie
  In / Out
```

Whole Movie is the default. For a trimmed movie it means the current active
trim bounds.

In / Out requires a complete valid pair. The engine no longer guesses that the
mere presence of one marker implies a valid selected export range.

A newly completed valid In/Out pair can choose In / Out implicitly until the
user explicitly selects a range mode. Once the user explicitly selects Whole
Movie or In / Out, that choice remains sticky according to the application
history rules.

The important architectural point is simpler:

> Invalid range state must stop export before native work starts.

---

# 18. Preview/export parity is now a first-class regression test

Once two different graphs were expected to represent the same movie, ordinary
smoke testing was not enough.

The project therefore added a headless parity harness.

The harness derives observable state from:

1. the live preview graph, and
2. a freshly built export graph created from the same snapshot.

It then compares:

```text
layer count
profile width / height
frame rate
composition length
normalized export range
layer presence
layer start frame
playlist/timeline length
still/timed classification
alpha mode
presentation geometry
opacity
track audio presence
track gain
```

Current parity scenarios include:

- timed Layer 2 with non-default geometry/opacity/gains
- held-alpha Layer 2
- timed/audio Layer 3 with independent Layer 2 and Layer 3 controls
- held-alpha Layer 3 through the composition final frame

The Layer 3 cases also verify that both preview and export report the third
indexed slot as present and equivalent.

This harness is the main reason Layer 3 could be added with confidence: export
was not allowed to drift into a third implementation of composition semantics.

---

# 19. Composition Undo/Redo has explicit baseline semantics

The first history model covered trim and selection state. POC 10 extended it to
composition state.

Property history includes overlay visibility, opacity, geometry, alpha mode,
source replacement, and per-track gains. Slider drags are grouped into one Undo
step rather than filling history with every intermediate slider event.

Adding a layer has special semantics:

```text
Add Layer 2 -> new Undo baseline
Add Layer 3 -> new Undo baseline
```

That means a user can edit a newly added layer, Undo those property edits back
to the freshly created composition, and stop there. Repeated Undo does not
unexpectedly remove the layer that established the current composition.

Explicit Remove is different:

```text
Remove Layer -> normal undoable edit
```

Undo after removing Layer 3 reconstructs the exact saved Layer 3 state.

Layer 2 cannot be removed while Layer 3 exists; the stack must be reduced from
the top.

---

# 20. Correct history was not enough; restore also had to look atomic

The first Layer 3 Remove/Undo implementation was logically correct but visibly
ugly.

Undo rebuilt Layer 2, reapplied its settings, and then made Layer 3 reappear.
The final composition was correct, but the user could watch the intermediate
graph states.

The first optimization stopped rebuilding Layer 2 unnecessarily when the
existing Layer 1/2 state already matched the history snapshot. That made the
restore faster, but not completely seamless because native `add_track` still had
to rebuild the tractor.

The final solution added a small preview transaction.

During an atomic composition restore:

```text
begin preview transaction
    freeze publication of newly rendered frames
    keep the last valid external texture visible
    suppress intermediate Dart ChangeNotifier updates
    rebuild / modify the tractor
    reapply saved layer state
end preview transaction
    invalidate duplicate-frame suppression
    request one fresh frame from the finished graph
    publish one final Dart state
```

A depth counter makes nested transaction paths safe, and failure paths always
release the freeze.

This is why Layer 3 Remove and Undo now appear seamless: the user sees the old
finished composition until the new finished composition is ready.

The lesson is useful outside this project:

> Transactional state restoration must control both the model notification path
> and the rendered-frame publication path if intermediate graph states are
> visually observable.

---

# 21. Native hardening removed hidden assumptions

Several cleanup passes happened before Layer 3 was exposed.

## Macro alias cleanup

The bridge had accumulated dozens of preprocessor aliases mapping old global
names onto fields in the active engine.

Those aliases were removed and replaced with explicit engine-field access. Only
real compile-time constants remain as macros.

That made ownership and missing-engine behavior much easier to reason about.

## No-active-engine guards

Public media/transport/property entry points now fail closed if no opaque engine
is active.

Depending on return type they provide a safe neutral or sentinel value, and the
last-error path reports that no active MLT engine exists.

A dedicated smoke program destroys the active engine and deliberately calls the
bridge afterward to prove the process does not crash.

## OpenGL texture retirement

OpenGL texture names cannot safely be deleted from arbitrary teardown code
because a valid GL context is not guaranteed there.

The bridge therefore retires old texture IDs and drains them from Flutter's
texture-population path, where a valid GL context exists. Unregister also waits
for in-flight raster readers before retiring the old name.

That makes re-register/hot-restart cycles safer without issuing GL deletion from
the wrong thread/context.

---

# 22. The MLT 7.22 unset-PTS warning was diagnosed, not papered over

Successful MP4 exports with encoded audio can emit FFmpeg warnings such as:

```text
Timestamps are unset in a packet for stream 1
Encoder did not produce proper pts, making some up.
```

The project added a focused PTS diagnostic with four cases:

```text
simple + audio
simple + silent
layered + audio
layered + silent
```

The result is stable:

```text
audio cases   -> warning
silent cases  -> no warning
```

Debug logging also shows audio packets reaching the relevant flush path with
`AV_NOPTS_VALUE`.

The application exporter does not manipulate AVPackets directly, so the project
does not insert a speculative local timestamp patch into composition code.

For MLT 7.22 this is treated as an upstream `avformat` audio-flush issue rather
than a Layer 2/Layer 3 graph bug.

---

# 23. The native code is split by responsibility

The original proof grew inside one large bridge translation unit. POC 10
hardening separated responsibilities:

```text
native/mlt_bridge.c
    engine lifecycle
    preview graph
    transport
    frame/texture path
    public bridge ABI

native/mlt_composition.c/.h
    shared placement / geometry / transition helpers

native/mlt_export.c/.h
    background export worker
    export graph ownership
    export diagnostics

native/mlt_layers.h
    indexed layer-slot definitions

native/mlt_layer_api.h
    indexed layer-control ABI used by Layer 3-aware Dart code

native/mlt_parity_smoke.c
    preview/export graph equivalence checks

native/mlt_pts_smoke.c
    focused MP4 audio timestamp diagnosis

native/mlt_guard_smoke.c
    no-active-engine regression checks
```

This split is not cosmetic. It prevents export code from reaching into the live
preview engine and gives parity tests a cleaner boundary to exercise.

---

# 24. `tools/smoke.sh` is the current native safety net

The normal native regression command is:

```bash
tools/smoke.sh
```

It builds and runs:

1. no-active-engine guard tests
2. the main native bridge smoke test
3. preview/export parity
4. the MP4 PTS diagnostic

The main smoke test covers transport, opaque-engine isolation, Layer 2 placement,
opacity, geometry, anchors, track audio, stills, alpha, layered export,
reopen/reset, junk rejection, and teardown.

Parity adds the three-layer cases and exact preview/export state comparison.

The PTS diagnostic remains informational for the known MLT 7.22 audio warning;
it is designed to catch a change in where that warning appears rather than to
pretend the upstream condition does not exist.

Linux CI runs the analyzer and native smoke/parity path against the project's
pinned environment.

---

# 25. Current UI rules for a three-layer composition

The Layers inspector exposes Layer 1, Layer 2, and Layer 3 state.

Current behavior is deliberately constrained:

```text
Layer 1
    timed base
    duration/profile authority
    audio gain

Layer 2
    video or held still
    playhead-relative start
    opacity / visibility
    X / Y / scale / anchors
    alpha interpretation
    audio gain
    replace source

Layer 3
    video or held still
    playhead-relative start
    opacity / visibility
    X / Y / scale / anchors
    alpha interpretation
    audio gain
    replace source
```

When three layers exist:

- Layer 3 is the removable top layer.
- Layer 2 removal is blocked until Layer 3 is removed.
- the existing Layer 1/Layer 2 swap is disabled.
- a fourth layer is rejected.

These limits keep the interaction model precise while the product remains a
QuickTime-style utility rather than drifting into a conventional NLE timeline.

---

# 26. What POC 10 now proves

At this checkpoint MLT Player has demonstrated all of the following in one
architecture:

```text
one/two/three-layer preview
playhead-relative overlay placement
timed and held-still overlays
alpha-aware compositing
independent overlay geometry
independent per-track gain
composition-aware Undo/Redo
explicit layer removal
seamless Layer 3 Remove/Undo
independent background composition export
preview/export parity diagnostics
fail-closed native engine access
headless regression coverage
```

The important result is not simply that three pictures can appear at once.

The result is that **the same three-layer movie exists coherently across UI
state, native preview state, history restoration, and offline export**.

That is the foundation needed before interchange or a broader track model makes
sense.

---

# 27. Current boundaries and next work

The current model intentionally stops at three layers.

Likely next composition/export work includes:

- export preset / codec selection
- explicit output frame-rate control
- richer layer timing/edit operations
- a deliberate broader reordering model
- blend-mode exploration
- broader alpha/color policy

The next major architectural milestone remains interchange:

```text
save MLT XML
open MLT XML
open image sequences at a chosen frame rate
```

XML should be built on top of the indexed, parity-tested composition model—not
used as a shortcut around it.

---

# Closing lesson

The path from one producer to three layers looked at first like a compositing
feature.

In practice it became an ownership, state-model, testing, and transaction
problem.

The useful sequence was:

```text
separate engine lifetime
build a real tractor
make placement explicit
make render properties observable
rebuild the same graph for export
prove preview/export parity
harden missing-engine and resource cleanup paths
generalize state before adding Layer 3
make history semantically correct
make history visually atomic
```

That sequence kept the application aligned with its original goal: a small,
precise movie tool whose internal graph can become sophisticated without forcing
the user into a full NLE workflow.
