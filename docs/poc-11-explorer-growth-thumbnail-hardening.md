<!-- docs/poc-11-explorer-growth-thumbnail-hardening.md -->

# POC 11 continuation: Explorer Growth, MLT-Native Thumbnails, and Release Hardening

## From a browser shell to a useful local-media workflow

Phase 11.1 proved the application structure:

```text
Explorer
→ selected asset
→ persistent MLT Player
→ return to the same browser context
```

That was intentionally narrow. The first Explorer used placeholders and focused
on directory scanning, selection, navigation, focus, and lifecycle ownership.

The next sequence, Phases 11.2 through 11.8, turned that shell into a practical
Adobe Bridge-style local media browser while preserving the project's narrower
product boundary:

```text
browse
→ recognize media visually
→ inspect lightweight metadata
→ rate / tag / filter
→ open one asset in the precision Player
→ return and continue browsing
```

This continuation also produced two of the most useful engineering lessons in
the project: two different failures worked under `flutter run` but failed in
the standalone release bundle.

The implementation described here was built and tested on Linux against **MLT
7.22.0**.

---

# 1. Phase 11.2 — real thumbnails without sacrificing Player responsiveness

The first major Explorer expansion was real thumbnails.

The browser needed to display many assets without turning the live Player into
a hidden batch decoder.

That led to a separate thumbnail subsystem with its own lifecycle:

```text
ExplorerPage
    ↓
ThumbnailService
    ↓
background generation
    ↓
persistent cache
```

The core browser rule remained:

> The live Player belongs to the selected asset, not to every file visible in a folder.

The first thumbnail service established several pieces that survived later
architecture changes:

- persistent cache under the user's cache directory
- cache keys derived from source change state
- in-flight deduplication
- bounded worker admission
- atomic temporary-file publish followed by rename
- pause/drain behavior before handing foreground ownership to Player
- immediate cache hits on revisiting a folder
- folders and unsupported asset types remain placeholders rather than forcing a decoder path

The initial generator used an external `ffmpeg` executable. That choice worked,
but it would later be reconsidered after code review because it created a media
engine mismatch between Explorer and Player.

---

# 2. Release-only failure one — still images exposed an implicit producer problem

The first standalone-build problem arrived early in thumbnail-era Explorer.

The application behaved correctly under:

```bash
flutter run -d linux
```

but the standalone build could fail when opening still images.

The failure was not caused by Flutter layout or by the Explorer shell. It was a
native producer-selection problem.

MLT's automatic producer selection could choose Qt's `qimage` path for a still
image. In the standalone release environment, that producer could execute in a
context where Qt expected application/main-thread state that was not valid for
this embedding.

The observed diagnostics included Qt application/thread complaints and a GLib
assertion. The important point was not the exact message. The important point
was that the same pathname and app logic could behave differently depending on
how the application was launched.

## Fix: make still-image producer policy explicit

The Player stopped relying on implicit still-image auto-selection.

For known still-image extensions, the preferred path became:

```text
pixbuf
→ avformat fallback
```

and the runtime deliberately avoided `qimage` for that path.

This mattered beyond one crash. It established a more general rule:

> When a producer choice has threading or embedding consequences, do not leave it to an opaque auto-loader if the application already knows the media class.

The standalone release was then explicitly tested with both MP4 and PNG media.

That was the first sign that `flutter run` alone was not a sufficient release
criterion for a native-heavy desktop app.

---

# 3. Phase 11.3 — metadata belongs beside selection, not in the thumbnail scan

The next Explorer slice added a richer right-side selection pane.

The browser needed enough information to answer ordinary file-selection
questions without opening the full Player:

- type
- extension/format
- file size
- modification time
- image dimensions when applicable

The important architecture decision was to keep this lightweight.

Explorer did **not** probe every media file through MLT merely to populate the
grid. File metadata was read independently, and expensive image decoding was
restricted to the selected item when needed.

This preserved the separation:

```text
Explorer = lightweight folder browsing
Player   = deep media inspection
```

---

# 4. Phase 11.4 — browser navigation became stateful

A real media browser needs more than “open folder” and “go to parent.”

Phase 11.4 added:

- Back
- Forward
- Up
- Home
- `Alt+Left`
- `Alt+Right`
- `Alt+Home`
- Favorites
- Recent locations
- toolbar favorite state
- persisted locations

Navigation history itself remained session-local, while Favorites and Recent
locations persisted.

This was an important usability milestone because Explorer could now be used as
a workspace rather than a single-folder picker.

---

# 5. Phase 11.5 — view density became part of browsing speed

Thumbnail size is not merely cosmetic in a media browser.

The useful amount of information on screen depends on whether the current task
is broad visual triage or closer inspection.

Phase 11.5 added a continuous control mapped onto named density bands:

```text
Compact
Small
Standard
Large
Extra Large
```

The grid changes as a unit:

- thumbnail dimensions
- card dimensions
- column count
- spacing

The chosen view preference persists across launches.

The right-side information pane and surrounding application layout remain
stable while the media grid changes density.

---

# 6. Phase 11.6 — current-folder filtering and sorting

The next step was finding assets inside a busy directory without introducing a
catalog database.

The browser gained:

- case-insensitive filename filtering
- `Ctrl+F`
- Name sort
- Modified sort
- Size sort
- Type sort
- ascending / descending direction
- persisted sort preference

Folders remain above media regardless of sort mode.

Selection is path-based rather than index-based, so resorting does not silently
change what asset the user selected.

This phase reinforced the product boundary:

```text
current folder search
≠
recursive DAM index
```

---

# 7. Phase 11.7 — ratings and tags without touching source media

The Explorer then gained the first true organizational metadata.

Each media asset can carry:

```text
rating: 0..5
tags:   free-form strings
```

The annotations are stored in MLT Player's configuration data rather than
written into the source media.

The normal Linux path is:

```text
~/.config/mlt_player/explorer_annotations.json
```

The catalog uses absolute paths as asset identity.

That has a known consequence: moving or renaming a source file can break the
association. That limitation was accepted because the current product is a
local browser, not yet a content-addressed archive catalog.

## Annotation rules

Ratings:

- clamp to 0–5
- zero means unrated

Tags:

- trim whitespace
- ignore empty values
- deduplicate case-insensitively
- preserve the first display casing/order

The catalog remains sparse. When an asset has rating 0 and no tags, its record
is removed.

Malformed persisted data fails open to an empty catalog rather than blocking
Explorer startup.

---

# 8. Phase 11.8 — rating and tag filters complete the triage loop

Once ratings and tags existed, they became useful as current-folder filters.

The filter bar now combines:

```text
filename query
AND
minimum rating
AND
exact tag
```

Rating choices are minimum thresholds:

```text
Any rating
1★+
2★+
3★+
4★+
5★
```

The tag menu is populated from tags actually used by media in the current
folder.

Tags are deduplicated case-insensitively and sorted for display.

## Directory behavior under annotation filters

Folders do not carry ratings or tags.

Therefore:

- filename-only filtering can continue to show matching directories
- active rating/tag filters hide directories
- clearing annotation filters restores normal folder visibility

That behavior is intentional rather than an accidental side effect of the
filter implementation.

## Selection behavior when a filter removes the selected asset

Selection remains path-based.

If an asset is edited so that it no longer satisfies the active filters, the
right-side pane moves to a no-visible-selection state instead of silently
selecting a different media item.

This preserves user intent and avoids index-driven selection surprises.

---

# 9. The thumbnail code review changed the decoder architecture

After 11.8, the thumbnail subsystem received a focused architectural review.

The cache engineering itself was strong:

- bounded work
- in-flight deduplication
- atomic publish
- pause/drain
- versioned cache identity

But the runtime decoder was an external `ffmpeg` command found through `$PATH`.

That created three concerns.

## 9.1 Undocumented runtime executable dependency

Explorer could lose thumbnails if the executable was missing, differently
configured, or inaccessible through PATH.

The failure path collapsed to “no thumbnail,” which was too opaque for a
project that otherwise emphasizes explicit native diagnostics.

## 9.2 Explorer and Player could disagree about media support

The Player opens media through MLT.

The Explorer was rendering thumbnails through an independently installed
ffmpeg command-line binary.

Even when both ultimately use FFmpeg code, they are not the same runtime
contract. Versions, modules, build flags, and installed codec support can
differ.

That means a thumbnail browser can potentially imply that a file is healthy
when the Player cannot open it, or fail to thumbnail a file that MLT can use.

For this product, the browser should report on media through the same engine
family as the tool it feeds.

## 9.3 Fixed one-second thumbnails recreated the black-thumbnail problem

The first generator tried:

```text
1 second
→ frame zero fallback
```

That is cheap and common, but poor for footage with:

- black leader
- fade-in
- slate
- leader graphics
- repeated opening cards

The Explorer was supposed to be more useful than a generic OS file browser, so
representative-frame choice became part of the hardening work.

---

# 10. The MLT-native thumbnail architecture

Runtime thumbnail generation was moved into a dedicated native MLT path rather
than reusing the global user-facing export subsystem.

That distinction matters.

The existing exact-frame export API is backed by process-global export state and
allows only one export job at a time. Thumbnail generation has a different
lifecycle and should not occupy or interfere with the user's export job.

The hardened architecture is:

```text
Explorer ThumbnailService
        ↓
Dart worker isolate
        ↓
MltThumbnailBridge
        ↓
private native thumbnail request
        ↓
private MLT profile + producer
        ↓
representative-frame scoring
        ↓
GdkPixbuf JPEG output
        ↓
existing atomic cache publish
```

There is no runtime `Process.run('ffmpeg', ...)` thumbnail path anymore.

The ffmpeg command-line tool remains useful in test tooling to manufacture
reproducible fixtures, but it is not an Explorer runtime dependency.

---

# 11. Representative-frame selection

Timed video now samples three positions:

```text
15%
50%
85%
```

Three samples were chosen instead of an arbitrarily large sample set to keep
cache-miss cost bounded on high-resolution or long-GOP media.

Candidate frames are decoded through MLT and scored using image information such
as luma variance/contrast, with a penalty for near-black frames.

The strongest candidate becomes the cached thumbnail.

## Regression fixture

The focused native thumbnail smoke creates a deterministic clip whose first two
seconds are pure black.

The test proves:

```text
MLT thumbnail generation succeeds
AND
selected representative frame is not from the black leader
```

It also checks requested output dimensions and still-image generation.

---

# 12. Cache identity stayed conservative

The cache identity remains based on:

```text
cache version
+ absolute path
+ file size
+ modification timestamp
```

A content fingerprint based on partial-file hashes was considered, but not
adopted during this hardening pass.

The existing key has a useful safety property: it favors invalidating too often
over serving a thumbnail from a changed source.

Moving or restoring archive footage may therefore cause regeneration. That is
an accepted tradeoff for the current local-browser phase.

The cache version was bumped for the MLT representative-frame implementation,
which cleanly invalidated thumbnails produced by the earlier ffmpeg generator.

---

# 13. Release-only failure two — in-process thumbnail concurrency

The MLT-native thumbnail replacement passed its first validation set:

```text
flutter analyze       clean
flutter test          green
native thumbnail smoke green
full native smoke     green
flutter run           works
```

But the standalone optimized release build still crashed while browsing.

This was the second time Explorer development proved that debug execution and
standalone release execution were not equivalent.

## What changed from the old generator

The original thumbnail service admitted multiple workers, but each worker
launched an external ffmpeg process.

Conceptually:

```text
Dart
→ ffmpeg process A
→ ffmpeg process B
```

The operating system/process boundary isolated the decoder work.

After moving thumbnail decoding in-process, the same worker policy became:

```text
Dart isolate A ─┐
                ├→ same application process → MLT thumbnail decode
Dart isolate B ─┘
```

The new code had introduced a native concurrency dimension that the original
single-request thumbnail smoke did not cover.

Release optimization/scheduling exposed it reliably enough to crash the
standalone bundle even though `flutter run` appeared stable.

---

# 14. The final concurrency hardening

The final fix was intentionally conservative rather than trying to prove broad
thread safety across every producer/plugin combination.

Two safeguards were added:

```text
Explorer ThumbnailService
→ one active thumbnail worker by default

native thumbnail API
→ process-wide serialization mutex
```

This creates one authoritative in-process thumbnail lane.

The surrounding async/cache design remains valuable:

- requests still deduplicate
- cached results remain immediate
- queued work remains off the UI thread
- pause/drain still protects Explorer → Player handoff
- the native lane simply prevents simultaneous MLT thumbnail graphs from
  executing inside the process

## New concurrency regression

The focused native smoke was expanded so multiple callers deliberately invoke
thumbnail generation concurrently.

The test proves that:

- concurrent callers complete safely
- every caller publishes a thumbnail
- representative-frame selection still works

Only after that test passed was the standalone release rebuilt and exercised
against the folder that previously crashed.

The release remained stable.

---

# 15. The two release failures were different problems with the same lesson

It is useful not to collapse the two incidents into one generic “release bug.”

They were distinct.

## Incident A — producer/thread-context problem

```text
still image
→ implicit qimage selection
→ Qt/thread assumptions in standalone release
→ explicit pixbuf / avformat policy
```

## Incident B — decoder concurrency problem

```text
MLT-native thumbnails
→ concurrent in-process callers
→ optimized standalone release crash
→ serialized native thumbnail lane
```

The common lesson is about validation:

> A native desktop application can pass unit tests, headless tests, and `flutter run` while still failing in the installed-style release environment.

Different launch modes change enough variables to matter:

- optimization
- scheduling
- library loading context
- plugin behavior
- process/thread timing
- application-framework assumptions

The project now treats release execution as its own proof tier.

---

# 16. Current four-tier validation model

For native-heavy changes, the practical test ladder is now:

## Tier 1 — Flutter/static behavior

```bash
flutter analyze
flutter test
```

Current checkpoint:

```text
No analyzer issues
64 Flutter tests passed
```

## Tier 2 — native headless regression

```bash
tools/thumbnail_smoke.sh
tools/smoke.sh
```

The thumbnail smoke covers:

- MLT initialization
- video thumbnail generation
- representative-frame selection past a two-second black leader
- correct output dimensions
- still thumbnail generation
- missing-media failure
- native diagnostic propagation
- concurrent callers safely serialized

The main smoke suite continues to cover:

- no-active-engine guards
- transport/composition
- preview/export parity
- layer timing
- source trims
- visual order
- export presets
- output frame-rate conform

## Tier 3 — Flutter debug interaction

```bash
flutter run -d linux
```

This proves real UI navigation, thumbnail population, Explorer → Player handoff,
and normal interaction.

## Tier 4 — standalone release interaction

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

For Explorer/native changes, this tier should include at least:

```text
browse a thumbnail-heavy directory
open timed video
return to Explorer
open a PNG/still
return to Explorer
continue browsing
```

This tier caught both release-only bugs and is now part of the expected
engineering workflow.

---

# 17. Test growth across the Explorer phase

Phase 11.1 began with:

```text
21 Flutter tests
```

By the completion of Phase 11.8 and thumbnail hardening:

```text
64 Flutter tests
+ focused native thumbnail smoke
+ existing full native smoke/parity suite
+ standalone release proof
```

The important accomplishment is not just the count.

Each Explorer slice added tests while the feature was introduced rather than
waiting for the browser to become large and then trying to retrofit coverage.

That preserved the testing discipline established during the Player and
composition work.

---

# 18. Phase-by-phase Explorer checkpoint

## Phase 11.1 — foundation

```text
Explorer application home
Open Folder
folder/media scan
selection
folder navigation
persistent Player handoff
return to same browser context
```

## Phase 11.2 — thumbnails + release still hardening

```text
real thumbnails
persistent cache
background generation
pause/drain handoff
release-safe primary still producer policy
```

## Phase 11.3 — selected-file metadata

```text
right-side metadata pane
file type/format
file size
modified time
image dimensions
```

## Phase 11.4 — navigation and locations

```text
Back / Forward / Up / Home
Favorites
Recent
persisted location data
```

## Phase 11.5 — thumbnail size and density

```text
Compact → Extra Large
persisted view preference
responsive grid geometry
```

## Phase 11.6 — sorting and filename filtering

```text
Ctrl+F
current-folder filename filter
Name / Modified / Size / Type
ascending / descending
path-stable selection
```

## Phase 11.7 — ratings and tags

```text
0–5 stars
persistent tags
case-insensitive tag dedupe
sparse sidecar catalog
```

## Phase 11.8 — rating and tag filters

```text
minimum-rating filter
exact-tag filter
current-folder tag choices
filename + rating + tag AND semantics
clear all filters
```

## Post-11.8 thumbnail hardening

```text
remove runtime ffmpeg executable dependency
MLT-native thumbnail FFI
representative-frame selection
cache version migration
serialized native thumbnail lane
release concurrency regression
```

---

# 19. What did not change

The Explorer expansion did not turn MLT Player into an NLE or a full asset
management database.

It still does not assume:

- giant project files
- conventional timeline editing
- recursive catalog ingestion
- automatic multi-selection workflows
- source-media metadata rewriting
- database ownership of every media file

The central workflow remains:

```text
open folder
→ browse
→ organize lightly
→ select one asset
→ inspect/edit precisely in Player
→ export if needed
→ return to browser
```

---

# 20. Current architectural picture

```text
Flutter app
   |
   +-- MLT Explorer
   |      |
   |      +-- directory scanner
   |      +-- metadata service
   |      +-- navigation service
   |      +-- view preferences
   |      +-- sort/filter service
   |      +-- annotation service
   |      |
   |      +-- ThumbnailService
   |             |
   |             +-- persistent cache
   |             +-- in-flight dedupe
   |             +-- pause/drain
   |             +-- single active worker
   |             |
   |             +-- MltThumbnailBridge
   |                    |
   |                    +-- serialized native thumbnail API
   |                           |
   |                           +-- private MLT producer/profile
   |                           +-- representative-frame scoring
   |                           +-- JPEG output
   |
   +-- persistent MLT Player
          |
          +-- selected asset only
          +-- preview engine
          +-- composition
          +-- inspection
          +-- export
```

The Explorer and Player now use MLT for the media-decoding paths that matter to
their shared workflow, while keeping thumbnail lifecycle and Player lifecycle
separate.

---

# 21. Final outcome of this build

The Explorer phase moved the application from:

```text
precision Player with a browser shell
```

to:

```text
usable local media browser
+
precision Player
```

The visible accomplishments are substantial:

- real representative thumbnails
- metadata browsing
- desktop navigation/history
- favorites/recent locations
- adjustable visual density
- sorting/filtering
- ratings
- tags
- rating/tag triage

The less visible accomplishments matter just as much:

- runtime thumbnail decoder aligned with MLT instead of an external CLI
- explicit still-image producer policy
- cache migration/version discipline
- release-only native concurrency hardening
- diagnostics instead of silent thumbnail failure
- regression coverage for black leaders and concurrent callers
- standalone release testing promoted to a first-class engineering requirement

POC 11 therefore did more than add Explorer features.

It established a browser architecture and a validation discipline suitable for
shipping a native-media desktop application rather than merely running it from
the Flutter development harness.
