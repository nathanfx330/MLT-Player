// lib/ui/redleaf_page.dart

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/redleaf_catalog_service.dart';
import '../services/redleaf_connection_service.dart';
import '../services/redleaf_srt_service.dart';

class RedleafPage extends StatefulWidget {
  const RedleafPage({
    super.key,
    required this.active,
    this.connection,
  });

  final bool active;
  final RedleafConnectionService? connection;

  @override
  State<RedleafPage> createState() => _RedleafPageState();
}

class _RedleafPageState extends State<RedleafPage> {
  late final RedleafConnectionService _connection;
  late final RedleafSrtDiscoveryService _discovery;
  late final RedleafCatalogService _catalogs;
  final TextEditingController _searchController = TextEditingController();

  String _query = '';
  int? _selectedDocId;
  int? _selectedCatalogId;
  Set<int>? _selectedCatalogDocumentIds;
  bool _catalogMembershipLoading = false;
  String? _catalogMembershipError;
  String _loadedInstanceId = '';

  @override
  void initState() {
    super.initState();

    _connection = widget.connection ?? RedleafConnectionService.instance;
    _discovery = RedleafSrtDiscoveryService(connection: _connection);
    _catalogs = RedleafCatalogService(connection: _connection);

    _connection.addListener(_onConnectionChanged);
    _discovery.addListener(_onDiscoveryChanged);
    _catalogs.addListener(_onCatalogsChanged);
    _searchController.addListener(_onSearchChanged);

    unawaited(_connection.load().then((_) {
      if (!mounted) {
        return;
      }
      _maybeLoad();
    }));
  }

  @override
  void didUpdateWidget(covariant RedleafPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!oldWidget.active && widget.active) {
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

  void _onConnectionChanged() {
    if (!_connection.isConnected) {
      _loadedInstanceId = '';
      _selectedDocId = null;
      _resetCatalogFilter();
      _discovery.clear();
    } else if (_loadedInstanceId.isNotEmpty &&
        _loadedInstanceId != _connection.instanceId) {
      _loadedInstanceId = '';
      _selectedDocId = null;
      _resetCatalogFilter();
      _discovery.clear();
    }

    if (mounted) {
      setState(() {});
    }

    _maybeLoad();
  }

  void _onCatalogsChanged() {
    if (!mounted) {
      return;
    }

    final selectedCatalogId = _selectedCatalogId;
    if (selectedCatalogId != null &&
        _catalogs.loaded &&
        !_visibleCatalogs.any(
          (catalog) => catalog.id == selectedCatalogId,
        )) {
      _resetCatalogFilter();
    }

    setState(() {});
  }

  void _onDiscoveryChanged() {
    if (mounted) {
      setState(() {});
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
      }
    });
  }

  void _maybeLoad() {
    if (!mounted || !widget.active || !_connection.isConnected) {
      return;
    }

    final instanceId = _connection.instanceId;
    if (_loadedInstanceId != instanceId) {
      _loadedInstanceId = instanceId;
      _selectedDocId = null;
      _resetCatalogFilter();
    }

    if (!_catalogs.loaded && !_catalogs.loading) {
      unawaited(_catalogs.refreshCatalogs());
    }

    if (!_discovery.loading &&
        !_discovery.scanningMedia &&
        _discovery.documents.isEmpty) {
      unawaited(_discovery.refresh());
    }
  }

  Future<void> _refresh() async {
    if (!_connection.isConnected) {
      return;
    }

    _loadedInstanceId = _connection.instanceId;

    final previousCatalogId = _selectedCatalogId;
    await _catalogs.refreshCatalogs();

    if (!mounted) {
      return;
    }

    if (previousCatalogId != null &&
        _visibleCatalogs.any(
          (catalog) => catalog.id == previousCatalogId,
        )) {
      await _loadCatalogMembership(
        previousCatalogId,
        forceRefresh: true,
      );
    } else if (previousCatalogId != null) {
      setState(_resetCatalogFilter);
    }

    await _discovery.refresh();
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
                  _connection.isConnected
                      ? _connection.projectName
                      : 'Connect in Settings to browse indexed SRTs',
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
          if (_connection.isConnected) ...[
            const _ConnectionChip(
              label: 'CONNECTED',
              color: Colors.greenAccent,
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Refresh Redleaf SRTs',
              visualDensity: VisualDensity.compact,
              onPressed: _discovery.loading ||
                      _discovery.scanningMedia ||
                      _catalogs.loading ||
                      _catalogMembershipLoading
                  ? null
                  : () => unawaited(_refresh()),
              icon: _discovery.loading ||
                      _discovery.scanningMedia ||
                      _catalogs.loading ||
                      _catalogMembershipLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
            ),
          ] else
            const _ConnectionChip(
              label: 'DISCONNECTED',
              color: Colors.white38,
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!_connection.isConnected) {
      return _DisconnectedState(
        serverUrl: _connection.serverUrl,
      );
    }

    if (_discovery.loading && _discovery.documents.isEmpty) {
      return const _LoadingState(
        label: 'Loading Redleaf SRT documents…',
      );
    }

    if (_discovery.lastError != null && _discovery.documents.isEmpty) {
      return _ErrorState(
        message: _discovery.lastError!,
        onRetry: () => unawaited(_refresh()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final showInspector = constraints.maxWidth >= 1180;

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
                  if (showInspector) ...[
                    const VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Colors.white10,
                    ),
                    SizedBox(
                      width: 330,
                      child: _RedleafInspector(
                        document: _selectedDocument,
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
          else
            Text(
              _discovery.hasCompleteMediaScan
                  ? 'Media scan complete'
                  : 'Read-only Redleaf view',
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
                onTap: () {
                  setState(() {
                    _selectedDocId = document.docId;
                  });
                },
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

class _RedleafInspector extends StatelessWidget {
  const _RedleafInspector({
    required this.document,
  });

  final RedleafSrtDocument? document;

  @override
  Widget build(BuildContext context) {
    final document = this.document;

    return Container(
      color: const Color(0xFF131313),
      child: document == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Select an SRT to inspect its Redleaf identity and media relationship.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: Colors.white30,
                  ),
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'REDLEAF DOCUMENT',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: Colors.white10),
                  const SizedBox(height: 14),
                  const Text(
                    'PATH',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    document.relativePath,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 16),
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
                  _MediaRelationshipBlock(
                    media: document.media,
                  ),
                ],
              ),
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
            width: 76,
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

class _MediaRelationshipBlock extends StatelessWidget {
  const _MediaRelationshipBlock({
    required this.media,
  });

  final RedleafMediaLink media;

  @override
  Widget build(BuildContext context) {
    if (media.state == RedleafMediaLinkState.unknown) {
      return const Text(
        'MLT could not verify Redleaf’s media status for this SRT.',
        style: TextStyle(
          fontSize: 10.5,
          height: 1.45,
          color: Colors.orangeAccent,
        ),
      );
    }

    if (!media.isLinked) {
      return const Text(
        'Redleaf reports no upstream media attached. This remains a valid transcript-only document.',
        style: TextStyle(
          fontSize: 10.5,
          height: 1.45,
          color: Colors.white54,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InspectorRow(
          label: 'Type',
          value: media.type?.toUpperCase() ?? 'MEDIA',
        ),
        _InspectorRow(
          label: 'Source',
          value: media.source ?? 'Unknown',
        ),
        if (media.path != null) ...[
          const SizedBox(height: 4),
          SelectableText(
            media.path!,
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: Colors.white60,
            ),
          ),
        ],
      ],
    );
  }
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
