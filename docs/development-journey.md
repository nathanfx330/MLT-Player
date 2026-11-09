<!-- docs/development-journey.md -->

# MLT Player: Development Overview and Update Record

**Record through November 9, 2026**

This document connects MLT Player's engineering history into a single narrative. **Part I** describes the development from a precise MLT-backed player to a file-first media browser with projects, catalogs and composition tools. **Part II** records the November 2026 Redleaf integration updates and their design decisions, including authentication, Trash, the shared encrypted credential vault and linked-video thumbnail parity.

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

[PR #13, merged November 9](https://github.com/nathanfx330/MLT-Player/pull/13) extracted the existing Explorer media card and thumbnail widget into reusable components. The Redleaf view now provides **THUMBNAILS** and **SRT TABLE**, with the table remaining the initial view.

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

The associated Hub changes were merged as [Hub #2](https://github.com/nathanfx330/Redleaf-Hub/pull/2) and [Hub #3](https://github.com/nathanfx330/Redleaf-Hub/pull/3). The user accepted both applications for promotion to `main`.

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

## Continuing this history

Append a **dated update chapter** for future work. Record the original user problem, the alternative designs, the implementation and rollback boundaries, observed failures, actual tests and PR merge. Do not rewrite earlier POC evidence to make past intermediate designs look like the current architecture.

The [engineering notes index](README.md) links the detailed POC histories. [Current architecture](architecture.md), [Redleaf workspace reference](redleaf-workspace.md), and the [root README](../README.md) remain the sources of truth for present functionality.
