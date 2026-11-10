<!-- docs/redleaf-workspace.md -->

# Redleaf Workspace Integration

This document describes the current Redleaf integration in MLT Player.

It is a present-tense implementation reference for the authenticated Redleaf
workspace path. It is separate from `.rlink` support: `.rlink` is a filesystem
resolver, while the Redleaf workspace uses Redleaf's authenticated HTTP API and
canonical database document identities.

The implementation described here is read-only unless a later section
explicitly says otherwise.

---

## 1. Product model

Redleaf is not a third top-level application tab.

It is a different kind of project source selected through the existing project
switch:

```text
EXPLORER        PROJECT
      ^
 Project Switch
      |
      +-- Local Project
      |     +-- local MLT catalogs
      |     +-- local metadata
      |
      +-- Redleaf Project
            +-- Redleaf SRT documents
            +-- Redleaf catalogs
            +-- Redleaf tags/colors already present in document rows
            +-- Redleaf media relationships
```

The shell keeps the active workspace source separate from the active local
Project ID.

That distinction prevents Redleaf identity from leaking into services that
assume a local MLT Project.

---

## 2. Workspace identity

Workspace identities are namespaced:

```text
local:<local-project-uuid>
redleaf:<redleaf-instance-id>
```

`WorkspaceProjectService` sits above `ProjectCatalogService`.

`ProjectCatalogService` remains local-only. A `redleaf:*` key must never be
passed into local Project catalog, rating, tag, color, or bookmark storage.

When a Redleaf project is active:

- the workspace source is Redleaf;
- the current local Project ID exposed to local metadata services is `null`;
- the last local Project remains intact and can be selected again later.

Disconnecting Redleaf while it is active falls back to a local Project rather
than inventing a broken local identity.

---

## 3. Launch from Redleaf Hub

Redleaf Hub already knows each project's local folder. MLT Player accepts
`--redleaf-project-path "/absolute/path/to/project"` or
`--redleaf-project-path=/absolute/path/to/project` at startup.

The Linux runner passes command-line arguments to Flutter. MLT Player locates
`knowledge_base.db` in the supplied project folder and reads
`app_settings.instance_id` **read-only** through Python 3's standard SQLite
library. It neither requires a running Redleaf server nor modifies that
database. An existing MLT Player registry entry is reused, including its
display name, connection URL and saved snapshot. Otherwise, the identity is
registered locally with the folder name as its initial display name and
Redleaf's default local URL as the connection hint.

Explorer waits for `WorkspaceProjectService` to load before selecting the
exact `redleaf:<instance_id>` workspace. The app shell then opens the
existing **PROJECT** tab. Without an argument, the normal local project
startup is unchanged.

The older `--redleaf-project <instance_id>` interface remains available for
already saved projects. Both flags accept equals syntax. Conflicting or empty
arguments report an error instead of silently selecting a different workspace.

An initialized Redleaf database must have its `instance_id` already stored.
If that ID is absent, MLT Player refuses to guess or write one, and asks the
user to initialize the project through Redleaf once. A newly registered
project with no cached snapshot can open its project view offline, but its
SRT inventory is empty until the user reconnects and chooses `SYNC NOW`.
Startup does not authenticate, refresh the archive, start Flask, or write
Redleaf's database. The command launches a new process; it is not IPC to
an existing MLT Player window.

### Hub launcher: cached project or authenticated onboarding

The compiled Redleaf Hub launcher uses this separate request:

```text
--redleaf-hub-project-path "/absolute/project/folder"
--redleaf-hub-server-url http://127.0.0.1:5000
```

MLT Player resolves the local database's `instance_id` read-only, then uses
`RedleafHubLaunchService.inspect` to determine the correct path. This is
**not** the same as the existing offline `--redleaf-project-path` mode,
which deliberately auto-registers a local database without Flask.

The Hub launch is explicitly classified by identity and snapshot, not by
folder name, URL, or login session:

1. **Registered, not trashed, valid cached snapshot:** select that saved
   Redleaf workspace and show the cached Redleaf Explorer immediately. No
   password and no automatic `SYNC NOW`.
2. **New or registered without a valid cached snapshot:** open a modal in
   MLT Player for a local project display name, server URL, Redleaf username,
   and password. It calls the existing `RedleafConnectionService.signIn`,
   verifies the authenticated server's instance ID equals the local database
   instance ID, then calls the existing explicit connected-import callback.
   The callback persists the project and requests the established sync path
   to populate SRT documents, catalogs, and memberships.
3. **Registered in Trash:** never automatically select or recreate it. Offer
   explicit restore. A valid cached snapshot can be restored without signing
   in; for a missing snapshot the user must authenticate before restoring
   and importing.

The server URL from Hub is a convenience hint, not proof of identity. The
Hub's port-5000 TCP check does not prove which database is running; a wrong
server is disconnected and rejected before any registry import. Neither
password nor session cookie is passed in the process arguments or persisted
in MLT Player's configuration. Credentials saved explicitly in Redleaf Hub
may be retrieved from the Linux login keyring, bound to the same database
instance ID and an approved server origin. The dialog does not accept empty
project names or credentials when needed. Canceling leaves the registry
untouched. Older startup flags are unchanged.

#### Shared encrypted vault for Hub launches

`RedleafSharedCredentialVault` is implemented identically in Redleaf Hub and
MLT Player, using bundled Dart AES-256-GCM encryption. No external keyring
command, secret service, native package installation or unlocked keyring is
required. Each canonical `instance_id` maps to a separate authenticated
encrypted record with a fresh random nonce. The trusted Redleaf server origin
and username are inside the ciphertext.

Both programs use the same private Linux directory:
`$XDG_DATA_HOME/redleaf-hub-mlt-auth/v2` or
`$HOME/.local/share/redleaf-hub-mlt-auth/v2`. The vault folder and entries
folder have mode `0700`, and the randomly generated encryption key and
individual encrypted records have mode `0600`. The implementation uses the
existing Linux libc directly through Dart FFI to create files privately and
atomically, avoiding a temporary world-readable password file. The key itself
is never sent in the launch arguments or environment.

For an already synced project, MLT Player opens its cached snapshot immediately,
then optionally authenticates in the background using the saved credential.
For onboarding, the user can choose the saved login and still select the
MLT Player project name. The server origin must match exactly and the Redleaf
authentication response must carry the selected database's `instance_id`.
Wrong credentials fall back to manual login and no wrong database is imported.

**Security model:** The goal is a self-contained, zero-install automatic login.
Since unattended login requires decryption without a separate unlock secret,
the encryption key is stored under the same Linux account as the ciphertext.
This protects against incidental disclosure, other unprivileged Linux users,
and passwords appearing in process arguments, but **does not** protect
against malware running as the same user, compromise of the account, or an
attacker with both files. Use a separate, unlocked OS keyring or hardware
credential store for those stronger protections. The vault does not import
browser passwords and does not use plaintext storage.

### Create New Redleaf Cloud Project from Settings

Signing in identifies a Redleaf instance and authenticates the session, but
**does not create an MLT Player workspace**. Settings offers a project-name
field prefilled from the Redleaf source name. The user can edit it before
choosing **CREATE NEW REDLEAF CLOUD PROJECT**. The selected name belongs to
MLT Player only; it never renames Redleaf's database.

`WorkspaceProjectService.importConnectedRedleafProject` uses the authenticated
`instance_id` and chosen display name to persist or reuse the registry entry
atomically. It then selects that workspace and opens the Redleaf Explorer,
where an explicit one-time import request runs the existing `SYNC NOW`
snapshot logic. Reimporting a known instance refreshes that same project.
If the user enters a different display name, that MLT Player name is updated.

### Redleaf Cloud Trash and conflict rules

Trash is a **soft-delete in the MLT Player registry**, never a deletion of
Redleaf itself. Each saved record has an optional `trashedAt` timestamp.
Older registry files without that field load as active projects. A record
in Trash:

- is absent from the active project switcher, including while its Redleaf
  instance is authenticated;
- retains its instance ID, chosen name, server URL, and cached snapshot;
- is shown under **Redleaf Trash…** in the standard three-dot project
  menu of either Explorer view, with an explicit **RESTORE** control;
- cannot be recreated by signing in or launching its folder. An import of
  that same `instance_id` instead offers **RESTORE AND IMPORT REDLEAF CLOUD
  PROJECT**, returning the original workspace record;
- reserves its display name. Another Redleaf instance cannot take that name
  while it remains in Trash, and name comparisons ignore letter case.

In Redleaf Explorer, the three-dot control next to the project dropdown
uses the same menu pattern as local projects. Rename and Move to Trash apply
to the selected Redleaf project. The Redleaf Trash dialog is accessible from
both Redleaf and local project menus so projects can be restored after their
selector entries are hidden. Creation and authentication stay in Settings;
project management belongs in the project menu.

Moving the currently selected Redleaf project to Trash returns selection to
the previous local workspace. No server database, media file, snapshot, or
credential is deleted.

The **EMPTY TRASH** control in this dialog is available when it contains
projects and requires a second confirmation stating the exact project count.
It permanently removes **only trashed MLT Player registry entries** in one
save, frees their display names and instance IDs for future explicit imports,
and leaves every active project intact. The removed entries cannot be
restored from Trash. This does not delete Redleaf databases, source media,
or locally cached snapshots. The button is disabled when Trash is empty.

`RedleafProjectRegistryService` owns the canonical identity and display-name
uniqueness checks. `WorkspaceProjectService` owns selector visibility and
fallback. The local folder launch respects Trash instead of silently
restoring it. Sign-in alone never restores a trashed workspace.

## 4. Authentication and instance identity

MLT Player authenticates to Redleaf through Redleaf's existing login flow.

The current connection sequence is:

```text
GET /login
  -> capture session cookie
  -> read CSRF token

POST /login
  -> authenticated session

GET /dashboard
  -> refresh CSRF token

GET /api/system/info
  -> project_name
  -> instance_id
  -> base_dir
```

`instance_id` is the stable Redleaf workspace identity used by MLT Player.

MLT Player persists only convenience connection information such as the server
URL and username. It does not persist the password or authenticated session.
Application launch therefore begins disconnected until the user signs in again.

The default local Redleaf URL is:

```text
http://127.0.0.1:5000
```

---

## 5. SRT discovery

The Redleaf workspace currently focuses on indexed SRT documents.

Discovery uses Redleaf's existing dashboard API:

```text
GET /api/dashboard/status
```

The dashboard's file-type filtering currently includes rows whose
`file_type IS NULL`, so MLT Player does not trust the server-side filter alone.

The discovery rule is:

```text
request SRT rows
  -> inspect every returned row
  -> keep only rows whose explicit file_type == SRT
  -> use Redleaf doc_id as canonical identity
```

MLT Player does not infer SRT identity from a filename extension.

This same rule is covered by automated tests.

---

## 6. Media relationships

For each discovered SRT, MLT Player asks Redleaf for the document's explicit
media relationship:

```text
GET /api/document/<doc_id>/media_status
```

The result is modeled as one of three states:

```text
linked
not linked
unknown
```

`unknown` is intentionally distinct from `not linked`.

A failed media-status request must not be silently converted into a
transcript-only result.

MLT Player also does not infer media by matching basenames.

A Redleaf media relationship describes what Redleaf says is linked. It does not
by itself prove that a local filesystem resource is physically playable by the
native MLT engine. Physical/playable resource resolution belongs to the later
Player handoff stage.

---

## 7. Redleaf catalogs

The catalog sidebar uses Redleaf's existing catalog APIs.

Catalog list:

```text
GET /api/catalogs/all
```

Catalog membership:

```text
GET /api/documents_by_tags?catalog_id=<catalog-id>
```

The sidebar displays Redleaf's actual user-created catalog names.

There are no hardcoded application catalog names.

The visible lane currently contains:

```text
All SRTs
<Redleaf user catalog 1>
<Redleaf user catalog 2>
...
```

Selecting a catalog:

```text
catalog id
  -> Redleaf membership query
  -> canonical Redleaf doc_id set
  -> intersect with discovered SRT documents
  -> display filtered SRT list
```

Membership filtering again keeps only rows explicitly identified as SRT.

Search remains an additional filter inside the selected catalog.

Catalog membership is cached until refresh, disconnect, or Redleaf instance
change.

The current sidebar intentionally exposes `user` catalogs. Automatic podcast
collections are not mixed into this browsing lane.

---

## 8. Current UI behavior

The current Redleaf Explorer view contains:

- Redleaf project identity and connection state;
- indexed SRT summary counts;
- media-linked, transcript-only, and unknown media counts;
- filename/path/doc-ID search;
- a left catalog sidebar;
- `All SRTs`;
- live Redleaf user catalog names;
- catalog filtering by canonical Redleaf `doc_id`;
- the SRT table with doc ID, path, tag count, color, and media state;
- a **THUMBNAILS** switch that shows only SRTs explicitly linked to video;
- identical local Explorer media-card visuals, slider density, MLT thumbnail
  generation and representative-frame cache for verified local video files;
- thumbnails filtered by the same SRT search and catalog membership;
- an explicit offline/unavailable fallback rather than decoding an unverified
  URL or guessed file location;
- single-click SRT selection, with double-click using the existing verified,
  transcript-aware Player handoff after thumbnail jobs drain;
- a read-only inspector for the selected SRT.

The PROJECT tab follows the same workspace switch. For a Redleaf Cloud
Project, a visible **OVERVIEW / BROWSE** switch sits above the project
content. OVERVIEW preserves the Redleaf instance name, identity, server, and
rename action. BROWSE displays the **existing Redleaf browser**, starting
in linked-video thumbnail mode, within the PROJECT tab itself. The browser's
SRT TABLE switch, search, catalog filters, size slider, cached snapshot,
verified media resolution and transcript-aware Player handoff all remain
available. Switching back to OVERVIEW disposes that gallery and stops
admitting new native thumbnail work. Pending decodes from inactive or
disposed thumbnail browsers are retained by a process-wide drain registry;
Player entry from either Explorer or Redleaf awaits all registered drains
before launching media. A slow drain shows a non-modal
"Finishing thumbnail…" status after 200 milliseconds; it disappears when
the handoff completes and never bypasses or times out the MLT safety gate.
Navigating to another workspace tab or changing the active project cancels
only the pending Player open and clears the indicator. Native thumbnail work
still drains safely. Player also rechecks the initiating project identity
before opening media, preventing stale media from using another project's
ratings, tags, or bookmark context.
If the user selects another Redleaf card during an in-progress handoff,
the cancelled request waits for its already-running native decode to drain
before resuming thumbnail generation. A newer handoff, including an unresolved grid double-click, keeps the browser
paused until its own Player transition finishes. On cancellation, visible
cards retry thumbnails that were skipped during the pause without needing
to leave and reopen BROWSE.
Reopening BROWSE never
replays the earlier Settings import sync signal, even when its serial is
nonzero and the remote project remains connected. Selecting another Redleaf Project
returns to its own OVERVIEW rather than carrying over a prior gallery.

The Redleaf Explorer continues to default to its SRT TABLE with its own
THUMBNAILS switch. Neither Project nor Explorer silently signs in, syncs,
or guesses local file locations. Selecting a Local Project restores the
existing local Project dashboard.

---

## 9. Read-only boundary

The current Redleaf workspace performs GET-only discovery and browsing.

The integration does not currently use Redleaf write endpoints for:

- media linking or unlinking;
- media-position updates;
- audio offsets;
- catalog membership writes;
- tag writes;
- color writes;
- curation-note writes.

That boundary is deliberate while identity, browsing, filtering, and media
handoff are being proven.

---

## 10. `.rlink` is separate

MLT Player also supports Redleaf `.rlink` files.

That mechanism is different:

```text
.rlink
  -> virtual Explorer folder
  -> filesystem path resolution
  -> physical media access
```

The authenticated Redleaf workspace is:

```text
Redleaf session
  -> Redleaf API
  -> instance_id / doc_id / catalog_id
  -> database-backed relationships
```

`.rlink` should not become the identity model for authenticated Redleaf API
objects.

It remains one possible filesystem-resolution mechanism where appropriate.

---

## 11. Validation completed

The current checkpoint has been validated through:

```text
flutter analyze
```

with no issues after the catalog sidebar integration.

Focused automated tests cover:

- workspace source switching;
- Redleaf SRT discovery;
- preservation of canonical Redleaf document IDs;
- explicit-SRT filtering;
- media-status semantics;
- Redleaf catalog loading;
- explicit-SRT catalog membership;
- membership caching;
- state clearing on disconnect.

The catalog-service focused suite currently passes:

```text
00:01 +2: All tests passed!
```

Interactive Linux validation has also confirmed:

- Redleaf appears through the existing Project switch;
- Explorer changes into the Redleaf workspace;
- PROJECT follows Redleaf/local source switching;
- the live Redleaf SRT corpus loads;
- actual Redleaf user catalogs appear;
- selecting a catalog filters the SRT list;
- `All SRTs` restores the full SRT list.

---

## 12. Current source ownership

| Concern | Primary source |
| --- | --- |
| Workspace identity model | `lib/models/workspace_project.dart` |
| Workspace source coordination | `lib/services/workspace_project_service.dart` |
| Unified project switch | `lib/ui/widgets/workspace_project_switcher.dart` |
| Explorer workspace integration | `lib/ui/explorer_page.dart` |
| App-shell Project synchronization | `lib/main.dart` |
| Redleaf authentication/inventory | `lib/services/redleaf_connection_service.dart` |
| Redleaf SRT discovery | `lib/services/redleaf_srt_service.dart` |
| Redleaf catalog discovery/membership | `lib/services/redleaf_catalog_service.dart` |
| Redleaf SRT/catalog UI | `lib/ui/redleaf_page.dart` |
| Workspace service tests | `test/workspace_project_service_test.dart` |
| SRT discovery tests | `test/redleaf_srt_service_test.dart` |
| Catalog tests | `test/redleaf_catalog_service_test.dart` |

---

## 13. Next integration boundary

The next feature is the Player handoff lane.

It should be implemented in two stages:

```text
selected Redleaf SRT
  -> selection/media side panel
  -> prove the exact resource Redleaf says is linked

then

resolved playable resource
  -> MLT Player
  -> transcript/cue navigation
```

The first stage must remain observational.

The native Player should not receive a guessed path, a guessed same-basename
file, or a Redleaf virtual path whose playable semantics have not been
established.

Once the resource contract is proven, Player handoff can be added without
weakening the identity rules established by the workspace and catalog layers.
