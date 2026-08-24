<!-- docs/poc-10-layer-ordering-and-atomic-role-swaps.md -->

# POC 10 continuation: Layer Ordering, Role Promotion, and Atomic Presentation

## Field notes from making layer order behave like a finished application

The first POC 10 document ends with a hardened three-layer tractor, stable
indexed slots, timing/source trims, composition history, preview/export parity,
and seamless Layer 3 Remove/Undo restoration.

The next problem initially looked like a UI detail:

```text
Move Up / Move Down
```

It forced the project to separate three concepts that cannot safely be treated
as synonyms:

```text
media identity
visual Z-order
base-movie authority
```

It also exposed a second class of correctness problem: the final graph can be
right while the application still looks broken if the user watches that graph
being rebuilt one property at a time.

This note records the final ordering model, true base-role promotion through all
three current slots, cross-frame-rate/cross-aspect handling, and the atomic
presentation pipeline that made those operations feel finished.

The implementation described here was developed and tested against **MLT
7.22.0 on Linux**.

---

# 1. Visual order is explicit state

The fixed logical composition remains:

```text
slot 0 = Layer 1 / base
slot 1 = Layer 2
slot 2 = Layer 3
```

Those indices are the ABI, history, and export identities.

Visual Z-order is a separate permutation.

That means a normal visual reorder can change where a layer is drawn without
moving all of its state into another object.

A reordered media asset keeps its own:

- source path
- timeline START / END
- timed-video SOURCE IN / SOURCE OUT
- source-length metadata
- position / scale / anchors
- opacity / visibility
- alpha interpretation
- audio presence / gain

Preview and export carry the same visual permutation.

The Layers inspector is sorted by actual visual position rather than assuming
slot number equals screen order.

---

# 2. Overlay-only ordering proved the model first

The safest first proof was Layer 2 ↔ Layer 3.

Both remained overlays, so base profile, frame zero, and movie duration stayed
unchanged.

The regression fixture deliberately gave the two overlays different timing,
source trim, geometry, opacity, alpha, and audio state, then verified:

```text
reorder
Undo
Redo
preview/export parity
```

That proved visual order could be explicit state without destabilizing logical
layer ownership.

---

# 3. Crossing Layer 1 is a role question

Allowing Layer 1 to participate visually exposed an important distinction.

A visual move can draw the current base above another layer while Layer 1 still
owns profile, frame zero, and duration.

But QuickTime-style movement across the base boundary has a stronger meaning.

If a timed overlay is moved into the Layer-1 role, users expect it to become the
actual base authority.

That is a **role promotion**, not merely a draw-order change.

---

# 4. True base promotion changes profile authority

When a timed video becomes Layer 1, it becomes authoritative for:

- canvas/profile
- frame zero
- base frame rate
- movie duration

A still image cannot be promoted into Layer 1.

A base-role change establishes a new composition baseline because old history
entries were recorded against a different frame-zero/profile authority.

---

# 5. Two-layer promotion established the first real role exchange

The first completed role change was:

```text
old Layer 1 / base
old Layer 2 / timed overlay
```

becoming:

```text
old Layer 2 -> new Layer 1 / base
old Layer 1 -> new Layer 2 / overlay
```

The displaced former base receives the normal overlay control set.

This was the first point where the implementation had to stop thinking of
"Layer 1" as just the lowest visual item.

---

# 6. Properties belong to media, not to the slot

A cross-aspect bug made the ownership rule explicit.

A vertical Layer 2 promoted over a horizontal base initially caused the
displaced horizontal source to inherit the vertical overlay's previous X/Y/scale.

That was wrong.

The rule became:

> Existing media-owned edits stay with their media. A former base becoming an
> overlay is a fresh overlay presentation and must be fitted against the new
> canvas.

So the displaced base is re-added through the normal MLT overlay path and gets
a sane fitted/centered transform for its new canvas.

---

# 7. Three-layer Layer 2 promotion

Once Layer 3 existed, Layer 2 promotion had to preserve the third media asset.

The role exchange became:

```text
before: A(base), B(L2), C(L3)
after:  B(base), A(L2), C(L3)
```

Layer 3 stays Layer 3.

Its media-owned presentation and audio state are preserved.

Its timeline START/END and timed SOURCE IN/OUT are converted through time when
the promoted base changes frame rate.

The old base is re-added as a fresh Layer 2 so cross-aspect fitting remains
correct.

---

# 8. Three-layer Layer 3 promotion completed the model

Layer 3 promotion is intentionally adjacent-boundary driven.

Layer 3 can first cross Layer 2 as a normal visual reorder.

Once Layer 3 is adjacent to Layer 1, crossing the base boundary performs the
true role exchange:

```text
before: A(base), B(L2), C(L3)
after:  C(base), B(L2), A(L3)
```

Layer 2 remains Layer 2 and preserves its own state.

The displaced old base becomes a fresh Layer 3.

This completed timed-video base-role promotion across all three current slots
without turning every visual reorder into a destructive slot rotation.

---

# 9. Cross-frame-rate conversion is boundary-by-time conversion

Raw frame numbers cannot survive a base-rate change.

The rule is:

```text
old frame / old fps
        ↓
     seconds
        ↓
new frame at new fps
```

START-like boundaries use direct time conversion.

Inclusive END / SOURCE OUT values use the exclusive boundary:

```text
inclusive end N
→ exclusive boundary N + 1
→ convert through seconds
→ subtract 1
```

The same semantic policy is used by explicit output-frame-rate conform.

This keeps represented time ranges stable when a promoted source has a
different frame rate.

---

# 10. Functional correctness was not enough

Early role swaps reached the correct final graph but briefly showed the rebuild:

```text
open promoted base
add displaced base
restore surviving overlay
restore geometry
restore opacity
restore alpha/audio
restore visual order
seek final playhead
```

The user could see intermediate states flash by.

That made presentation atomicity part of edit correctness.

---

# 11. Atomic presentation uses several barriers

The final graph-changing presentation path combines several layers.

## Dart notification batching

`ChangeNotifier` publication is held while the graph is being rebuilt.

The Inspector therefore does not walk through intermediate state.

## Native frame-publication freeze

The previous completed preview frame remains published during the destructive
graph work.

## Final-frame readiness barrier

Dart waits for the completed replacement frame to reach the native ready slot.
"Refresh requested" is not treated as equivalent to "new frame rendered."

## Double-buffered OpenGL textures

The GL texture currently displayed by Flutter is not resized or overwritten in
place during a cross-aspect swap.

A hidden texture receives the replacement frame and any new-size allocation.

Only the completed upload can become the new front texture.

## Flutter `Texture.freeze`

Flutter's `Texture` widget is frozen before graph mutation and released together
with the final media/layout state.

The intended presentation transaction is:

```text
freeze old completed presentation
        ↓
rebuild MLT graph
        ↓
render completed replacement behind freeze
        ↓
publish new model/layout
        ↓
unfreeze
```

---

# 12. First-swap prewarming removed the final cold-path hitch

After double buffering and Flutter freeze, repeated cross-aspect swaps were
clean but the first swap after launch could still expose a small cold-path hitch.

The remaining cost was lazy allocation of the alternate-size hidden texture.

The final preflight asks native code to determine the would-be promoted
profile dimensions and allocate the inactive texture while the old composition
is still visible.

Then the real frozen transaction begins.

This makes the first role promotion use the same prepared texture path as later
promotions.

---

# 13. Timing/source-trim rebuilds use the same discipline

START / END and SOURCE IN / SOURCE OUT edits also rebuild playlist topology.

They now share the same frozen-preview transaction rule:

> Any edit that rebuilds the visible MLT graph should publish one completed
> visual state, not a visible sequence of implementation states.

---

# 14. Preview/export parity remains the correctness boundary

Visual ordering and layer timing cannot be preview-only concepts.

The export snapshot carries the indexed composition plus visual order and
rebuilds it with fresh MLT objects on the worker graph.

The native safety net verifies:

- two-layer ordering
- three-layer ordering
- complete state preservation after reorder
- Layer 1 in bottom/middle/top visual positions
- profile/frame-zero authority during visual-only reorder
- preview/export visual-order parity
- timing parity
- source-trim parity
- output-rate conform
- invalid-order rejection

Role promotion itself is orchestrated by Dart around the existing hardened
native graph APIs and is additionally proved through interactive Player testing.

---

# 15. Final POC 10 ordering rules

The completed model now distinguishes two operations.

## Visual reorder

Any present Layer 1 / 2 / 3 can move visually.

This changes the draw stack while preserving logical role.

## Base-role promotion

When a timed overlay crosses the actual Layer-1 role boundary, it can become the
new base authority.

Supported role outcomes include:

```text
A(base), B, C
→ B(base), A, C

A(base), B, C
→ C(base), B, A
```

Current topology constraints remain:

- still images cannot become Layer 1
- Layer 3 is removed before Layer 2
- a fourth layer is rejected
- the fixed three-slot model is preserved

These are intentional constraints for a precision media utility, not an
unfinished attempt at an unlimited NLE timeline.

---

# 16. What this milestone proves

The completed ordering/promotion milestone demonstrates:

```text
explicit three-layer visual Z-order
media-owned state preservation
Undo/Redo-safe visual ordering
preview/export order parity
true Layer 2 base promotion
true Layer 3 base promotion
surviving-overlay preservation
cross-frame-rate role conversion
cross-aspect displaced-base fitting
atomic timing/source-trim rebuilds
Dart notification batching
native frame-publication freeze
final-frame readiness barrier
double-buffered GL texture presentation
Flutter Texture.freeze commit boundary
alternate-profile texture prewarming
```

The most important architectural result is:

```text
media identity
≠
logical role
≠
visual order
```

and all three are now explicit enough to survive real role changes.

---

# 17. Handoff to the next product phase

With composition identity, ordering, profile authority, and atomic presentation
proven, the project no longer needed to keep expanding the Player before
starting its original product goal.

The next phase became **MLT Explorer**: an Adobe Bridge-style local media
browser whose selected asset opens in this completed precision Player.

That work is documented in
[POC 11: MLT Explorer Foundation](poc-11-mlt-explorer-foundation.md).
