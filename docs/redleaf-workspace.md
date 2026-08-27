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

## 3. Authentication and instance identity

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

## 4. SRT discovery

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

## 5. Media relationships

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

## 6. Redleaf catalogs

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

## 7. Current UI behavior

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
- a read-only inspector for the selected SRT.

The PROJECT tab follows the same workspace switch.

Selecting Redleaf in Explorer makes PROJECT show the Redleaf project identity.
Selecting a local Project restores the existing local Project dashboard.

---

## 8. Read-only boundary

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

## 9. `.rlink` is separate

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

## 10. Validation completed

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

## 11. Current source ownership

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

## 12. Next integration boundary

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
