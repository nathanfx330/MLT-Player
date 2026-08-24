<!-- docs/poc-11-mlt-explorer-foundation.md -->

# POC 11: MLT Explorer Foundation

## Turning the precision Player into the preview engine of a media browser

The original reason for building MLT Player was larger than a standalone
playback window.

The intended product was a local media browser in the spirit of Adobe Bridge:

```text
open a directory
→ see the media
→ move quickly through assets
→ open one in a purpose-built MLT preview/player
→ inspect or make a precise change
→ return to browsing
```

The Player had to become trustworthy before it could be embedded in that
workflow.

By the start of POC 11 the Player already had precise transport, metadata,
selection/trim, export, three-layer composition, arbitrary timed-video base
promotion, and atomic graph-changing presentation.

Phase 11.1 therefore concentrates on **application structure and navigation**,
not thumbnails.

The implementation described here was built and tested on Linux against **MLT
7.22.0**.

---

# 1. Explorer becomes the application home

Before POC 11, `main.dart` launched directly into the Player.

That made sense while playback was the product under construction, but it was
the wrong final entry point.

The application now launches into:

```text
MLT Explorer
```

The Player becomes the selected-asset workspace behind the browser.

The conceptual product model is:

```text
Explorer = home
Player   = precision workspace
```

---

# 2. The first slice deliberately avoids thumbnails

The first Explorer cards use media-type placeholders.

This is not a compromise in the final design. It is an ordering decision.

The browser needed to prove:

- directory selection
- scanning
- file classification
- selection
- navigation
- keyboard focus
- Player handoff
- Player return
- MLT lifecycle preservation

before adding background image generation.

That prevents thumbnail concurrency from hiding basic browser/navigation bugs.

---

# 3. Directory scanning is a separate service

The first Explorer service scans one directory non-recursively.

It returns typed items rather than handing raw `FileSystemEntity` objects to the
UI.

The browser model distinguishes:

- folders
- video
- image
- audio
- MLT/XML project-like files

Unsupported files are filtered out.

Folders sort before media, with alphabetical ordering inside each group.

This gives the UI a stable predictable list independent of thumbnail work.

---

# 4. The browser shell is intentionally small

Phase 11.1 provides:

```text
Open Folder
folder/media grid
selection
folder entry
parent-folder navigation
Open in Player
return to Explorer
```

It does not yet provide:

- real thumbnails
- search index
- ratings
- tags
- asset database
- recursive catalog
- giant DAM workflow

The product remains a fast local utility.

---

# 5. Explorer and Player share one persistent application shell

A critical architecture decision was **not** to treat Player as a disposable
route that is destroyed every time the user goes back to the browser.

The Player already owns a hardened native lifecycle:

```text
Flutter PlayerEngine
→ Dart FFI
→ opaque native MLT engine
→ preview consumer
→ texture path
```

Repeatedly tearing that down merely because the user pressed Back would create
avoidable startup, texture, focus, and native-lifetime risk.

Instead Explorer and Player live in one persistent shell.

Conceptually:

```text
App shell
   |
   +-- Explorer view
   |
   +-- Player view
```

Only one is presented at a time, but the Player remains alive.

Returning to Explorer therefore does not require reinitializing the MLT
repository, engine, texture registration, or preview infrastructure.

---

# 6. Opening media is a command into the existing Player

Explorer does not implement a second preview system.

When a media item is opened, the shell hands its path to the existing Player
workspace.

This preserves one source of truth for:

- MLT open behavior
- codec handling
- still classification
- audio/video detection
- transport
- metadata
- composition
- export

The browser is responsible for discovering and selecting assets.

The Player remains responsible for actually opening them.

---

# 7. Returning to Explorer preserves browser context

The browser keeps:

- current directory
- item list
- current selection

Opening Player does not replace the Explorer with a newly constructed browser.

When the user returns, the same directory and selection are still present.

This is essential to the Adobe Bridge-style workflow: inspect an asset, return,
and continue browsing from the same place.

---

# 8. Focus is part of desktop navigation correctness

Keeping both views alive introduced a desktop-specific issue: a hidden view can
retain keyboard focus.

The shell therefore moves focus explicitly as the active view changes.

Explorer shortcuts must belong to Explorer.

Player transport shortcuts must belong to Player.

Without explicit handoff, arrow keys or Enter could be delivered to the wrong
workspace even though the other view is visible.

This is a small implementation detail with a large effect on whether the
application feels like a real desktop tool.

---

# 9. Current Explorer navigation

Phase 11.1 supports:

- Open Folder button
- `Ctrl+Shift+O` — Open Folder
- `Ctrl+O` — direct Open media
- single-click selection
- double-click open
- `Enter` open
- parent-directory toolbar navigation
- `Backspace` parent directory
- Player back control
- `Esc` from Player returns to Explorer when Player is not fullscreen

The Player still owns its established transport/edit shortcuts while active.

---

# 10. Same-path reopening needed an explicit request model

A subtle shell bug was caught before packaging.

If the browser opened one asset, the Player later opened another asset, and
Explorer then requested the original pathname again, a naïve "path changed"
check could treat that as no new work.

Explorer therefore treats opening as a **request**, not merely a new string
value.

Selecting the same pathname again must still be able to issue a fresh Player
open.

This is important for a browser, where repeated navigation among a small set of
files is normal.

---

# 11. Phase 11.1 testing

The Explorer service adds Flutter tests around the pure directory-scan behavior.

At the completed checkpoint:

```text
flutter analyze
→ No issues found

flutter test
→ 21 tests passed

tools/smoke.sh
→ all native groups passed with zero failures
```

The native suite still proves the Player foundation underneath Explorer:

- no-active-engine guards
- transport/composition smoke
- preview/export parity
- Layer START / END
- SOURCE IN / SOURCE OUT
- visual ordering
- video export presets
- layered frame-rate conform

Interactive Linux testing additionally proved:

```text
launch
→ Explorer appears
→ choose directory
→ browse folders/media
→ open asset in Player
→ Player works
→ return to Explorer
```

---

# 12. Why thumbnails are a separate subsystem

The next phase should not generate thumbnails by repeatedly opening every file
through the live PlayerEngine.

A large directory may contain hundreds or thousands of assets.

The correct architecture is closer to:

```text
Explorer
   |
   +-- DirectoryScanner
   |
   +-- ThumbnailService
   |      |
   |      +-- background workers
   |      +-- visible-item priority
   |      +-- cancellation
   |      +-- persistent cache
   |
   +-- PlayerEngine
          |
          +-- selected asset only
```

The live Player must remain responsive and dedicated to the selected item.

Thumbnail generation is batch/background work with a different lifecycle and
different performance constraints.

---

# 13. Thumbnail cache identity

A persistent cache should be invalidated when the underlying media changes.

A practical cache identity can be derived from values such as:

```text
absolute path
+ file size
+ modification timestamp
```

The exact on-disk key format is a Phase 11.2 implementation detail, but the
product rule is already clear:

> Reopening an unchanged directory should not regenerate unchanged thumbnails.

---

# 14. Phase 11.2 target

The next bounded slice is:

```text
real thumbnails
+ asynchronous generation
+ persistent cache
```

The first implementation should prioritize visible grid items and avoid
blocking directory navigation.

Likely media behavior:

- images → scaled image thumbnail
- timed video → representative decoded frame
- audio → type artwork/waveform later, not required for the first thumbnail slice
- folders → folder treatment, not generated media thumbnails

Only after that foundation is proven should Explorer add richer browsing
features such as a detailed selection metadata pane, thumbnail-size controls,
navigation history, or optional favorite locations.

---

# 15. Product direction after Phase 11.1

The project has now reached the workflow that originally motivated the custom
Player:

```text
MLT Explorer
      ↓
browse local media
      ↓
select asset
      ↓
MLT Player
      ↓
precise inspection / edit / export
      ↓
return to Explorer
```

The Player is no longer the destination.

It is the precision media engine inside the larger browsing workflow.
