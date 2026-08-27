// lib/ui/redleaf_page.dart

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/redleaf_player_handoff.dart';
import '../models/workspace_project.dart';
import '../services/redleaf_catalog_service.dart';
import '../services/redleaf_connection_service.dart';
import '../services/redleaf_media_resource_service.dart';
import '../services/redleaf_media_scan_service.dart';
import '../services/redleaf_project_snapshot_service.dart';
import '../services/redleaf_srt_service.dart';
import '../services/redleaf_transcript_service.dart';

class RedleafPage extends StatefulWidget {
  const RedleafPage({
    super.key,
    required this.active,
    this.workspaceProject,
    this.connection,
    this.onOpenVerifiedMedia,
    this.onOpenRedleafHandoff,
  });

  final bool active;

  /// Saved MLT Player workspace identity for this Redleaf instance.
  ///
  /// This is deliberately separate from the live Redleaf connection so the
  /// page can later reopen a cached project even while Redleaf is disconnected.
  final WorkspaceProject? workspaceProject;

  final RedleafConnectionService? connection;

  /// Legacy D3 verified-media callback. Kept so the currently wired Explorer
  /// path remains functional until the transcript-aware handoff is connected.
  final ValueChanged<String>? onOpenVerifiedMedia;

  /// Transcript-aware Redleaf handoff. When connected, Player open fails
  /// closed unless the exact Redleaf transcript can be loaded by canonical
  /// document ID.
  final ValueChanged<RedleafPlayerHandoff>? onOpenRedleafHandoff;

  @override
  State<RedleafPage> createState() => _RedleafPageState();
}

class _RedleafPageState extends State<RedleafPage> {
  late final RedleafConnectionService _connection;
  late final RedleafSrtDiscoveryService _discovery;
  late final RedleafCatalogService _catalogs;
  late final RedleafMediaResourceService _mediaResources;
  late final RedleafMediaScanService _mediaScanner;
  late final RedleafTranscriptService _transcripts;
  late final RedleafProjectSnapshotService _snapshots;
  final TextEditingController _searchController = TextEditingController();

  String _query = '';
  int? _selectedDocId;
  int? _selectedCatalogId;
  Set<int>? _selectedCatalogDocumentIds;
  bool _catalogMembershipLoading = false;
  String? _catalogMembershipError;
  String _loadedInstanceId = '';
  RedleafProjectSnapshot? _snapshot;
  bool _snapshotLoading = false;
  String? _snapshotError;
  int _snapshotLoadSerial = 0;
  bool _syncing = false;
  String? _syncError;
  bool _scanForMediaLoading = false;
  String? _scanForMediaMessage;
  String? _scanForMediaError;
  int _scanForMediaSerial = 0;
  RedleafMediaResourceResolution? _selectedMediaResolution;
  bool _mediaResolutionLoading = false;
  String? _selectedMediaSignature;
  int _mediaResolutionSerial = 0;
  bool _handoffLoading = false;
  String? _handoffError;
  int _handoffSerial = 0;

  @override
  void initState() {
    super.initState();

    _connection = widget.connection ?? RedleafConnectionService.instance;
    _discovery = RedleafSrtDiscoveryService(connection: _connection);
    _catalogs = RedleafCatalogService(connection: _connection);
    _mediaResources = RedleafMediaResourceService(connection: _connection);
    _mediaScanner = RedleafMediaScanService(connection: _connection);
    _transcripts = RedleafTranscriptService(connection: _connection);
    _snapshots = RedleafProjectSnapshotService();

    _connection.addListener(_onConnectionChanged);
    _discovery.addListener(_onDiscoveryChanged);
    _catalogs.addListener(_onCatalogsChanged);
    _searchController.addListener(_onSearchChanged);

    _maybeLoad();

    unawaited(_connection.load().then((_) {
      if (!mounted) {
        return;
      }
      _onConnectionChanged();
    }));
  }

  @override
  void didUpdateWidget(covariant RedleafPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldKey = oldWidget.workspaceProject?.key;
    final newKey = widget.workspaceProject?.key;

    if (oldKey != newKey) {
      _snapshotLoadSerial += 1;
      _loadedInstanceId = '';
      _snapshot = null;
      _snapshotError = null;
      _syncError = null;
      _selectedDocId = null;
      _resetMediaResolution();
      _resetCatalogFilter();
      _discovery.clear();
      _catalogs.clear();
    }

    if (widget.active && (!oldWidget.active || oldKey != newKey)) {
      _maybeLoad();
    }
  }

  @override
  void dispose() {
    _connection.removeListener(_onConnectionChanged);
    _discovery.removeListener(_onDiscoveryChanged);
    _catalogs.removeListener(_onCatalogsChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _catalogs.dispose();
    _discovery.dispose();
    super.dispose();
  }

  WorkspaceProject? get _redleafWorkspaceProject {
    final project = widget.workspaceProject;
    if (project == null || !project.isRedleaf) {
      return null;
    }
    return project;
  }

  String get _workspaceInstanceId =>
      _redleafWorkspaceProject?.redleafInstanceId?.trim() ?? '';

  bool get _connectionMatchesWorkspace {
    final instanceId = _workspaceInstanceId;
    return instanceId.isNotEmpty &&
        _connection.isConnected &&
        _connection.instanceId == instanceId;
  }

  void _onConnectionChanged() {
    final selected = _selectedDocument;

    _resetMediaResolution();

    if (mounted) {
      setState(() {
        _syncError = null;
      });
    }

    if (_connectionMatchesWorkspace && selected != null) {
      unawaited(_resolveSelectedMedia(selected));
    }

    _maybeLoad();
  }

  void _onCatalogsChanged() {
    if (!mounted) {
      return;
    }

    final selectedCatalogId = _selectedCatalogId;
    if (selectedCatalogId != null &&
        _loadedInstanceId.isNotEmpty &&
        _catalogs.loadedFor(_loadedInstanceId) &&
        !_visibleCatalogs.any(
          (catalog) => catalog.id == selectedCatalogId,
        )) {
      _resetCatalogFilter();
    }

    setState(() {});
  }

  void _onDiscoveryChanged() {
    if (!mounted) {
      return;
    }

    final selected = _selectedDocument;
    final signature = selected == null ? null : _mediaSignature(selected);
    final shouldResolve = selected != null &&
        _connectionMatchesWorkspace &&
        signature != _selectedMediaSignature &&
        !_mediaResolutionLoading;

    setState(() {});

    if (shouldResolve) {
      unawaited(_resolveSelectedMedia(selected));
    }
  }

  void _onSearchChanged() {
    final next = _searchController.text.trim().toLowerCase();
    if (next == _query) {
      return;
    }

    setState(() {
      _query = next;
      if (_selectedDocId != null &&
          !_filteredDocuments.any(
            (document) => document.docId == _selectedDocId,
          )) {
        _selectedDocId = null;
        _resetMediaResolution();
      }
    });
  }

  void _maybeLoad() {
    if (!mounted || !widget.active) {
      return;
    }

    final instanceId = _workspaceInstanceId;
    if (instanceId.isEmpty) {
      return;
    }

    final servicesHydrated =
        _discovery.loadedInstanceId == instanceId &&
        _catalogs.loadedFor(instanceId);

    final alreadyLoaded =
        _loadedInstanceId == instanceId &&
        (_snapshot != null
            ? servicesHydrated
            : (!_snapshotLoading &&
                _discovery.documents.isEmpty &&
                _catalogs.catalogs.isEmpty));

    if (alreadyLoaded || _snapshotLoading) {
      return;
    }

    unawaited(_loadSnapshot(instanceId));
  }

  Future<void> _loadSnapshot(String instanceId) async {
    final serial = ++_snapshotLoadSerial;

    setState(() {
      _snapshotLoading = true;
      _snapshotError = null;
    });

    try {
      final snapshot = await _snapshots.load(instanceId);

      if (!mounted ||
          serial != _snapshotLoadSerial ||
          _workspaceInstanceId != instanceId) {
        return;
      }

      _selectedDocId = null;
      _resetMediaResolution();
      _resetCatalogFilter();

      if (snapshot == null) {
        _discovery.clear();
        _catalogs.clear();

        setState(() {
          _loadedInstanceId = instanceId;
          _snapshot = null;
          _snapshotLoading = false;
          _snapshotError = null;
        });
        return;
      }

      _hydrateSnapshot(snapshot);

      setState(() {
        _loadedInstanceId = instanceId;
        _snapshot = snapshot;
        _snapshotLoading = false;
        _snapshotError = null;
      });
    } catch (error) {
      if (!mounted ||
          serial != _snapshotLoadSerial ||
          _workspaceInstanceId != instanceId) {
        return;
      }

      setState(() {
        _loadedInstanceId = instanceId;
        _snapshot = null;
        _snapshotLoading = false;
        _snapshotError = 'Could not load the saved Redleaf snapshot: $error';
      });
    }
  }

  void _hydrateSnapshot(RedleafProjectSnapshot snapshot) {
    _discovery.loadCachedDocuments(
      instanceId: snapshot.instanceId,
      documents: snapshot.documents,
    );
    _catalogs.loadCachedCatalogs(
      instanceId: snapshot.instanceId,
      catalogs: snapshot.catalogs,
      catalogMemberships: snapshot.catalogMemberships,
    );
  }

  Future<void> _syncNow() async {
    final instanceId = _workspaceInstanceId;

    if (instanceId.isEmpty || _syncing) {
      return;
    }

    if (!_connectionMatchesWorkspace) {
      setState(() {
        _syncError = _connection.isConnected
            ? 'The connected Redleaf instance does not match this saved project.'
            : 'Connect this Redleaf project in Settings before syncing.';
      });
      return;
    }

    final previousSnapshot = _snapshot;
    final previousCatalogId = _selectedCatalogId;

    setState(() {
      _syncing = true;
      _syncError = null;
      _snapshotError = null;
    });

    try {
      await _connection.refreshInventory();

      final catalogsLoaded = await _catalogs.refreshCatalogs();
      if (!catalogsLoaded) {
        throw StateError(
          _catalogs.lastError ?? 'Could not refresh Redleaf catalogs.',
        );
      }

      final memberships = <int, Set<int>>{};
      for (final catalog in _visibleCatalogs) {
        memberships[catalog.id] =
            await _catalogs.srtDocumentIdsForCatalog(
          catalog.id,
          forceRefresh: true,
        );
      }

      final documentsLoaded = await _discovery.refresh();
      if (!documentsLoaded) {
        throw StateError(
          _discovery.lastError ?? 'Could not refresh Redleaf SRTs.',
        );
      }

      final syncedAt = DateTime.now().toUtc();

      await _snapshots.save(
        instanceId: instanceId,
        documents: _discovery.documents,
        catalogs: _catalogs.catalogs,
        catalogMemberships: memberships,
        syncedAt: syncedAt,
      );

      final snapshot = RedleafProjectSnapshot(
        instanceId: instanceId,
        syncedAt: syncedAt,
        documents: _discovery.documents,
        catalogs: _catalogs.catalogs,
        catalogMemberships: memberships,
      );

      if (!mounted || _workspaceInstanceId != instanceId) {
        return;
      }

      setState(() {
        _loadedInstanceId = instanceId;
        _snapshot = snapshot;
        _syncing = false;
        _syncError = null;

        if (previousCatalogId != null &&
            _visibleCatalogs.any(
              (catalog) => catalog.id == previousCatalogId,
            )) {
          _selectedCatalogId = previousCatalogId;
          _selectedCatalogDocumentIds =
              snapshot.documentIdsForCatalog(previousCatalogId);
          _catalogMembershipLoading = false;
          _catalogMembershipError = null;
        } else if (previousCatalogId != null) {
          _resetCatalogFilter();
        }
      });
    } catch (error) {
      if (!mounted || _workspaceInstanceId != instanceId) {
        return;
      }

      if (previousSnapshot != null) {
        _hydrateSnapshot(previousSnapshot);
      } else {
        _discovery.clear();
        _catalogs.clear();
      }

      setState(() {
        _loadedInstanceId = instanceId;
        _snapshot = previousSnapshot;
        _syncing = false;
        _syncError = error.toString();
      });
    }
  }

  List<RedleafCatalog> get _visibleCatalogs {
    return _catalogs.catalogs
        .where((catalog) => catalog.isUser)
        .toList(growable: false);
  }

  RedleafCatalog? get _selectedCatalog {
    final catalogId = _selectedCatalogId;
    if (catalogId == null) {
      return null;
    }

    for (final catalog in _visibleCatalogs) {
      if (catalog.id == catalogId) {
        return catalog;
      }
    }
    return null;
  }

  List<RedleafSrtDocument> get _filteredDocuments {
    Iterable<RedleafSrtDocument> documents = _discovery.documents;

    final selectedCatalogId = _selectedCatalogId;
    if (selectedCatalogId != null) {
      final memberDocIds = _selectedCatalogDocumentIds;
      if (memberDocIds == null) {
        return const <RedleafSrtDocument>[];
      }

      documents = documents.where(
        (document) => memberDocIds.contains(document.docId),
      );
    }

    if (_query.isNotEmpty) {
      documents = documents.where(
        (document) =>
            document.relativePath.toLowerCase().contains(_query) ||
            document.docId.toString().contains(_query),
      );
    }

    return documents.toList(growable: false);
  }

  void _resetCatalogFilter() {
    _selectedCatalogId = null;
    _selectedCatalogDocumentIds = null;
    _catalogMembershipLoading = false;
    _catalogMembershipError = null;
  }

  Future<void> _selectCatalog(RedleafCatalog? catalog) async {
    if (catalog == null) {
      setState(() {
        _resetCatalogFilter();
        if (_selectedDocId != null &&
            !_filteredDocuments.any(
              (document) => document.docId == _selectedDocId,
            )) {
          _selectedDocId = null;
          _resetMediaResolution();
        }
      });
      return;
    }

    setState(() {
      _selectedCatalogId = catalog.id;
      _selectedCatalogDocumentIds = null;
      _catalogMembershipLoading = true;
      _catalogMembershipError = null;
      _selectedDocId = null;
      _resetMediaResolution();
    });

    await _loadCatalogMembership(catalog.id);
  }

  Future<void> _loadCatalogMembership(
    int catalogId, {
    bool forceRefresh = false,
  }) async {
    try {
      final docIds = await _catalogs.srtDocumentIdsForCatalog(
        catalogId,
        forceRefresh: forceRefresh,
      );

      if (!mounted || _selectedCatalogId != catalogId) {
        return;
      }

      setState(() {
        _selectedCatalogDocumentIds = docIds;
        _catalogMembershipLoading = false;
        _catalogMembershipError = null;
      });
    } catch (error) {
      if (!mounted || _selectedCatalogId != catalogId) {
        return;
      }

      setState(() {
        _selectedCatalogDocumentIds = const <int>{};
        _catalogMembershipLoading = false;
        _catalogMembershipError = error.toString();
      });
    }
  }

  void _resetMediaResolution() {
    _mediaResolutionSerial += 1;
    _selectedMediaResolution = null;
    _mediaResolutionLoading = false;
    _selectedMediaSignature = null;
    _resetHandoffState();
    _resetMediaScanState();
  }

  void _resetMediaScanState() {
    _scanForMediaSerial += 1;
    _scanForMediaLoading = false;
    _scanForMediaMessage = null;
    _scanForMediaError = null;
  }

  void _resetHandoffState() {
    _handoffSerial += 1;
    _handoffLoading = false;
    _handoffError = null;
  }

  String _mediaSignature(RedleafSrtDocument document) {
    final media = document.media;
    return <Object?>[
      document.docId,
      media.state,
      media.path,
      media.type,
      media.source,
      media.positionSeconds,
      media.offsetSeconds,
    ].join('|');
  }

  Future<void> _selectDocument(RedleafSrtDocument document) async {
    setState(() {
      _selectedDocId = document.docId;
      _resetMediaResolution();
    });

    await _resolveSelectedMedia(document);
  }

  Future<void> _scanSelectedMedia() async {
    final document = _selectedDocument;
    final instanceId = _workspaceInstanceId;

    if (document == null ||
        document.media.state != RedleafMediaLinkState.notLinked ||
        instanceId.isEmpty ||
        _scanForMediaLoading) {
      return;
    }

    if (!_connectionMatchesWorkspace) {
      setState(() {
        _scanForMediaError =
            'Connect this Redleaf project before scanning for media.';
        _scanForMediaMessage = null;
      });
      return;
    }

    final serial = ++_scanForMediaSerial;
    final docId = document.docId;

    setState(() {
      _scanForMediaLoading = true;
      _scanForMediaMessage = null;
      _scanForMediaError = null;
    });

    try {
      final result = await _mediaScanner.scanForDocument(
        instanceId: instanceId,
        document: document,
      );

      if (!mounted ||
          serial != _scanForMediaSerial ||
          _selectedDocId != docId ||
          _workspaceInstanceId != instanceId) {
        return;
      }

      if (!result.linked) {
        setState(() {
          _scanForMediaLoading = false;
          _scanForMediaMessage = result.message;
          _scanForMediaError = null;
        });
        return;
      }

      final refreshed =
          await _discovery.refreshMediaStatusForDocument(docId);

      if (!mounted ||
          serial != _scanForMediaSerial ||
          _selectedDocId != docId ||
          _workspaceInstanceId != instanceId) {
        return;
      }

      if (!refreshed) {
        throw StateError(
          _discovery.lastError ??
              'Redleaf linked media, but MLT Player could not refresh '
                  'the updated media relationship.',
        );
      }

      final updatedDocument = _selectedDocument;
      if (updatedDocument == null ||
          !updatedDocument.media.isLinked) {
        throw StateError(
          'Redleaf reported a successful media link, but the refreshed '
          'document is still transcript-only.',
        );
      }

      String? snapshotWarning;
      try {
        await _persistSnapshotAfterMediaScan(instanceId);
      } catch (error) {
        snapshotWarning =
            'Media was linked in Redleaf, but the local snapshot could not '
            'be updated: $error';
      }

      if (!mounted ||
          serial != _scanForMediaSerial ||
          _selectedDocId != docId ||
          _workspaceInstanceId != instanceId) {
        return;
      }

      setState(() {
        _scanForMediaLoading = false;
        _scanForMediaMessage = result.message;
        _scanForMediaError = snapshotWarning;
      });
    } catch (error) {
      if (!mounted ||
          serial != _scanForMediaSerial ||
          _selectedDocId != docId ||
          _workspaceInstanceId != instanceId) {
        return;
      }

      setState(() {
        _scanForMediaLoading = false;
        _scanForMediaMessage = null;
        _scanForMediaError = error.toString();
      });
    }
  }

  Future<void> _persistSnapshotAfterMediaScan(
    String instanceId,
  ) async {
    final previousSnapshot = _snapshot;
    if (previousSnapshot == null) {
      return;
    }

    final updatedSnapshot = RedleafProjectSnapshot(
      instanceId: previousSnapshot.instanceId,
      syncedAt: previousSnapshot.syncedAt,
      documents: _discovery.documents,
      catalogs: previousSnapshot.catalogs,
      catalogMemberships: previousSnapshot.catalogMemberships,
    );

    await _snapshots.save(
      instanceId: instanceId,
      documents: updatedSnapshot.documents,
      catalogs: updatedSnapshot.catalogs,
      catalogMemberships: updatedSnapshot.catalogMemberships,
      syncedAt: updatedSnapshot.syncedAt,
    );

    if (!mounted || _workspaceInstanceId != instanceId) {
      return;
    }

    setState(() {
      _snapshot = updatedSnapshot;
    });
  }

  Future<void> _resolveSelectedMedia(RedleafSrtDocument document) async {
    if (_selectedDocId != document.docId || !_connectionMatchesWorkspace) {
      return;
    }

    final serial = ++_mediaResolutionSerial;
    final signature = _mediaSignature(document);

    setState(() {
      _mediaResolutionLoading = true;
      _selectedMediaResolution = null;
      _selectedMediaSignature = signature;
    });

    final resolution = await _mediaResources.resolve(document);

    if (!mounted ||
        serial != _mediaResolutionSerial ||
        _selectedDocId != document.docId) {
      return;
    }

    final current = _selectedDocument;
    final currentSignature =
        current == null ? null : _mediaSignature(current);

    if (current != null && currentSignature != signature) {
      setState(() {
        _mediaResolutionLoading = false;
      });
      unawaited(_resolveSelectedMedia(current));
      return;
    }

    setState(() {
      _selectedMediaResolution = resolution;
      _mediaResolutionLoading = false;
      _selectedMediaSignature = signature;
    });
  }

  Future<void> _openSelectedVerifiedMedia(String mediaPath) async {
    if (!_connectionMatchesWorkspace) {
      setState(() {
        _handoffError =
            'Connect this Redleaf project before opening its media in Player.';
      });
      return;
    }

    final document = _selectedDocument;
    final resolution = _selectedMediaResolution;
    final resource = mediaPath.trim();

    if (document == null ||
        resolution?.isLocalFileReady != true ||
        resource.isEmpty ||
        resolution?.resolvedResource?.trim() != resource) {
      return;
    }

    final transcriptAwareCallback = widget.onOpenRedleafHandoff;
    if (transcriptAwareCallback == null) {
      widget.onOpenVerifiedMedia?.call(resource);
      return;
    }

    final serial = ++_handoffSerial;
    final docId = document.docId;

    setState(() {
      _handoffLoading = true;
      _handoffError = null;
    });

    try {
      final transcript = await _transcripts.loadForDocument(document);

      if (!mounted || serial != _handoffSerial || _selectedDocId != docId) {
        return;
      }

      final currentResolution = _selectedMediaResolution;
      if (currentResolution?.isLocalFileReady != true ||
          currentResolution?.resolvedResource?.trim() != resource) {
        setState(() {
          _handoffLoading = false;
          _handoffError =
              'The verified media resource changed before Player handoff.';
        });
        return;
      }

      final handoff = RedleafPlayerHandoff.fromTranscript(
        mediaPath: resource,
        transcript: transcript,
      );

      setState(() {
        _handoffLoading = false;
        _handoffError = null;
      });

      transcriptAwareCallback(handoff);
    } catch (error) {
      if (!mounted || serial != _handoffSerial || _selectedDocId != docId) {
        return;
      }

      setState(() {
        _handoffLoading = false;
        _handoffError = error.toString();
      });
    }
  }

  RedleafSrtDocument? get _selectedDocument {
    final docId = _selectedDocId;
    if (docId == null) {
      return null;
    }

    for (final document in _discovery.documents) {
      if (document.docId == docId) {
        return document;
      }
    }

    return null;
  }

  String _formatSnapshotTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '$month/$day ${local.year} $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: Column(
          children: [
            _buildToolbar(context),
            const Divider(height: 1, color: Colors.white10),
            Expanded(
              child: _buildBody(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final project = _redleafWorkspaceProject;
    final connectedHere = _connectionMatchesWorkspace;
    final connectedElsewhere =
        _connection.isConnected && !connectedHere;
    final busy = _syncing ||
        _discovery.loading ||
        _discovery.scanningMedia ||
        _catalogs.loading ||
        _catalogMembershipLoading;

    final subtitle = connectedHere
        ? _connection.projectName
        : connectedElsewhere
            ? 'Connected to a different Redleaf instance'
            : project == null
                ? 'No saved Redleaf project selected'
                : 'Cached project · ${project.name}';

    return Container(
      height: 58,
      color: const Color(0xFF131313),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              Icons.article_outlined,
              size: 17,
              color: primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'REDLEAF',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          if (connectedHere) ...[
            const _ConnectionChip(
              label: 'CONNECTED',
              color: Colors.greenAccent,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : () => unawaited(_syncNow()),
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 16),
              label: const Text(
                'SYNC NOW',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ] else if (connectedElsewhere)
            const _ConnectionChip(
              label: 'OTHER INSTANCE',
              color: Colors.orangeAccent,
            )
          else
            const _ConnectionChip(
              label: 'DISCONNECTED',
              color: Colors.white38,
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final workspaceProject = _redleafWorkspaceProject;

    if (workspaceProject == null) {
      return const _LoadingState(
        label: 'Waiting for a saved Redleaf project…',
      );
    }

    if (_snapshotLoading && _discovery.documents.isEmpty) {
      return const _LoadingState(
        label: 'Opening saved Redleaf snapshot…',
      );
    }

    if (_snapshotError != null && _discovery.documents.isEmpty) {
      return _ErrorState(
        message: _snapshotError!,
        onRetry: () => unawaited(
          _loadSnapshot(_workspaceInstanceId),
        ),
      );
    }

    if (_snapshot == null && _discovery.documents.isEmpty) {
      if (_connectionMatchesWorkspace) {
        return _ErrorState(
          message:
              'This Redleaf project does not have a saved snapshot yet. '
              'Use SYNC NOW to create its local browse cache.',
          onRetry: () => unawaited(_syncNow()),
        );
      }

      return _DisconnectedState(
        serverUrl: workspaceProject.redleafServerUrl ??
            _connection.serverUrl,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final showHandoffPanel = constraints.maxWidth >= 980;
        final handoffPanelWidth =
            constraints.maxWidth >= 1320 ? 370.0 : 330.0;

        return Column(
          children: [
            _buildSummary(context),
            const Divider(height: 1, color: Colors.white10),
            _buildSearchRow(context),
            const Divider(height: 1, color: Colors.white10),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: _buildCatalogSidebar(context),
                  ),
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: Colors.white10,
                  ),
                  Expanded(
                    child: _buildDocumentTable(context),
                  ),
                  if (showHandoffPanel) ...[
                    const VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Colors.white10,
                    ),
                    SizedBox(
                      width: handoffPanelWidth,
                      child: _RedleafHandoffPanel(
                        document: _selectedDocument,
                        catalogName: _selectedCatalog?.name,
                        mediaScanInProgress: _discovery.scanningMedia,
                        scanForMediaLoading: _scanForMediaLoading,
                        scanForMediaMessage: _scanForMediaMessage,
                        scanForMediaError: _scanForMediaError,
                        onScanForMedia:
                            _connectionMatchesWorkspace && !_syncing
                                ? () => unawaited(_scanSelectedMedia())
                                : null,
                        resolution: _selectedMediaResolution,
                        resolutionLoading: _mediaResolutionLoading,
                        handoffLoading: _handoffLoading,
                        handoffError: _handoffError,
                        onOpenVerifiedMedia:
                            widget.onOpenRedleafHandoff != null ||
                                    widget.onOpenVerifiedMedia != null
                                ? (path) => unawaited(
                                      _openSelectedVerifiedMedia(path),
                                    )
                                : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummary(BuildContext context) {
    final expected = _discovery.expectedSrtCount;
    final loaded = _discovery.documentCount;
    final linked = _discovery.linkedMediaCount;
    final transcriptOnly = _discovery.transcriptOnlyCount;
    final unknown = _discovery.unknownMediaCount;

    final scanningText = _discovery.scanningMedia
        ? 'Checking media ${_discovery.mediaCheckedCount}/$loaded'
        : null;

    return Container(
      color: const Color(0xFF151515),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          _Metric(
            label: 'SRTS',
            value: loaded,
            secondary: expected > 0 && expected != loaded
                ? 'expected $expected'
                : null,
          ),
          const _MetricDivider(),
          _Metric(
            label: 'MEDIA LINKED',
            value: linked,
          ),
          const _MetricDivider(),
          _Metric(
            label: 'TRANSCRIPT ONLY',
            value: transcriptOnly,
          ),
          const _MetricDivider(),
          _Metric(
            label: 'UNKNOWN',
            value: unknown,
          ),
          const Spacer(),
          if (scanningText != null)
            Text(
              scanningText,
              style: const TextStyle(
                fontSize: 10.5,
                color: Colors.white38,
              ),
            )
          else if (_syncError != null)
            Flexible(
              child: Text(
                _syncError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Colors.orangeAccent,
                ),
              ),
            )
          else
            Text(
              _snapshot == null
                  ? 'No saved snapshot'
                  : 'Cached snapshot · ${_formatSnapshotTime(_snapshot!.syncedAt)}',
              style: const TextStyle(
                fontSize: 10.5,
                color: Colors.white38,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchRow(BuildContext context) {
    return Container(
      height: 52,
      color: const Color(0xFF121212),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 360,
            child: TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter SRTs by filename, path, or doc ID…',
                hintStyle: const TextStyle(
                  fontSize: 11,
                  color: Colors.white30,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 17,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear filter',
                        onPressed: _searchController.clear,
                        icon: const Icon(Icons.close, size: 16),
                      ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _catalogMembershipLoading
                ? 'Loading ${_selectedCatalog?.name ?? 'catalog'}…'
                : _selectedCatalog != null
                    ? '${_filteredDocuments.length} SRTs in ${_selectedCatalog!.name}'
                    : _query.isEmpty
                        ? '${_discovery.documentCount} indexed SRTs'
                        : '${_filteredDocuments.length} of ${_discovery.documentCount} SRTs',
            style: const TextStyle(
              fontSize: 10.5,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogSidebar(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final catalogs = _visibleCatalogs;

    return Container(
      color: const Color(0xFF131313),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'CATALOGS',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                      color: Colors.white38,
                    ),
                  ),
                ),
                if (_catalogs.loading)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
          _CatalogTile(
            label: 'All SRTs',
            count: _discovery.documentCount,
            selected: _selectedCatalogId == null,
            loading: false,
            primary: primary,
            onTap: () => unawaited(_selectCatalog(null)),
          ),
          const Divider(height: 1, color: Colors.white10),
          if (_catalogs.lastError != null && catalogs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                _catalogs.lastError!,
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  color: Colors.orangeAccent,
                ),
              ),
            )
          else if (!_catalogs.loading && catalogs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No user catalogs in this Redleaf project.',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  color: Colors.white30,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: catalogs.length,
                itemBuilder: (context, index) {
                  final catalog = catalogs[index];
                  final selected = catalog.id == _selectedCatalogId;
                  final count = selected && !_catalogMembershipLoading
                      ? _selectedCatalogDocumentIds?.length
                      : null;

                  return _CatalogTile(
                    label: catalog.name,
                    count: count,
                    selected: selected,
                    loading: selected && _catalogMembershipLoading,
                    primary: primary,
                    onTap: () => unawaited(_selectCatalog(catalog)),
                  );
                },
              ),
            ),
          if (_catalogMembershipError != null) ...[
            const Divider(height: 1, color: Colors.white10),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _catalogMembershipError!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 9.5,
                  height: 1.35,
                  color: Colors.orangeAccent,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDocumentTable(BuildContext context) {
    final documents = _filteredDocuments;

    if (documents.isEmpty) {
      final message = _catalogMembershipLoading
          ? 'Loading catalog membership…'
          : _selectedCatalog != null
              ? 'No SRTs in this Redleaf catalog match the current filter.'
              : 'No Redleaf SRTs match this filter.';

      return Center(
        child: Text(
          message,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white38,
          ),
        ),
      );
    }

    return Column(
      children: [
        const _TableHeader(),
        const Divider(height: 1, color: Colors.white10),
        Expanded(
          child: ListView.builder(
            itemCount: documents.length,
            itemExtent: 44,
            itemBuilder: (context, index) {
              final document = documents[index];
              return _DocumentRow(
                document: document,
                selected: document.docId == _selectedDocId,
                onTap: () => unawaited(_selectDocument(document)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.label,
    required this.count,
    required this.selected,
    required this.loading,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool selected;
  final bool loading;
  final Color primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.folder_open_outlined
                    : Icons.folder_outlined,
                size: 15,
                color: selected ? primary : Colors.white38,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? Colors.white70 : Colors.white54,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else if (count != null)
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: Colors.white30,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.secondary,
  });

  final String label;
  final int value;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 18,
              height: 1,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                  color: Colors.white38,
                ),
              ),
              if (secondary != null) ...[
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    secondary!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 8.5,
                      color: Colors.white24,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(right: 16),
      child: SizedBox(
        height: 30,
        child: VerticalDivider(
          width: 1,
          thickness: 1,
          color: Colors.white10,
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      color: const Color(0xFF161616),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: const Row(
        children: [
          SizedBox(
            width: 72,
            child: _HeaderText('DOC ID'),
          ),
          Expanded(
            flex: 7,
            child: _HeaderText('SRT'),
          ),
          SizedBox(
            width: 72,
            child: _HeaderText('TAGS'),
          ),
          SizedBox(
            width: 92,
            child: _HeaderText('COLOR'),
          ),
          SizedBox(
            width: 118,
            child: _HeaderText('MEDIA'),
          ),
        ],
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  const _HeaderText(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 8.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.7,
        color: Colors.white38,
      ),
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.document,
    required this.selected,
    required this.onTap,
  });

  final RedleafSrtDocument document;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Material(
      color: selected
          ? primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.045),
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  '${document.docId}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: selected ? primary : Colors.white38,
                  ),
                ),
              ),
              Expanded(
                flex: 7,
                child: Tooltip(
                  message: document.relativePath,
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text(
                    document.relativePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  '${document.tagCount}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Colors.white54,
                  ),
                ),
              ),
              SizedBox(
                width: 92,
                child: _ColorLabel(
                  value: document.color,
                ),
              ),
              SizedBox(
                width: 118,
                child: _MediaStateLabel(
                  media: document.media,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorLabel extends StatelessWidget {
  const _ColorLabel({
    required this.value,
  });

  final String? value;

  @override
  Widget build(BuildContext context) {
    final label = value?.trim() ?? '';
    if (label.isEmpty) {
      return const Text(
        '—',
        style: TextStyle(
          fontSize: 10.5,
          color: Colors.white24,
        ),
      );
    }

    final swatch = _parseRedleafColor(label);

    return Row(
      children: [
        if (swatch != null) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: swatch,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white12),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white54,
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaStateLabel extends StatelessWidget {
  const _MediaStateLabel({
    required this.media,
  });

  final RedleafMediaLink media;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (media.state) {
      RedleafMediaLinkState.linked => (
          media.isVideo ? Icons.movie_outlined : Icons.audiotrack,
          media.isVideo ? 'VIDEO' : 'AUDIO',
          Colors.greenAccent,
        ),
      RedleafMediaLinkState.notLinked => (
          Icons.notes_outlined,
          'TRANSCRIPT',
          Colors.white38,
        ),
      RedleafMediaLinkState.unknown => (
          Icons.help_outline,
          'UNKNOWN',
          Colors.orangeAccent,
        ),
    };

    return Row(
      children: [
        Icon(
          icon,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.45,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _RedleafHandoffPanel extends StatelessWidget {
  const _RedleafHandoffPanel({
    required this.document,
    required this.catalogName,
    required this.mediaScanInProgress,
    required this.scanForMediaLoading,
    required this.scanForMediaMessage,
    required this.scanForMediaError,
    required this.onScanForMedia,
    required this.resolution,
    required this.resolutionLoading,
    required this.handoffLoading,
    required this.handoffError,
    required this.onOpenVerifiedMedia,
  });

  final RedleafSrtDocument? document;
  final String? catalogName;
  final bool mediaScanInProgress;
  final bool scanForMediaLoading;
  final String? scanForMediaMessage;
  final String? scanForMediaError;
  final VoidCallback? onScanForMedia;
  final RedleafMediaResourceResolution? resolution;
  final bool resolutionLoading;
  final bool handoffLoading;
  final String? handoffError;
  final ValueChanged<String>? onOpenVerifiedMedia;

  VoidCallback? get _openVerifiedLocalFile {
    final resolution = this.resolution;
    final callback = onOpenVerifiedMedia;
    final resource = resolution?.resolvedResource?.trim() ?? '';

    if (resolution?.isLocalFileReady != true ||
        callback == null ||
        resource.isEmpty ||
        handoffLoading) {
      return null;
    }

    return () => callback(resource);
  }

  @override
  Widget build(BuildContext context) {
    final document = this.document;

    return Container(
      color: const Color(0xFF131313),
      child: document == null
          ? const _EmptyHandoffState()
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PLAYER HANDOFF',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _HandoffMediaStatus(
                    media: document.media,
                    mediaScanInProgress: mediaScanInProgress,
                    resolution: resolution,
                    resolutionLoading: resolutionLoading,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    document.fileName,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _InspectorRow(
                    label: 'Doc ID',
                    value: '${document.docId}',
                  ),
                  _InspectorRow(
                    label: 'Catalog',
                    value: catalogName ?? 'All SRTs',
                  ),
                  _InspectorRow(
                    label: 'Status',
                    value: document.status.isEmpty
                        ? 'Unknown'
                        : document.status,
                  ),
                  _InspectorRow(
                    label: 'Tags',
                    value: '${document.tagCount}',
                  ),
                  _InspectorRow(
                    label: 'Color',
                    value: document.color ?? '—',
                  ),
                  _InspectorRow(
                    label: 'Duration',
                    value: _formatDuration(document.durationSeconds),
                  ),
                  _InspectorRow(
                    label: 'SRT size',
                    value: _formatByteCount(document.fileSizeBytes),
                  ),
                  if (document.processedAt != null)
                    _InspectorRow(
                      label: 'Processed',
                      value: document.processedAt!,
                    ),
                  if (document.statusMessage != null) ...[
                    const SizedBox(height: 4),
                    _InfoBlock(
                      heading: 'REDLEAF STATUS MESSAGE',
                      child: Text(
                        document.statusMessage!,
                        style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.45,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: Colors.white10),
                  const SizedBox(height: 14),
                  _InfoBlock(
                    heading: 'SRT REFERENCE',
                    child: SelectableText(
                      document.relativePath,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.4,
                        color: Colors.white60,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: Colors.white10),
                  const SizedBox(height: 14),
                  _MediaRelationshipBlock(
                    media: document.media,
                    mediaScanInProgress: mediaScanInProgress,
                  ),
                  if (document.media.state ==
                          RedleafMediaLinkState.notLinked &&
                      onScanForMedia != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed:
                            scanForMediaLoading ? null : onScanForMedia,
                        icon: scanForMediaLoading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              )
                            : const Icon(
                                Icons.manage_search,
                                size: 16,
                              ),
                        label: Text(
                          scanForMediaLoading
                              ? 'SCANNING REDLEAF…'
                              : 'SCAN FOR MEDIA',
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.35,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (scanForMediaMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      scanForMediaMessage!,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.45,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ],
                  if (scanForMediaError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      scanForMediaError!,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.45,
                        color: Colors.orangeAccent,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: Colors.white10),
                  const SizedBox(height: 14),
                  _ResourceResolutionBlock(
                    resolution: resolution,
                    loading: resolutionLoading,
                    media: document.media,
                  ),
                  if (handoffError != null) ...[
                    const SizedBox(height: 12),
                    _InfoBlock(
                      heading: 'TRANSCRIPT HANDOFF ERROR',
                      child: Text(
                        handoffError!,
                        style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.45,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: Colors.white10),
                  const SizedBox(height: 14),
                  _PlayerBoundaryBlock(
                    canOpenVerifiedLocalFile:
                        resolution?.isLocalFileReady == true &&
                            onOpenVerifiedMedia != null &&
                            !handoffLoading,
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _openVerifiedLocalFile,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: Text(
                        _handoffButtonLabel(
                          document.media,
                          resolution,
                          resolutionLoading || handoffLoading,
                          onOpenVerifiedMedia != null,
                        ),
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.35,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _EmptyHandoffState extends StatelessWidget {
  const _EmptyHandoffState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_play,
              size: 30,
              color: Colors.white24,
            ),
            SizedBox(height: 12),
            Text(
              'Select an SRT',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white54,
              ),
            ),
            SizedBox(height: 7),
            Text(
              'This panel will queue the Redleaf identity and media relationship for inspection before anything is handed to MLT Player.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.45,
                color: Colors.white30,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HandoffMediaStatus extends StatelessWidget {
  const _HandoffMediaStatus({
    required this.media,
    required this.mediaScanInProgress,
    required this.resolution,
    required this.resolutionLoading,
  });

  final RedleafMediaLink media;
  final bool mediaScanInProgress;
  final RedleafMediaResourceResolution? resolution;
  final bool resolutionLoading;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = resolutionLoading
        ? (
            Icons.sync,
            'RESOLVING RESOURCE',
            Colors.lightBlueAccent,
          )
        : _resolutionStatusPresentation(
            media,
            resolution,
            mediaScanInProgress,
          );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.55,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectorRow extends StatelessWidget {
  const _InspectorRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white38,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({
    required this.heading,
    required this.child,
  });

  final String heading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: const TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
            color: Colors.white38,
          ),
        ),
        const SizedBox(height: 7),
        child,
      ],
    );
  }
}

class _MediaRelationshipBlock extends StatelessWidget {
  const _MediaRelationshipBlock({
    required this.media,
    required this.mediaScanInProgress,
  });

  final RedleafMediaLink media;
  final bool mediaScanInProgress;

  @override
  Widget build(BuildContext context) {
    if (media.state == RedleafMediaLinkState.unknown) {
      return _InfoBlock(
        heading: 'MEDIA RELATIONSHIP',
        child: Text(
          mediaScanInProgress
              ? 'Redleaf media status is still being checked. No Player resource has been inferred.'
              : 'MLT Player could not verify Redleaf’s media status for this SRT. Unknown is not treated as transcript-only.',
          style: const TextStyle(
            fontSize: 10.5,
            height: 1.45,
            color: Colors.orangeAccent,
          ),
        ),
      );
    }

    if (!media.isLinked) {
      return const _InfoBlock(
        heading: 'MEDIA RELATIONSHIP',
        child: Text(
          'Redleaf explicitly reports no upstream media attached. This is a valid transcript-only SRT and there is no media resource to hand to the Player.',
          style: TextStyle(
            fontSize: 10.5,
            height: 1.45,
            color: Colors.white54,
          ),
        ),
      );
    }

    final path = media.path?.trim() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'MEDIA RELATIONSHIP',
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
            color: Colors.white38,
          ),
        ),
        const SizedBox(height: 8),
        _InspectorRow(
          label: 'Type',
          value: media.type?.toUpperCase() ?? 'MEDIA',
        ),
        _InspectorRow(
          label: 'Source',
          value: media.source ?? 'Unknown',
        ),
        _InspectorRow(
          label: 'Position',
          value: _formatSeconds(media.positionSeconds),
        ),
        _InspectorRow(
          label: 'Offset',
          value: _formatSignedSeconds(media.offsetSeconds),
        ),
        const SizedBox(height: 6),
        const Text(
          'RESOURCE REFERENCE',
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
            color: Colors.white38,
          ),
        ),
        const SizedBox(height: 7),
        if (path.isEmpty)
          const Text(
            'Redleaf reports linked media but did not provide a path or URL reference.',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.45,
              color: Colors.orangeAccent,
            ),
          )
        else
          SelectableText(
            path,
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: Colors.white70,
            ),
          ),
      ],
    );
  }
}

class _ResourceResolutionBlock extends StatelessWidget {
  const _ResourceResolutionBlock({
    required this.resolution,
    required this.loading,
    required this.media,
  });

  final RedleafMediaResourceResolution? resolution;
  final bool loading;
  final RedleafMediaLink media;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _InfoBlock(
        heading: 'RESOURCE RESOLUTION',
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Resolving Redleaf’s media reference without opening the Player…',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  color: Colors.white54,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final resolution = this.resolution;
    if (resolution == null) {
      return _InfoBlock(
        heading: 'RESOURCE RESOLUTION',
        child: Text(
          media.state == RedleafMediaLinkState.unknown
              ? 'Waiting for Redleaf media status before resolving a resource.'
              : 'No resource-resolution result is available yet.',
          style: const TextStyle(
            fontSize: 10.5,
            height: 1.45,
            color: Colors.white38,
          ),
        ),
      );
    }

    final (label, color) = switch (resolution.state) {
      RedleafMediaResourceState.localFileReady => (
          'VERIFIED LOCAL FILE',
          Colors.greenAccent,
        ),
      RedleafMediaResourceState.webUrlCandidate => (
          'WEB CANDIDATE',
          Colors.lightBlueAccent,
        ),
      RedleafMediaResourceState.transcriptOnly => (
          'TRANSCRIPT ONLY',
          Colors.white54,
        ),
      RedleafMediaResourceState.unknown => (
          'UNKNOWN',
          Colors.orangeAccent,
        ),
      RedleafMediaResourceState.unavailable => (
          'UNAVAILABLE',
          Colors.redAccent,
        ),
    };

    final resource = resolution.resolvedResource?.trim() ?? '';
    final virtualPath = resolution.virtualPath?.trim() ?? '';
    final message = resolution.message?.trim() ?? '';

    return _InfoBlock(
      heading: 'RESOURCE RESOLUTION',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: color.withValues(alpha: 0.22),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.55,
                color: color,
              ),
            ),
          ),
          if (virtualPath.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'REDLEAF VIRTUAL PATH',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: Colors.white30,
              ),
            ),
            const SizedBox(height: 5),
            SelectableText(
              virtualPath,
              style: const TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: Colors.white60,
              ),
            ),
          ],
          if (resource.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              resolution.isLocalFileReady
                  ? 'VERIFIED PHYSICAL RESOURCE'
                  : 'PRESERVED WEB RESOURCE',
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: Colors.white30,
              ),
            ),
            const SizedBox(height: 5),
            SelectableText(
              resource,
              style: const TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: Colors.white70,
              ),
            ),
          ],
          if (message.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(
                fontSize: 10,
                height: 1.4,
                color: resolution.state == RedleafMediaResourceState.unavailable
                    ? Colors.redAccent
                    : Colors.white38,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlayerBoundaryBlock extends StatelessWidget {
  const _PlayerBoundaryBlock({
    required this.canOpenVerifiedLocalFile,
  });

  final bool canOpenVerifiedLocalFile;

  @override
  Widget build(BuildContext context) {
    final heading =
        canOpenVerifiedLocalFile ? 'VERIFIED FOR PLAYER' : 'PLAYER GATE CLOSED';
    final message = canOpenVerifiedLocalFile
        ? 'Only this verified local filesystem resource may be handed to MLT Player.'
        : 'MLT Player remains blocked unless Redleaf media resolves to a verified local filesystem resource.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            canOpenVerifiedLocalFile
                ? Icons.verified_user_outlined
                : Icons.shield_outlined,
            size: 15,
            color: canOpenVerifiedLocalFile
                ? Colors.greenAccent
                : Colors.white38,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: canOpenVerifiedLocalFile
                        ? Colors.greenAccent
                        : Colors.white54,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.4,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

(IconData, String, Color) _resolutionStatusPresentation(
  RedleafMediaLink media,
  RedleafMediaResourceResolution? resolution,
  bool mediaScanInProgress,
) {
  if (resolution != null) {
    return switch (resolution.state) {
      RedleafMediaResourceState.localFileReady => (
          Icons.verified_outlined,
          'VERIFIED LOCAL FILE',
          Colors.greenAccent,
        ),
      RedleafMediaResourceState.webUrlCandidate => (
          Icons.language,
          'WEB CANDIDATE',
          Colors.lightBlueAccent,
        ),
      RedleafMediaResourceState.transcriptOnly => (
          Icons.notes_outlined,
          'TRANSCRIPT ONLY',
          Colors.white54,
        ),
      RedleafMediaResourceState.unknown => (
          Icons.help_outline,
          mediaScanInProgress ? 'MEDIA STATUS PENDING' : 'UNKNOWN',
          Colors.orangeAccent,
        ),
      RedleafMediaResourceState.unavailable => (
          Icons.error_outline,
          'RESOURCE UNAVAILABLE',
          Colors.redAccent,
        ),
    };
  }

  return switch (media.state) {
    RedleafMediaLinkState.linked => (
        media.isVideo ? Icons.movie_outlined : Icons.audiotrack,
        media.isVideo ? 'LINKED VIDEO' : 'LINKED AUDIO',
        Colors.greenAccent,
      ),
    RedleafMediaLinkState.notLinked => (
        Icons.notes_outlined,
        'TRANSCRIPT ONLY',
        Colors.white54,
      ),
    RedleafMediaLinkState.unknown => (
        Icons.help_outline,
        mediaScanInProgress ? 'MEDIA STATUS PENDING' : 'MEDIA STATUS UNKNOWN',
        Colors.orangeAccent,
      ),
  };
}

String _handoffButtonLabel(
  RedleafMediaLink media,
  RedleafMediaResourceResolution? resolution,
  bool loading,
  bool hasOpenCallback,
) {
  if (loading) {
    return 'PREPARING PLAYER HANDOFF';
  }

  if (resolution != null) {
    return switch (resolution.state) {
      RedleafMediaResourceState.localFileReady => hasOpenCallback
          ? 'OPEN VERIFIED FILE IN PLAYER'
          : 'PLAYER HANDOFF NOT CONNECTED',
      RedleafMediaResourceState.webUrlCandidate =>
        'WEB PLAYBACK NOT VERIFIED',
      RedleafMediaResourceState.transcriptOnly =>
        'NO LINKED MEDIA TO OPEN',
      RedleafMediaResourceState.unknown =>
        'WAITING FOR MEDIA STATUS',
      RedleafMediaResourceState.unavailable =>
        'RESOURCE NOT AVAILABLE',
    };
  }

  return switch (media.state) {
    RedleafMediaLinkState.linked => 'RESOLUTION PENDING',
    RedleafMediaLinkState.notLinked => 'NO LINKED MEDIA TO OPEN',
    RedleafMediaLinkState.unknown => 'WAITING FOR MEDIA STATUS',
  };
}

String _formatDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds < 0) {
    return '—';
  }

  final totalSeconds = seconds.round();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final remainingSeconds = totalSeconds % 60;

  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
}

String _formatByteCount(int? bytes) {
  if (bytes == null || bytes < 0) {
    return '—';
  }

  if (bytes < 1024) {
    return '$bytes B';
  }

  final kib = bytes / 1024;
  if (kib < 1024) {
    return '${kib.toStringAsFixed(kib >= 100 ? 0 : 1)} KiB';
  }

  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib >= 100 ? 0 : 1)} MiB';
}

String _formatSeconds(double? seconds) {
  if (seconds == null || !seconds.isFinite) {
    return '—';
  }
  return '${seconds.toStringAsFixed(3)} s';
}

String _formatSignedSeconds(double? seconds) {
  if (seconds == null || !seconds.isFinite) {
    return '—';
  }

  final prefix = seconds > 0 ? '+' : '';
  return '$prefix${seconds.toStringAsFixed(3)} s';
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: color.withValues(alpha: 0.28),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
          color: color,
        ),
      ),
    );
  }
}

class _DisconnectedState extends StatelessWidget {
  const _DisconnectedState({
    required this.serverUrl,
  });

  final String serverUrl;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 38,
              color: Colors.white24,
            ),
            const SizedBox(height: 14),
            const Text(
              'Redleaf is not connected',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'Open Settings, sign in to Redleaf, then return here to browse indexed SRT transcripts.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Colors.white38,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              serverUrl,
              style: const TextStyle(
                fontSize: 10.5,
                color: Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({
    required this.label,
  });

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 34,
              color: Colors.redAccent,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('RETRY'),
            ),
          ],
        ),
      ),
    );
  }
}

Color? _parseRedleafColor(String raw) {
  final normalized = raw.trim().toLowerCase();

  const named = <String, Color>{
    'red': Color(0xFFE57373),
    'orange': Color(0xFFFFB74D),
    'yellow': Color(0xFFFFF176),
    'green': Color(0xFF81C784),
    'blue': Color(0xFF64B5F6),
    'purple': Color(0xFFBA68C8),
    'pink': Color(0xFFF06292),
    'cyan': Color(0xFF4DD0E1),
  };

  final namedColor = named[normalized];
  if (namedColor != null) {
    return namedColor;
  }

  if (normalized.startsWith('#')) {
    final hex = normalized.substring(1);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        return Color(0xFF000000 | value);
      }
    }
  }

  return null;
}
