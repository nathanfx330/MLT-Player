<!-- docs/rocky-mlt-740-compatibility-journey.md -->

# Rocky MLT 7.40 Compatibility Journey

**Date:** September 26, 2026  
**Platform:** Rocky Linux  
**MLT:** 7.40.0 from a private prefix under `~/.local/mlt-7.40`  
**Starting point:** `main` at `409788d` after the Explorer thumbnail performance work  
**Compatibility branch:** `fix-mlt-740-image-size-api`  
**Merged by:** PR #9, **Harden Rocky MLT 7.40 compatibility**  
**Merge commit:** `da7bbc3`

This document is the historical engineering record of the Rocky/MLT 7.40
verification pass that followed the Explorer thumbnail performance work.

It is intentionally a journey document rather than a current architecture
reference. The point is to preserve the sequence of failures, wrong turns,
diagnostic corrections, and final proofs that led to the compatibility changes.

The current architecture remains documented in
[architecture.md](architecture.md). The reusable MLT embedding lessons remain in
[embedding-mlt-in-a-flutter-linux-app.md](embedding-mlt-in-a-flutter-linux-app.md).

---

## 1. Why this verification happened

The Explorer representative-thumbnail fast path had already been completed and
merged. Ubuntu verification was good, the full Flutter suite was green, and the
large-directory Explorer test showed a clearly noticeable improvement.

The next step was to verify the same code on the Rocky workstation.

That machine matters because it is not the same environment as the project's
Linux baseline:

- the Linux baseline remains MLT 7.22.x;
- Rocky uses a private MLT 7.40.0 installation;
- Rocky also carries a newer FFmpeg stack;
- the MLT 7.40 installation is not in the ordinary system runtime search path.

That made Rocky a useful cross-version proof machine.

The initial goal was narrow:

> Make sure the thumbnail optimization still works on Rocky.

What followed exposed three different compatibility layers:

1. **compile-time MLT API compatibility;**
2. **runtime discovery of a private MLT installation;**
3. **test-harness compatibility with a newer FFmpeg.**

The media engine itself ultimately passed.

---

## 2. First failure: MLT 7.40 turns a warning into a build failure

The first Rocky run was:

```bash
./tools/thumbnail_smoke.sh
```

The smoke build stopped in `native/mlt_bridge.c`:

```text
error: ‘mlt_image_format_size’ is deprecated [-Werror=deprecated-declarations]
```

The important detail was `-Werror`.

The existing code was not suddenly wrong at runtime. MLT 7.40 had marked
`mlt_image_format_size()` deprecated strongly enough for GCC to emit a
deprecation warning, and the smoke build deliberately promotes warnings to
errors.

The code had originally used MLT's own sizing API for a good reason. After
requesting RGBA from the frame, the callback did not want to assume:

```text
width * height * 4
```

as the copy size.

The bridge wanted MLT to remain authoritative for the image byte count.

### What we deliberately did not do

Three tempting fixes were rejected:

- do not suppress `-Wdeprecated-declarations`;
- do not weaken `-Werror`;
- do not replace the call with a hard-coded RGBA byte formula.

Any of those would make the immediate build failure disappear while weakening a
useful safety property.

### The API audit

The relevant MLT headers were checked across both versions that matter to this
project:

- MLT 7.22.x, the Linux baseline;
- MLT 7.40.0, the Rocky/Windows-era version.

Both expose:

```c
mlt_image_calculate_size(mlt_image self)
```

For the already-validated `mlt_image_rgba` case, that API preserves the same
intent: describe the image to MLT and let MLT calculate its byte count.

The bridge was therefore changed from the deprecated format helper to a small
stack `mlt_image_s` description:

```c
struct mlt_image_s measured_image = {
    .format = format,
    .width = width,
    .height = height,
};

const int measured_size =
    mlt_image_calculate_size(&measured_image);
```

This was commit:

```text
5cc5690 Use supported MLT image sizing API
```

The key property survived:

> The bridge still asks MLT how many image bytes it owns instead of inventing
> that number itself.

---

## 3. Second failure: the code compiled, but the smoke binary could not find MLT

After the API change, the thumbnail smoke progressed past compilation.

It then failed at process startup:

```text
error while loading shared libraries:
libmlt-7.so.7: cannot open shared object file: No such file or directory
```

This was a different class of failure.

The compiler had found MLT through `pkg-config`, but the dynamic loader did not
know about the private Rocky prefix when launching the generated smoke binary.

The smoke scripts were already setting `LD_LIBRARY_PATH`, but only for their
temporary build directory. That was sufficient for the locally built bridge
library, not for:

```text
~/.local/mlt-7.40/lib/libmlt-7.so.7
```

### Fix: derive the runtime path from the same authority as the build path

Rather than hard-code the Rocky path, the scripts now ask `pkg-config`:

```bash
MLT_LIB_DIR="$(pkg-config --variable=libdir mlt-framework-7)"
```

and compose the runtime path with:

```bash
LD_LIBRARY_PATH="$WORK:$MLT_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

The same assumption existed in three native scripts, so the fix was applied to:

- `tools/thumbnail_smoke.sh`;
- `tools/smoke.sh`;
- `tools/pts_diag.sh`.

Those changes landed as the consecutive **Honor custom MLT runtime library
path** commits.

This is an important distinction:

> A successful `pkg-config` compile does not prove the generated executable can
> locate that same private-prefix library at runtime.

After this correction:

```text
PASS thumbnail smoke (0 failures)
```

The representative-frame selector, exact storyboard generation, still-image
generation, failure recovery, and serialized concurrent thumbnail callers all
passed on Rocky MLT 7.40.

That completed the original thumbnail-specific verification.

---

## 4. The broader smoke suite exposed a more interesting problem

Because `native/mlt_bridge.c` had changed, verification did not stop at
thumbnail generation.

The broader native suite was run:

```bash
./tools/smoke.sh
```

Most of it passed.

The green areas included:

- no-active-engine guards;
- ordinary media open/play/pause/seek;
- independent opaque engines;
- track insertion offsets;
- opacity and geometry;
- track audio gain;
- EOF and replay;
- still-image behavior;
- alpha still/video layers;
- whole-movie layered export;
- preview/export parity;
- two- and three-layer derived-state parity;
- layer timing;
- source trimming;
- visual layer ordering;
- ProRes preset export.

Then the final frame-rate conform section reported four failures.

The failing assertions were the outside boundaries around two overlays in a
25 fps -> 30000/1001 export:

```text
Layer 3 START is not left at source frame 20
Layer 3 conformed source range ends after output frame 84
Layer 2 START is not left at source frame 100
Layer 2 inclusive END 130 converts to output END 156
```

At the same time, the interior assertions passed.

That pattern looked like MLT 7.40 might be extending both overlays across their
expected boundaries.

It was plausible because the Windows foundation documentation had already
called out MLT 7.22 vs 7.40 as a version seam that must not be treated casually.

But it was not enough evidence to change engine behavior.

---

## 5. The rule that prevented a false fix

At this point there were two easy but bad responses:

1. relax the frame assertions so Rocky goes green;
2. change the conform calculations to compensate for an assumed MLT 7.40
   difference.

Neither was justified.

The export had completed successfully. The expected interior frames were still
reported as overlay frames. The failure was specifically at the sampled
boundaries.

So the next question was not:

> How do we make the test pass?

It was:

> What pixels are actually present at those exact output frames?

That distinction matters. A cross-version test failure is evidence that
something differs. It is not evidence about which subsystem is wrong.

---

## 6. First diagnostic attempt: the diagnostic changed the test

The first diagnostic revision tried to refactor the boolean
`frame_is_magenta()` helper into a reusable RGB sampling helper.

The result was worse:

```text
RGB sample unavailable
```

for every requested frame, and the frame-rate section went from four failures
to eight.

That was a diagnostic mistake, not a new media-engine regression.

The instrumentation had altered the same path that determined the assertions,
so a failure in the new sampler contaminated the thing being measured.

The next revision restored the original boolean assertion path and made RGB
printing observation-only.

That preserved the original four-failure shape, but the RGB diagnostic still
could not retrieve sample bytes.

This became the next lesson:

> Diagnostic code should not silently replace the predicate it is supposed to
> explain.

---

## 7. Prove the encoded export before blaming frame selection

The next diagnostic looked at the exported file itself.

The layered 29.97 export reported:

```text
codec_name=h264
width=640
height=360
pix_fmt=yuv420p
r_frame_rate=30000/1001
avg_frame_rate=30000/1001
duration=6.039367
nb_frames=181
nb_read_frames=181
```

And both checks succeeded:

```text
ffprobe exit: 0
first-frame decode exit: 0
```

That eliminated a large class of possible explanations.

The export was not empty.

It did not lack a video stream.

It was not malformed in a way that prevented FFmpeg from decoding it.

It had 181 readable H.264 frames at the requested 30000/1001 output rate.

So the problem had moved again:

> The file is healthy. The selected-frame sampling pipeline is not.

---

## 8. The hidden bug in the old color probe

The original conform test sampled a selected output frame with FFmpeg and piped
three raw RGB bytes through `od` and `awk`.

Conceptually:

```text
ffmpeg selected frame
    -> raw RGB bytes
    -> od
    -> awk color threshold
```

The test expected `awk` to distinguish:

```text
magenta
vs.
not magenta
```

But there was an unrepresented third state:

```text
no sample bytes arrived at all
```

The awk program attempted to reject malformed rows with an `NF` check, but if
there is no input record at all, awk executes no record action and exits
successfully by default.

That means an empty upstream sample can collapse into the same shell exit status
as a successful magenta match.

On the newer Rocky FFmpeg, the particular selected-frame rawvideo pipe could
complete without giving the downstream probe the expected three bytes.

The test was therefore not measuring only color.

It was sometimes measuring:

```text
color OR absence of data
```

and treating both as success.

That explained the strange earlier result where interior overlay frames looked
correct while the boundary behavior looked shifted.

---

## 9. Final sampler: one-pixel PPM with explicit data validation

The robust replacement kept FFmpeg as the frame decoder but stopped using an
unframed raw three-byte pipe.

For each requested output frame, FFmpeg now produces a one-pixel PPM image:

```text
selected output frame
    -> area-average to 1x1
    -> RGB24
    -> PPM image2pipe
```

The C smoke test parses the tiny PPM directly.

It validates:

- the `P6` magic;
- width = 1;
- height = 1;
- max value = 255;
- presence of all three RGB bytes;
- successful child-process exit.

Only after those checks does the sample participate in the magenta predicate.

This became:

```text
0733d02 Sample conform frames through one-pixel PPM
e50d91c Harden conform frame sampling across FFmpeg versions
```

The important semantic change is small:

> Missing sample data now fails closed instead of accidentally looking like a
> positive color match.

---

## 10. The RGB proof

With the PPM sampler in place, the eight key frames finally reported real
values:

```text
frame 22:  RGB 123 130 127 -> not magenta
frame 24:  RGB 253   1 252 -> magenta
frame 80:  RGB 253   1 252 -> magenta
frame 85:  RGB 124 128 128 -> not magenta

frame 118: RGB 127 127 124 -> not magenta
frame 120: RGB 253   1 252 -> magenta
frame 156: RGB 253   1 252 -> magenta
frame 157: RGB 125 126 132 -> not magenta
```

Those values matched the intended conform contract exactly.

For Layer 3:

```text
source START 20 -> output START 24
visible through output frame 84
gone at output frame 85
```

For Layer 2:

```text
source START 100 -> output START 120
inclusive source END 130 -> final visible output frame 156
gone at output frame 157
```

The suspected MLT 7.40 boundary regression was not real.

The engine's frame-rate conform behavior was correct.

The failing component was the old test sampler.

---

## 11. Cleanup and final proof

Once the diagnosis was complete, the temporary stream and RGB logging was
removed.

The robust PPM sampling remained as the actual test implementation.

The cleaned native suite was run again on Rocky and finished green.

The final frame-rate section reported:

```text
PASS video export frame rate (0 failures)
[ok] 25 fps source conforms to 30000/1001 without changing duration
[ok] one source second becomes 30 output frames
```

The earlier sections also remained green:

```text
PASS guards (0 failures)
PASS (0 failures)
PASS parity (0 failures)
PASS layer timing (0 failures)
PASS layer source trim (0 failures)
PASS layer order (0 failures)
PASS video export presets (0 failures)
```

The full Dart/Flutter test suite had already passed 152/152 on this Rocky
checkout before the bounded native compatibility work. The compatibility branch
then changed native C, shell smoke infrastructure, the conform smoke test, and
documentation; the final proof for those changes was the native suite plus
manual application testing.

The real application was then launched with:

```bash
flutter run -d linux
```

Manual verification covered:

- normal video open;
- playback;
- pause/resume;
- scrubbing;
- Explorer thumbnail generation;
- the recently improved thumbnail population speed.

The result was reported as working great.

---

## 12. What actually changed

The final compatibility work had three production/test-infrastructure changes.

### 12.1 Preview image sizing

`native/mlt_bridge.c`

Before:

```c
mlt_image_format_size(...)
```

After:

```c
mlt_image_calculate_size(...)
```

The bridge still validates RGBA and still lets MLT own the byte-count decision.

### 12.2 Private-prefix runtime discovery

The native scripts now include the MLT `libdir` from `pkg-config` in
`LD_LIBRARY_PATH`.

Affected scripts:

```text
tools/thumbnail_smoke.sh
tools/smoke.sh
tools/pts_diag.sh
```

This avoids coupling the scripts to either a system install or a specific Rocky
path.

### 12.3 Frame-rate conform sampling

`native/mlt_export_frame_rate_smoke.c`

The selected-frame color probe now uses a one-pixel PPM image and explicitly
verifies that pixel data exists before classifying the frame.

That makes the test more portable across FFmpeg versions and removes the
empty-input ambiguity of the older rawvideo/awk path.

---

## 13. What did not change

Several things are just as important because they define the scope of this work.

The change did **not**:

- remove the process-wide thumbnail serialization lock;
- raise Explorer thumbnail concurrency;
- change representative-thumbnail selection behavior;
- change the 25 -> 30000/1001 conform math;
- add an MLT 7.40-specific timing workaround;
- weaken any conform boundary assertion;
- hard-code the Rocky MLT installation path;
- suppress compiler deprecation warnings;
- hard-code RGBA copy size;
- raise the Linux CI baseline from MLT 7.22.x to MLT 7.40;
- prove Windows export parity.

This remained a compatibility-hardening pass, not an implicit version migration.

---

## 14. Why the journey matters

The most useful result was not merely that Rocky now passes.

The journey identified three categories of compatibility that are easy to mix
together.

### API compatibility

A newer dependency can turn a previously tolerated API into a hard build
failure without changing runtime semantics.

The correct response is to find the supported API that preserves the original
ownership contract.

### Loader compatibility

The compiler and runtime loader are separate systems.

A build found through `pkg-config` does not imply the resulting executable can
find the same shared libraries when launched.

Test infrastructure should derive both compile-time and runtime discovery from
the installation rather than from workstation-specific paths.

### Probe compatibility

A test can fail because its measurement mechanism changed underneath it.

That is especially dangerous when the test reduces several physical states to a
single shell exit code.

For media probes, distinguish at least:

```text
expected pixels
unexpected pixels
no pixels
decoder failure
probe failure
```

Do not let absence of evidence silently become a positive match.

---

## 15. Diagnostic rules worth preserving

This investigation reinforced several practical rules for future native work.

### Keep the first failure narrow

The original failure was a deprecation warning promoted to an error.

Fix that exact problem before changing unrelated engine behavior.

### Do not use warning suppression as version compatibility

If both supported versions expose a non-deprecated API that preserves the
contract, use it.

### Do not confuse build success with launch success

For private-prefix native libraries, verify the runtime loader path explicitly.

### Do not weaken a correctness assertion because a new dependency version fails it

First prove what the output actually contains.

### Instrument around the test before rewriting the test

The first RGB diagnostic temporarily violated this rule and turned four failures
into eight. That was useful as a reminder: diagnostics should initially observe,
not redefine.

### Positive probes need a valid-data proof

A test that answers “is this magenta?” must first answer “did I receive a
pixel?”

### Cross-version success does not automatically change the baseline

Rocky MLT 7.40 passing is valuable evidence.

It does not by itself change the project's supported Linux CI contract.

---

## 16. Final state

The compatibility branch was documented and merged through PR #9.

Final merge:

```text
da7bbc3
```

At the end of the journey:

```text
Ubuntu/Linux baseline: MLT 7.22.x
Rocky verification:    MLT 7.40.0
Rocky native smoke:    PASS
Rocky thumbnail smoke: PASS
29.97 conform:         PASS
Manual app check:      PASS
```

The important conclusion is narrower than “7.22 and 7.40 are identical.”

They are not assumed to be interchangeable.

The conclusion is:

> The current MLT Player Linux native engine and thumbnail/export correctness
> contracts survived this Rocky MLT 7.40 verification once the deprecated API,
> private-prefix loader path, and FFmpeg-dependent test sampler were hardened.

That is a much stronger result than merely getting the build green, because the
verification preserved the existing behavioral assertions instead of weakening
them.
