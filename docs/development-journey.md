<!-- docs/development-journey.md -->

# MLT Player: Development Overview and Update Record

**Record through November 10, 2026**

This document connects MLT Player's engineering history into a single narrative. **Part I** describes the development from a precise MLT-backed player to a file-first media browser with projects, catalogs and composition tools. **Part II** records the November 9 Redleaf integration checkpoint, including authentication, Trash, the shared encrypted credential vault and linked-video thumbnail parity. **Part III** continues through the November 10 Gold merges, including PROJECT BROWSE, Player handoff safety, thumbnail recovery, and coordinated cross-repository CI.

This is a history, not a replacement for [current architecture](architecture.md), [current Redleaf workspace behavior](redleaf-workspace.md), or the [root README](../README.md). The individual POC documents remain the detailed evidence for their stages.

---

# Part I. Development overview

## 1. Product intention: a media browser with a serious Player

The project was not intended to grow into a conventional nonlinear editor with an ever-expanding timeline. Its target was a **local, file-first media browser**, similar in workflow to Adobe Bridge, with a precise media Player available whenever an asset needed inspection, annotation, a trim or an export.

The eventual loop was:

```text
Find an asset in Explorer
    -> Open the persistent MLT Player
    -> Inspect, seek, select, annotate or compose
    -> Export only when explicitly requested
    -> Return to Explorer and continue browsing
```

The Player had to become reliable before that browser could depend on it. That development order explains why early POC records emphasize decoding, exact frames, native interfaces and export long before Explorer became the application's home screen.

## 2. Initial foundation: Flutter as the interface, MLT as the engine

The system established a clear ownership boundary:

- **Flutter/Dart** owns windows, navigation, project organization, controls, edit intent, selection, history and subtitle presentation.
- **MLT** owns media decoding, audio, frame production, composition graphs, rendering and export.
- **The native C bridge** exposes a narrow and testable boundary between them.

The Linux runner, Flutter texture presentation and native shared library are parts of a single desktop runtime, but no one part substitutes for the others.

The first Player proofs included source opening and metadata, an external texture preview, frame-accurate transport, J/K/L shuttle controls, In/Out range selection, non-destructive trim, Undo/Redo and a background MP4 export path.

The early engineering lesson was simple: a useful control in Flutter is not proof of correct media timing or rendering. The native side, the preview and the exported file each require their own verification.

Reference: [architecture.md](architecture.md) and [Embedding MLT in a Flutter/Linux Desktop Player](embedding-mlt-in-a-flutter-linux-app.md).

## 3. POC 9: Export becomes a dependable subsystem

[POC 9](poc-9-export-formats-and-hardening.md) expanded the first movie proof into PNG stills, image sequences and audio-only output in addition to movie export.

The difficult work was not exposing additional buttons. It was defining source-range semantics, display geometry, missing audio/video stream behavior, cancellation cleanup, progress, output completion and deterministic tests.

The architectural decision was to **render on an independent export graph** rather than reuse the graph carrying live playback. This avoided an export unexpectedly seeking or reconfiguring the picture a user was inspecting.

## 4. POC 10: From one source to a composition

[POC 10](poc-10-multitrack-compositing-and-export.md) introduced MLT tractors, multiple timed layers, opacity, alpha, audio levels, source replacement and positioning. Later work generalized the model to a third logical layer.

[The POC 10 continuation](poc-10-layer-ordering-and-atomic-role-swaps.md) dealt with layer ordering, base-role promotion and safe presentation during graph changes. It distinguished the visual order of layers from their underlying logical identities.

A composition was not finished merely because preview looked right. The same placement, alpha, timing and ordering policies had to be applied to independently constructed export graphs. The preview/export parity tests are a consequence of that requirement.

## 5. POC 11: Explorer becomes the home screen

[POC 11](poc-11-mlt-explorer-foundation.md) was the product pivot. Instead of launching directly into Player, MLT Player began in Explorer, and Player became the precision workspace behind it.

The first Explorer phase intentionally used placeholder artwork. Directory discovery, classification, selection, focus, navigation and Player handoff were proven **before** background thumbnails were added.

[The POC 11 continuation](poc-11-explorer-growth-thumbnail-hardening.md) added MLT-native representative thumbnails, metadata, navigation, annotation and filtering. Background thumbnail generation was separated from live Player transport, with native decoding serialized and cached results reused.

That separation matters again in the November 2026 Redleaf thumbnail chapter: the later feature reuses the established Explorer pipeline rather than inventing a second decoder.

## 6. POC 12: Storyboard, transcripts and stability

[POC 12](poc-12-storyboard-subtitles-and-last-mile-hardening.md) extended the Player with exact-frame Storyboard views, SRT sidecars and searchable transcript navigation.

It also exposed cross-boundary failures that ordinary widget tests would not necessarily catch: native file-picker lifecycle, focus ownership, background work continuing across view switches, and release-only crashes.

The September follow-on work added bookmark transcript profiles, nested Catalog tiles, workspace-scoped Recent and History, faster representative thumbnail selection, and continuous Storyboard thumbnail backfill with progress and fairness between visible and background requests. These milestones are recorded in [CHANGES.md](../CHANGES.md) and the earlier merged PRs.

## 7. Cross-platform verification became a design requirement

The baseline Linux work used **MLT 7.22.0**. Rocky Linux verification against **MLT 7.40.0** found three separate compatibility problems: a deprecated preview sizing API, private library discovery and a misleading frame-sampling probe under a newer FFmpeg stack.

[Rocky MLT 7.40 Compatibility Journey](rocky-mlt-740-compatibility-journey.md) preserves the sequence of incorrect hypotheses and final proofs. The guiding rule was to **fix the failing layer**, not suppress a warning, weaken a parity assertion, or declare success from an invalid diagnostic.

Current tests therefore span Dart services and widgets, native smoke tests, thumbnail decoding, preview/export parity and real GUI verification.

## 8. The product architecture that emerged

```text
MLT Player
  |
  +-- Explorer: local filesystem, Projects and Catalogs
  |     +-- MLT thumbnail service and representative-frame cache
  |     +-- Ratings, tags, colors, bookmarks and navigation history
  |
  +-- Redleaf workspace: remote-source Project
  |     +-- Redleaf instance_id and authenticated session
  |     +-- Cached SRT documents, catalog membership and media links
  |     +-- Verified local media resolution
  |
  +-- Player: exact transport, Storyboard, SRT navigation
  |     +-- Three-layer composition
  |     +-- Independent preview and export graphs
  |
  +-- Native MLT bridge: playback, composition, export, thumbnails
```

The important constraint is **source ownership**. Local MLT Projects and Redleaf Projects share a user-facing selector but not a database identity or authorization model. The two sources must not be accidentally written through one another's metadata APIs.

---

# Part II. Update chapter: November 9, 2026

## Chapter 1. Redleaf becomes a first-class Project, not another tab

### 1. What the integration needed to solve

A Redleaf archive could already supply SRTs, catalogs and document-to-media relationships, but merely connecting to its server did not answer several product questions:

- Which MLT Player Project represents this archive?
- Can the archive open when Redleaf is offline?
- Can a user choose an MLT Player display name without renaming the Redleaf database?
- How should launching from Redleaf Hub differ from opening an offline project folder?
- What happens to a hidden or trashed Project when Hub tries to reopen it?
- How can MLT Player use linked videos without trusting arbitrary web URLs as local media?

The adopted model makes Redleaf a **Project source** under the existing Explorer and Project views rather than adding a third top-level tab.

Namespaced keys such as `local:<project-id>` and `redleaf:<instance-id>` keep local Project storage distinct from Redleaf's identity. The permanent identity of a Redleaf Project is the initialized database `instance_id`, **not** the folder name or the MLT Player display name.

Reference: [redleaf-workspace.md](redleaf-workspace.md), [`WorkspaceProjectService`](../lib/services/workspace_project_service.dart) and [`RedleafProjectRegistryService`](../lib/services/redleaf_project_registry_service.dart).

### 2. Connected import and native project management

The first integration deliberately separated **signing in** from **creating an MLT Project**. Signing in establishes the Redleaf session. The user then selects an MLT Player name and explicitly imports or reopens the corresponding Project.

Management belongs in the familiar **three-dot menu beside the project selector**, not in a second management list in Settings. Redleaf Projects gained Rename, Move to Trash, Restore and confirmed Empty Trash, following the existing local Project interaction pattern.

Trash is a registry operation:

- A trashed entry disappears from the active switcher but keeps its display name and Redleaf instance identity reserved.
- Restore is explicit, including when a Hub launch targets a trashed Project.
- Empty Trash removes trashed MLT registry entries and frees their names for future explicit import.
- **Neither Trash nor Empty Trash deletes the Redleaf database, source videos, or cached media snapshot.**

That distinction prevents an application-side organizational action from becoming a destructive operation on an external research archive.

### 3. Hub launch, authentication and cache-first opening

[PR #12, merged November 9](https://github.com/nathanfx330/MLT-Player/pull/12) established the coordinated Hub-to-MLT startup path.

The existing offline `--redleaf-project-path` option was kept separate from the newer Hub-specific options:

```text
--redleaf-hub-project-path "/absolute/project/folder"
--redleaf-hub-server-url http://127.0.0.1:5000
```

The distinction is intentional. The offline path can register a local project identity without Flask. The Hub path checks **both the saved MLT Player registry and a valid synced snapshot** before deciding what the user sees.

| Hub launch state | Result |
| --- | --- |
| Saved Project with a valid cached snapshot | Open the exact Redleaf workspace without prompting for a password or forcing another sync |
| New Project or missing snapshot | Show authenticated onboarding and the editable MLT display name, then import |
| Trashed Project | Require explicit restoration; a cached snapshot can be restored without signing in |

MLT Player reads `knowledge_base.db` read-only to obtain the intended `instance_id`. A successful login alone is not enough: the authenticated Redleaf server must report that **same** database identity before it may be imported. A local port being reachable is only a server hint, not identity verification.

The cached SRT and catalog inventory is retained across disconnects and restarts. A reconnect does not automatically perform a full `SYNC NOW`. The user retains control over updates to the archive snapshot.

### 4. Password handoff without putting a password on the command line

The initial launch design correctly passed only a folder and a server address, but onboarding could still require typing Redleaf credentials again. The next question was how Hub and MLT Player could share a saved login without putting a password into process arguments, configuration files or logs.

An early implementation used Linux Secret Service through `secret-tool`. That required an external keyring utility or working keyring service, which conflicted with the desired self-contained desktop workflow. It was replaced with the final shared vault.

Both applications now implement [`RedleafSharedCredentialVault`](../lib/services/redleaf_shared_credential_vault.dart) using bundled AES-256-GCM. Each record is bound to the Redleaf database identity and approved server origin. The encryption key and ciphertext are stored in private Linux user files, with `0700` directories and `0600` files, under:

```text
$XDG_DATA_HOME/redleaf-hub-mlt-auth/v2
or
$HOME/.local/share/redleaf-hub-mlt-auth/v2
```

Hub explicitly saves or removes the secret. MLT Player retrieves it from the same vault when onboarding or optionally authenticating a previously synced Project. An invalid saved password falls back to manual login. A different server origin does not receive the secret. A wrong instance ID is rejected after authentication.

**Threat-model limitation:** The key must be readable for unattended login. Software already running with the same Linux user privileges can obtain both key and ciphertext. Encryption protects against casual file disclosure and other unprivileged users, but it is **not** a separately unlocked keyring or hardware-backed secret store. Browser-saved passwords are not imported.

Companion work: [Redleaf Hub PR #2](https://github.com/nathanfx330/Redleaf-Hub/pull/2).

### 5. The media boundary: linked content must be verified

A Redleaf document may describe a media relationship, but the relationship is not by itself permission to send a URL or guessed pathname to MLT. The Player uses [`RedleafMediaResourceService`](../lib/services/redleaf_media_resource_service.dart) to verify a local media resource, including paths resolved through Redleaf `.rlink` virtual folders.

The Redleaf workspace reads and displays SRT documents and catalog membership using their canonical IDs. An explicit, constrained `SCAN FOR MEDIA` flow is a separate authorized write path; it is not triggered by browsing or a thumbnail.

On verified Player handoff, the linked transcript and timing information are carried with the selected media. The project stays file-first while gaining Redleaf's documentary organization.

### 6. Thumbnail mode with actual local Explorer parity

The next request was specific: **linked Redleaf videos must have the same thumbnail mode as normal local projects**. Simply making new colored cards would have looked similar without sharing the behavior that makes Explorer reliable.

[PR #13, merged November 9](https://github.com/nathanfx330/MLT-Player/pull/13) extracted the existing Explorer media card and thumbnail widget into reusable components. The Redleaf Explorer view provides **THUMBNAILS** and **SRT TABLE**, with the table remaining the initial view. The later PROJECT BROWSE destination starts in thumbnail mode, as recorded in Part III.

The grid:

- Shows only SRTs explicitly linked to video. Transcript-only, audio-only and unknown media links are not guessed into video cards.
- Uses the **same Explorer media card, MLT representative-frame generator, cache and thumbnail density metrics** as local projects.
- Honors the current Redleaf SRT search query and catalog membership selection.
- Displays fallback artwork if the link is unavailable or its resource is not verified as a local file.
- Selects the SRT on click and uses the existing verified, transcript-aware Player handoff on double-click.
- Drains outstanding thumbnail work before switching into Player.

This required no parallel media decoder. It extended the proven native thumbnail boundary to another type of Project.

Source: [`explorer_media_card.dart`](../lib/ui/widgets/explorer_media_card.dart), [`explorer_media_thumbnail.dart`](../lib/ui/widgets/explorer_media_thumbnail.dart), [`redleaf_linked_video_card.dart`](../lib/ui/widgets/redleaf_linked_video_card.dart), and [`redleaf_page.dart`](../lib/ui/redleaf_page.dart).

### 7. Bugs resolved during the update

The integration was not completed in one untested commit. The history includes corrections worth retaining:

- **Onboarding and Trash:** explicit import and restoration rules were required so a launch could not silently duplicate or resurrect a Project.
- **Password storage:** the original keyring dependency was removed in favor of a bundled vault with an explicit security tradeoff.
- **Thumbnail sharing:** moving a private widget into a shared file exposed another consumer in the Explorer selection pane. Its import had to be corrected without changing existing thumbnails.
- **Analyzer hardening:** public shared widgets needed standard key parameters; redundant null assertions and interpolation warnings were removed.
- **Input timing in widget tests:** a card supporting both single click and double click delays the single-click callback until double-click detection expires. The regression test was corrected to wait for that timeout instead of assuming an immediate tap event.
- **Native handoff:** pending MLT thumbnail work must drain before opening the selected video in Player.

These are different failure categories. UI parity, source identity, asynchronous interaction tests and native resource ownership each needed the fix appropriate to that boundary.

### 8. Validation and merge record

| Milestone | Merged PR | Evidence |
| --- | --- | --- |
| Hub onboarding, project management and encrypted credentials | [MLT #12](https://github.com/nathanfx330/MLT-Player/pull/12) | Flutter analysis, regression tests, and cross-application GUI acceptance |
| Shared Redleaf video thumbnails | [MLT #13](https://github.com/nathanfx330/MLT-Player/pull/13) | CI #197 passed Dart tests, native smoke, preview/export parity and native thumbnail smoke |

The associated Hub changes were merged as [Hub #2](https://github.com/nathanfx330/Redleaf-Hub/pull/2) and [Hub #3](https://github.com/nathanfx330/Redleaf-Hub/pull/3). Both applications were approved for promotion to `main` after testing.

The November 9 merge commits in this repository were `4467c3a` for Redleaf onboarding and credentials, followed by `f869416` for shared linked-video thumbnails. This is a merged-code checkpoint, not a claim that a new numbered release tag was published.

### 9. The resulting product boundary

MLT Player remains a media browser with precise playback and composition. Its Redleaf integration adds remote project identity, authenticated discovery, cached document catalogs and verified linked-media access. **It does not convert MLT Player into the owner of Redleaf's database.**

Several invariants should survive future work:

1. A Redleaf `instance_id` is authoritative; folder names, display labels and port checks are not.
2. Local Projects and Redleaf Projects share UI patterns without sharing their underlying storage namespaces.
3. Browsing is not an implicit synchronization or write operation.
4. Neither a remote media URL nor a transcript filename substitutes for verified local media access.
5. The Player's preview, export and thumbnail decoding retain their separate lifecycles.
6. Credential convenience does not justify hiding the shared-vault security model.

# Part III. Late November 9 through November 10, 2026

## Chapter 2. PROJECT browsing, native drain ownership, and vault CI

This chapter documents the work merged after the November 9 afternoon checkpoint. Dates span the evening of November 9 in the US Eastern time zone and the early hours of November 10 in UTC. The preceding chapter preserves the original integration sequence rather than presenting the intermediate implementation as today's interface.

### 1. PROJECT gains BROWSE without duplicating the Explorer browser

[PR #17](https://github.com/nathanfx330/MLT-Player/pull/17) brought Redleaf's existing document browser into the Redleaf **PROJECT** tab. PROJECT gained an **OVERVIEW** destination and a second destination originally labeled **THUMBNAILS**. The second destination mounts the established `RedleafPage` and starts in linked-video grid mode, with the existing search, catalog membership filtering, density control, **SRT TABLE** toggle, and verified transcript-aware Player handoff still available. The Redleaf Explorer tab retains SRT TABLE as its default.

[PR #19](https://github.com/nathanfx330/MLT-Player/pull/19) renamed the PROJECT destination to **BROWSE**, because it can show either thumbnails or a file table. **THUMBNAILS** remains the internal view toggle; it is not the name of the PROJECT navigation destination.

The approved contract distinguishes navigation from presentation: PROJECT offers **OVERVIEW / BROWSE**; BROWSE offers **THUMBNAILS / SRT TABLE**. Project creation remains outside the BROWSE gallery, and a change to another Redleaf Project resets the PROJECT destination to OVERVIEW. Neither mounting BROWSE nor changing its presentation triggers an implicit sync.

### 2. A native MLT drain must outlive the widget that started it

[PR #18](https://github.com/nathanfx330/MLT-Player/pull/18) fixed two distinct lifecycle problems.

First, the PROJECT gallery is mounted with `importRequestSerial: 0`. Only Explorer consumes the explicit Settings import signal. Reopening the PROJECT gallery must not replay a previous import or synchronize the archive merely because it is connected.

Second, a thumbnail worker can still be decoding after its gallery has closed or become inactive. `ThumbnailService.pauseAndDrain()` registers outstanding drains in a static, process-wide set, including drains from detached or disposed browsers. The root shell makes both Explorer and Redleaf Player entry pass through `ThumbnailService.waitForDetachedDrains()` before showing Player. A native MLT thumbnail decode is allowed to finish; it is neither interrupted nor bypassed.

This is a resource-ownership rule, not a cosmetic wait. The widget may disappear, but the native decode still exists and must be accounted for. The project also aligned its Dart lower SDK bound with the committed dependency lock (Dart 3.11 or later); the separate vault cadence branch later inherited that already-merged change.

### 3. Make the wait visible, then invalidate stale openings

The global drain gate made Player entry safe, but a slow decode left no feedback. [PR #19](https://github.com/nathanfx330/MLT-Player/pull/19) introduced a small, non-modal amber **Finishing thumbnail…** indicator after 200 milliseconds. Fast opens show no indicator. There is no timeout: the indicator reports the wait without weakening the gate.

[PR #20](https://github.com/nathanfx330/MLT-Player/pull/20) closed a more serious navigation race. A user could request media from Project A, navigate to Project B while the drain continued, then see the delayed Player open under Project B's metadata context. The shell now cancels pending openings on workspace, project, tab, import and startup navigation. `PlayerHandoffWaitController.cancel()` invalidates the request serial and dismisses feedback without cancelling native work. `run(isStillCurrent: ...)` separately checks the workspace key and local Project ID captured at request time.

Explorer and Redleaf also invalidate their own view-local request serials when they become inactive or change projects. This matters when the delayed operation occurs **before** the shell handoff, such as a Redleaf transcript fetch or a local thumbnail drain. No old callback may open Player after navigation. Local review passed 221 Flutter tests and the Linux GUI; the previous PR's CI rerun was cancelled during dependency installation, so that cancellation is not recorded as a green CI result.

### 4. Recover browsing after a cancelled Redleaf Player handoff

[PR #21](https://github.com/nathanfx330/MLT-Player/pull/21) corrected a quieter side effect. Selecting another card during an in-progress handoff invalidated the opening correctly, but `RedleafPage` could remain mounted with its `ThumbnailService` paused. New cards then stopped receiving thumbnails until the user left the page.

The recovery logic tracks `_pendingPlayerHandoffs`, `_pendingGridOpens` (double-clicks still resolving media), and `_playerHandoffSubmitted` (a request already passed to the shell). It resumes only when the page is active, its service is paused, no newer operation is pending, and no submitted Player transition still owns the handoff. All handoff exits, including errors, pass through a `finally` path. On recovery, `_thumbnailRecoverySerial` changes the visible card keys so cards that skipped decoding while paused remount and retry.

This prevents an old cancelled drain from admitting new thumbnail decodes during a newer handoff or while the shell waits on the global gate. The relevant test suite uses the cards' callbacks directly rather than leaving artificial double-tap gesture timers pending. The merged CI run passed Dart analysis, **225 Flutter tests**, native MLT playback smoke, preview/export parity and thumbnail smoke. Linux GUI review was also completed.

A narrow edge remains deliberately documented, not patched: if the shell drops an **already submitted** Player request but the Redleaf browser stays active in the same project, the browser does not receive an acknowledgement and might remain paused. [Issue #22](https://github.com/nathanfx330/MLT-Player/issues/22) proposes an explicit per-request `opened` or `dropped` acknowledgement from the shell. Clearing the flag only on an import serial change would not close every cancellation path. The issue is low priority and does not block the November Gold checkpoint.

### 5. Shared vault parity becomes a coordinated two-repository CI contract

The credential vault source is deliberately byte-identical in MLT Player and Redleaf Hub. Earlier review exposed portability and reproducibility issues. [MLT PR #15](https://github.com/nathanfx330/MLT-Player/pull/15), paired with [Hub PR #5](https://github.com/nathanfx330/Redleaf-Hub/pull/5), removed an architecture-specific numeric `O_NOFOLLOW` flag, retained portable exclusive file creation, enforced the committed `pubspec.lock`, and added cross-repository source parity checks. This hardening did not change the vault record format or login flow.

The first parity gate had an unavoidable merge-order problem: GitHub cannot atomically merge two repositories. A strict check on every `main` push would briefly fail while only one half of an approved pair was merged. [MLT PR #16](https://github.com/nathanfx330/MLT-Player/pull/16) and [Hub PR #6](https://github.com/nathanfx330/Redleaf-Hub/pull/6) replaced that behavior with three cases:

| Event | Parity behavior |
| --- | --- |
| Pull request | Strict. Compare against the corresponding branch in the other repository, falling back to its `main` when that branch does not exist. |
| Push to `main` | Advisory. Emit a warning during a legitimate cross-repository merge window rather than failing the entire build. |
| Scheduled audit | Strict. MLT runs daily at **09:43 UTC**; Hub runs daily at **09:17 UTC**. These audit the published `main` branches. |

The script resolves the counterpart ref with `git ls-remote`, then requests `redleaf_shared_credential_vault.dart` by immutable commit SHA. This avoids relying on a potentially stale CDN response for a mutable branch URL. The script itself is byte-identical across both repositories. The pair was merged into Gold on November 10, with MLT merge commit `bb2bb7e` and Hub merge commit `3e85e88`. The vault implementations and parity checker were checked again after merging and matched exactly.

The checker compares the **vault implementation**, not its own script file. Its strict failure currently uses `set -e` propagation from `report_issue`, and Git terminal prompts are not explicitly disabled. Scheduled GitHub workflows may also be disabled on inactive public repositories. These are documented maintenance considerations, not blockers for the approved Gold merge.

### 6. Validation and final ownership boundaries

| Workstream | Merged PRs | Main result |
| --- | --- | --- |
| PROJECT BROWSE and gallery lifecycle | [#17](https://github.com/nathanfx330/MLT-Player/pull/17), [#18](https://github.com/nathanfx330/MLT-Player/pull/18) | Same Redleaf browser in PROJECT; no replay of Settings sync; globally tracked native thumbnail drains. |
| Visible wait and stale opening cancellation | [#19](https://github.com/nathanfx330/MLT-Player/pull/19), [#20](https://github.com/nathanfx330/MLT-Player/pull/20) | Subtle wait indicator and request/project identity checks before Player entry. |
| Thumbnail restoration | [#21](https://github.com/nathanfx330/MLT-Player/pull/21) | Resumes active browsing after a cancelled drain without disrupting newer requests. |
| Vault reproducibility and CI cadence | [#15](https://github.com/nathanfx330/MLT-Player/pull/15), [#16](https://github.com/nathanfx330/MLT-Player/pull/16) | Paired vault checks with Hub, enforced lockfile, and daily strict parity audit. |

The high-level division remains unchanged. Flutter owns navigation, Redleaf identity and user interaction. Native MLT owns thumbnail decoding and playback. Neither browser deactivation nor a cancelled request authorizes overlapping native decode and Player work. Redleaf Hub remains the external launcher and credential-vault peer; it was **not** modified by the Player's BROWSE or handoff changes.

---

## Continuing this history

Append a **dated update chapter** for future work. Record the original user problem, the alternative designs, the implementation and rollback boundaries, observed failures, actual tests and PR merge. Do not rewrite earlier POC evidence to make past intermediate designs look like the current architecture.

The [engineering notes index](README.md) links the detailed POC histories. [Current architecture](architecture.md), [Redleaf workspace reference](redleaf-workspace.md), and the [root README](../README.md) remain the sources of truth for present functionality.
