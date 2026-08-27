# MLT Player

[![CI](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml/badge.svg)](https://github.com/nathanfx330/MLT-Player/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A fast, frame-exact media browser, project organizer, and precision player for
Linux, built on
[MLT (Media Lovin' Toolkit)](https://www.mltframework.org/), with optional
Redleaf-backed workspace projects for indexed transcript and media archives.

<!--
TODO: add screenshots. Suggested:
(1) Explorer grid with thumbnails and Project/Catalog controls
(2) Redleaf Project open from a cached snapshot
(3) Player with the Layers inspector open
(4) Storyboard or Bookmarks view

![Explorer](docs/images/explorer.png)
![Redleaf Project](docs/images/redleaf-project.png)
![Player](docs/images/player.png)
-->

---

## What this is

MLT Player is built around three connected workspaces:

**Explorer** is the main browser. For local Projects it is filesystem-first:
open a directory directly, browse real media thumbnails, filter and sort,
organize files into Catalogs, and open an asset without importing it into a
media database first. For Redleaf Projects it browses a saved Redleaf
catalog/SRT snapshot and can reconnect to Redleaf only when live data or a
controlled media-link action is needed.

**Project** is the organizational layer. Local Projects summarize Catalogs,
ratings, tags, color labels, and bookmarks. Redleaf Projects have their own
persistent MLT Player identity, name, last-known server, source identity, and
cached Redleaf snapshot.

**Player** opens a single file for frame-exact inspection, exact-frame
bookmarks, selection and trim, three-layer composition, transcript navigation,
and export.

The Project switch can select either kind of workspace project:

```text
Project Switch
  |
  +-- Local Project
  |     -> filesystem media
  |     -> local Catalogs
  |     -> local ratings / tags / colors / bookmarks
  |
  +-- Redleaf Project
        -> persistent Redleaf instance identity
        -> cached Redleaf Catalogs / SRTs / media-link state
        -> explicit SYNC NOW for refresh
```

The basic local workflow remains deliberately direct:

```text
open a directory or media file
  -> browse visually
  -> organize only if useful
  -> inspect precisely
  -> make one surgical change
  -> export
  -> return to the browser
```

The Redleaf workflow follows the same principle:

```text
connect to Redleaf
  -> save/select the Redleaf Project
  -> SYNC NOW when a fresh snapshot is wanted
  -> browse the snapshot immediately afterward or while disconnected
  -> open a linked local media file with its exact Redleaf transcript
```

The filesystem remains primary for media playback. Redleaf supplies indexed
document organization and media relationships; MLT Player never turns those
relationships into a proprietary media store.

> **The filesystem owns the media. Projects organize it. Redleaf can index and
> relate it. MLT plays and transforms it.**

## Why it exists

QuickTime 7 Pro occupied a specific niche: open a file, look at it closely, do
one thing to it, save, close. Nothing replaced it cleanly. Modern tools are
often either players that tell you almost nothing about the file, or editors
that require an ingest-and-project workflow before useful work can begin.

MLT Player tries to recover that directness on Linux while adding the pieces
that become necessary once a media collection grows: visual browsing,
persistent annotations, lightweight Projects, Catalogs, precise playback, and
optional interoperability with an existing Redleaf archive.

Local Projects do **not** sit between you and your files. You can still open a
directory or individual media file directly. A Local Project scopes
organization and metadata; it does not take ownership of the media.

Catalogs are intentionally lightweight. They are bin-like in the useful sense:
a media file can belong to one or more named collections, including nested
Catalogs, without being copied, moved, or imported into a proprietary project
store. Catalog membership and Project metadata are organizational state layered
over ordinary filesystem paths.

Redleaf Projects follow the same separation. MLT Player stores a lightweight
workspace identity and cached snapshot keyed to the Redleaf database
`instance_id`. It does not duplicate the Redleaf database and does not make
Redleaf a hidden dependency for opening the application.

That distinction is deliberate.

Non-goals remain: no NLE timeline, no conform workflow, no mandatory ingest
database, no batch transcoder, and no feature added merely because MLT exposes
it.

---

## Features

### Explorer

- Filesystem-first local browsing with typed classification for video, audio,
  image, and project-like files
- Thumbnails decoded through MLT rather than an external `ffmpeg` process, so
  Explorer and Player agree about what a file contains
- Representative-frame selection that scores candidates and skips black leader,
  slates, and fades instead of blindly grabbing one fixed offset
- Persistent thumbnail cache with atomic publish and adjustable tile size
- Filename filtering, sorting, navigation history, Home, Up, Back, Forward,
  and saved favorite folders
- Direct Open File and Open Folder workflows
- Compact Settings access from Explorer
- The same top-level Explorer can switch between Local and saved Redleaf
  workspace Projects

### Projects and Catalogs

- Multiple Local Projects with create, rename, switch, and delete
- Persistent Redleaf workspace Projects keyed by Redleaf `instance_id`
- User-defined MLT Player names for Redleaf Projects without renaming the
  Redleaf source database
- Redleaf Projects remain selectable after disconnect and application restart
- Per-Project Favorites for Local Projects
- Nested local Catalogs
- Many-to-many local Catalog membership: one media file may belong to multiple
  Catalogs without being duplicated
- Catalog browsing through the same Explorer surface
- Project-wide dashboard with Catalog and metadata counts
- Clickable Project dashboard rows that open Explorer directly into the
  corresponding Catalog or smart view

A **local Catalog** is intentional membership: you explicitly put media into it.

A **smart view** is computed from Local Project metadata: ratings, tags, colors,
and bookmarks can produce a project-wide view without changing Catalog
membership.

Redleaf Catalog membership is read from Redleaf and cached as part of a Redleaf
Project snapshot. MLT Player does not write Redleaf Catalog membership.

### Project metadata and smart views

Local Project metadata is scoped to the active Local Project rather than stored
as one global annotation layer.

- 0–5 star ratings
- Exact rating filters such as `Exactly 4★`
- Minimum rating filters such as `4★ or better`
- Tags
- Color labels
- Exact-frame bookmarks
- Project-wide smart views for ratings, tags, colors, and bookmarked media
- Combined filtering: filename, rating, tag, and color filters can be layered
  together
- Project Bookmarks view containing only media that currently has one or more
  bookmarks

Bookmarks are soft screenshots: they store exact source-frame positions rather
than creating image files.

### Redleaf workspace integration

Redleaf is a first-class **workspace-project source**, not a separate top-level
application tab and not a fake Local Project.

A saved Redleaf Project is keyed by:

```text
redleaf:<instance_id>
```

MLT Player keeps the local display name separate from Redleaf's own
`project_name`. The source-side name is informational; renaming a Redleaf
Project in MLT Player does not rename Redleaf.

#### Persistent project identity

A saved Redleaf Project records:

- Redleaf `instance_id`
- user-controlled MLT Player display name
- last-known Redleaf server URL
- Redleaf source project name for reference
- created / updated / last-synced timestamps

Saved Redleaf Project records survive Redleaf disconnects and MLT Player
restarts.

Redleaf sessions are deliberately **not** persisted. A new MLT Player launch
starts disconnected until the user signs in again. Reconnecting authenticates
and identifies the Redleaf instance only; it does not silently scan the archive.

#### Cache-first snapshots

`SYNC NOW` is the explicit refresh boundary.

A Redleaf Project snapshot stores:

- SRT document identity and exact relative path
- document status, color, size, duration, and tag count
- Redleaf media-link state and reference
- Redleaf Catalog definitions
- exact Catalog-to-SRT memberships
- snapshot synchronization time

The snapshot is persisted locally and is loaded by Redleaf `instance_id`.

That means:

```text
open saved Redleaf Project
  -> load cached snapshot immediately
  -> browse while disconnected
  -> reconnect only when needed
  -> press SYNC NOW only when a fresh archive snapshot is wanted
```

Opening Explorer or reconnecting to Redleaf does **not** perform a hidden full
SRT/media scan.

The Redleaf Explorer view reports SRT totals including:

- media linked
- transcript only
- media status unknown

Catalog filtering works from the cached membership snapshot while disconnected.

#### Exact transcript handoff

When a Redleaf SRT with verified local media is opened in Player, MLT Player
carries the selected Redleaf document identity into the handoff.

The transcript is loaded from the selected document's **exact Redleaf SRT
relative path** through Redleaf's authenticated `/serve_doc/...` route and
parsed by the existing SRT subtitle service.

There is no basename guessing.

The handoff is keyed by the Redleaf `instance_id` and document ID, so Player
does not accidentally attach a similarly named transcript from another part of
the archive.

#### Verified media resolution

Redleaf `media_status` is treated as the authority for the relationship.

For local media, MLT Player resolves Redleaf virtual paths using the same model
Redleaf uses:

- ordinary media under Redleaf's `documents/` tree
- media reached through root `.rlink` virtual folders
- exact virtual path preservation
- physical filesystem resolution only when needed
- existence verification before a resource is considered Player-ready

A local media relationship is not enough by itself: the final filesystem file
must exist before MLT Player opens it.

External web media URLs are preserved as Redleaf media candidates, but they are
not currently treated as native MLT Player-ready resources.

#### Controlled `SCAN FOR MEDIA` write

Redleaf integration is read-only by default with one deliberately narrow write
operation:

**SCAN FOR MEDIA**

It is available only when Redleaf explicitly reports the selected SRT as
transcript-only and the matching Redleaf instance is connected.

The current scan policy is intentionally conservative:

```text
selected transcript-only SRT
  -> ask Redleaf for exact local .mp4 match
  -> if none, ask Redleaf for exact local .mp3 match
  -> Redleaf performs the filesystem / .rlink scan
  -> Redleaf writes the relationship
  -> MLT Player refreshes only that document's media_status
  -> update the local snapshot
```

MLT Player does **not** run an independent filesystem scanner.

Redleaf's optional fuzzy-name matching is deliberately disabled in MLT Player
for this action. A scan either finds Redleaf's exact match or reports no match;
it does not silently guess.

The write uses the authenticated Redleaf session and refreshes CSRF
authorization from the exact Redleaf document workbench immediately before the
POST.

MLT Player does not currently write Redleaf tags, Catalog membership, document
metadata, playback offsets, or other Redleaf state.

### Redleaf `.rlink` interoperability

MLT Player also understands Redleaf `.rlink` files as virtual folders during
normal filesystem browsing.

An `.rlink` points at an external directory while preserving a virtual browsing
path inside Explorer. Media stays on the external filesystem; MLT Player does
not copy it into the Project.

This is useful for large archives, removable storage, and collections already
organized for Redleaf because the same external tree can remain the source of
truth.

Current `.rlink` support includes:

- `.rlink` entries displayed as virtual folders
- virtual breadcrumbs while browsing linked media
- physical path resolution only when actual filesystem or media access is
  required
- disconnected links remaining visible instead of silently disappearing
- normal Player, thumbnail, and export access to resolved media
- Redleaf media-resource resolution through `.rlink` paths during Redleaf
  Player handoff

`.rlink` support is implemented and tested at the application level. Real
removable-drive workflows are still being field-verified, so portable media
identity beyond the current path-based model is intentionally not claimed yet.

### Player

- Frame-exact stepping
- J/K/L shuttle at 1x, 2x, 4x, and 8x in both directions
- Play All Frames for deterministic no-drop review
- Clip-relative timecode plus embedded source timecode
- Deep inspection including codec, pixel format, colorspace, transfer
  characteristic, color range, source timecode, full stream list, channel
  layout, and bitrate
- In and Out marking
- Play Selection
- Non-destructive Trim with full Undo and Redo
- Storyboard view at 5, 10, 30, or 60 second intervals
- Exact-frame Bookmarks with generated frame previews
- Searchable SRT sidecar subtitles with UTF-8, Windows-1252, and Latin-1
  handling
- Floating transcript sidebar with search-to-seek behavior
- Exact Redleaf transcript handoff for verified Redleaf local media

### Composition

- Three fixed layer slots, indexed identically on both sides of the FFI boundary
- Per-layer timeline START and END
- Per-layer source IN and OUT
- Opacity, visibility, position, scale, anchor, alpha interpretation, and audio
  gain
- Visual Z-order independent of logical slot identity
- Base-role promotion applied as an atomic graph-changing edit
- Composition edits participate in Undo and Redo

Layer 4 is deliberately rejected rather than silently creating an untested
topology. The three-slot model is indexed and generalized, so adding another
slot is a feature decision rather than a hidden topology change.

### Export

- Independent export graph; the live playback graph is never reused
- H.264 Delivery preset
- ProRes 422 HQ Master preset
- Current-frame PNG
- PNG sequence
- WAV
- Explicit output frame rate with layer positions correctly conformed
- Background export thread
- Progress and cancellation
- Partial-file cleanup
- Preview and export derive composition from shared policy code and are checked
  against each other in CI

---

## Requirements

Linux with MLT **7.22.x**. Other series may work but are not validated.

```bash
sudo apt-get install -y \
  libepoxy-dev \
  libgtk-3-dev \
  libmlt-data \
  libmlt-dev \
  pkg-config \
  ffmpeg
```

`libmlt-data` is required, not optional. MLT service discovery depends on the
installed service dictionaries, and the application fails in confusing ways
without them.

`ffmpeg` and `ffprobe` are used by the test tooling for fixture generation and
output validation. They are not used as the application's runtime media engine.

Flutter with Linux desktop support enabled is also required.

### Optional Redleaf integration

Redleaf workspace support requires a reachable, compatible Redleaf server and a
normal Redleaf user account.

Configure the Redleaf server and sign in from MLT Player Settings. MLT Player
may remember connection convenience information, but authenticated sessions are
not persisted between application launches.

The current integration expects Redleaf support for:

- system identity
- dashboard inventory
- Catalog listing and membership lookup
- per-document `media_status`
- authenticated document serving
- exact local `find_video` / `find_audio` media linking

Redleaf itself remains responsible for its database, filesystem discovery,
`.rlink` resolution, and relationship writes.

## Build and run

```bash
flutter pub get
flutter run -d linux
```

After changing anything under `native/`:

```bash
flutter clean
flutter pub get
flutter run -d linux
```

Release build:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

---

## Keyboard shortcuts

### Explorer

| Key | Action |
| --- | --- |
| `Ctrl+Shift+O` | Open folder |
| `Ctrl+O` | Open media directly |
| `Ctrl+F` | Focus the filename filter |
| `Alt+Left` / `Alt+Right` | Back / Forward |
| `Alt+Home` | Home |
| `Backspace` | Parent directory |
| `Enter` or double-click | Open the selection |

### Player

| Key | Action |
| --- | --- |
| `Left` / `Right` | Step one frame |
| `J` / `K` / `L` | Reverse shuttle / pause / forward shuttle |
| `I` / `O` | Set In / Set Out |
| `Shift+Space` | Play Selection |
| `Ctrl+T` | Trim Selection |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / Redo |
| `C` | Toggle subtitles |
| `Ctrl+F` | Open/focus transcript search |
| `Ctrl+I` | Inspector |
| `Ctrl+E` | Export |
| `Esc` | Return to Explorer |

---

## Architecture

```text
Flutter application
  |
  +-- WorkspaceProjectService
  |     |
  |     +-- local:<uuid>
  |     |     |
  |     |     +-- ProjectCatalogService
  |     |     +-- ProjectMediaMetadataService
  |     |
  |     +-- redleaf:<instance_id>
  |           |
  |           +-- RedleafProjectRegistryService
  |           +-- RedleafProjectSnapshotService
  |           +-- RedleafConnectionService
  |           +-- RedleafCatalogService
  |           +-- RedleafSrtDiscoveryService
  |           +-- RedleafMediaResourceService
  |           +-- RedleafMediaScanService
  |           +-- RedleafTranscriptService
  |
  +-- Explorer workspace
  |     |
  |     +-- local filesystem / .rlink browsing
  |     +-- local Catalogs and smart views
  |     +-- cached Redleaf SRT/Catalog browsing
  |     +-- ThumbnailService ---------------------+
  |                                               |
  +-- Project workspace                           |
  |                                               |
  +-- Player view -------- PlayerEngine ----------+
  |                                               |
  +-- Dart FFI --------------------------> libmlt_bridge.so
                                                   |
                                            opaque MLT engine
                                                   |
                            +----------------------+----------------------+
                            |                                             |
                         preview                                       export
                            |                                             |
                   indexed composition                          indexed snapshot
                            |                                             |
                         tractor                                  fresh tractor
                            |                                             |
                   preview consumer                            avformat consumer
                            |
                    OpenGL texture -> Flutter Texture widget
```

Flutter owns the application. MLT owns media playback and transformation. A
small C bridge connects them, split into translation units for engine/playback,
shared composition policy, export, and thumbnail generation.

`WorkspaceProjectService` sits above the project-source implementations.

A Local Project continues to use the existing local Catalog and metadata
services.

A Redleaf Project is deliberately separate. Its identity is the Redleaf
`instance_id`; its cached snapshot and MLT Player display name are persistent,
while its authenticated connection remains ephemeral. Redleaf IDs are never
passed into Local Project metadata services.

Explorer and Project share the same Local Project Catalog and metadata services
when a Local Project is active. When a Redleaf Project is active, Explorer uses
the Redleaf snapshot/services instead of pretending the remote archive is a
Local Project.

Explorer and Player are persistent views rather than native lifecycles that are
destroyed and rebuilt on every navigation. Thumbnail generation uses independent
producer and profile objects and never drives the live player through a
directory.

Preview and export intentionally build separate MLT graphs. The composition
rules both paths depend on live in shared code so they cannot quietly drift.

For the broader engineering record, see
[`docs/architecture.md`](docs/architecture.md).

### Building on MLT yourself?

The standalone engineering guide
**[Embedding MLT in a Flutter/Linux Desktop Player: Field Notes from Building MLT Player](docs/embedding-mlt-in-a-flutter-linux-app.md)**
is written for developers embedding MLT rather than driving it through `melt`.

It covers the producer/consumer model, lazy rendering, threading and lock
boundaries, external Flutter textures, frame-exact transport, metadata,
consumer lifecycle properties, background export, and failures that looked like
MLT bugs but were not.

The chronological POC documents remain available as the project's historical
engineering record in [`docs/`](docs/README.md).

---

## Data model

MLT Player deliberately separates media, organizational state, and remote source
identity.

```text
Workspace Project
  |
  +-- Local Project
  |     |
  |     +-- filesystem media
  |     +-- Favorites
  |     +-- Catalogs
  |     |     +-- nested Catalogs
  |     |     +-- media memberships
  |     |
  |     +-- media metadata
  |           +-- rating
  |           +-- tags
  |           +-- color label
  |           +-- bookmark frames
  |
  +-- Redleaf Project
        |
        +-- identity
        |     +-- instance_id
        |     +-- MLT Player display name
        |     +-- last-known server
        |     +-- source project name
        |
        +-- persistent snapshot
        |     +-- SRT documents
        |     +-- Catalogs
        |     +-- Catalog memberships
        |     +-- media-link state
        |     +-- synced_at
        |
        +-- ephemeral live connection
              +-- authenticated session
              +-- CSRF authorization
```

The local filesystem can also contain:

```text
filesystem
  |
  +-- media files
  +-- directories
  +-- Redleaf .rlink pointers
```

Deleting a Local Catalog does not delete the media file. Assigning media to a
Local Catalog does not move or copy it. A media file may be represented in more
than one Catalog while still having one ordinary filesystem location.

A Redleaf snapshot does not copy the media or replace Redleaf's database. It
stores enough Redleaf document and relationship state for immediate browsing and
deliberate synchronization.

The persistent Redleaf state currently lives under MLT Player's config
directory, including the saved project registry and per-instance snapshots.
Authenticated Redleaf sessions are intentionally excluded from that persistent
project state.

That separation is the reason both Local and Redleaf Projects fit the original
file-first design rather than replacing it.

---

## Testing

```bash
flutter analyze
flutter test
tools/smoke.sh
tools/thumbnail_smoke.sh
```

CI runs the automated suites on every push.

The native smoke suites are headless and cover engine guards, transport, layer
timing, source trims, layer ordering, export presets, frame-rate conform, and
preview/export parity. Parity is checked by comparing derived composition state
between the two graphs, and the frame-rate conform test goes further: it decodes
output frames and asserts the color, so a layer that lands on the wrong frame
after conversion fails rather than passing quietly.

The workspace-project test suite also covers Redleaf identity persistence,
selection across disconnect, and MLT Player-local Redleaf naming behavior.

Because Redleaf integration crosses the boundary between two applications,
cache-first reconnect, explicit synchronization, exact transcript handoff,
verified local-media playback, and `SCAN FOR MEDIA` are also validated against
a live Redleaf instance during integration development.

Some failures during Explorer development appeared only in standalone release
builds and not under `flutter run`. Release validation is therefore a
first-class tier rather than an afterthought:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/mlt_player
```

A separate reproducible diagnostic for the known MLT 7.22 audio-flush PTS
warning lives in `tools/pts_diag.sh`. It is deliberately not part of CI because
gating on a known upstream issue would make the build red for something outside
this project. It becomes a regression gate when the MLT baseline moves to a
version containing the fix.

---

## Status and roadmap

### Implemented

- Playback foundation and Linux external-texture preview
- Frame-exact transport and inspection
- Selection, trim, Undo, and Redo
- Storyboard and exact-frame bookmarks
- Searchable SRT sidecars and transcript navigation
- Three-layer composition model
- H.264, ProRes, PNG, PNG-sequence, and WAV export
- Filesystem Explorer with MLT representative thumbnails
- Local Projects and nested Catalogs
- Per-Project Favorites
- Project-scoped ratings, tags, color labels, and bookmarks
- Exact and minimum rating filters
- Project dashboard
- Project-wide rating, tag, color, and bookmark smart views
- Redleaf `.rlink` virtual-folder support
- Persistent Redleaf workspace Projects keyed by `instance_id`
- User-defined MLT Player names for Redleaf Projects
- Persistent Redleaf catalog/SRT/media snapshots
- Cache-first Redleaf browsing across disconnect and restart
- Connection-only Redleaf reconnect with no automatic project scan
- Explicit Redleaf `SYNC NOW`
- Cached Redleaf Catalog membership browsing
- Exact Redleaf transcript handoff to Player
- Verified Redleaf local-media resolution including `.rlink`
- Controlled Redleaf `SCAN FOR MEDIA` exact-match write path
- Targeted post-link `media_status` refresh without a full project sync

### Next

- **Interchange:** MLT XML save and open. The composition can be built but not
  yet saved, which remains the largest interchange gap.
- Real removable-drive field verification for `.rlink`
- Portable media identity only after real `.rlink` behavior is proven
- Image sequences treated as single browsable items rather than thousands of
  files
- Richer layer timing and ordering rules
- Blend modes and a broader alpha/color policy
- Redleaf integration polish only where it preserves the current explicit
  read/sync/write boundaries

The roadmap deliberately favors capabilities that preserve MLT Player's
file-first character rather than turning it into a conventional NLE.

---

## License

MLT Player's own source is MIT licensed. See [`LICENSE`](LICENSE).

That covers code authored for this repository. It does not cover MLT, FFmpeg,
codec libraries, Redleaf, or other third-party components used at runtime or
bundled into a binary package.

MLT Player dynamically links `mlt-framework-7`, which is LGPL-2.1, but
individual MLT modules carry different licenses and some build configurations
enable GPL components. FFmpeg is normally LGPL-2.1-or-later and becomes GPL when
components such as `libx264` are enabled.

Anyone distributing prebuilt binaries should audit the exact MLT modules,
FFmpeg configuration, codec libraries, and any separately distributed Redleaf
components being shipped, then satisfy the obligations that actually apply. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the distribution
checklist and upstream references.

---

Built and tested against MLT 7.22.0 on Linux.
