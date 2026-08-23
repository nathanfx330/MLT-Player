<!-- docs/poc-9-export-formats-and-hardening.md -->

# POC 9: Export Formats and Hardening

## Field notes from turning the first export proof into a dependable output system

The first MLT Player export proof answered one question:

```text
Can a Flutter/MLT player render a selected source range to a file
without taking over the live playback graph?
```

The answer was yes.

POC 9 then had to answer the harder questions:

```text
Can the same export architecture support movie, still, image-sequence,
and audio-only output?

Can it preserve the source's display geometry?

Can it avoid inventing streams that do not exist?

Can cancellation leave the filesystem clean?

Can an image sequence prove that every requested frame was written?

Can those rules be tested against deterministic media instead of whatever
file happens to be nearby?
```

That hardening work is the part of POC 9 that is easiest to lose if the project
is remembered only as "we added MP4 export."

This document records the mature POC 9 export architecture immediately before
POC 10 introduced multitrack tractors and composition-aware export.

The implementation described here was developed and tested against **MLT
7.22.0 on Linux**.

---

# 1. Where POC 9 sits in the project

By the time export work began, MLT Player already had:

```text
media open / probe
external Flutter texture preview
MLT-owned audio
frame-accurate transport
J / K / L shuttle
Play All Frames
metadata inspection
In / Out selection
non-destructive trim
Undo / Redo
```

The editing model was deliberately small.

The export model had to preserve that same philosophy:

```text
open -> inspect -> mark or trim -> export -> close
```

The important progression was:

```text
first background MP4 proof
        ↓
current-frame PNG
        ↓
PNG image sequence
        ↓
WAV audio-only export
        ↓
grouped Export UI
        ↓
output-policy hardening
        ↓
sequence ownership + validation
        ↓
deterministic regression fixtures
```

POC 9 therefore became less about "adding codecs" and more about defining what
an export operation promises.

---

# 2. The foundational rule: export never steals the playback graph

The preview graph already has a difficult job:

```text
source producer
    ↓
sdl2_audio consumer
    ↓
MLT render workers
    ↓
RGBA frame handoff
    ↓
Flutter external texture
```

Attaching an encoder to that live producer would couple playback state to file
output and create questions such as:

```text
What happens if the user seeks while exporting?
What happens if playback is running at -4x?
Who owns the producer In/Out?
Who gets to stop the consumer?
Can an export rebuild its profile without disturbing preview?
```

POC 9 avoids all of those questions.

Every export runs on a background worker with a separate graph:

```text
LIVE PREVIEW                       OFFLINE EXPORT

playback profile                   export profile
playback producer                  fresh export producer
sdl2_audio consumer                avformat consumer
Flutter texture                    destination file(s)
```

The two paths share MLT's initialized factory, but they do not share live
producer or consumer objects.

That remained the correct rule later in POC 10, when the export graph became a
freshly rebuilt tractor instead of a fresh single producer.

The lesson:

> Preview state and export state may describe the same movie, but they should
> not require ownership of the same live MLT graph.

---

# 3. Export repeats probe -> profile -> reopen

The export worker does not blindly inherit the preview window's dimensions or
an arbitrary application profile.

It repeats the same source discovery pattern used by playback:

```text
create temporary producer
probe producer
derive MLT profile from producer
close temporary producer
reopen source against derived profile
```

Conceptually:

```c
mlt_profile export_profile = mlt_profile_init(NULL);

mlt_producer probe =
    mlt_factory_producer(export_profile, NULL, source_path);

mlt_producer_probe(probe);
mlt_profile_from_producer(export_profile, probe);
mlt_producer_close(probe);

mlt_producer export_producer =
    mlt_factory_producer(export_profile, NULL, source_path);
```

This keeps source timing, geometry, frame rate, and display information tied to
the media rather than to Flutter layout.

---

# 4. The range model is frame-inclusive

MLT Player's selection model is frame-based and inclusive.

For example:

```text
In  = 10
Out = 19
```

means ten frames, not nine.

The export worker receives source-frame bounds and applies them to the export
producer with:

```c
mlt_producer_set_in_and_out(
    export_producer,
    in_frame,
    out_frame
);
```

The producer is then sought to its new local position zero and played forward
at normal speed for offline rendering.

The POC 9 application policy was originally:

```text
marked In / Out, when present
otherwise active trimmed clip
otherwise whole active clip
```

Later UI work made range selection explicit, but the important POC 9 lesson is
the same: export boundaries are exact source frames and the UI/application owns
the meaning of the logical clip.

---

# 5. Export is offline rendering, so frame dropping is wrong

Preview may need to sacrifice frames to stay synchronized to wall-clock audio.
Export must not.

Every POC 9 export consumer therefore uses:

```text
real_time = -1
```

which tells MLT not to drop frames merely to maintain real-time playback.

The encoder is also configured so it can terminate cleanly when the producer
reaches the requested range boundary.

The conceptual distinction is:

```text
preview:
correct timing may matter more than showing every frame

export:
every requested frame matters more than wall-clock speed
```

This is the same MLT `real_time` property used by Play All Frames, but the
reason is stronger for export: a missing frame is an incorrect result, not just
a playback compromise.

---

# 6. The fixed MP4 preset proved policy before configurability

POC 9 deliberately used one known-good movie preset before exposing a codec
chooser.

The proven preset is:

```text
Container:    MP4
Video codec:  libx264 / H.264
Pixel format: yuv420p
Quality:      CRF 18
Preset:       medium
Fast start:   +faststart
Audio codec:  AAC when the composition/source actually has audio
Output:       progressive
MLT:          real_time = -1
```

Representative consumer properties are:

```c
mlt_properties_set(properties, "f", "mp4");
mlt_properties_set(properties, "vcodec", "libx264");
mlt_properties_set(properties, "pix_fmt", "yuv420p");
mlt_properties_set(properties, "preset", "medium");
mlt_properties_set_int(properties, "crf", 18);
mlt_properties_set(properties, "movflags", "+faststart");
```

The architectural lesson is more important than these particular settings:

> Prove one end-to-end delivery path before turning encoder options into UI.

A codec menu built before the render lifecycle is trustworthy only multiplies
failure modes.

---

# 7. Do not manufacture an audio stream for video-only media

The earliest fixed MP4 path could easily have been written as:

```text
always configure AAC
```

but that silently changes the media model for a video-only source.

POC 9 hardened the export graph so the worker determines whether the source
actually contains audio.

When MLT exposes `audio_index`, that is the first source of truth.

When a producer does not expose `audio_index`, the bridge can inspect the
available `meta.media.N.stream.type` topology before falling back.

The MP4 consumer then behaves as follows:

```text
source has audio
    -> configure AAC

source has no audio
    -> disable audio output
```

This sounds small, but it establishes a useful project rule:

> Output should not acquire a stream merely because a preset knows how to
> encode that stream type.

The deterministic `video_only.mp4` fixture exists specifically to protect this
behavior.

---

# 8. Interlaced input has an explicit progressive-output policy

MLT Player presents progressive frames to Flutter.

POC 9 made movie export follow the same policy instead of leaving field handling
implicit.

The MP4 path configures the export consumer with the bridge's selected
MLT deinterlacer, field-order handling, and progressive output flag.

In the current build the deinterlacer is:

```text
onefield
```

The policy is therefore explicit:

```text
interlaced source
    ↓
MLT deinterlacing/render path
    ↓
progressive MP4 output
```

Whether a later version chooses a better deinterlacer is a quality decision.
The important engineering decision is that field treatment is not left as an
accidental FFmpeg default.

The regression fixture `interlaced_av.mkv` exists to make this testable with
`ffprobe`.

---

# 9. Current-frame PNG is an export operation, not a screenshot

A tempting implementation for "Export Current Frame" is to save whatever RGBA
bytes happen to be in the Flutter texture.

POC 9 deliberately does not do that.

The texture is a preview artifact. It may have been scaled for the window, may
have different timing semantics, and is not the source graph.

Instead the application determines the exact visible source frame, parks
transport on that frame, and starts a one-frame offline export from the media
graph.

The user-visible contract is:

```text
invoke current-frame export
        ↓
identify the visible source frame
        ↓
park playback on that exact frame
        ↓
open the save dialog
        ↓
render that source frame to PNG
```

The save dialog therefore cannot cause playback to drift away from the frame
the user thought they were exporting.

The lesson:

> A frame export should be tied to timeline identity, not to whichever preview
> buffer happened to be newest.

---

# 10. PNG output uses display geometry, not blindly stored pixel dimensions

Anamorphic media exposed an important difference between "source pixels" and
"the image the user sees."

Consider a 1440x1080 source carrying a 16:9 display aspect ratio.

Writing those stored pixels directly to a square-pixel PNG produces a squeezed
image.

For PNG output, POC 9 clones the source profile and creates a square-pixel image
profile whose width is derived from the source display aspect:

```text
image width  = image height × display aspect
SAR          = 1:1
progressive  = true
```

So the 1440x1080 anamorphic 16:9 fixture produces approximately:

```text
1920x1080 PNG
```

rather than:

```text
1440x1080 squeezed PNG
```

The source profile remains untouched; only the PNG consumer receives the
square-pixel clone.

This is one of the strongest reasons not to equate a video frame's encoded
storage geometry with a still image's presentation geometry.

---

# 11. PNG scaling uses an explicit high-quality offline resampler

Preview and export have different performance budgets.

For PNG output POC 9 uses:

```text
rescale = lanczos
```

instead of treating preview's faster scaling choice as the universal policy.

That separation is intentional:

```text
preview scaling
    optimized for responsive playback

offline PNG scaling
    optimized for output quality
```

Again, the larger lesson is that preview properties should not become export
properties merely because both paths eventually request an image.

---

# 12. PNG keeps RGBA so source alpha is not destroyed prematurely

PNG export requests RGBA and writes an RGBA-capable PNG pixel format.

POC 9 did not attempt to guess alpha semantics from codec names and then flatten
transparency away.

The rule was simpler:

```text
if the decoded source provides alpha,
preserve it in the PNG result
```

The harder question of whether a source should be interpreted as straight or
premultiplied alpha was intentionally deferred until POC 10, where alpha became
part of actual layer compositing.

That sequencing was useful. POC 9 preserved information; POC 10 later defined
how that information participates in a composition.

---

# 13. Image-sequence export owns a fresh directory

A movie export owns one destination file.

An image sequence owns many files, so cancellation and cleanup become much more
dangerous.

The POC 9 UI creates a unique directory for the sequence, with a shape such as:

```text
movie_frames/
    frame_000001.png
    frame_000002.png
    frame_000003.png
    ...
```

The bridge then enforces a stronger invariant:

> A sequence export may start only when the supplied destination directory
> already exists and is empty.

That moves ownership from a UI convention to a native export precondition.

Without that invariant, code that tries to "clean up a cancelled export" risks
deleting files that existed before the export started.

---

# 14. The sequence filename pattern is one-based and deterministic

MLT's avformat/image2 consumer is given a pattern equivalent to:

```text
frame_%06d.png
```

with:

```text
start_number = 1
update       = 0
```

The resulting sequence is therefore intentionally:

```text
frame_000001.png
frame_000002.png
...
```

not zero-based and not dependent on source frame numbering.

The sequence numbers identify files in the exported result, while In/Out still
identify exact source-frame boundaries.

Those are different namespaces and keeping them separate makes validation much
simpler.

---

# 15. Sequence completion is validated, not assumed

A consumer reaching a stopped state is not sufficient proof that a requested
image sequence is complete.

POC 9 validates both producer progress and filesystem results.

For the owned PNG files it verifies:

```text
expected file count exists
minimum sequence number == 1
maximum sequence number == expected frame count
every owned PNG has non-zero file size
producer reached the expected final position
```

Because directory entries are unique, this combination is useful:

```text
count = N
minimum = 1
maximum = N
```

If all three are true, there cannot be a missing number inside the sequence.

For example, five unique files with minimum 1 and maximum 5 cannot omit frame 3
without either reducing the count or introducing a number outside the allowed
range.

This is much stronger than checking only whether the final PNG exists.

---

# 16. Cancellation cleanup removes only output the export owns

The cancellation promise for a single-file export is straightforward:

```text
success
    -> finished file remains

failure or cancel
    -> partial destination file is removed
```

For an image sequence, POC 9 applies the same principle more carefully.

Cleanup removes only filenames belonging to the export's known frame pattern.
The directory itself is removed only if it becomes empty.

That means the native layer never interprets "cancel this sequence" as
"recursively delete whatever happens to be inside this directory."

The rule is:

> Cleanup authority should be no broader than output ownership.

That is one of the most important hardening lessons in POC 9.

---

# 17. WAV export uses a professional uncompressed interchange target

Instead of introducing a menu of audio codecs, POC 9 established one dependable
audio-only output:

```text
Container: WAV
Codec:     PCM signed 24-bit little-endian
Video:     disabled
```

The final FFmpeg encoder is:

```text
pcm_s24le
```

MLT does not have a 24-bit internal render-buffer format, so the bridge requests
signed 32-bit integer audio internally:

```text
mlt_audio_format = s32le
```

and lets FFmpeg write the final 24-bit samples.

This distinction matters:

```text
MLT render format != final file sample width
```

Trying to force a nonexistent 24-bit internal MLT sample type would solve the
wrong layer of the pipeline.

---

# 18. Preserve source sample rate and channel count when MLT exposes them

The WAV path inspects the selected source audio stream for:

```text
meta.media.N.codec.sample_rate
meta.media.N.codec.channels
```

When those values are available and valid, the consumer receives matching
frequency and channel settings.

When they are unavailable, the bridge leaves MLT's defaults alone instead of
inventing source metadata.

This follows the same rule already used by the Inspector:

> Missing metadata is preferable to plausible-looking fabricated metadata.

The deterministic `pcm24.wav` fixture makes codec/sample-format behavior easy to
inspect separately from arbitrary production media.

---

# 19. The grouped Export control separates output type from the operation

Once movie, image sequence, and audio-only output all existed, three unrelated
buttons would have made export state harder to understand.

POC 9 introduced one grouped/split Export control:

```text
Export
    Export Video
    Export Image Sequence
    Export Audio (WAV)
```

The selected mode is persistent for the primary `Ctrl+E` action.

Current-frame PNG remains separate because it is a snapshot operation rather
than a range-export mode.

This distinction mirrors the underlying model:

```text
range export
    consumes a timeline interval

current-frame export
    consumes one identified timeline frame
```

---

# 20. A one-shot shortcut should not silently change persistent mode

The image-sequence shortcut is intentionally a one-shot action.

The user can invoke image-sequence export directly without changing whichever
mode is selected in the grouped Export control.

This became a small but useful UI invariant:

```text
direct shortcut = perform this operation once

mode selection = change what the general Export command means later
```

The distinction prevents a shortcut from leaving behind surprising UI state.

It is also explicitly part of the manual regression checks.

---

# 21. Progress is producer-position based

The native export worker publishes progress from the export producer's current
position relative to the requested frame count.

Conceptually:

```c
progress =
    (position + 1) /
    total_frames;
```

The worker stores that value in a small mutex-protected export-status block.
Dart polls that block rather than receiving callbacks from the encoding thread.

This keeps the threading model simple:

```text
encoder thread
    updates plain native status

Flutter/Dart
    polls status on its own schedule
```

No encoder thread needs to enter Dart or manipulate Flutter UI state.

---

# 22. Cancellation is cooperative

The UI does not kill the encoder thread.

It sets a cancellation flag.

The worker checks that flag while the consumer is running and requests a normal
MLT consumer stop.

That gives the worker one cleanup path for:

```text
normal EOF
user cancellation
startup failure
encoding failure
```

The worker remains responsible for closing the consumer, graph objects, owned
profiles, temporary target strings, and partial output.

Cooperative cancellation was deliberately chosen over asynchronous thread
termination because media encoders and muxers need an opportunity to release
their own resources coherently.

---

# 23. Stop the consumer even if it already stopped itself

At EOF the MLT consumer may already report that it is stopped.

POC 9 still calls:

```c
mlt_consumer_stop(export_consumer);
```

before closing it.

This is important because the stop path joins worker activity and gives the
muxer/encoder lifecycle a clean completion point before object destruction.

For container formats in particular, the final trailer is part of having a
valid file.

A useful lifecycle rule from this project is:

> "The service says it stopped" and "I have completed the stop/join lifecycle"
> are not always the same statement.

---

# 24. A successful export is not defined only by absence of an error

POC 9 tightened completion checks by output kind.

For a single PNG frame, the useful completion evidence is that the requested
file exists and contains data.

For MP4 and WAV, the worker checks that:

```text
producer reached the requested final position
and
output file exists with non-zero data
```

For PNG sequence, the stronger sequence validation described above is used.

This changes the definition of success from:

```text
no API call returned an error
```

into:

```text
the requested media interval was consumed
and the expected filesystem result exists
```

That distinction is worth preserving in any future export backend.

---

# 25. Deterministic fixtures turned export policy into regression tests

Real production media is useful for discovering bugs but poor for documenting
what a test is supposed to prove.

POC 9 added `tools/generate_export_fixtures.sh`, which creates a compact FFmpeg
fixture set:

```text
progressive_av.mp4
interlaced_av.mkv
video_only.mp4
anamorphic_1440x1080_16x9.mp4
pcm24.wav
```

Each file has one job.

## `progressive_av.mp4`

A conventional A/V source for the baseline MP4 path.

## `interlaced_av.mkv`

A deliberately interlaced A/V source for testing progressive export policy.

## `video_only.mp4`

A source with no audio stream for verifying that export does not manufacture
AAC.

## `anamorphic_1440x1080_16x9.mp4`

A 1440x1080 source with SAR 4:3 and 16:9 display aspect for proving that PNG
output becomes display-correct square-pixel geometry.

## `pcm24.wav`

A 48 kHz 24-bit PCM source for audio export/interchange checks.

The script also runs `ffprobe` summaries after generation so the fixtures
self-describe the properties they are intended to exercise.

---

# 26. Useful POC 9 regression checks

The fixture set supports very small, very specific assertions.

## Video-only export contains no audio stream

```bash
ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name \
  -of default=noprint_wrappers=1 exported_video_only.mp4
```

Expected: no audio stream output.

## Interlaced input produces progressive MP4

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=field_order \
  -of default=noprint_wrappers=1 exported_interlaced.mp4
```

Expected: progressive output field order.

## Anamorphic source produces display-sized PNG

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height \
  -of default=noprint_wrappers=1 exported_frame.png
```

For the included anamorphic fixture the expected result is approximately:

```text
1920x1080
```

## WAV output is 24-bit PCM

```bash
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_fmt,bits_per_raw_sample,sample_rate,channels \
  -of default=noprint_wrappers=1 exported_audio.wav
```

Expected codec:

```text
pcm_s24le
```

Also verify manually that the one-shot image-sequence shortcut does not change
the persistent grouped Export mode.

---

# 27. POC 9 changed the meaning of "export graph"

At the beginning of POC 9, the export graph could be summarized as:

```text
fresh source producer
    ↓
avformat consumer
```

By the end of POC 9, "export graph" had acquired a stronger set of rules:

```text
fresh source-derived profile
fresh producer
exact frame range
output-kind-specific consumer profile
output-kind-specific codec/pixel/audio policy
no frame dropping
progress state
cooperative cancellation
completion validation
owned-output cleanup
```

That architecture is what made POC 10 possible.

When the project later added a second layer, the encoder lifecycle did not need
to be reinvented. Only the source side of the export graph changed:

```text
POC 9:
fresh source producer

POC 10:
freshly reconstructed composition tractor
```

Everything downstream could continue to use the same output-kind, progress,
cancellation, cleanup, and validation machinery.

---

# 28. Things POC 9 deliberately did not solve

POC 9 proved dependable output, not a complete render-settings system.

The following remained intentionally outside the proof:

```text
codec/preset chooser
explicit output frame-rate control
arbitrary output dimensions
color-management UI
arbitrary audio-format menu
multi-track composition
saved project/interchange format
```

The absence of those options was deliberate.

The project first needed to know that one MP4, one PNG path, one image-sequence
path, and one WAV path had predictable semantics.

---

# 29. The POC 9 export recipe

For a normal range export, the mature construction order is approximately:

```text
capture requested source-frame range
        ↓
create export profile
        ↓
probe source
        ↓
derive profile from source
        ↓
reopen fresh export producer
        ↓
apply inclusive In / Out
        ↓
prepare output-specific consumer profile
        ↓
create avformat consumer
        ↓
configure MP4 / PNG / sequence / WAV policy
        ↓
set real_time = -1
        ↓
prepare/validate destination ownership
        ↓
connect consumer to export producer
        ↓
start consumer
        ↓
poll progress + cancellation
        ↓
stop/join consumer
        ↓
validate completed output
        ↓
keep successful result
or remove only owned partial output
```

Current-frame PNG uses the same machinery with a one-frame range after the
application identifies and parks the visible source frame.

---

# 30. Final POC 9 lessons

The most reusable lessons from this phase are:

1. **Export should own an independent MLT graph.**
   Do not borrow the live playback producer.

2. **Use source frames as the range contract.**
   Avoid converting edit boundaries back and forth through milliseconds.

3. **Offline output should not drop frames.**
   `real_time = -1` belongs in the export policy.

4. **Do not manufacture streams.**
   A video-only source should remain video-only unless the user explicitly asks
   for something else.

5. **Presentation geometry and storage geometry are not the same thing.**
   Anamorphic video needs square-pixel conversion when becoming a normal PNG.

6. **A still export is not a screenshot.**
   Render the identified source frame from the media graph.

7. **Use higher-quality scaling offline when the performance budget allows it.**

8. **Preserve alpha before you have a reason to destroy it.**

9. **Directory ownership must be explicit for image sequences.**

10. **Cancellation cleanup should remove only files the job owns.**

11. **Validate the result, not merely the API calls.**
    Producer completion plus filesystem evidence is a stronger success signal.

12. **MLT's internal audio sample format does not have to equal the final file
    sample width.**

13. **Stop/join the consumer before closing it, even at normal EOF.**

14. **Build deterministic fixtures for every policy decision that matters.**

15. **Prove output semantics before building a large preset UI.**

POC 9 began with a working H.264 export and ended with something much more
important: a defined contract for offline rendering.

That contract is what POC 10 later reused when the thing being rendered stopped
being one source and became an MLT tractor composition.
