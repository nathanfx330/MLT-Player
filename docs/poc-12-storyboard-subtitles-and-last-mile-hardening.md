<!-- docs/poc-12-storyboard-subtitles-and-last-mile-hardening.md -->

# POC 12: Storyboard, Searchable Subtitles, and the Last Mile of Release Hardening

## The point where feature work became stability work

By this stage MLT Player already had the architecture that mattered:

```text
Explorer
→ persistent Player
→ precise transport / inspection
→ three-layer composition
→ independent export
→ return to Explorer
```

The remaining work looked smaller than the phases that came before it:

- a Storyboard view
- sidecar SRT subtitles
- searchable transcript navigation
- a few cleanup passes
- CI cleanup

In practice, this final stretch produced some of the most reusable lessons in the project.

The important failures were no longer obvious feature failures. They were boundary failures:

```text
Flutter UI
↕
Linux desktop lifecycle
↕
background work
↕
Dart FFI
↕
MLT
```

A build could compile, analyze, and pass tests while still crashing only in a standalone release. The same file could open safely by drag-and-drop and crash when chosen through the native file picker. A deprecation warning could fail CI even though the locally installed Flutter SDK did not yet provide the replacement API.

The central lesson of this phase is therefore:

> When a native desktop application is already mostly correct, isolate the boundary that changed before changing the architecture around it.

The implementation described here was developed and tested on Linux against **MLT 7.22.0**.

---

# 1. Storyboard: exact frames without turning the Player into a thumbnail decoder

Storyboard was added as a second Player view rather than as a new playback mode inside the MLT engine.

The view samples the current clip at selectable intervals:

```text
5 seconds
10 seconds
30 seconds
60 seconds
```

Each card represents a real source frame. Clicking a card seeks the Player; double-clicking returns to video at that position.

The important architectural decision was the same one established for Explorer thumbnails:

> Background visual browsing must not drive the live Player through a sequence of hidden seeks.

Storyboard therefore uses a separate `StoryboardThumbnailService` and the native exact-frame thumbnail path.

The service owns several pieces of defensive state:

- one active source pathname
- a generation/session counter
- one-at-a-time native thumbnail admission
- in-flight request deduplication
- temporary-file publication followed by rename
- cancellation by invalidating stale generations rather than attempting to interrupt an in-progress synchronous native decode

That last point matters. An MLT decode already executing synchronously inside native code is not treated as safely interruptible. Instead, navigation or interval changes make the result obsolete. When the decode returns, an obsolete result is discarded instead of published.

Conceptually:

```text
request frame
   ↓
remember generation N
   ↓
run native decode
   ↓
source/interval changed?
   ├─ no  → publish thumbnail
   └─ yes → discard temporary result
```

This is less dramatic than forcibly cancelling native work, but it is much easier to reason about.

---

# 2. A refactor that passed tests and still made the release worse

During thumbnail hardening, the cache/store and generation-coordinator responsibilities were split more aggressively.

On paper the refactor was cleaner. It also passed the ordinary checks.

Then the standalone release began crashing when opening media.

Rolling the refactor back restored the working runtime.

That experience changed the standard for structural work near native lifecycle code.

A refactor is not proven by:

```text
flutter analyze
flutter test
successful compilation
```

when the code sits next to asynchronous work, FFI, texture ownership, or MLT object lifetimes.

It must also pass the same runtime handoff the user performs.

For this project, that means at minimum:

```text
build standalone release
launch standalone release
open real video
exercise the path that changed
```

The broader lesson is uncomfortable but useful:

> Cleaner ownership on paper can still change timing enough to expose a native race.

Once the application reaches a stable checkpoint, architectural cleanup needs a concrete reason. File size and aesthetic symmetry are not enough by themselves.

---

# 3. Sidecar SRT subtitles: keep the first version boring

Subtitle support started with one intentionally narrow rule:

```text
Movie.mp4
Movie.srt
```

Open `Movie.mp4`, and the application looks for a same-basename SRT sidecar.

The first implementation did only four things:

1. locate the sidecar
2. decode the text
3. parse SRT cue timing and multiline payloads
4. render the active cue over the Player

No MLT subtitle filter was added. No subtitle data was inserted into the composition graph. No native bridge change was required.

That was deliberate.

Subtitle presentation is application UI state, while the media graph already had enough responsibilities. Keeping SRT parsing and presentation in Dart made the first version easy to validate independently of playback.

Only after the passive overlay was working did the feature grow into:

- subtitle visibility toggle
- floating transcript panel
- full transcript view
- text search
- case-insensitive multiword matching
- clicking a cue to seek to its start
- active-cue highlighting
- `Ctrl+F` to open/focus transcript search
- `Esc` to close the transcript panel before leaving the Player

This sequence is worth preserving as a general pattern:

> First prove passive presentation. Then add interaction. Then add keyboard integration.

It creates much smaller failure surfaces than delivering all three layers at once.

---

# 4. Search fields and global shortcuts must have an explicit treaty

The first searchable transcript UI exposed an ordinary desktop-app problem: global player shortcuts and focused text input wanted the same keys.

Examples:

- plain `F` was a Player fullscreen shortcut
- `Ctrl+F` was now transcript search
- `C` toggled captions
- typing the letter `c` inside the search field must obviously not toggle captions

There was also a hit-testing issue: controls could be visually present but positioned beneath a later Player control layer, making them impossible to click.

The final input policy became explicit:

```text
focused transcript TextField
→ text input owns ordinary letter keys

Ctrl+F
→ transcript search

plain F
→ Player fullscreen behavior only

Esc with transcript open
→ close transcript first
```

And the subtitle/transcript controls were placed above the Player control layer so visual Z-order and hit-test Z-order agreed.

Two practical rules came out of this:

> A visible control is not necessarily a hittable control in a layered Flutter `Stack`.

and:

> Never implement a global letter shortcut without deciding what happens when a text field has focus.

Keyboard behavior is part of UI ownership, not a small detail to patch after the feature is done.

---

# 5. Legacy subtitle encodings: Latin-1 is not a Windows-1252 decoder

The original subtitle decoder tried UTF-8 first and Latin-1 second.

That sounds reasonable until real subtitle files arrive.

Many legacy Western-language subtitle files are Windows-1252 rather than ISO-8859-1. The two encodings differ most visibly in bytes `0x80` through `0x9F`, where Windows-1252 contains characters commonly found in prose:

- smart single quotes
- smart double quotes
- en dash
- em dash
- ellipsis
- euro sign
- several ligatures and punctuation marks

ISO-8859-1 maps that range to C1 control characters.

There is another trap: Latin-1 decoding is total. It can map every byte value, so it does not throw and therefore cannot be used as an intermediate “try this and fall through if it fails” decoder.

The resulting policy became:

```text
1. strict UTF-8
2. Windows-1252
3. Latin-1 fallback for bytes not meaningfully mapped by CP1252 policy
```

Dart's standard `dart:convert` library does not provide a Windows-1252 codec, so MLT Player uses a small internal mapping for the differing control range.

The regression test uses real CP1252 byte values rather than a Unicode string that has already been decoded by the test harness. That distinction matters: encoding tests should exercise bytes, not merely the text they are expected to become.

A useful sample contains the characters equivalent to:

```text
It’s “fine” – really — yes…
```

If those characters survive from actual CP1252 bytes, the path is doing real work.

---

# 6. The hardest last-mile bug: Open File crashed, drag-and-drop did not

The most instructive bug in this phase appeared in the standalone release.

The symptoms were strangely specific:

- the release executable could play media
- drag-and-drop could open the media
- opening the same media through **Open File** could crash
- launch location/current working directory appeared to influence how reliably the problem reproduced

This was exactly the kind of failure that invites a broad native rewrite.

That would have been the wrong first move.

## 6.1 Build an experiment matrix

Instead of treating “opening a file” as one operation, the paths were separated.

The same release executable was launched from different working directories and the same media was opened through different UI entry points.

Useful comparisons included:

```text
project-root launch + Open File
home-directory launch + Open File
project-root launch + drag/drop
home-directory launch + drag/drop
```

The decisive result was:

> Drag-and-drop of the same media worked both inside and outside the project working directory.

That ruled out several attractive theories at once:

- the media pathname itself was not inherently invalid
- MLT could open and play the file
- the release bundle could locate its required runtime libraries
- current working directory alone was not enough to explain the failure

The difference was now much narrower:

```text
native file chooser handoff
versus
drag/drop handoff
```

## 6.2 Use system tracing to eliminate red herrings

`strace` was used to compare file access from the working and failing launch cases.

For example:

```bash
strace -f -e trace=file -s 300 \
  -o /tmp/mlt-open.log \
  ./build/linux/x64/release/bundle/mlt_player
```

A suspicious relative lookup such as `dv_pal` appeared, but it appeared in both good and bad cases. Therefore it could not explain the behavioral difference.

That is an important debugging discipline:

> A strange log line is not evidence of causation if it is also present in the working control case.

Differential evidence is much more valuable than unusual evidence.

## 6.3 Respect the chooser lifecycle boundary

Explorer already drains foreground-conflicting thumbnail work before handing media to the Player.

The remaining difference was timing around the Linux file chooser returning control to Flutter and the application immediately entering the MLT open path.

The stable implementation adds a short Linux-only settle window before `_openPath()` touches MLT after the chooser handoff.

The delay is small — 200 ms — and intentionally localized to this boundary.

Conceptually:

```text
file chooser closes
   ↓
short Linux settle window
   ↓
foreground media open
   ↓
MLT
```

This is a pragmatic lifecycle barrier, not a claim that 200 ms is a magical MLT requirement or that the exact GTK/Flutter/MLT internal race has been proven.

That distinction should remain in the documentation.

The tested statement is:

> The release build that previously crashed on the chooser path stopped crashing with the localized settle barrier in the tested scenario.

The unproven statement would be:

> “The root cause of every file-open crash is known and permanently fixed.”

Native integration work benefits from keeping those two levels of confidence separate.

---

# 7. Do not let a successful alternate path become a false root-cause story

One experiment moved media opening back onto the current Dart isolate rather than using the helper-isolate path.

That build also completed the tested open successfully.

It was useful evidence, but later UI wiring could still expose instability. Therefore the experiment did not justify the stronger conclusion that isolate choice alone had been the root cause.

This is another general lesson:

> A change that makes one reproduction disappear is a candidate explanation, not automatically the explanation.

Keep narrowing until one hypothesis distinguishes the failing path from a working control.

In this case, drag/drop versus native chooser handoff provided the sharper distinction.

---

# 8. Standalone release is a separate test environment

POC 11 had already shown that `flutter run` and a standalone release are not equivalent for a native-heavy Linux application.

POC 12 made the release gate even more specific.

The useful matrix is now:

```text
1. flutter analyze
2. flutter test
3. native smoke/parity tests
4. flutter run interactive behavior
5. standalone release launched from project directory
6. standalone release launched from an unrelated working directory
7. Open File path
8. drag/drop path when relevant
```

The last four are not redundant.

Launching from an unrelated directory is particularly useful because it exposes accidental relative-path dependencies that remain invisible when development always begins from the repository root.

A good release check is therefore:

```bash
flutter build linux --release

cd ~
~/dev/mlt_player/build/linux/x64/release/bundle/mlt_player
```

Then exercise the actual user entry point that changed.

For file-opening work, merely seeing the window appear is not a release test.

---

# 9. CI can fail because the environment moved, even when the application did not

Near the final checkpoint, GitHub Actions went red at `flutter analyze`.

Nothing in MLT had failed. The Linux build itself had succeeded. CI stopped because its pinned Flutter SDK reported a deprecation in Storyboard:

```text
GridView.builder(cacheExtent: ...)
```

CI used Flutter 3.47.0, where that parameter generated a deprecation diagnostic recommending the newer cache-extent API.

The obvious fix was to rename the parameter.

That failed locally because the locally installed Flutter SDK did not yet define the replacement named parameter.

This exposed a compatibility rule that applies to any project supporting more than one SDK point:

> A deprecation replacement can exist in the newer SDK that reports the warning while being unavailable in the older SDK you still support.

The safe solution for this checkpoint was not to raise the entire Flutter baseline for one optimization hint.

Instead, MLT Player kept the compatible property and documented the one intentional use with a narrowly scoped analyzer suppression:

```dart
// ignore: deprecated_member_use
cacheExtent: 500,
```

That preserved behavior on the existing local SDK and allowed CI's newer analyzer to continue into the real regression tests.

The broader CI lesson is:

```text
red CI
≠ automatically broken runtime
```

Read the first failing step. If analysis stops the workflow, every later test may be marked skipped even though none of them failed.

---

# 10. Dead code is different from risky cleanup

At the end of the feature work, the repository still contained an unused `tracks_inspector.dart`: a large alternate inspector implementation that nothing imported.

The live UI used `LayersInspector` instead.

Deleting the orphan was low-risk because it removed code outside the runtime graph.

Renaming live methods merely to make their names aesthetically match the surviving widget would have touched known-good application code for no behavioral benefit, so that part was deliberately not bundled into the cleanup.

This gives a useful distinction for mature native applications:

```text
disconnected dead code
→ cheap to remove

large but working live code
→ not automatically a refactor target
```

A 5,000-line working engine may deserve future decomposition. It does not deserve immediate decomposition solely because it is large, especially after a sequence where timing-only changes have already exposed release crashes.

At a stability checkpoint, the burden of proof flips:

> New structure must justify the risk of touching known-good behavior.

---

# 11. The final validation checkpoint

The final hardening pass ended with:

```text
flutter analyze          clean
flutter test             73 passed
standalone release       built successfully
real video open          interactively proven in the tested release
GitHub CI                passing
```

The test suite also deliberately emits a thumbnail diagnostic for a broken fixture while still passing the corresponding test. A diagnostic line in test output is therefore not itself a failed test; the suite result and assertion context matter.

This sounds obvious, but native/media test logs often contain warnings from deliberately malformed fixtures. Treating every stderr line as a regression creates noise and encourages the wrong fixes.

---

# 12. A debugging playbook for Flutter + native media engines

The last mile of MLT Player can be reduced to a practical sequence.

When a release-only crash appears:

## Step 1 — freeze the known-good boundary

Do not begin with cleanup or refactoring.

Record:

- last known-good commit
- exact launch command
- exact media file
- exact UI path used to open it

## Step 2 — vary one axis at a time

Useful axes include:

```text
debug vs release
project CWD vs unrelated CWD
file chooser vs drag/drop
video vs still image
foreground open vs background generation active
```

## Step 3 — use the working case as evidence

If the same media opens through another handoff path, stop blaming the decoder until new evidence appears.

If a strange filesystem lookup happens in both cases, stop blaming that lookup.

## Step 4 — put barriers at ownership transitions, not everywhere

Examples in this project:

- pause/drain background thumbnail work before foreground Player ownership
- invalidate stale Storyboard generations rather than force-cancelling native work
- allow the native Linux chooser to settle before beginning a sensitive media open

A localized barrier is easier to validate than global sleeps or broad serialization.

## Step 5 — prove the release, not merely the code

For native desktop work, success means the built artifact performs the real workflow.

## Step 6 — keep claims proportional to evidence

Prefer:

```text
“the latest tested release passed this reproduction”
```

over:

```text
“the crash is permanently solved”
```

That language is not caution for its own sake. It keeps future debugging honest.

---

# 13. What not to do

This phase also clarified several anti-patterns.

### Do not perform destructive repository cleanup as a debugging shortcut

Untracked work can be real work. Commands that reset the tree and delete untracked files can destroy the very state being investigated.

Prefer inspection first:

```bash
git status
git diff
git log --oneline --decorate -5
```

Then make the smallest explicit change required.

### Do not “fix” CI by changing the application blindly

First identify the exact failing step and the exact SDK/environment CI is using.

### Do not infer a native root cause from one successful rebuild

Timing-sensitive native bugs can disappear when code is rearranged without the underlying ownership problem being understood.

### Do not combine feature work and cleanup when the runtime is fragile

A small, isolated commit gives you a useful checkpoint and makes rollback meaningful.

### Do not let test count replace interactive validation

Seventy-three green Dart tests do not exercise the Linux native file chooser closing immediately before an MLT open. Test the boundary that actually failed.

---

# 14. Closing principle

The first half of a media application is about making capabilities possible.

The last half is about making boundaries boring.

For MLT Player, the final useful architecture was not the one with the maximum number of abstractions. It was the one where ownership became predictable:

```text
Explorer owns browsing
thumbnail services own background decoding
Player owns the selected media
Storyboard owns disposable exact-frame browsing work
Dart owns sidecar subtitle parsing and search UI
MLT owns media playback/composition/export
CI owns repeatable automated gates
standalone release testing owns the final runtime truth
```

That is the checkpoint worth preserving.
