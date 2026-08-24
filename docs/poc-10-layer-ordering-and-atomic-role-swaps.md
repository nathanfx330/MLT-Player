<!-- docs/poc-10-layer-ordering-and-atomic-role-swaps.md -->

# POC 10 continuation: Layer Ordering, Role Swaps, and Atomic Presentation

## Field notes from making layer order behave like a finished application

The first POC 10 document ends at a hardened three-layer composition with stable indexed slots, preview/export parity, timing/source trims, and atomic Layer 3 Remove/Undo restoration.

The next problem looked smaller than it was:

```text
Move Up / Move Down
```

In practice it forced MLT Player to separate three concepts that had previously been allowed to overlap:

```text
logical layer identity
visual Z-order
base-movie authority
```

It also exposed a second class of problem. A composition can be logically correct and still look broken if the user sees the graph being rebuilt one property at a time.

This note records the ordering model, the two-layer base-role swap, cross-aspect fitting, and the presentation pipeline that made the swap visually atomic.

The implementation described here was developed and tested against **MLT 7.22.0 on Linux**.

---

# 1. Visual order is not the same thing as logical identity

The indexed composition model remains:

```text
slot 0 = Layer 1
slot 1 = Layer 2
slot 2 = Layer 3
```

Those slots are still the stable ABI and history/export identity of the layers.

Generalized visual ordering adds a separate permutation describing how the present layers are stacked. Moving a layer therefore does not need to swap every property between two state objects.

A reorder preserves the layer's own:

- source path
- timeline START / END
- timed-video SOURCE IN / SOURCE OUT
- source length metadata
- position / scale / anchors
- opacity / visibility
- alpha interpretation
- audio presence / gain

The same order permutation is carried through preview/export parity, so offline output reproduces the stack shown by the player.

The Layers inspector is also sorted by the actual visual stack rather than assuming slot number always equals screen order.

---

# 2. Overlay-only reordering was the first safe proof

The first generalized slice only exchanged the visual positions of Layer 2 and Layer 3.

Layer 1 stayed the base authority, so the proof could concentrate on one question:

> Can two overlays exchange visual order without losing any of their independent state?

The regression fixture deliberately gave the two overlays different timing, source trims, geometry, opacity, alpha/audio state, and then verified:

```text
reorder
Undo
Redo
preview/export parity
```

That proved visual order could become explicit state without destabilizing the existing composition model.

---

# 3. Layer 1 introduced a role question, not just a Z-order question

Allowing Layer 1 to move visually exposed an important UX distinction.

A purely visual move can put the base picture above or below another layer while keeping the same logical base authority. That is useful in a three-layer stack and is supported by the generalized Z-order model.

But in the two-layer QuickTime-style workflow, users naturally expect this operation:

```text
Layer 2 -> move into Layer 1
```

to mean more than "draw Layer 2 underneath or above the old base."

They expect a **role swap**:

```text
old Layer 2 -> new Layer 1 / base
old Layer 1 -> new Layer 2 / editable overlay
```

The displaced base must therefore gain the full overlay control set rather than remaining a base-only object that merely happens to be drawn second.

That semantic correction reused the earlier proven base/overlay swap path instead of inventing a second implementation.

---

# 4. A true base-role swap changes profile authority

When a timed Layer 2 becomes Layer 1, the promoted source becomes the new base movie.

It therefore becomes authoritative for:

- movie canvas/profile
- frame zero
- base frame rate
- movie duration

A still image cannot be promoted into Layer 1.

Because the old and new base can have different frame rates, placement and playhead values are converted through time rather than copied as raw frame numbers.

Conceptually:

```text
old frame / old fps -> seconds -> new frame at new fps
```

Inclusive END boundaries are converted through the exclusive boundary (`END + 1`) and converted back afterward, matching the same boundary policy used by output-frame-rate conform.

The role-swap transaction establishes a new composition baseline rather than trying to replay old history against a different base timeline.

---

# 5. Properties belong to media assets, not to the slot they happened to occupy

The first role-swap implementation reached the correct topology but exposed a subtle bug with very different source shapes.

If a vertical Layer 2 was promoted over a horizontal base, the displaced horizontal video initially inherited Layer 2's old overlay transform.

That was the wrong ownership rule.

The correct rule is:

> Presentation properties belong to the media state being edited; a displaced base should not inherit an unrelated overlay's transform merely because it now occupies that slot.

The corrected swap re-adds the old base as a fresh overlay on the new canvas. MLT Player computes a sane fitted presentation for that media and canvas.

This is why a horizontal former base now fits naturally inside a vertical promoted base rather than adopting the vertical clip's previous geometry.

---

# 6. Logical correctness was not enough: rebuilds had to become invisible

After the role swap was functionally correct, the viewer still exposed the rebuild sequence for a fraction of a second.

The visible pattern was effectively:

```text
open promoted base
add displaced base as overlay
apply timing
apply geometry
apply opacity
apply audio / alpha
park final frame
```

The final result was correct, but the user could watch some of those intermediate states flash by.

This was the same class of failure previously found in Layer 3 Remove/Undo, only harder because a role swap can also change the viewport aspect and GL texture dimensions.

---

# 7. Atomic presentation required barriers at more than one layer

The final presentation path uses several cooperating mechanisms.

## Dart notification batching

The engine holds `ChangeNotifier` publication while a graph-changing transaction is in progress. The inspector therefore does not walk through intermediate state values.

## Native frame-publication freeze

The last completed preview frame remains the published frame while MLT rebuilds the graph and reapplies state.

## Final-frame readiness barrier

Dart does not treat "refresh requested" as equivalent to "new frame ready." The transaction waits for the completed replacement frame to reach the native presentation path.

## Double-buffered OpenGL textures

The texture currently displayed by Flutter is never resized or rewritten in place during a cross-aspect swap.

Instead:

```text
front texture = currently displayed and read-only
back texture  = hidden upload target
```

The new frame, including any new width/height allocation, is uploaded into the hidden texture. Only after that upload completes does the back texture become the next front texture.

This prevents a live `glTexImage2D` reallocation from being visible to the compositor.

## Flutter `Texture.freeze`

Flutter's own `Texture` widget is frozen before the destructive part of the role swap.

The intended transaction becomes:

```text
freeze already displayed Flutter texture
wait until freeze is committed
rebuild native composition
prepare final frame behind the freeze
update media/layout/inspector state
unfreeze texture
```

The first frame Flutter is allowed to fetch for the new layout is therefore the completed replacement frame.

---

# 8. The final first-swap hitch was a lazy-allocation problem

After the Flutter freeze and GL double buffering were in place, repeated swaps were visually perfect but the **first** cross-aspect swap after launch could still show a tiny intermediate blink.

That pattern was diagnostic:

```text
first swap  -> slightly imperfect
second swap -> perfect
third swap  -> perfect
```

The remaining cost was one-time initialization of the alternate-size hidden texture path.

The final fix prewarms the would-be base profile before the first real role change.

While the current composition remains visible, native code determines the dimensions Layer 2 would have as the base and preallocates the hidden GL texture to that profile.

Only after the prewarm completes does the normal Flutter-freeze / rebuild / commit transaction begin.

The tradeoff is intentional: the first promotion may wait briefly, but once it switches the user sees:

```text
old finished composition
          ->
new finished composition
```

with no visible assembly in between.

---

# 9. Timing and source-trim edits use the same atomic rebuild discipline

The role-swap investigation also exposed that START / END and SOURCE IN / SOURCE OUT changes could briefly reveal their rebuild path.

Those graph-changing edits now use the same frozen-preview transaction rather than allowing the viewer to observe playlist reconstruction and property reapplication.

This keeps the model consistent:

> Any edit that must rebuild the visible MLT graph should publish one completed visual state, not a sequence of implementation states.

---

# 10. Preview/export parity remains the correctness boundary

Ordering is not allowed to become a preview-only concept.

The export snapshot carries the same indexed layer state plus visual-order information, and the worker rebuilds a graph that reproduces the preview stack.

Focused native layer-order coverage verifies:

- two-layer visual ordering
- three-layer ordering
- complete layer-state preservation after reorder
- Layer 1 in bottom/middle/top visual positions
- Layer 1 remains frame-zero/duration authority for visual-only reorders
- preview/export order parity
- invalid duplicate order rejection without damaging the existing graph

The existing timing, source-trim, export-preset, and frame-rate-conform suites continue to run alongside the layer-order tests.

---

# 11. Current ordering rules

The current product deliberately distinguishes visual order from base-role promotion.

### Three-layer visual ordering

Layer 1, Layer 2, and Layer 3 participate in Move Up / Move Down visual ordering. Their logical indexed identities and per-layer state remain stable.

### Two-layer base-role swap

With exactly Layer 1 + Layer 2, crossing the Layer-1 boundary performs a true role swap when the promoted Layer 2 is timed video.

The promoted source becomes the new base authority and the displaced former base becomes Layer 2 with the full overlay controls.

### Current topology constraints

- A still image cannot become Layer 1.
- Layer 3 is still removed before Layer 2; removal topology remains conservative.
- Arbitrary three-layer **role promotion** into the base slot is not yet generalized. Three-layer visual order and two-layer base-role swapping are separate, explicit behaviors.
- A fourth layer remains rejected.

These constraints are intentional. MLT Player is still optimizing for a precise QuickTime-style utility rather than silently turning into a general NLE timeline.

---

# 12. What this milestone proves

The completed ordering/role-swap milestone now demonstrates:

```text
explicit three-layer visual Z-order
full per-layer state preservation through reorder
Undo/Redo-safe overlay ordering
preview/export ordering parity
true two-layer base-role swapping
cross-frame-rate role-swap conversion
cross-aspect fitting of the displaced base
atomic timing/source-trim graph rebuilds
Dart notification batching
native frame freeze
final-frame readiness barrier
double-buffered GL texture presentation
Flutter Texture.freeze presentation boundary
first-swap alternate-profile prewarming
```

The result is not merely that the final frame is correct.

The application now treats **presentation atomicity as part of edit correctness**: the user should see the old completed movie until the new completed movie is ready.

---

# 13. Next work

The composition model is now strong enough for the next feature families without first solving basic layer identity again.

Likely next work includes:

- arbitrary three-layer base-role promotion, if the product needs it
- blend-mode exploration
- broader alpha / color policy
- MLT XML interchange

The architectural lesson from this phase is straightforward:

> A media graph can be transactionally correct and still feel broken until model state, rendered-frame publication, GPU resource replacement, and UI composition all share the same commit boundary.
