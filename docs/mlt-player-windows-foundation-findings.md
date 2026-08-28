# MLT Player on Windows: Native Foundation Findings and Porting Notes

**Status:** Windows media foundation proven  
**Date:** August 27, 2026  
**Reference MLT version:** 7.40.0 (MSYS2 UCRT64 package)  
**Reference Flutter version:** 3.41.8 stable  
**Reference architecture:** Windows 11 x64

---

## 1. Why this work was done

MLT Player was already a working Linux application with a native MLT media engine, Flutter UI, SDL2 audio, and a Linux-specific Flutter/OpenGL texture path.

The Windows port raised a basic architectural question before any serious application work should begin:

> Can MLT itself provide the same fundamental media-engine behavior natively on Windows, or would Windows require a different media backend or a fundamentally different application architecture?

Rather than porting the full MLT Player immediately, the Windows work was deliberately split into two stages:

1. **Native MLT feasibility tests**
2. **A stripped-down Windows reference player**

The reference player intentionally excluded Explorer, Redleaf, projects, layers, compositing, export, thumbnails, and other higher-level MLT Player features.

The point was to isolate the media stack:

```text
Flutter
  ↓
Dart/native boundary
  ↓
MLT
  ↓
FFmpeg decode + SDL2 audio
  ↓
decoded RGBA frame
  ↓
Windows Flutter texture
```

This approach proved valuable. It allowed Windows-specific problems to be found and fixed without disturbing the known-good Linux application.

---

## 2. Core architectural conclusion

The Windows experiments support the same high-level architecture already used by MLT Player:

```text
Flutter owns the application.
MLT owns the media.
The native bridge owns the boundary.
```

Windows does **not** require a separate media engine.

The intended long-term structure remains:

```text
                  shared MLT engine
                         |
              +----------+----------+
              |                     |
       Linux presentation     Windows presentation
              |                     |
     Flutter GL texture       Flutter Windows texture
```

The important lesson is that platform-specific presentation should be separated from the shared media engine.

The Linux implementation currently mixes MLT engine behavior with Linux Flutter/OpenGL presentation in `native/mlt_bridge.c`. The Windows work showed that those responsibilities can and should be separated.

A likely eventual structure is:

```text
native/
    mlt_bridge.c
    mlt_composition.c
    mlt_export.c
    mlt_thumbnail.c

    platform/
        linux/
            mlt_texture_linux.c

        windows/
            mlt_texture_windows.cc
```

The exact filenames can change. The principle should not.

### Pre-W4 gate: resolve or contain the MLT version split

The Windows foundation was validated against **MLT 7.40.0**. The Linux project is not merely "known to work" on an older release: current CI is explicitly named `MLT 7.22 smoke + parity`, hard-fails if `mlt-framework-7` is not in the **7.22.x** series, and tells maintainers to run `tools/pts_diag.sh` before raising that baseline.

That makes version skew a porting risk, not a footnote.

Before shared engine refactoring begins, the project should choose and document one of these strategies:

```text
A. Raise the Linux baseline to a candidate newer MLT version,
   but only after running:
       tools/pts_diag.sh
       tools/smoke.sh
       preview/export parity
       export preset tests
       export frame-rate conform tests

or

B. Keep Linux on 7.22.x temporarily and validate shared native changes
   against both the Linux 7.22 behavior and the Windows 7.40 behavior
   until the baseline can be unified.
```

The key rule is:

> Do not refactor shared media-engine code across the Linux/Windows seam while treating 7.22 and 7.40 as interchangeable.

The existing PTS diagnostic is especially relevant because it was deliberately kept diagnostic rather than promoted to the zero-warning CI gate. A candidate baseline that changes audio-flush behavior should be characterized before the shared bridge is reorganized.

---

# Part I — Native Windows MLT feasibility

## 3. Windows development environment

The reference Windows machine used:

```text
Windows 11 Home 25H2 x64
Flutter 3.41.8 stable
Dart 3.11.5
Visual Studio Community 2026
Windows SDK 10.0.26100.0
CMake 3.31.3
Git for Windows
MSYS2 UCRT64
GCC 16.2.0
MLT 7.40.0
FFmpeg
```

MSYS2 UCRT64 was used as the native C build environment.

This is important:

> MSYS2 UCRT64 is not WSL, a VM, or Linux emulation.

The resulting `.exe` and `.dll` files are ordinary native Windows x64 binaries using the Windows UCRT.

Path equivalence used during development:

```text
Windows:  C:\dev\hello-mlt
MSYS2:    /c/dev/hello-mlt

Windows:  C:\msys64\ucrt64\bin
MSYS2:    /ucrt64/bin
```

The MLT pkg-config package name is:

```text
mlt-framework-7
```

not:

```text
mlt-framework
```

Example:

```bash
pkg-config --modversion mlt-framework-7
```

Result:

```text
7.40.0
```

Example compiler flags:

```bash
pkg-config --cflags --libs mlt-framework-7
```

Typical result:

```text
-IC:/msys64/ucrt64/include/mlt-7 -lmlt-7
```

---

## 4. Test media fixture

A deterministic three-second test file was generated:

```bash
ffmpeg -y \
  -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 3 \
  -c:v libx264 -pix_fmt yuv420p \
  -c:a aac \
  sample.mp4
```

Expected properties:

```text
Video:     H.264
Audio:     AAC
Size:      1280x720
Frame rate: 30 fps
Frames:    90
Duration:  3.0 seconds
Tone:      440 Hz
```

This fixture was useful because video correctness was visually obvious and audio output could be confirmed immediately by hearing the tone.

---

## 5. W0 — MLT initialization and media inspection

**Result: PASS**

The first test proved that native Windows code could:

- initialize the MLT factory
- load MLT services
- open H.264/AAC media
- inspect source dimensions
- inspect source frame rate
- obtain the correct timeline length

### Important discovery: source profile probing

The first implementation created the producer using the default MLT profile.

That caused the three-second, 30 fps source to initially behave as though it were a PAL 25 fps timeline.

The incorrect result was approximately:

```text
75 frames
2.5 seconds
```

The source itself was correct:

```text
90 frames
3.0 seconds
30 fps
```

### Correct pattern

Use a two-pass open:

```text
1. Create a temporary/default profile.
2. Open a probe producer.
3. Call mlt_profile_from_producer(profile, probe).
4. Close the probe.
5. Reopen the producer using the detected profile.
```

After doing that:

```text
Width:    1280
Height:   720
FPS:      30.000000
Frames:   90
Duration: 3.000 seconds
```

### Lesson

Do not assume the initial/default MLT profile matches the media.

For ordinary source playback, derive the source profile before creating the real playback producer.

---

## 6. Windows MLT runtime discovery

Another important issue appeared immediately.

Calling:

```c
mlt_factory_init(NULL)
```

from an executable located at:

```text
C:\dev\hello-mlt
```

caused the relocatable Windows MLT build to look for runtime content around:

```text
C:\dev\lib\mlt
C:\dev\share\mlt
```

instead of the MSYS2 installation.

For the feasibility tests the MLT repository was therefore initialized explicitly using:

```text
C:/msys64/ucrt64/lib/mlt
```

and the data/profile paths were supplied as:

```text
MLT_DATA=C:/msys64/ucrt64/share/mlt
MLT_PROFILES_PATH=C:/msys64/ucrt64/share/mlt/profiles
```

### Lesson

Windows runtime discovery must be treated as a packaging responsibility.

A standalone application needs a deliberate layout for:

```text
MLT framework DLL
MLT modules
MLT data
MLT profiles
FFmpeg DLLs
SDL2
other required dependencies
```

Do not depend on MLT guessing the correct installation root.

---

## 7. Optional MLT module warnings

The MSYS2 MLT installation emitted warnings for some optional modules whose transitive dependencies were unavailable.

Examples encountered included:

```text
glaxnimate-qt6
plus
qt6
resample
rnnoise
rtaudio
rubberband
sox
```

These warnings did **not** prevent the tested playback path from working.

The required paths for the foundation were:

```text
loader/core
avformat
sdl2_audio
```

### Lesson

An MLT startup warning is not automatically a fatal error.

Determine whether the failed service is actually part of the application's required media path before treating it as a blocker.

For production packaging, missing optional modules should still be intentionally handled rather than ignored blindly.

---

## 8. W1 — Actual video frame decoding

**Result: PASS**

The next test:

- opened the source
- sought to frame 45
- requested a real MLT frame
- called `mlt_frame_get_image`
- requested RGB pixels
- wrote the frame to a PPM file
- converted the PPM to PNG for visual inspection

Result:

```text
[ok] Seeking to frame 45
[ok] MLT frame object obtained
[ok] Decoded RGB frame: 1280x720
[ok] Wrote frame.ppm

PASS: MLT decoded an actual video frame on Windows.
```

The rendered `testsrc2` pattern was visually correct.

### Lesson

The CPU-frame path needed for a Flutter Windows texture is viable.

MLT can decode real source frames on native Windows and expose the pixels to application-owned code.

---

## 9. W2 — Headless transport

**Result: PASS**

The headless transport test exercised:

```text
open
seek
play
pause
seek while paused
close
```

Playback advanced:

```text
10
11
12
13
14
15
16
17
18
19
```

Paused pulls remained stationary:

```text
20
20
```

Seek while paused was exact:

```text
requested 60
received  60
```

The test forced image evaluation on every frame pull, so it was not merely manipulating timeline metadata.

### Lesson

MLT's producer transport behaves correctly on native Windows without an MLT-created playback window.

This is important because Flutter, not MLT, should own the application window and video presentation.

---

## 10. W3 — Windows audio using `sdl2_audio`

**Result: PASS**

MLT's Windows installation exposed:

```text
sdl2
sdl2_audio
```

This was especially useful because the Linux MLT Player already uses `sdl2_audio`.

A direct `melt` test successfully produced the 440 Hz tone.

### `terminate_on_pause` observation

The command:

```bash
melt sample.mp4 -consumer sdl2_audio terminate_on_pause=1
```

reached the last frame:

```text
Current Position: 89
```

but did not reliably return to the command prompt automatically.

This was not treated as a media failure.

Instead it established a design rule:

> The application should explicitly own consumer start/stop behavior rather than relying on `terminate_on_pause` to manage its lifecycle.

A dedicated C harness then successfully tested:

- create `sdl2_audio`
- connect it to the producer
- start it
- play audible audio
- pause
- purge buffered media
- seek while paused
- resume
- stop explicitly
- close cleanly

Final result:

```text
PASS: MLT sdl2_audio transport works on Windows.
```

### Lesson

Use:

```text
terminate_on_pause = 0
```

and explicitly control the consumer lifecycle.

---

# Part II — The Windows reference player

## 11. Why a separate reference player was built

After W0-W3, the next step was intentionally **not** to modify MLT Player.

Instead a standalone project was created:

```text
C:\dev\MLT-Windows-Foundation
```

It deliberately contained only the media-player responsibilities.

Excluded:

```text
Explorer
Redleaf
project model
layers
compositing
export
thumbnail pipeline
annotations
application-specific media organization
```

Included:

```text
Open File
Play
Pause
Seek
Frame stepping
J/K/L shuttle
Volume
Media dimensions
Frame rate
Frame count
MLT audio
MLT video
Flutter texture presentation
```

### Lesson

A thin reference implementation is extremely useful when porting a complicated application.

It gives the platform backend a known-good target independent of application complexity.

---

## 12. Windows Flutter texture strategy

The first Windows implementation uses a **CPU pixel-buffer Flutter texture**.

The flow is:

```text
MLT render thread
      ↓
RGBA frame
      ↓
application-owned frame buffer
      ↓
Windows Flutter PixelBufferTexture
      ↓
Flutter Texture widget
```

This was chosen instead of immediately implementing D3D/GPU interop.

### Why

It matches the data MLT already produces.

It is easy to reason about.

It allows the media engine and presentation backend to be debugged separately.

It preserves an upgrade path to GPU-native textures later.

### Lesson

Correct architecture first, GPU optimization later.

The media-engine contract should not depend on the eventual texture implementation.

### 12A. The full application has a richer presentation contract than the foundation player

The stripped-down Windows Foundation player proves ordinary frame delivery, but it deliberately has **no layers, role swaps, composition rebuilds, or Undo/Redo graph restoration**.

The real MLT Player already exposes a presentation protocol through `native/mlt_layer_api.h`:

```text
mlt_bridge_preview_update_begin()
mlt_bridge_preview_update_end()

mlt_bridge_preview_frame_serial()
mlt_bridge_preview_texture_serial()

mlt_bridge_preview_prewarm_layer()
mlt_bridge_preview_prewarm_serial()
```

Those calls are not incidental GL helpers.

They encode application-visible semantics:

```text
freeze publication while the MLT graph is rebuilt
        ↓
publish only a frame from the completed graph
        ↓
distinguish "MLT frame waiting" from "Flutter texture consumed"
        ↓
hold Texture(freeze: true) until replacement presentation is safe
        ↓
preflight the would-be base dimensions before an atomic role swap
```

Therefore the Windows seam is **not** just:

```text
upload RGBA pixels()
```

The platform presentation interface must preserve the freeze/serial/prewarm contract as well.

A useful conceptual interface is:

```text
PresentationBackend
    register / unregister
    publish frame
    begin atomic preview update
    end atomic preview update
    rendered-frame serial
    presented-texture serial
    prewarm future base presentation
    prewarm-complete serial
```

The Linux implementation can continue to satisfy that contract with its double-buffered GL textures.

The Windows implementation may satisfy it differently—for example with CPU pixel-buffer backing storage rather than literal OpenGL preallocation—but it must preserve the **observable transaction semantics**. A no-op stub is not sufficient if Dart composition, Undo/Redo, or role-swap code depends on the serial advancing or on a replacement frame being safely staged.

This is the major seam risk that the reference player could not exercise.

---

## 13. Important playback bug: consumer refresh after changing speed

The first Flutter player could:

- open a video
- display a frame
- pause

but normal Play did not advance continuously.

Strangely, clicking Pause caused the image to advance by one frame.

That symptom isolated the problem.

### Cause

The consumer was started while the producer was at speed:

```text
0.0
```

Changing the producer to:

```text
1.0
```

did not automatically wake the consumer.

The Pause path happened to issue a consumer refresh, which caused another frame to be pulled.

### Fix

Every transport speed change now also wakes/refreshes the consumer.

Conceptually:

```text
set producer speed
        ↓
set consumer refresh
```

The corrected path is shared by:

```text
Play
Pause
J
K
L
reverse/shuttle speed changes
```

### Lesson

Changing producer speed is not always sufficient to make a parked consumer immediately resume pulling frames.

Treat transport rate changes and consumer wake-up as one operation in the bridge.

---

## 14. Track the frame actually delivered

Another subtle transport lesson emerged during stabilization.

The producer cursor is not necessarily the best representation of what the user is currently seeing.

For UI state and frame stepping, the reference player tracks:

> the last frame actually delivered to the presentation layer

rather than blindly displaying the producer's next internal position.

### Why

Without this distinction, paused stepping can become one frame ahead of the visible picture.

### Lesson

Keep separate concepts for:

```text
requested transport position
producer/internal position
last delivered/displayed frame
```

Do not collapse all three into one integer.

---

## 15. Rapid frame stepping

Rapid frame stepping introduced another race.

Suppose the current displayed frame is 100 and the user rapidly requests:

```text
Right
Right
Right
Right
```

If each request calculates from the most recently *delivered* frame, rendering may not have caught up yet.

Multiple requests can therefore all calculate:

```text
100 + 1
```

instead of:

```text
101
102
103
104
```

### Fix

Maintain a separate requested transport position.

Each step changes the requested position immediately, independent of whether that frame has already been presented.

### Lesson

User intent must not be serialized through rendering latency.

This will become even more important once compositing and heavier frames are involved.

---

## 16. J/K/L keyboard handling

The reference player also exposed an ordinary UI problem.

If shuttle-rate changes are tied directly to key-repeat events, holding `L` can cause:

```text
1x
2x
4x
8x
1x
...
```

far faster than intended.

The stabilized player avoids treating every OS key-repeat event as a new shuttle command.

### Lesson

Transport semantics should interpret key state, not merely raw repeated key-down events.

---

## 17. EOF and replay

End-of-file behavior was hardened before considering the reference player stable.

A stopped MLT consumer must be handled deliberately.

The correct replay order is conceptually:

```text
detect stopped consumer
      ↓
join/stop old consumer state
      ↓
rewind producer
      ↓
restart consumer
      ↓
resume playback
```

An earlier ordering woke/restarted the consumer before rewinding, which could race at EOF.

### Lesson

EOF is a lifecycle transition, not just another seek.

Treat consumer stopped-state explicitly.

---

## 18. Opening a second media file

The reference player was tested by opening a second video in the same application session, including media with a different resolution/aspect ratio.

This validated:

- producer replacement
- old consumer teardown
- new consumer creation
- frame-buffer dimension changes
- Flutter texture resize behavior
- continued play/pause/seek behavior

### Lesson

"Open file" is not just initialization.

Replacement media is a teardown/rebuild transaction and should be tested separately from first-open behavior.

---

# Part III — Build and release findings

## 19. Debug build

The stabilized reference player passed:

```text
flutter analyze
Windows debug build
runtime playback
```

Analyzer cleanup also exposed a repository-structure lesson:

A copied template source under:

```text
app_overlay/
```

was being analyzed in addition to the active:

```text
lib/
```

source, causing duplicate analyzer findings.

The template directory was excluded from analysis.

### Lesson

Generated/template source trees should not silently participate in normal analysis unless they are intended to be compiled.

---

## 20. PowerShell execution policy

PowerShell refused to run unsigned `.ps1` helper scripts on a fresh shell.

Example:

```text
PSSecurityException
run.ps1 is not digitally signed
```

Temporary workaround:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

or:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

For convenience, later helper scripts used `.cmd` launchers where practical.

### Lesson

Do not make ordinary end-user or developer launch behavior depend unnecessarily on local PowerShell execution-policy configuration.

---

## 21. Release build: Windows error 126

The first optimized Release executable built successfully, but direct launch produced:

```text
Failed to load dynamic library '...\mlt_foundation.dll'
The specified module could not be found.
error code: 126
```

The important detail:

```text
mlt_foundation.dll
```

was actually present.

### Cause

Windows error 126 can mean:

> the requested DLL exists, but one of *its dependencies* cannot be resolved.

The development launch worked because the MSYS2 UCRT64 binary directory was on `PATH`.

A direct double-click did not have:

```text
C:\msys64\ucrt64\bin
```

available in the loader search path.

### Fix

The application registers/configures the MLT runtime DLL location before Dart attempts to load:

```text
mlt_foundation.dll
```

The loader also prefers runtime DLLs bundled beside the executable.

### Lesson

On Windows, never interpret error 126 as proof that the named DLL itself is absent.

Always inspect its dependency closure.

---

# Part IV — Portable packaging

## 22. Portable runtime goal

After Release playback worked, the next experiment was to remove the development runtime assumption.

The target layout became approximately:

```text
MLT-Windows-Foundation-Portable/
    mlt_windows_foundation.exe
    flutter_windows.dll
    mlt_foundation.dll

    libmlt-7.dll
    SDL2.dll
    FFmpeg/runtime DLLs
    other dependency DLLs

    lib/
        mlt/
            libmltcore.dll
            libmltavformat.dll
            libmltsdl2.dll
            ...

    share/
        mlt/
            profiles/
            presets/
            services/
            ...
```

The initial portable package intentionally focused on the MLT modules required by the foundation:

```text
core / loader
avformat
sdl2
```

and then recursively included their non-system DLL dependencies.

---

## 23. Dependency-closure packaging strategy

The portable packager inspects PE imports and recursively copies required UCRT64 DLLs.

The important design rule:

> Fail closed.

If a required non-Windows DLL cannot be resolved, packaging stops instead of silently producing a partially functional "portable" folder.

This is preferable to discovering missing dependencies only after distribution.

### Lesson

Portable packaging is a graph problem.

Do not maintain a hand-written flat DLL list indefinitely.

Start from the known roots and compute the dependency closure.

---

## 24. Portable test

The portable build was tested with a launcher that removed MSYS2 from `PATH` and pointed MLT at the package-local runtime:

```text
.\lib\mlt
.\share\mlt
.\share\mlt\profiles
```

Video and audio worked.

The package also successfully launched through the ordinary Release executable after the local runtime paths were added.

### What this proves

It proves that the package-local runtime layout is sufficient for the tested media path on the development machine without relying on MSYS2 being present in `PATH`.

### What this does NOT yet prove

A final clean-machine portability test is still recommended.

For maximum confidence, test the portable folder on a Windows x64 machine that has never had:

```text
MSYS2
MLT
FFmpeg development packages
```

installed.

Alternatively, temporarily make the development installation unavailable and repeat the test.

Do not overstate the portability result until that independent test is complete.

---

## 24A. Export and preview/export parity remain unproven on Windows

The Windows Foundation project intentionally excluded export.

That means the successful Windows preview work does **not** establish that the real application's export path is equivalent across platforms.

This matters because export uses a different consumer path than ordinary `sdl2_audio` preview. The Linux smoke suite already treats export as a first-class correctness surface by building and running:

```text
mlt_parity_smoke
mlt_export_preset_smoke
mlt_export_frame_rate_smoke
```

The Linux CI gate also runs `tools/smoke.sh`, which includes preview/export parity, ProRes preset validation, and frame-rate conform checks.

Before Windows can claim feature parity, the port should reproduce equivalent gates against the Windows MLT runtime, including at minimum:

```text
[ ] preview/export picture parity for the controlled fixture
[ ] layered preview/export parity
[ ] export consumer starts and terminates cleanly
[ ] ProRes preset produces the expected codec/profile/pixel format
[ ] audio export format is correct when source audio exists
[ ] 25 fps -> 30000/1001 conform preserves source duration
[ ] expected output frame count is produced
```

This is also a second place—after preview/audio timing—where **MLT 7.22 vs 7.40** can produce a correctness difference without producing a crash.

Until those tests exist on Windows:

> Windows playback is proven; Windows export parity is not.

---

# Part V — Current validated behavior

## 25. Reference player runtime matrix

The Windows foundation has successfully demonstrated:

| Capability | Result |
|---|---|
| Native MLT initialization | PASS |
| H.264/AAC media loading | PASS |
| Source-profile detection | PASS |
| Accurate frame count/duration | PASS |
| Real video decode | PASS |
| RGB/RGBA CPU frame access | PASS |
| Exact seek | PASS |
| Forward playback | PASS |
| Pause | PASS |
| Seek while paused | PASS |
| Frame stepping | PASS |
| Rapid repeated frame stepping | PASS |
| J/K/L shuttle | PASS |
| SDL2 audio output | PASS |
| Audio pause/resume | PASS |
| Consumer buffer purge | PASS |
| Explicit consumer shutdown | PASS |
| EOF handling | PASS |
| Single-command replay after EOF | PASS |
| Opening replacement media | PASS |
| Resolution/aspect-ratio change | PASS |
| Flutter Windows texture | PASS |
| Debug build | PASS |
| Release build | PASS |
| Direct Release EXE launch | PASS |
| Package-local MLT runtime | PASS on development machine |
| Layer freeze/serial/prewarm protocol | NOT YET VERIFIED ON WINDOWS |
| Multilayer composition/atomic role swaps | NOT YET VERIFIED ON WINDOWS |
| Export consumer path | NOT YET VERIFIED ON WINDOWS |
| Preview/export parity | NOT YET VERIFIED ON WINDOWS |
| Clean machine with no MLT/MSYS2 installed | NOT YET VERIFIED |

---

# Part VI — Design rules to carry into MLT Player

## 26. Rules that should become part of the real Windows port

### Rule 1 — Do not create a separate Windows media engine

Reuse the MLT engine model.

Only presentation and host integration should be platform-specific.

---

### Rule 2 — Separate engine from presentation before adding Windows complexity

Shared responsibilities include:

```text
MLT factory lifecycle
profiles
producers
consumer lifecycle
transport
frame positions
frame buffers
media inspection
event handling
composition graph
export
thumbnail generation
```

Platform-specific responsibilities include:

```text
Flutter texture registration
texture upload/presentation
atomic preview freeze/resume behavior
rendered-frame vs presented-texture serials
presentation prewarm for base-role changes
platform runner integration
native window behavior
platform file dialogs, if used
```

The freeze/serial/prewarm operations are part of the platform presentation contract because composition and Undo/Redo depend on their semantics. Windows must provide an equivalent implementation even if its pixel-buffer backend does not use the same GL mechanics as Linux.

---

### Rule 3 — Keep the `sdl2_audio` consumer

The same consumer family works on Linux and Windows.

This reduces platform divergence.

---

### Rule 4 — Explicitly own consumer lifecycle

Do not rely on:

```text
terminate_on_pause
```

for normal playback control.

Use explicit:

```text
start
pause through producer speed
refresh
purge where required
stop
close
```

---

### Rule 5 — Wake the consumer after transport changes

Changing producer speed alone is not sufficient in every state.

Rate changes should share one native bridge operation that also refreshes/wakes the consumer.

---

### Rule 6 — Distinguish requested position from displayed position

Maintain at least:

```text
requested transport frame
last delivered/displayed frame
```

and do not assume the producer's internal cursor equals the visible frame.

---

### Rule 7 — Treat media replacement as a transaction

Opening another file should cleanly tear down the previous producer/consumer/frame state before committing the new state.

A failed replacement should not leave Dart believing the previous or new media is valid incorrectly.

---

### Rule 8 — Treat EOF as a lifecycle state

If the consumer has stopped:

```text
join/stop it
rewind
restart
resume
```

in a deterministic order.

---

### Rule 9 — Runtime paths are part of the product

MLT module/data discovery should be based on the installed application location, not the developer's MSYS2 installation.

Development fallbacks are fine.

Production packaging must prefer package-local paths.

---

### Rule 10 — Compute DLL closure

Do not ship a guessed dependency list.

Recursively inspect binary imports and fail packaging if a required dependency is unresolved.

---

### Rule 11 — Keep the CPU texture path as the correctness baseline

A future D3D/GPU texture backend may improve efficiency.

It should be treated as an optimization behind the same presentation interface, not as a new player architecture.

---

# Part VII — Recommended next phase

## 27. W4 — Platform seam in the real MLT Player

The next substantial task should be to modify the actual MLT Player architecture.

Do **not** begin by copying the standalone player wholesale into the application.

Instead use it as the reference behavior while extracting the existing Linux-specific presentation code from the shared bridge.

### W4 entry gate — version strategy

Before step 1, explicitly decide how the project will handle the MLT split:

```text
Linux CI:      MLT 7.22.x
Windows test:  MLT 7.40.0
```

Either raise the Linux baseline after candidate diagnostics and the full smoke/parity suite, or keep a two-version validation strategy while the seam is being introduced.

Do not let the first large shared-native refactor also become an implicit MLT version migration.

### Conservative migration sequence

```text
1. Freeze the known-good Linux behavior and preserve the existing CI gate.

2. Write down the presentation-backend contract before moving code.
   It must include:
       frame publication
       atomic preview-update begin/end
       rendered-frame serial
       presented-texture serial
       future-base prewarm
       prewarm-complete serial

3. Identify shared MLT engine/frame-slot/composition code.

4. Identify Linux-only Flutter/OpenGL implementation code.

5. Move the Linux presentation implementation behind the new interface
   with no intended behavior change.

6. Run Linux smoke + preview/export parity + layer tests again on the
   validated Linux MLT baseline.

7. Add the Windows pixel-buffer presentation backend and implement the
   same freeze/serial/prewarm semantics.

8. Reconnect layers/composition and specifically test:
       add/remove layer
       Undo/Redo restoration
       logical-vs-visual ordering
       base promotion
       cross-aspect role swaps
       Texture(freeze:true) release timing
       prewarm completion

9. Port the Windows export path and run Windows equivalents of:
       mlt_parity_smoke
       mlt_export_preset_smoke
       mlt_export_frame_rate_smoke

10. Reuse the validated Windows runtime/package-local dependency logic.

11. Only after media parity is stable, reconnect higher-level
    application systems.
```

A safer restoration order is approximately:

```text
ordinary single-file playback
→ transport
→ media inspection
→ atomic presentation transaction semantics
→ layers/composition and role swaps
→ preview/export parity
→ export presets and frame-rate conform
→ thumbnails
→ Explorer
→ project state
→ Redleaf integration
→ Windows-specific runner polish
```

The point is not that export must precede every thumbnail feature forever. The point is that **media correctness gates should be established before application-specific surfaces make failures harder to attribute**.

---

# Part VIII — Things not to forget

## 28. Known facts worth preserving

- The tested Windows MLT package was **7.40.0**.
- Linux CI explicitly hard-gates **MLT 7.22.x** and runs smoke + preview/export parity there.
- The 7.22/7.40 split is an unresolved porting risk that should be addressed **before** large shared-native refactors.
- `tools/pts_diag.sh` exists specifically to characterize candidate MLT baselines before raising the Linux version.
- `sdl2_audio` works on Windows.
- `rtaudio` was not needed.
- MLT can render RGBA frames through an audio-only consumer when video is enabled and the consumer requests the desired image format.
- A Flutter external texture does not require MLT to own the application window.
- The Windows CPU pixel-buffer texture is sufficient for smooth ordinary playback on the tested machine.
- Release behavior must be tested by **direct EXE launch**, not only from a developer shell.
- Runtime dependency failures can appear only in Release/direct-launch scenarios even when compilation succeeds.
- A working development machine can hide packaging mistakes. Keep a clean-machine test in the release checklist.

---

## 29. Reproduction checklist

For someone reproducing the investigation from scratch:

```text
[ ] Install Flutter Windows tooling
[ ] Install Visual Studio C++/Windows SDK
[ ] Install MSYS2
[ ] Use the UCRT64 environment
[ ] Install GCC, pkg-config, MLT, FFmpeg
[ ] Confirm `melt --version`
[ ] Confirm `pkg-config --modversion mlt-framework-7`
[ ] Build W0 initialization/open test
[ ] Probe source profile before real producer creation
[ ] Build W1 decoded-frame test
[ ] Build W2 headless transport test
[ ] Confirm `sdl2_audio` exists
[ ] Build W3 explicit audio-consumer test
[ ] Build the thin Flutter reference player
[ ] Use CPU pixel-buffer texture first
[ ] Test Play/Pause/Seek
[ ] Test rapid frame stepping
[ ] Test J/K/L
[ ] Test EOF/replay
[ ] Test media replacement/resolution changes
[ ] Test Flutter debug build
[ ] Test Flutter release build
[ ] Test direct EXE launch
[ ] Build portable dependency closure
[ ] Test with MSYS2 removed from PATH
[ ] Test on a clean Windows machine
[ ] Record the Linux MLT baseline used by CI
[ ] Run tools/pts_diag.sh before raising that baseline
[ ] Preserve Linux smoke + preview/export parity during seam refactor
[ ] Implement Windows atomic preview freeze/serial/prewarm semantics
[ ] Exercise Windows multilayer role swaps and Undo/Redo
[ ] Port the export consumer path
[ ] Run Windows preview/export parity
[ ] Run Windows export preset validation
[ ] Run Windows frame-rate conform validation
```

---

# 30. Final conclusion

The central feasibility question has been answered:

> MLT can serve as the native media engine for MLT Player on Windows.

The Windows implementation does not need a second playback architecture.

The experiments demonstrated native Windows:

```text
decode
audio
transport
seeking
frame stepping
shuttle
Flutter video presentation
release builds
package-local runtime loading
```

The most important outcome is not merely that a small player works.

It is that the small player exposed many of the platform-specific rules that should now guide the real port, while the full Linux application reveals two additional gates the foundation could not prove: the atomic layer-presentation protocol and export parity.

```text
keep the MLT engine shared
separate platform presentation
include freeze/serial/prewarm semantics in that presentation seam
own consumer lifecycle explicitly
wake the consumer after transport changes
track requested and displayed frames separately
treat EOF and replacement media as lifecycle transitions
make runtime discovery/package layout deliberate
resolve or contain MLT 7.22 vs 7.40 version skew
establish Windows preview/export parity before claiming full parity
```

The reference player should remain available during the real port as a control implementation.

When a Windows behavior fails in the full MLT Player, the first diagnostic question should be:

> Does the same media and transport operation still work in the Windows Foundation player?

That gives the project a known-good baseline for distinguishing:

```text
MLT/platform problems
from
MLT Player application problems
```

and should save substantial debugging time during the rest of the Windows port.
