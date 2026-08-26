// lib/ui/explorer_page.dart

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/explorer_asset_annotation.dart';
import '../models/explorer_item.dart';
import '../models/explorer_metadata.dart';
import '../models/project_catalog.dart';
import '../services/explorer_annotation_service.dart';
import '../services/explorer_metadata_service.dart';
import '../services/explorer_navigation_service.dart';
import '../services/explorer_service.dart';
import '../services/explorer_sort_filter_service.dart';
import '../services/explorer_view_preferences_service.dart';
import '../services/project_catalog_service.dart';
import '../services/thumbnail_service.dart';

enum _ExplorerHistoryMove { none, back, forward }

enum _ExplorerSourceMode { directory, catalog }

enum _ProjectMenuAction { create, rename, delete }

enum _CatalogMenuAction { createChild, rename, delete }

enum _MediaMenuAction {
  favorite,
  assignCatalogs,
  createCatalog,
  removeFromCurrent,
}

class _CatalogDepthEntry {
  const _CatalogDepthEntry(this.catalog, this.depth);

  final MediaCatalog catalog;
  final int depth;
}

class ExplorerPage extends StatefulWidget {
  const ExplorerPage({
    super.key,
    required this.initialized,
    required this.version,
    required this.onOpenMedia,
    this.startupError,
    this.active = true,
  });

  final bool initialized;
  final String version;
  final String? startupError;
  final ValueChanged<String> onOpenMedia;
  final bool active;

  @override
  State<ExplorerPage> createState() => _ExplorerPageState();
}

class _ExplorerPageState extends State<ExplorerPage> {
  final ExplorerService _service = ExplorerService();
  final ExplorerSortFilterService _sortFilterService =
      ExplorerSortFilterService();
  final ExplorerMetadataService _metadataService = ExplorerMetadataService();
  final ExplorerAnnotationService _annotationService =
      ExplorerAnnotationService();
  final ExplorerNavigationService _navigationService =
      ExplorerNavigationService();
  final ExplorerViewPreferencesService _viewPreferencesService =
      ExplorerViewPreferencesService();
  final ProjectCatalogService _projectCatalogService = ProjectCatalogService();
  final ThumbnailService _thumbnailService = ThumbnailService();

  final FocusNode _focusNode = FocusNode(debugLabel: 'mlt-explorer');
  final FocusNode _filterFocusNode =
      FocusNode(debugLabel: 'mlt-explorer-filter');
  final TextEditingController _filterController = TextEditingController();

  _ExplorerSourceMode _sourceMode = _ExplorerSourceMode.directory;
  String? _directoryPath;
  String? _selectedCatalogId;
  final Set<String> _expandedCatalogIds = <String>{};

  List<ExplorerItem> _items = const <ExplorerItem>[];
  List<ExplorerItem> _visibleItems = const <ExplorerItem>[];
  String? _selectedPath;

  String _filterQuery = '';
  int _minimumRatingFilter = 0;
  String? _tagFilter;

  bool _loading = false;
  String? _error;
  int _scanSerial = 0;

  bool _navigationLoaded = false;
  bool _viewPreferencesLoaded = false;
  bool _annotationsLoaded = false;
  bool _projectCatalogsLoaded = false;

  ExplorerItem? get _selectedItem {
    final path = _selectedPath;
    if (path == null) {
      return null;
    }

    for (final item in _visibleItems) {
      if (item.path == path) {
        return item;
      }
    }
    return null;
  }

  bool get _hasSource {
    return switch (_sourceMode) {
      _ExplorerSourceMode.directory => _directoryPath != null,
      _ExplorerSourceMode.catalog => _selectedCatalogId != null,
    };
  }

  MediaCatalog? get _selectedCatalog {
    final catalogId = _selectedCatalogId;
    if (!_projectCatalogsLoaded || catalogId == null) {
      return null;
    }
    return _projectCatalogService.catalogById(catalogId);
  }

  String get _sourceLabel {
    if (_sourceMode == _ExplorerSourceMode.catalog) {
      final catalog = _selectedCatalog;
      if (catalog == null) {
        return 'Catalogs';
      }
      final breadcrumb = _projectCatalogService.catalogBreadcrumb(catalog.id);
      return breadcrumb.isEmpty ? 'Catalogs' : 'Catalogs / $breadcrumb';
    }
    return _directoryPath ?? 'No folder open';
  }

  bool get _hasAnnotationFilter =>
      _minimumRatingFilter > 0 || _tagFilter != null;

  bool get _hasAnyFilter =>
      _filterQuery.trim().isNotEmpty || _hasAnnotationFilter;

  List<String> get _availableTags {
    if (!_annotationsLoaded) {
      return const <String>[];
    }

    return _annotationService.tagsForPaths(
      _items.where((item) => !item.isDirectory).map((item) => item.path),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeNavigation());
    unawaited(_initializeViewPreferences());
    unawaited(_initializeAnnotations());
    unawaited(_initializeProjectCatalogs());
  }

  @override
  void didUpdateWidget(covariant ExplorerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _thumbnailService.resume();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    } else if (!widget.active && oldWidget.active) {
      unawaited(_thumbnailService.pauseAndDrain());
    }
  }

  @override
  void dispose() {
    _filterController.dispose();
    _filterFocusNode.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _initializeNavigation() async {
    try {
      await _navigationService.load();
    } catch (_) {
      // Saved locations are convenience state and must never block Explorer.
    }

    if (!mounted) {
      return;
    }

    final currentPath = _directoryPath;
    if (currentPath != null) {
      _navigationService.rememberRecent(currentPath);
      unawaited(_persistNavigation());
    }

    setState(() => _navigationLoaded = true);
  }

  Future<void> _initializeViewPreferences() async {
    try {
      await _viewPreferencesService.load();
    } catch (_) {
      // Density is convenience state and must never block Explorer startup.
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _viewPreferencesLoaded = true;
      _refreshVisibleItems();
    });
  }

  Future<void> _initializeAnnotations() async {
    try {
      await _annotationService.load();
    } catch (_) {
      // Existing ratings/tags remain untouched during the catalog foundation.
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _annotationsLoaded = true;
      _refreshVisibleItems();
    });
  }

  Future<void> _initializeProjectCatalogs() async {
    try {
      await _projectCatalogService.load();
    } catch (_) {
      // The service repairs or recreates its own default state when possible.
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _projectCatalogsLoaded = true;
    });
  }

  Future<void> _persistNavigation() async {
    try {
      await _navigationService.save();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save Explorer locations.')),
      );
    }
  }

  Future<void> _persistViewPreferences() async {
    try {
      await _viewPreferencesService.save();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save Explorer view preferences.'),
        ),
      );
    }
  }

  Future<void> _persistAnnotations() async {
    try {
      await _annotationService.save();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save Explorer ratings and tags.'),
        ),
      );
    }
  }

  Future<void> _persistProjectCatalogs() async {
    try {
      await _projectCatalogService.save();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save Projects and Catalogs.'),
        ),
      );
    }
  }

  void _refreshVisibleItems() {
    var visible = _sortFilterService.apply(
      _items,
      query: _filterQuery,
      sortMode: _viewPreferencesService.sortMode,
      descending: _viewPreferencesService.sortDescending,
    );

    if (_annotationsLoaded && _hasAnnotationFilter) {
      visible = visible.where((item) {
        if (item.isDirectory) {
          return false;
        }

        return _annotationService.matchesFilters(
          item.path,
          minimumRating: _minimumRatingFilter,
          tag: _tagFilter,
        );
      }).toList(growable: false);
    }

    _visibleItems = visible;
  }

  void _setAssetRating(ExplorerItem item, int rating) {
    if (item.isDirectory) {
      return;
    }

    setState(() {
      _annotationService.setRating(item.path, rating);
      _refreshVisibleItems();
    });
    unawaited(_persistAnnotations());
  }

  void _addAssetTag(ExplorerItem item, String tag) {
    if (item.isDirectory || tag.trim().isEmpty) {
      return;
    }

    setState(() {
      _annotationService.addTag(item.path, tag);
      _refreshVisibleItems();
    });
    unawaited(_persistAnnotations());
  }

  void _removeAssetTag(ExplorerItem item, String tag) {
    if (item.isDirectory) {
      return;
    }

    setState(() {
      _annotationService.removeTag(item.path, tag);
      _refreshVisibleItems();
    });
    unawaited(_persistAnnotations());
  }

  void _setThumbnailDensity(double value) {
    final index = value.round();
    if (index == _viewPreferencesService.densityIndex) {
      return;
    }

    setState(() => _viewPreferencesService.setDensityIndex(index));
    unawaited(_persistViewPreferences());
  }

  void _setSortMode(ExplorerSortMode mode) {
    if (mode == _viewPreferencesService.sortMode) {
      return;
    }

    setState(() {
      _viewPreferencesService.setSortMode(mode);
      _refreshVisibleItems();
    });
    unawaited(_persistViewPreferences());
  }

  void _toggleSortDirection() {
    setState(() {
      _viewPreferencesService.setSortDescending(
        !_viewPreferencesService.sortDescending,
      );
      _refreshVisibleItems();
    });
    unawaited(_persistViewPreferences());
  }

  void _setFilterQuery(String value) {
    setState(() {
      _filterQuery = value;
      _refreshVisibleItems();
    });
  }

  void _setMinimumRatingFilter(int value) {
    final normalized = value.clamp(0, 5).toInt();
    if (normalized == _minimumRatingFilter) {
      return;
    }

    setState(() {
      _minimumRatingFilter = normalized;
      _refreshVisibleItems();
    });
  }

  void _setTagFilter(String? value) {
    final normalized = value?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _tagFilter) {
      return;
    }

    setState(() {
      _tagFilter = next;
      _refreshVisibleItems();
    });
  }

  void _clearAllFilters({bool returnFocus = false}) {
    _filterController.clear();
    setState(() {
      _filterQuery = '';
      _minimumRatingFilter = 0;
      _tagFilter = null;
      _refreshVisibleItems();
    });
    if (returnFocus) {
      _focusNode.requestFocus();
    }
  }

  void _clearFilter({bool returnFocus = false}) {
    _filterController.clear();
    setState(() {
      _filterQuery = '';
      _refreshVisibleItems();
    });
    if (returnFocus) {
      _focusNode.requestFocus();
    }
  }

  void _focusFilter() {
    _filterFocusNode.requestFocus();
    _filterController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _filterController.text.length,
    );
  }

  Future<void> _openMediaInPlayer(String path) async {
    await _thumbnailService.pauseAndDrain();
    if (!mounted) {
      return;
    }
    widget.onOpenMedia(path);
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open Folder');
    if (path == null || path.isEmpty) {
      return;
    }
    await _loadDirectory(path);
  }

  Future<void> _pickMedia() async {
    final file = await openFile(
      confirmButtonText: 'Open',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Media',
          extensions: ExplorerService.supportedExtensions,
        ),
      ],
    );

    if (file != null) {
      await _openMediaInPlayer(file.path);
    }
  }

  Future<void> _loadDirectory(
    String path, {
    _ExplorerHistoryMove historyMove = _ExplorerHistoryMove.none,
  }) async {
    final serial = ++_scanSerial;
    setState(() {
      _loading = true;
      _error = null;
      _selectedPath = null;
    });

    try {
      final resolvedPath = Directory(path).absolute.path;
      final items = await _service.scanDirectory(resolvedPath);
      if (!mounted || serial != _scanSerial) {
        return;
      }

      switch (historyMove) {
        case _ExplorerHistoryMove.back:
          _navigationService.commitBack();
          break;
        case _ExplorerHistoryMove.forward:
          _navigationService.commitForward();
          break;
        case _ExplorerHistoryMove.none:
          _navigationService.recordVisit(resolvedPath);
          break;
      }

      setState(() {
        _sourceMode = _ExplorerSourceMode.directory;
        _directoryPath = resolvedPath;
        _selectedCatalogId = null;
        _items = items;
        _refreshVisibleItems();
        _loading = false;
      });

      unawaited(_persistNavigation());
    } on FileSystemException catch (error) {
      if (!mounted || serial != _scanSerial) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.isEmpty
            ? 'Could not read that directory.'
            : error.message;
      });
    } catch (error) {
      if (!mounted || serial != _scanSerial) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<ExplorerItem?> _catalogItemForPath(String path) async {
    final kind = _service.kindForPath(path);
    if (kind == null) {
      return null;
    }

    final file = File(path);
    FileStat? stat;

    try {
      if (await file.exists()) {
        stat = await file.stat();
      }
    } on FileSystemException {
      // Keep a missing/offline catalog member visible so it can be reassigned
      // or removed from the virtual organization.
    }

    return ExplorerItem.media(file, kind, stat: stat);
  }

  Future<void> _loadCatalog(String catalogId) async {
    if (!_projectCatalogsLoaded || _loading) {
      return;
    }

    final catalog = _projectCatalogService.catalogById(catalogId);
    if (catalog == null ||
        catalog.projectId != _projectCatalogService.activeProjectId) {
      return;
    }

    final serial = ++_scanSerial;
    setState(() {
      _loading = true;
      _error = null;
      _selectedPath = null;
    });

    try {
      final paths = _projectCatalogService.mediaPathsForCatalog(catalog.id);
      final resolved = await Future.wait(paths.map(_catalogItemForPath));
      if (!mounted || serial != _scanSerial) {
        return;
      }

      final items = resolved.whereType<ExplorerItem>().toList(growable: false);
      final catalogPath = _projectCatalogService.catalogPath(catalog.id);

      setState(() {
        _sourceMode = _ExplorerSourceMode.catalog;
        _selectedCatalogId = catalog.id;
        _expandedCatalogIds.addAll(catalogPath.map((entry) => entry.id));
        _items = items;
        _refreshVisibleItems();
        _loading = false;
      });
    } catch (error) {
      if (!mounted || serial != _scanSerial) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _reloadCurrentCatalog() async {
    final catalogId = _selectedCatalogId;
    if (_sourceMode != _ExplorerSourceMode.catalog || catalogId == null) {
      if (mounted) {
        setState(() {});
      }
      return;
    }

    await _loadCatalog(catalogId);
  }

  Future<void> _goBack() async {
    if (_sourceMode != _ExplorerSourceMode.directory) {
      return;
    }

    final path = _navigationService.backPath;
    if (path == null || _loading) {
      return;
    }
    await _loadDirectory(path, historyMove: _ExplorerHistoryMove.back);
  }

  Future<void> _goForward() async {
    if (_sourceMode != _ExplorerSourceMode.directory) {
      return;
    }

    final path = _navigationService.forwardPath;
    if (path == null || _loading) {
      return;
    }
    await _loadDirectory(path, historyMove: _ExplorerHistoryMove.forward);
  }

  Future<void> _goHome() async {
    if (_loading) {
      return;
    }
    await _loadDirectory(_navigationService.homePath);
  }

  Future<void> _goUp() async {
    if (_sourceMode == _ExplorerSourceMode.catalog) {
      final parentId = _selectedCatalog?.parentId;
      if (parentId != null) {
        await _loadCatalog(parentId);
      }
      return;
    }

    final path = _directoryPath;
    if (path == null) {
      return;
    }

    final current = Directory(path).absolute;
    final parent = current.parent;
    if (parent.path == current.path) {
      return;
    }
    await _loadDirectory(parent.path);
  }

  Future<void> _toggleFavoriteCurrentFolder() async {
    if (_sourceMode != _ExplorerSourceMode.directory) {
      return;
    }

    final path = _directoryPath;
    if (path == null) {
      return;
    }

    setState(() => _navigationService.toggleFavorite(path));
    await _persistNavigation();
  }

  Future<void> _activate(ExplorerItem item) async {
    if (item.isDirectory) {
      await _loadDirectory(item.path);
      return;
    }
    await _openMediaInPlayer(item.path);
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isNotEmpty) {
                Navigator.of(dialogContext).pop(trimmed);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) {
                  Navigator.of(dialogContext).pop(value);
                }
              },
              child: const Text('SAVE'),
            ),
          ],
        );
      },
    );

    controller.dispose();
    return result;
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    String confirmLabel = 'DELETE',
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('CANCEL'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(confirmLabel),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  void _showProjectCatalogError(Object error) {
    if (!mounted) {
      return;
    }

    late final String message;
    if (error is ArgumentError) {
      message = error.message?.toString() ?? error.toString();
    } else if (error is StateError) {
      message = error.message;
    } else {
      message = error.toString();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _switchProject(String projectId) async {
    if (!_projectCatalogsLoaded ||
        projectId == _projectCatalogService.activeProjectId) {
      return;
    }

    try {
      _projectCatalogService.setActiveProject(projectId);
      _expandedCatalogIds.clear();
      await _persistProjectCatalogs();

      if (!mounted) {
        return;
      }

      if (_sourceMode == _ExplorerSourceMode.catalog) {
        final favorites =
            _projectCatalogService.favoritesCatalogForProject(projectId);
        await _loadCatalog(favorites.id);
      } else {
        setState(() {
          _selectedCatalogId = null;
        });
      }
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _createProject() async {
    final name = await _promptText(
      title: 'New Project',
      hint: 'Project name',
    );
    if (name == null) {
      return;
    }

    try {
      final project = _projectCatalogService.createProject(name);
      _projectCatalogService.setActiveProject(project.id);
      _expandedCatalogIds.clear();
      await _persistProjectCatalogs();

      if (!mounted) {
        return;
      }

      final favorites =
          _projectCatalogService.favoritesCatalogForProject(project.id);
      await _loadCatalog(favorites.id);
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _renameActiveProject() async {
    if (!_projectCatalogsLoaded) {
      return;
    }

    final project = _projectCatalogService.activeProject;
    final name = await _promptText(
      title: 'Rename Project',
      hint: 'Project name',
      initialValue: project.name,
    );
    if (name == null) {
      return;
    }

    try {
      _projectCatalogService.renameProject(project.id, name);
      await _persistProjectCatalogs();
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _deleteActiveProject() async {
    if (!_projectCatalogsLoaded) {
      return;
    }

    if (_projectCatalogService.projects.length <= 1) {
      _showProjectCatalogError(
        StateError('MLT Player must keep at least one project.'),
      );
      return;
    }

    final project = _projectCatalogService.activeProject;
    final confirmed = await _confirm(
      title: 'Delete Project?',
      message:
          'Delete "${project.name}" and all of its Catalog memberships? '
          'Source files will not be moved or deleted.',
    );
    if (!confirmed) {
      return;
    }

    try {
      _projectCatalogService.deleteProject(project.id);
      _expandedCatalogIds.clear();
      await _persistProjectCatalogs();

      if (!mounted) {
        return;
      }

      if (_sourceMode == _ExplorerSourceMode.catalog) {
        final favorites =
            _projectCatalogService.favoritesCatalogForProject();
        await _loadCatalog(favorites.id);
      } else {
        setState(() {
          _selectedCatalogId = null;
        });
      }
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _handleProjectAction(_ProjectMenuAction action) async {
    switch (action) {
      case _ProjectMenuAction.create:
        await _createProject();
        break;
      case _ProjectMenuAction.rename:
        await _renameActiveProject();
        break;
      case _ProjectMenuAction.delete:
        await _deleteActiveProject();
        break;
    }
  }

  Future<MediaCatalog?> _createCatalog({
    String? parentId,
    String? mediaPath,
  }) async {
    if (!_projectCatalogsLoaded) {
      return null;
    }

    final name = await _promptText(
      title: parentId == null ? 'New Catalog' : 'New Catalog Inside',
      hint: 'Catalog name',
    );
    if (name == null) {
      return null;
    }

    try {
      final catalog = _projectCatalogService.createCatalog(
        name,
        parentId: parentId,
      );

      if (mediaPath != null) {
        _projectCatalogService.addMediaToCatalog(mediaPath, catalog.id);
      }

      if (parentId != null) {
        _expandedCatalogIds.add(parentId);
      }

      await _persistProjectCatalogs();
      if (mounted) {
        setState(() {});
      }
      return catalog;
    } catch (error) {
      _showProjectCatalogError(error);
      return null;
    }
  }

  Future<void> _renameCatalog(MediaCatalog catalog) async {
    if (catalog.isFavorites) {
      return;
    }

    final name = await _promptText(
      title: 'Rename Catalog',
      hint: 'Catalog name',
      initialValue: catalog.name,
    );
    if (name == null) {
      return;
    }

    try {
      _projectCatalogService.renameCatalog(catalog.id, name);
      await _persistProjectCatalogs();
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _deleteCatalog(MediaCatalog catalog) async {
    if (catalog.isFavorites) {
      return;
    }

    final selectedPath = _selectedCatalogId == null
        ? const <MediaCatalog>[]
        : _projectCatalogService.catalogPath(_selectedCatalogId!);
    final selectedAffected =
        selectedPath.any((entry) => entry.id == catalog.id);
    final parentId = catalog.parentId;

    final confirmed = await _confirm(
      title: 'Delete Catalog?',
      message:
          'Delete "${catalog.name}" and any Catalogs nested inside it? '
          'Source files will not be moved or deleted.',
    );
    if (!confirmed) {
      return;
    }

    try {
      _projectCatalogService.deleteCatalog(catalog.id);
      _expandedCatalogIds.remove(catalog.id);
      await _persistProjectCatalogs();

      if (!mounted) {
        return;
      }

      if (selectedAffected && _sourceMode == _ExplorerSourceMode.catalog) {
        if (parentId != null &&
            _projectCatalogService.catalogById(parentId) != null) {
          await _loadCatalog(parentId);
        } else {
          final favorites =
              _projectCatalogService.favoritesCatalogForProject();
          await _loadCatalog(favorites.id);
        }
      } else {
        setState(() {});
      }
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _handleCatalogAction(
    MediaCatalog catalog,
    _CatalogMenuAction action,
  ) async {
    switch (action) {
      case _CatalogMenuAction.createChild:
        await _createCatalog(parentId: catalog.id);
        break;
      case _CatalogMenuAction.rename:
        await _renameCatalog(catalog);
        break;
      case _CatalogMenuAction.delete:
        await _deleteCatalog(catalog);
        break;
    }
  }

  RelativeRect _menuPosition(Offset globalPosition) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(globalPosition);

    return RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    );
  }

  Future<void> _showCatalogContextMenu(
    MediaCatalog catalog,
    Offset position,
  ) async {
    if (catalog.isFavorites) {
      return;
    }

    final action = await showMenu<_CatalogMenuAction>(
      context: context,
      position: _menuPosition(position),
      items: const [
        PopupMenuItem(
          value: _CatalogMenuAction.createChild,
          child: Text('New Catalog Inside…'),
        ),
        PopupMenuItem(
          value: _CatalogMenuAction.rename,
          child: Text('Rename'),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: _CatalogMenuAction.delete,
          child: Text('Delete'),
        ),
      ],
    );

    if (action != null) {
      await _handleCatalogAction(catalog, action);
    }
  }

  List<MediaCatalog> _orderedCatalogs(Iterable<MediaCatalog> catalogs) {
    final values = catalogs.toList(growable: false);
    values.sort((a, b) {
      if (a.isFavorites != b.isFavorites) {
        return a.isFavorites ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return values;
  }

  List<_CatalogDepthEntry> _flattenCatalogs() {
    if (!_projectCatalogsLoaded) {
      return const <_CatalogDepthEntry>[];
    }

    final result = <_CatalogDepthEntry>[];

    void addBranch(MediaCatalog catalog, int depth) {
      result.add(_CatalogDepthEntry(catalog, depth));
      for (final child in _orderedCatalogs(
        _projectCatalogService.childrenOf(catalog.id),
      )) {
        addBranch(child, depth + 1);
      }
    }

    for (final root in _orderedCatalogs(
      _projectCatalogService.rootCatalogsForProject(),
    )) {
      addBranch(root, 0);
    }

    return result;
  }

  Future<void> _toggleMediaFavorite(ExplorerItem item) async {
    if (!_projectCatalogsLoaded || item.isDirectory) {
      return;
    }

    try {
      _projectCatalogService.toggleFavorite(item.path);
      await _persistProjectCatalogs();
      await _reloadCurrentCatalog();
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _assignMediaToCatalogs(ExplorerItem item) async {
    if (!_projectCatalogsLoaded || item.isDirectory) {
      return;
    }

    final projectId = _projectCatalogService.activeProjectId;
    final selected = _projectCatalogService
        .catalogIdsForMedia(item.path, projectId: projectId)
        .toSet();
    final flattened = _flattenCatalogs();

    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Assign to Catalogs'),
              content: SizedBox(
                width: 430,
                height: 420,
                child: flattened.isEmpty
                    ? const Center(child: Text('No Catalogs available.'))
                    : ListView.builder(
                        itemCount: flattened.length,
                        itemBuilder: (context, index) {
                          final entry = flattened[index];
                          final catalog = entry.catalog;
                          final checked = selected.contains(catalog.id);

                          return Padding(
                            padding: EdgeInsets.only(
                              left: entry.depth * 18.0,
                            ),
                            child: CheckboxListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              value: checked,
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              secondary: Icon(
                                catalog.isFavorites
                                    ? Icons.star
                                    : Icons.folder_outlined,
                                size: 18,
                                color: catalog.isFavorites
                                    ? const Color(0xFFE8A33D)
                                    : Colors.white38,
                              ),
                              title: Text(
                                catalog.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onChanged: (value) {
                                setDialogState(() {
                                  if (value ?? false) {
                                    selected.add(catalog.id);
                                  } else {
                                    selected.remove(catalog.id);
                                  }
                                });
                              },
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('CANCEL'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(selected),
                  child: const Text('SAVE'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) {
      return;
    }

    try {
      _projectCatalogService.setMediaCatalogs(
        item.path,
        result,
        projectId: projectId,
      );
      await _persistProjectCatalogs();
      await _reloadCurrentCatalog();
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _newCatalogForMedia(ExplorerItem item) async {
    if (item.isDirectory) {
      return;
    }
    await _createCatalog(mediaPath: item.path);
    await _reloadCurrentCatalog();
  }

  Future<void> _removeMediaFromCurrentCatalog(ExplorerItem item) async {
    final catalog = _selectedCatalog;
    if (catalog == null || item.isDirectory) {
      return;
    }

    try {
      _projectCatalogService.removeMediaFromCatalog(item.path, catalog.id);
      await _persistProjectCatalogs();
      await _reloadCurrentCatalog();
    } catch (error) {
      _showProjectCatalogError(error);
    }
  }

  Future<void> _showMediaContextMenu(
    ExplorerItem item,
    Offset position,
  ) async {
    if (!_projectCatalogsLoaded || item.isDirectory) {
      return;
    }

    final favorite = _projectCatalogService.isFavorite(item.path);
    final currentCatalog = _selectedCatalog;
    final canRemoveFromCurrent =
        _sourceMode == _ExplorerSourceMode.catalog &&
        currentCatalog != null &&
        !currentCatalog.isFavorites;

    final action = await showMenu<_MediaMenuAction>(
      context: context,
      position: _menuPosition(position),
      items: [
        PopupMenuItem(
          value: _MediaMenuAction.favorite,
          child: Text(
            favorite ? 'Remove from Favorites' : 'Add to Favorites',
          ),
        ),
        const PopupMenuItem(
          value: _MediaMenuAction.assignCatalogs,
          child: Text('Assign to Catalogs…'),
        ),
        const PopupMenuItem(
          value: _MediaMenuAction.createCatalog,
          child: Text('New Catalog for This Media…'),
        ),
        if (canRemoveFromCurrent) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _MediaMenuAction.removeFromCurrent,
            child: Text('Remove from "${currentCatalog.name}"'),
          ),
        ],
      ],
    );

    if (action == null) {
      return;
    }

    switch (action) {
      case _MediaMenuAction.favorite:
        await _toggleMediaFavorite(item);
        break;
      case _MediaMenuAction.assignCatalogs:
        await _assignMediaToCatalogs(item);
        break;
      case _MediaMenuAction.createCatalog:
        await _newCatalogForMedia(item);
        break;
      case _MediaMenuAction.removeFromCurrent:
        await _removeMediaFromCurrentCatalog(item);
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final control = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;

    if (event is KeyDownEvent &&
        control &&
        shift &&
        key == LogicalKeyboardKey.keyO) {
      unawaited(_pickFolder());
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        control &&
        key == LogicalKeyboardKey.keyO) {
      unawaited(_pickMedia());
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        control &&
        key == LogicalKeyboardKey.keyF) {
      _focusFilter();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        alt &&
        key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_goBack());
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        alt &&
        key == LogicalKeyboardKey.arrowRight) {
      unawaited(_goForward());
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        alt &&
        key == LogicalKeyboardKey.home) {
      unawaited(_goHome());
      return KeyEventResult.handled;
    }

    if (_filterFocusNode.hasFocus) {
      if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
        if (_filterQuery.isNotEmpty) {
          _clearFilter();
        } else {
          _focusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.enter) {
      final item = _selectedItem;
      if (item != null) {
        unawaited(_activate(item));
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.backspace && _hasSource) {
      unawaited(_goUp());
      return KeyEventResult.handled;
    }

    if (_visibleItems.isEmpty) {
      return KeyEventResult.ignored;
    }

    final selectedIndex = _selectedPath == null
        ? -1
        : _visibleItems.indexWhere((item) => item.path == _selectedPath);

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      final next =
          (selectedIndex + 1).clamp(0, _visibleItems.length - 1).toInt();
      setState(() => _selectedPath = _visibleItems[next].path);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      final start = selectedIndex < 0 ? 1 : selectedIndex;
      final next = (start - 1).clamp(0, _visibleItems.length - 1).toInt();
      setState(() => _selectedPath = _visibleItems[next].path);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.active,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: SafeArea(
          child: Column(
            children: [
              _buildToolbar(),
              if (_hasSource) _buildFilterSortBar(),
              const Divider(height: 1, color: Colors.white12),
              Expanded(child: _buildBody()),
              _buildStatusBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final directoryCanGoUp = _sourceMode == _ExplorerSourceMode.directory &&
        _directoryPath != null &&
        Directory(_directoryPath!).absolute.parent.path !=
            Directory(_directoryPath!).absolute.path;
    final catalogCanGoUp = _sourceMode == _ExplorerSourceMode.catalog &&
        _selectedCatalog?.parentId != null;
    final canGoUp = directoryCanGoUp || catalogCanGoUp;

    final currentFolderFavorite =
        _sourceMode == _ExplorerSourceMode.directory &&
            _directoryPath != null &&
            _navigationService.isFavorite(_directoryPath!);

    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.collections_outlined, size: 22),
            const SizedBox(width: 9),
            const Text(
              'MLT Explorer',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 12),
            if (_projectCatalogsLoaded) ...[
              SizedBox(
                width: 170,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _projectCatalogService.activeProjectId,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF252525),
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white70),
                    items: [
                      for (final project in _projectCatalogService.projects)
                        DropdownMenuItem<String>(
                          value: project.id,
                          child: Text(
                            project.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _loading
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(_switchProject(value));
                            }
                          },
                  ),
                ),
              ),
              PopupMenuButton<_ProjectMenuAction>(
                tooltip: 'Project options',
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (action) =>
                    unawaited(_handleProjectAction(action)),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _ProjectMenuAction.create,
                    child: Text('New Project…'),
                  ),
                  const PopupMenuItem(
                    value: _ProjectMenuAction.rename,
                    child: Text('Rename Project…'),
                  ),
                  PopupMenuItem(
                    value: _ProjectMenuAction.delete,
                    enabled: _projectCatalogService.projects.length > 1,
                    child: const Text('Delete Project…'),
                  ),
                ],
              ),
              const SizedBox(width: 4),
            ],
            IconButton(
              tooltip: 'Back (Alt+Left)',
              onPressed: _sourceMode == _ExplorerSourceMode.directory &&
                      _navigationService.canGoBack &&
                      !_loading
                  ? _goBack
                  : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: 'Forward (Alt+Right)',
              onPressed: _sourceMode == _ExplorerSourceMode.directory &&
                      _navigationService.canGoForward &&
                      !_loading
                  ? _goForward
                  : null,
              icon: const Icon(Icons.arrow_forward),
            ),
            IconButton(
              tooltip: _sourceMode == _ExplorerSourceMode.catalog
                  ? 'Parent Catalog (Backspace)'
                  : 'Up one folder (Backspace)',
              onPressed: canGoUp && !_loading ? _goUp : null,
              icon: const Icon(Icons.arrow_upward),
            ),
            IconButton(
              tooltip: 'Home (Alt+Home)',
              onPressed: _navigationLoaded && !_loading ? _goHome : null,
              icon: const Icon(Icons.home_outlined),
            ),
            IconButton(
              tooltip: currentFolderFavorite
                  ? 'Remove current folder from Favorite Folders'
                  : 'Add current folder to Favorite Folders',
              onPressed: _sourceMode == _ExplorerSourceMode.directory &&
                      _directoryPath != null &&
                      !_loading
                  ? _toggleFavoriteCurrentFolder
                  : null,
              icon: Icon(
                currentFolderFavorite ? Icons.star : Icons.star_border,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                height: 34,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: const Color(0x0FFFFFFF),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                child: Text(
                  _sourceLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: widget.initialized && !_loading ? _pickMedia : null,
              icon: const Icon(Icons.movie_outlined, size: 18),
              label: const Text('OPEN FILE'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: !_loading ? _pickFolder : null,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('OPEN FOLDER'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterSortBar() {
    final hasTextFilter = _filterQuery.trim().isNotEmpty;
    final hasAnyFilter = _hasAnyFilter;
    final availableTags = _availableTags;
    final tagChoices = <String>[
      if (_tagFilter != null) _tagFilter!,
      ...availableTags.where(
        (tag) =>
            _tagFilter == null ||
            tag.toLowerCase() != _tagFilter!.toLowerCase(),
      ),
    ];

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: const BoxDecoration(color: Color(0xFF151515)),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _filterController,
              focusNode: _filterFocusNode,
              onChanged: _setFilterQuery,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter current view (Ctrl+F)',
                hintStyle: const TextStyle(color: Colors.white30),
                prefixIcon: const Icon(Icons.search, size: 17),
                suffixIcon: hasTextFilter
                    ? IconButton(
                        tooltip: 'Clear filename filter',
                        onPressed: () => _clearFilter(),
                        icon: const Icon(Icons.close, size: 16),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                filled: true,
                fillColor: const Color(0x0FFFFFFF),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Colors.white12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Colors.white12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 108,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _minimumRatingFilter,
                isExpanded: true,
                dropdownColor: const Color(0xFF252525),
                style:
                    const TextStyle(fontSize: 11, color: Colors.white70),
                items: const <DropdownMenuItem<int>>[
                  DropdownMenuItem(value: 0, child: Text('Any rating')),
                  DropdownMenuItem(value: 1, child: Text('1★+')),
                  DropdownMenuItem(value: 2, child: Text('2★+')),
                  DropdownMenuItem(value: 3, child: Text('3★+')),
                  DropdownMenuItem(value: 4, child: Text('4★+')),
                  DropdownMenuItem(value: 5, child: Text('5★')),
                ],
                onChanged: !_annotationsLoaded || _loading
                    ? null
                    : (value) {
                        if (value != null) {
                          _setMinimumRatingFilter(value);
                        }
                      },
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _tagFilter ?? '',
                isExpanded: true,
                dropdownColor: const Color(0xFF252525),
                style:
                    const TextStyle(fontSize: 11, color: Colors.white70),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('Any tag'),
                  ),
                  for (final tag in tagChoices)
                    DropdownMenuItem<String>(
                      value: tag,
                      child: Text(
                        tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged:
                    !_annotationsLoaded || _loading ? null : _setTagFilter,
              ),
            ),
          ),
          if (hasAnyFilter) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: _loading ? null : () => _clearAllFilters(),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text(
                'CLEAR',
                style: TextStyle(fontSize: 9),
              ),
            ),
          ],
          const SizedBox(width: 10),
          const Text(
            'SORT',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: Colors.white38,
            ),
          ),
          const SizedBox(width: 7),
          DropdownButtonHideUnderline(
            child: DropdownButton<ExplorerSortMode>(
              value: _viewPreferencesService.sortMode,
              dropdownColor: const Color(0xFF252525),
              style:
                  const TextStyle(fontSize: 12, color: Colors.white70),
              items: ExplorerSortMode.values
                  .map(
                    (mode) => DropdownMenuItem<ExplorerSortMode>(
                      value: mode,
                      child: Text(mode.label),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _loading
                  ? null
                  : (mode) {
                      if (mode != null) {
                        _setSortMode(mode);
                      }
                    },
            ),
          ),
          IconButton(
            tooltip: _viewPreferencesService.sortDescending
                ? 'Descending — click for ascending'
                : 'Ascending — click for descending',
            onPressed: _loading ? null : _toggleSortDirection,
            icon: Icon(
              _viewPreferencesService.sortDescending
                  ? Icons.arrow_downward
                  : Icons.arrow_upward,
              size: 17,
            ),
          ),
          const Spacer(),
          Text(
            hasAnyFilter
                ? '${_visibleItems.length} of ${_items.length} shown'
                : '${_items.length} ${_items.length == 1 ? 'item' : 'items'}',
            style:
                const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!widget.initialized) {
      return _buildUnavailable();
    }

    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE57373)),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final selected = _selectedItem;
        final showLocations = constraints.maxWidth >= 1180;
        final showDetails = constraints.maxWidth >= 900;

        final mainContent = !_hasSource
            ? _buildWelcome()
            : _visibleItems.isEmpty
                ? _buildEmptyGridState()
                : GridView.builder(
                    padding: const EdgeInsets.all(14),
                    gridDelegate:
                        SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent:
                          _viewPreferencesService.thumbnailExtent,
                      mainAxisExtent: _viewPreferencesService.cardHeight,
                      crossAxisSpacing:
                          _viewPreferencesService.gridSpacing,
                      mainAxisSpacing:
                          _viewPreferencesService.gridSpacing,
                    ),
                    itemCount: _visibleItems.length,
                    itemBuilder: (context, index) {
                      final item = _visibleItems[index];
                      final favorite = _projectCatalogsLoaded &&
                          !item.isDirectory &&
                          _projectCatalogService.isFavorite(item.path);

                      return GestureDetector(
                        behavior: HitTestBehavior.deferToChild,
                        onSecondaryTapDown: item.isDirectory
                            ? null
                            : (details) => unawaited(
                                  _showMediaContextMenu(
                                    item,
                                    details.globalPosition,
                                  ),
                                ),
                        child: _ExplorerCard(
                          item: item,
                          thumbnailService: _thumbnailService,
                          active: widget.active,
                          selected: _selectedPath == item.path,
                          rating: _annotationsLoaded
                              ? _annotationService.ratingFor(item.path)
                              : 0,
                          favorite: favorite,
                          onTap: () {
                            _focusNode.requestFocus();
                            setState(() => _selectedPath = item.path);
                          },
                          onDoubleTap: () => unawaited(_activate(item)),
                        ),
                      );
                    },
                  );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showLocations) ...[
              SizedBox(
                width: 230,
                child: _buildSidebar(),
              ),
              const VerticalDivider(width: 1, color: Colors.white12),
            ],
            Expanded(child: mainContent),
            if (showDetails && _hasSource) ...[
              const VerticalDivider(width: 1, color: Colors.white12),
              SizedBox(
                width: 300,
                child: _ExplorerSelectionPane(
                  item: selected,
                  metadataService: _metadataService,
                  thumbnailService: _thumbnailService,
                  annotation: selected == null || !_annotationsLoaded
                      ? ExplorerAssetAnnotation.empty
                      : _annotationService.annotationFor(selected.path),
                  active: widget.active,
                  favorite: selected != null &&
                          !selected.isDirectory &&
                          _projectCatalogsLoaded
                      ? _projectCatalogService.isFavorite(selected.path)
                      : false,
                  onRatingChanged: selected == null ||
                          selected.isDirectory ||
                          !_annotationsLoaded
                      ? null
                      : (rating) => _setAssetRating(selected, rating),
                  onAddTag: selected == null ||
                          selected.isDirectory ||
                          !_annotationsLoaded
                      ? null
                      : (tag) => _addAssetTag(selected, tag),
                  onRemoveTag: selected == null ||
                          selected.isDirectory ||
                          !_annotationsLoaded
                      ? null
                      : (tag) => _removeAssetTag(selected, tag),
                  onToggleFavorite: selected == null ||
                          selected.isDirectory ||
                          !_projectCatalogsLoaded
                      ? null
                      : () => unawaited(_toggleMediaFavorite(selected)),
                  onAssignCatalogs: selected == null ||
                          selected.isDirectory ||
                          !_projectCatalogsLoaded
                      ? null
                      : () => unawaited(_assignMediaToCatalogs(selected)),
                  onOpen: selected == null
                      ? null
                      : () => unawaited(_activate(selected)),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildSidebar() {
    return ColoredBox(
      color: const Color(0xFF151515),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 18),
        children: [
          const _ExplorerLocationHeading('LOCATIONS'),
          const SizedBox(height: 6),
          _ExplorerLocationRow(
            icon: Icons.home_outlined,
            label: 'Home',
            path: _navigationService.homePath,
            selected: _sourceMode == _ExplorerSourceMode.directory &&
                _directoryPath == _navigationService.homePath,
            onTap: () => unawaited(_goHome()),
          ),
          const SizedBox(height: 18),
          const _ExplorerLocationHeading('FAVORITE FOLDERS'),
          const SizedBox(height: 6),
          if (_navigationService.favorites.isEmpty)
            const _ExplorerLocationEmpty('Star a folder to keep it here.')
          else
            for (final path in _navigationService.favorites)
              _ExplorerLocationRow(
                icon: Icons.star_outline,
                label: _locationLabel(path),
                path: path,
                selected: _sourceMode == _ExplorerSourceMode.directory &&
                    _directoryPath == path,
                onTap: () => unawaited(_loadDirectory(path)),
              ),
          const SizedBox(height: 18),
          const _ExplorerLocationHeading('RECENT'),
          const SizedBox(height: 6),
          if (_navigationService.recents.isEmpty)
            const _ExplorerLocationEmpty('Visited folders appear here.')
          else
            for (final path in _navigationService.recents)
              _ExplorerLocationRow(
                icon: Icons.history,
                label: _locationLabel(path),
                path: path,
                selected: _sourceMode == _ExplorerSourceMode.directory &&
                    _directoryPath == path,
                onTap: () => unawaited(_loadDirectory(path)),
              ),
          const SizedBox(height: 20),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: _ExplorerLocationHeading('CATALOGS'),
              ),
              IconButton(
                tooltip: 'New Catalog',
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: _projectCatalogsLoaded && !_loading
                    ? () => unawaited(_createCatalog())
                    : null,
                icon: const Icon(Icons.add, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 5),
          if (!_projectCatalogsLoaded)
            const _ExplorerLocationEmpty('Loading Projects…')
          else
            for (final catalog in _orderedCatalogs(
              _projectCatalogService.rootCatalogsForProject(),
            ))
              _buildCatalogTree(catalog, 0),
        ],
      ),
    );
  }

  Widget _buildCatalogTree(MediaCatalog catalog, int depth) {
    final children =
        _orderedCatalogs(_projectCatalogService.childrenOf(catalog.id));
    final hasChildren = children.isNotEmpty;
    final expanded = _expandedCatalogIds.contains(catalog.id);
    final selected = _sourceMode == _ExplorerSourceMode.catalog &&
        _selectedCatalogId == catalog.id;
    final count = _projectCatalogService.mediaCountForCatalog(catalog.id);

    final row = Material(
      color: selected ? const Color(0x22E8A33D) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => unawaited(_loadCatalog(catalog.id)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            4 + depth * 14.0,
            3,
            2,
            3,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                height: 28,
                child: hasChildren
                    ? IconButton(
                        tooltip: expanded ? 'Collapse' : 'Expand',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          setState(() {
                            if (expanded) {
                              _expandedCatalogIds.remove(catalog.id);
                            } else {
                              _expandedCatalogIds.add(catalog.id);
                            }
                          });
                        },
                        icon: Icon(
                          expanded
                              ? Icons.expand_more
                              : Icons.chevron_right,
                          size: 17,
                          color: Colors.white38,
                        ),
                      )
                    : null,
              ),
              Icon(
                catalog.isFavorites
                    ? Icons.star
                    : Icons.folder_outlined,
                size: 16,
                color: catalog.isFavorites
                    ? const Color(0xFFE8A33D)
                    : selected
                        ? const Color(0xFFE8A33D)
                        : Colors.white38,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  catalog.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        selected ? Colors.white70 : Colors.white54,
                  ),
                ),
              ),
              Text(
                '$count',
                style:
                    const TextStyle(fontSize: 9, color: Colors.white30),
              ),
              if (!catalog.isFavorites)
                PopupMenuButton<_CatalogMenuAction>(
                  tooltip: 'Catalog options',
                  padding: EdgeInsets.zero,
                  icon:
                      const Icon(Icons.more_horiz, size: 16),
                  onSelected: (action) =>
                      unawaited(_handleCatalogAction(catalog, action)),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _CatalogMenuAction.createChild,
                      child: Text('New Catalog Inside…'),
                    ),
                    PopupMenuItem(
                      value: _CatalogMenuAction.rename,
                      child: Text('Rename'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: _CatalogMenuAction.delete,
                      child: Text('Delete'),
                    ),
                  ],
                )
              else
                const SizedBox(width: 32),
            ],
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onSecondaryTapDown: catalog.isFavorites
              ? null
              : (details) => unawaited(
                    _showCatalogContextMenu(
                      catalog,
                      details.globalPosition,
                    ),
                  ),
          child: row,
        ),
        if (hasChildren && expanded)
          for (final child in children)
            _buildCatalogTree(child, depth + 1),
      ],
    );
  }

  static String _locationLabel(String path) {
    final name = ExplorerItem.basename(path);
    return name.isEmpty ? path : name;
  }

  Widget _buildEmptyGridState() {
    final filtered = _hasAnyFilter && _items.isNotEmpty;
    final catalogMode = _sourceMode == _ExplorerSourceMode.catalog;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            filtered
                ? Icons.search_off
                : catalogMode
                    ? Icons.folder_open_outlined
                    : Icons.video_library_outlined,
            size: 64,
            color: Colors.white24,
          ),
          const SizedBox(height: 14),
          Text(
            filtered
                ? 'No items match this filter'
                : catalogMode
                    ? 'This Catalog is empty'
                    : 'No supported media in this folder',
            style: const TextStyle(color: Colors.white54),
          ),
          if (catalogMode && !filtered) ...[
            const SizedBox(height: 8),
            const Text(
              'Right-click media in a folder to assign it here.',
              style: TextStyle(fontSize: 11, color: Colors.white30),
            ),
          ],
          if (filtered) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => _clearAllFilters(),
              child: const Text('Clear filters'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.collections_outlined,
            size: 76,
            color: Colors.white24,
          ),
          const SizedBox(height: 18),
          const Text(
            'MLT Explorer',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Open a folder, or choose a Catalog from the left.',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Folder'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _pickMedia,
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Open one media file instead'),
          ),
        ],
      ),
    );
  }

  Widget _buildUnavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 58,
              color: Color(0xFFE57373),
            ),
            const SizedBox(height: 16),
            const Text(
              'MLT is unavailable',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (widget.startupError != null &&
                widget.startupError!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                widget.startupError!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFE57373),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    final selected = _selectedItem;

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF171717),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Text(
            !_hasSource
                ? 'Ready'
                : _hasAnyFilter
                    ? '${_visibleItems.length} of ${_items.length} shown'
                    : '${_items.length} ${_items.length == 1 ? 'item' : 'items'}',
            style:
                const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          if (_sourceMode == _ExplorerSourceMode.catalog &&
              _projectCatalogsLoaded) ...[
            const SizedBox(width: 12),
            Text(
              _projectCatalogService.activeProject.name,
              style:
                  const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ],
          if (selected != null) ...[
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                selected.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ] else
            const Spacer(),
          if (_hasSource) ...[
            const SizedBox(width: 12),
            _ExplorerThumbnailSizeControl(
              value:
                  _viewPreferencesService.densityIndex.toDouble(),
              label: _viewPreferencesLoaded
                  ? _viewPreferencesService.densityLabel
                  : 'Standard',
              onChanged: _setThumbnailDensity,
            ),
            const SizedBox(width: 12),
          ],
          Text(
            'MLT ${widget.version}',
            style:
                const TextStyle(fontSize: 10, color: Colors.white30),
          ),
        ],
      ),
    );
  }
}

class _ExplorerThumbnailSizeControl extends StatelessWidget {
  const _ExplorerThumbnailSizeControl({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final double value;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Thumbnail size: $label',
      child: SizedBox(
        width: 190,
        child: Row(
          children: [
            const Icon(
              Icons.grid_view,
              size: 13,
              color: Colors.white38,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: value,
                  min: ExplorerViewPreferencesService.minDensityIndex
                      .toDouble(),
                  max: ExplorerViewPreferencesService.maxDensityIndex
                      .toDouble(),
                  divisions:
                      ExplorerViewPreferencesService.maxDensityIndex -
                          ExplorerViewPreferencesService.minDensityIndex,
                  label: label,
                  onChanged: onChanged,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.grid_view,
              size: 19,
              color: Colors.white54,
            ),
          ],
        ),
      ),
    );
  }
}

class _ExplorerLocationHeading extends StatelessWidget {
  const _ExplorerLocationHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.05,
          color: Colors.white38,
        ),
      ),
    );
  }
}

class _ExplorerLocationEmpty extends StatelessWidget {
  const _ExplorerLocationEmpty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10, color: Colors.white30),
      ),
    );
  }
}

class _ExplorerLocationRow extends StatelessWidget {
  const _ExplorerLocationRow({
    required this.icon,
    required this.label,
    required this.path,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String path;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: path,
      child: Material(
        color:
            selected ? const Color(0x22E8A33D) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected
                      ? const Color(0xFFE8A33D)
                      : Colors.white38,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          selected ? Colors.white70 : Colors.white54,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExplorerCard extends StatelessWidget {
  const _ExplorerCard({
    required this.item,
    required this.thumbnailService,
    required this.active,
    required this.selected,
    required this.rating,
    required this.favorite,
    required this.onTap,
    required this.onDoubleTap,
  });

  final ExplorerItem item;
  final ThumbnailService thumbnailService;
  final bool active;
  final bool selected;
  final int rating;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      ExplorerItemKind.directory => Icons.folder,
      ExplorerItemKind.video => Icons.movie_outlined,
      ExplorerItemKind.audio => Icons.graphic_eq,
      ExplorerItemKind.image => Icons.image_outlined,
      ExplorerItemKind.project => Icons.account_tree_outlined,
    };

    return Material(
      color: selected
          ? const Color(0x33E8A33D)
          : const Color(0xFF1B1B1B),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0xFFE8A33D)
                  : Colors.white10,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ExplorerThumbnail(
                      item: item,
                      thumbnailService: thumbnailService,
                      fallbackIcon: icon,
                      active: active,
                    ),
                    if (favorite && !item.isDirectory)
                      const Positioned(
                        top: 7,
                        left: 7,
                        child: Icon(
                          Icons.star,
                          size: 16,
                          color: Color(0xFFE8A33D),
                          shadows: [
                            Shadow(
                              blurRadius: 4,
                              color: Colors.black87,
                            ),
                          ],
                        ),
                      ),
                    if (!item.isDirectory && rating > 0)
                      Positioned(
                        top: 7,
                        right: 7,
                        child: _ExplorerRatingBadge(rating: rating),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 8, 9, 3),
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
                child: Text(
                  item.isDirectory
                      ? 'Folder'
                      : item.extension.toUpperCase(),
                  style:
                      const TextStyle(fontSize: 9, color: Colors.white30),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExplorerRatingBadge extends StatelessWidget {
  const _ExplorerRatingBadge({required this.rating});

  final int rating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC111111),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.star,
            size: 11,
            color: Color(0xFFE8A33D),
          ),
          const SizedBox(width: 3),
          Text(
            '$rating',
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExplorerSelectionPane extends StatefulWidget {
  const _ExplorerSelectionPane({
    required this.item,
    required this.metadataService,
    required this.thumbnailService,
    required this.annotation,
    required this.active,
    required this.favorite,
    required this.onRatingChanged,
    required this.onAddTag,
    required this.onRemoveTag,
    required this.onToggleFavorite,
    required this.onAssignCatalogs,
    required this.onOpen,
  });

  final ExplorerItem? item;
  final ExplorerMetadataService metadataService;
  final ThumbnailService thumbnailService;
  final ExplorerAssetAnnotation annotation;
  final bool active;
  final bool favorite;
  final ValueChanged<int>? onRatingChanged;
  final ValueChanged<String>? onAddTag;
  final ValueChanged<String>? onRemoveTag;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onAssignCatalogs;
  final VoidCallback? onOpen;

  @override
  State<_ExplorerSelectionPane> createState() =>
      _ExplorerSelectionPaneState();
}

class _ExplorerSelectionPaneState
    extends State<_ExplorerSelectionPane> {
  final TextEditingController _tagController =
      TextEditingController();
  Future<ExplorerMetadata>? _metadataFuture;

  @override
  void initState() {
    super.initState();
    _requestMetadata();
  }

  @override
  void didUpdateWidget(
    covariant _ExplorerSelectionPane oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.item?.path != widget.item?.path ||
        !identical(
          oldWidget.metadataService,
          widget.metadataService,
        )) {
      _tagController.clear();
      _requestMetadata();
    }
  }

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  void _requestMetadata() {
    final item = widget.item;
    _metadataFuture = item == null
        ? null
        : widget.metadataService.metadataFor(item);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Select a file or folder',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ),
      );
    }

    final icon = switch (item.kind) {
      ExplorerItemKind.directory => Icons.folder,
      ExplorerItemKind.video => Icons.movie_outlined,
      ExplorerItemKind.audio => Icons.graphic_eq,
      ExplorerItemKind.image => Icons.image_outlined,
      ExplorerItemKind.project => Icons.account_tree_outlined,
    };

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'SELECTION',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 18),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _ExplorerThumbnail(
                item: item,
                thumbnailService: widget.thumbnailService,
                fallbackIcon: icon,
                active: widget.active,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            item.name,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            item.path,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          const SizedBox(height: 18),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 14),
          const Text(
            'INFO',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FutureBuilder<ExplorerMetadata>(
                    future: _metadataFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
                          ),
                        );
                      }

                      if (snapshot.hasError || !snapshot.hasData) {
                        return const Padding(
                          padding:
                              EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            'Metadata unavailable',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        );
                      }

                      return _ExplorerMetadataTable(
                        item: item,
                        metadata: snapshot.data!,
                      );
                    },
                  ),
                  if (!item.isDirectory) ...[
                    const SizedBox(height: 16),
                    const Divider(
                      height: 1,
                      color: Colors.white12,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'ANNOTATIONS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: Colors.white38,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ExplorerAnnotationEditor(
                      annotation: widget.annotation,
                      tagController: _tagController,
                      onRatingChanged:
                          widget.onRatingChanged,
                      onAddTag: widget.onAddTag,
                      onRemoveTag: widget.onRemoveTag,
                    ),
                    const SizedBox(height: 14),
                    const Divider(
                      height: 1,
                      color: Colors.white12,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: widget.onToggleFavorite,
                      icon: Icon(
                        widget.favorite
                            ? Icons.star
                            : Icons.star_border,
                        size: 17,
                      ),
                      label: Text(
                        widget.favorite
                            ? 'REMOVE FAVORITE'
                            : 'ADD FAVORITE',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: widget.onAssignCatalogs,
                      icon: const Icon(
                        Icons.folder_copy_outlined,
                        size: 17,
                      ),
                      label: const Text('ASSIGN CATALOGS'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: widget.onOpen,
            icon: Icon(
              item.isDirectory
                  ? Icons.folder_open
                  : Icons.play_arrow,
            ),
            label: Text(
              item.isDirectory
                  ? 'OPEN FOLDER'
                  : 'OPEN IN PLAYER',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Double-click an item to open it.',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 10, color: Colors.white30),
          ),
        ],
      ),
    );
  }
}

class _ExplorerAnnotationEditor extends StatelessWidget {
  const _ExplorerAnnotationEditor({
    required this.annotation,
    required this.tagController,
    required this.onRatingChanged,
    required this.onAddTag,
    required this.onRemoveTag,
  });

  final ExplorerAssetAnnotation annotation;
  final TextEditingController tagController;
  final ValueChanged<int>? onRatingChanged;
  final ValueChanged<String>? onAddTag;
  final ValueChanged<String>? onRemoveTag;

  void _submitTag() {
    final tag = tagController.text.trim();
    if (tag.isEmpty || onAddTag == null) {
      return;
    }

    onAddTag!(tag);
    tagController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 58,
              child: Text(
                'Rating',
                style:
                    TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
            Expanded(
              child: _ExplorerStarRating(
                rating: annotation.rating,
                onChanged: onRatingChanged,
              ),
            ),
            TextButton(
              onPressed:
                  annotation.rating > 0 && onRatingChanged != null
                      ? () => onRatingChanged!(0)
                      : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
              ),
              child: const Text(
                'Clear',
                style: TextStyle(fontSize: 9),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Tags',
          style: TextStyle(fontSize: 10, color: Colors.white38),
        ),
        const SizedBox(height: 7),
        if (annotation.tags.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in annotation.tags)
                InputChip(
                  label: Text(
                    tag,
                    style: const TextStyle(fontSize: 10),
                  ),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                  onDeleted: onRemoveTag == null
                      ? null
                      : () => onRemoveTag!(tag),
                ),
            ],
          )
        else
          const Text(
            'No tags',
            style:
                TextStyle(fontSize: 10, color: Colors.white30),
          ),
        const SizedBox(height: 9),
        TextField(
          controller: tagController,
          enabled: onAddTag != null,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitTag(),
          style: const TextStyle(fontSize: 11),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Add tag',
            hintStyle:
                const TextStyle(fontSize: 10, color: Colors.white30),
            contentPadding:
                const EdgeInsets.fromLTRB(10, 9, 4, 9),
            border: const OutlineInputBorder(),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 34,
              minHeight: 34,
            ),
            suffixIcon: IconButton(
              tooltip: 'Add tag',
              onPressed: onAddTag == null ? null : _submitTag,
              icon: const Icon(Icons.add, size: 16),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }
}

class _ExplorerStarRating extends StatelessWidget {
  const _ExplorerStarRating({
    required this.rating,
    required this.onChanged,
  });

  final int rating;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var value = 1; value <= 5; value++)
          Tooltip(
            message: '$value ${value == 1 ? 'star' : 'stars'}',
            child: InkResponse(
              radius: 16,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(value),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  value <= rating
                      ? Icons.star
                      : Icons.star_border,
                  size: 20,
                  color: value <= rating
                      ? const Color(0xFFE8A33D)
                      : Colors.white30,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ExplorerMetadataTable extends StatelessWidget {
  const _ExplorerMetadataTable({
    required this.item,
    required this.metadata,
  });

  final ExplorerItem item;
  final ExplorerMetadata metadata;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[
      MapEntry('Type', _kindLabel(item.kind)),
    ];

    if (!item.isDirectory && item.extension.isNotEmpty) {
      rows.add(
        MapEntry('Format', item.extension.toUpperCase()),
      );
    }

    final byteSize = metadata.byteSize;
    if (byteSize != null) {
      rows.add(MapEntry('Size', _formatBytes(byteSize)));
    }

    if (metadata.hasDimensions) {
      rows.add(
        MapEntry(
          'Dimensions',
          '${metadata.pixelWidth} × ${metadata.pixelHeight}',
        ),
      );
    }

    rows.add(
      MapEntry('Modified', _formatModified(metadata.modified)),
    );

    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 78,
                  child: Text(
                    row.key,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white38,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    row.value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _kindLabel(ExplorerItemKind kind) {
    return switch (kind) {
      ExplorerItemKind.directory => 'Folder',
      ExplorerItemKind.video => 'Video',
      ExplorerItemKind.audio => 'Audio',
      ExplorerItemKind.image => 'Image',
      ExplorerItemKind.project => 'MLT Project',
    };
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024.0;
    var unitIndex = 0;

    while (value >= 1024.0 && unitIndex < units.length - 1) {
      value /= 1024.0;
      unitIndex += 1;
    }

    final digits = value >= 100 ? 0 : value >= 10 ? 1 : 2;
    return '${value.toStringAsFixed(digits)} ${units[unitIndex]}';
  }

  static String _formatModified(DateTime value) {
    final local = value.toLocal();

    String two(int number) =>
        number.toString().padLeft(2, '0');

    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _ExplorerThumbnail extends StatefulWidget {
  const _ExplorerThumbnail({
    required this.item,
    required this.thumbnailService,
    required this.fallbackIcon,
    required this.active,
  });

  final ExplorerItem item;
  final ThumbnailService thumbnailService;
  final IconData fallbackIcon;
  final bool active;

  @override
  State<_ExplorerThumbnail> createState() =>
      _ExplorerThumbnailState();
}

class _ExplorerThumbnailState
    extends State<_ExplorerThumbnail> {
  Future<String?>? _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _requestThumbnail();
  }

  @override
  void didUpdateWidget(
    covariant _ExplorerThumbnail oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path ||
        oldWidget.item.kind != widget.item.kind ||
        !identical(
          oldWidget.thumbnailService,
          widget.thumbnailService,
        ) ||
        oldWidget.active != widget.active) {
      _requestThumbnail();
    }
  }

  void _requestThumbnail() {
    if (!widget.active) {
      _thumbnailFuture = null;
      return;
    }

    _thumbnailFuture =
        widget.thumbnailService.supports(widget.item)
            ? widget.thumbnailService.thumbnailFor(widget.item)
            : null;
  }

  @override
  Widget build(BuildContext context) {
    final future = _thumbnailFuture;
    if (future == null) {
      return _buildFallback(loading: false);
    }

    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path != null && path.isNotEmpty) {
          return Image.file(
            File(path),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              return _buildFallback(loading: false);
            },
          );
        }

        return _buildFallback(
          loading:
              snapshot.connectionState ==
                  ConnectionState.waiting,
        );
      },
    );
  }

  Widget _buildFallback({required bool loading}) {
    return ColoredBox(
      color: Colors.black26,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Icon(
              widget.fallbackIcon,
              size: 52,
              color: Colors.white30,
            ),
          ),
          if (loading)
            const Positioned(
              right: 8,
              bottom: 8,
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white38,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
