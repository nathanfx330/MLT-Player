// lib/ui/explorer_page.dart

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/explorer_asset_annotation.dart';
import '../models/explorer_item.dart';
import '../models/explorer_metadata.dart';
import '../services/explorer_annotation_service.dart';
import '../services/explorer_metadata_service.dart';
import '../services/explorer_navigation_service.dart';
import '../services/explorer_service.dart';
import '../services/explorer_sort_filter_service.dart';
import '../services/explorer_view_preferences_service.dart';
import '../services/thumbnail_service.dart';

enum _ExplorerHistoryMove { none, back, forward }

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
  final ExplorerNavigationService _navigationService = ExplorerNavigationService();
  final ExplorerViewPreferencesService _viewPreferencesService =
      ExplorerViewPreferencesService();
  final ThumbnailService _thumbnailService = ThumbnailService();
  final FocusNode _focusNode = FocusNode(debugLabel: 'mlt-explorer');
  final FocusNode _filterFocusNode =
      FocusNode(debugLabel: 'mlt-explorer-filter');
  final TextEditingController _filterController = TextEditingController();

  String? _directoryPath;
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

  @override
  void initState() {
    super.initState();
    unawaited(_initializeNavigation());
    unawaited(_initializeViewPreferences());
    unawaited(_initializeAnnotations());
  }

  Future<void> _initializeNavigation() async {
    try {
      await _navigationService.load();
    } catch (_) {
      // Saved locations are convenience state and must never block Explorer.
    }

    if (mounted) {
      final currentPath = _directoryPath;
      if (currentPath != null) {
        _navigationService.rememberRecent(currentPath);
        unawaited(_persistNavigation());
      }
      setState(() => _navigationLoaded = true);
    }
  }

  Future<void> _initializeViewPreferences() async {
    try {
      await _viewPreferencesService.load();
    } catch (_) {
      // Density is convenience state and must never block Explorer startup.
    }

    if (mounted) {
      setState(() {
        _viewPreferencesLoaded = true;
        _refreshVisibleItems();
      });
    }
  }

  Future<void> _initializeAnnotations() async {
    try {
      await _annotationService.load();
    } catch (_) {
      // Ratings and tags are convenience catalog data and must not block Explorer.
    }

    if (mounted) {
      setState(() {
        _annotationsLoaded = true;
        _refreshVisibleItems();
      });
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
        const SnackBar(content: Text('Could not save Explorer view preferences.')),
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
        const SnackBar(content: Text('Could not save Explorer ratings and tags.')),
      );
    }
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
      // _openMediaInPlayer normally drains before the shell switches views.
      // This is a defensive guard for any future shell-driven transition.
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
        _directoryPath = resolvedPath;
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

  Future<void> _goBack() async {
    final path = _navigationService.backPath;
    if (path == null || _loading) {
      return;
    }
    await _loadDirectory(path, historyMove: _ExplorerHistoryMove.back);
  }

  Future<void> _goForward() async {
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

  Future<void> _toggleFavoriteCurrent() async {
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

    if (key == LogicalKeyboardKey.backspace && _directoryPath != null) {
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
      final next = (selectedIndex + 1)
          .clamp(0, _visibleItems.length - 1)
          .toInt();
      setState(() => _selectedPath = _visibleItems[next].path);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      final start = selectedIndex < 0 ? 1 : selectedIndex;
      final next = (start - 1)
          .clamp(0, _visibleItems.length - 1)
          .toInt();
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
              if (_directoryPath != null) _buildFilterSortBar(),
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
    final canGoUp = _directoryPath != null &&
        Directory(_directoryPath!).absolute.parent.path !=
            Directory(_directoryPath!).absolute.path;

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
            IconButton(
              tooltip: 'Back (Alt+Left)',
              onPressed: _navigationService.canGoBack && !_loading
                  ? _goBack
                  : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: 'Forward (Alt+Right)',
              onPressed: _navigationService.canGoForward && !_loading
                  ? _goForward
                  : null,
              icon: const Icon(Icons.arrow_forward),
            ),
            IconButton(
              tooltip: 'Up one folder (Backspace)',
              onPressed: canGoUp && !_loading ? _goUp : null,
              icon: const Icon(Icons.arrow_upward),
            ),
            IconButton(
              tooltip: 'Home (Alt+Home)',
              onPressed: _navigationLoaded && !_loading ? _goHome : null,
              icon: const Icon(Icons.home_outlined),
            ),
            IconButton(
              tooltip: _directoryPath != null &&
                      _navigationService.isFavorite(_directoryPath!)
                  ? 'Remove current folder from Favorites'
                  : 'Add current folder to Favorites',
              onPressed: _directoryPath != null && !_loading
                  ? _toggleFavoriteCurrent
                  : null,
              icon: Icon(
                _directoryPath != null &&
                        _navigationService.isFavorite(_directoryPath!)
                    ? Icons.star
                    : Icons.star_border,
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
                  _directoryPath ?? 'No folder open',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
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
        (tag) => _tagFilter == null ||
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
                hintText: 'Filter current folder (Ctrl+F)',
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
                style: const TextStyle(fontSize: 11, color: Colors.white70),
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
                style: const TextStyle(fontSize: 11, color: Colors.white70),
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
                onChanged: !_annotationsLoaded || _loading
                    ? null
                    : _setTagFilter,
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
              style: const TextStyle(fontSize: 12, color: Colors.white70),
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
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!widget.initialized) {
      return _buildUnavailable();
    }

    if (_directoryPath == null) {
      return _buildWelcome();
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

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showLocations) ...[
              SizedBox(
                width: 210,
                child: _ExplorerLocationsPane(
                  homePath: _navigationService.homePath,
                  currentPath: _directoryPath,
                  favorites: _navigationService.favorites,
                  recents: _navigationService.recents,
                  onOpenPath: (path) => unawaited(_loadDirectory(path)),
                ),
              ),
              const VerticalDivider(width: 1, color: Colors.white12),
            ],
            Expanded(
              child: _visibleItems.isEmpty
                  ? _buildEmptyGridState()
                  : GridView.builder(
                      padding: const EdgeInsets.all(14),
                      gridDelegate:
                          SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent:
                            _viewPreferencesService.thumbnailExtent,
                        mainAxisExtent: _viewPreferencesService.cardHeight,
                        crossAxisSpacing: _viewPreferencesService.gridSpacing,
                        mainAxisSpacing: _viewPreferencesService.gridSpacing,
                      ),
                      itemCount: _visibleItems.length,
                      itemBuilder: (context, index) {
                        final item = _visibleItems[index];
                        return _ExplorerCard(
                          item: item,
                          thumbnailService: _thumbnailService,
                          active: widget.active,
                          selected: _selectedPath == item.path,
                          rating: _annotationsLoaded
                              ? _annotationService.ratingFor(item.path)
                              : 0,
                          onTap: () {
                            _focusNode.requestFocus();
                            setState(() => _selectedPath = item.path);
                          },
                          onDoubleTap: () => unawaited(_activate(item)),
                        );
                      },
                    ),
            ),
            if (showDetails) ...[
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
                  onRatingChanged:
                      selected == null || selected.isDirectory || !_annotationsLoaded
                          ? null
                          : (rating) => _setAssetRating(selected, rating),
                  onAddTag:
                      selected == null || selected.isDirectory || !_annotationsLoaded
                          ? null
                          : (tag) => _addAssetTag(selected, tag),
                  onRemoveTag:
                      selected == null || selected.isDirectory || !_annotationsLoaded
                          ? null
                          : (tag) => _removeAssetTag(selected, tag),
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

  Widget _buildEmptyGridState() {
    final filtered = _hasAnyFilter && _items.isNotEmpty;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            filtered ? Icons.search_off : Icons.video_library_outlined,
            size: 64,
            color: Colors.white24,
          ),
          const SizedBox(height: 14),
          Text(
            filtered
                ? 'No items match this filter'
                : 'No supported media in this folder',
            style: const TextStyle(color: Colors.white54),
          ),
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
          const Icon(Icons.collections_outlined, size: 76, color: Colors.white24),
          const SizedBox(height: 18),
          const Text(
            'MLT Explorer',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Open a folder to browse media.',
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
            const Icon(Icons.error_outline, size: 58, color: Color(0xFFE57373)),
            const SizedBox(height: 16),
            const Text(
              'MLT is unavailable',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (widget.startupError != null && widget.startupError!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                widget.startupError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFE57373)),
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
            _directoryPath == null
                ? 'Ready'
                : _hasAnyFilter
                    ? '${_visibleItems.length} of ${_items.length} shown'
                    : '${_items.length} ${_items.length == 1 ? 'item' : 'items'}',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          if (selected != null) ...[
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                selected.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ] else
            const Spacer(),
          if (_directoryPath != null) ...[
            const SizedBox(width: 12),
            _ExplorerThumbnailSizeControl(
              value: _viewPreferencesService.densityIndex.toDouble(),
              label: _viewPreferencesLoaded
                  ? _viewPreferencesService.densityLabel
                  : 'Standard',
              onChanged: _setThumbnailDensity,
            ),
            const SizedBox(width: 12),
          ],
          Text(
            'MLT ${widget.version}',
            style: const TextStyle(fontSize: 10, color: Colors.white30),
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
            const Icon(Icons.grid_view, size: 13, color: Colors.white38),
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
                  min: ExplorerViewPreferencesService.minDensityIndex.toDouble(),
                  max: ExplorerViewPreferencesService.maxDensityIndex.toDouble(),
                  divisions: ExplorerViewPreferencesService.maxDensityIndex -
                      ExplorerViewPreferencesService.minDensityIndex,
                  label: label,
                  onChanged: onChanged,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.grid_view, size: 19, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}


class _ExplorerLocationsPane extends StatelessWidget {
  const _ExplorerLocationsPane({
    required this.homePath,
    required this.currentPath,
    required this.favorites,
    required this.recents,
    required this.onOpenPath,
  });

  final String homePath;
  final String? currentPath;
  final List<String> favorites;
  final List<String> recents;
  final ValueChanged<String> onOpenPath;

  @override
  Widget build(BuildContext context) {
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
            path: homePath,
            selected: currentPath == homePath,
            onTap: () => onOpenPath(homePath),
          ),
          const SizedBox(height: 18),
          const _ExplorerLocationHeading('FAVORITES'),
          const SizedBox(height: 6),
          if (favorites.isEmpty)
            const _ExplorerLocationEmpty('Star a folder to keep it here.')
          else
            for (final path in favorites)
              _ExplorerLocationRow(
                icon: Icons.star_outline,
                label: _locationLabel(path),
                path: path,
                selected: currentPath == path,
                onTap: () => onOpenPath(path),
              ),
          const SizedBox(height: 18),
          const _ExplorerLocationHeading('RECENT'),
          const SizedBox(height: 6),
          if (recents.isEmpty)
            const _ExplorerLocationEmpty('Visited folders appear here.')
          else
            for (final path in recents)
              _ExplorerLocationRow(
                icon: Icons.history,
                label: _locationLabel(path),
                path: path,
                selected: currentPath == path,
                onTap: () => onOpenPath(path),
              ),
        ],
      ),
    );
  }

  static String _locationLabel(String path) {
    final name = ExplorerItem.basename(path);
    return name.isEmpty ? path : name;
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
        color: selected ? const Color(0x22E8A33D) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? const Color(0xFFE8A33D) : Colors.white38,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: selected ? Colors.white70 : Colors.white54,
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
    required this.onTap,
    required this.onDoubleTap,
  });

  final ExplorerItem item;
  final ThumbnailService thumbnailService;
  final bool active;
  final bool selected;
  final int rating;
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
              color: selected ? const Color(0xFFE8A33D) : Colors.white10,
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
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
                child: Text(
                  item.isDirectory
                      ? 'Folder'
                      : item.extension.toUpperCase(),
                  style: const TextStyle(fontSize: 9, color: Colors.white30),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
    required this.onRatingChanged,
    required this.onAddTag,
    required this.onRemoveTag,
    required this.onOpen,
  });

  final ExplorerItem? item;
  final ExplorerMetadataService metadataService;
  final ThumbnailService thumbnailService;
  final ExplorerAssetAnnotation annotation;
  final bool active;
  final ValueChanged<int>? onRatingChanged;
  final ValueChanged<String>? onAddTag;
  final ValueChanged<String>? onRemoveTag;
  final VoidCallback? onOpen;

  @override
  State<_ExplorerSelectionPane> createState() => _ExplorerSelectionPaneState();
}

class _ExplorerSelectionPaneState extends State<_ExplorerSelectionPane> {
  final TextEditingController _tagController = TextEditingController();
  Future<ExplorerMetadata>? _metadataFuture;

  @override
  void initState() {
    super.initState();
    _requestMetadata();
  }

  @override
  void didUpdateWidget(covariant _ExplorerSelectionPane oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.item?.path != widget.item?.path ||
        !identical(oldWidget.metadataService, widget.metadataService)) {
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
            style: TextStyle(fontSize: 12, color: Colors.white38),
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
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          Text(
            item.path,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
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
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 1.5),
                            ),
                          ),
                        );
                      }

                      if (snapshot.hasError || !snapshot.hasData) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            'Metadata unavailable',
                            style: TextStyle(fontSize: 11, color: Colors.white38),
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
                    const Divider(height: 1, color: Colors.white12),
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
                      onRatingChanged: widget.onRatingChanged,
                      onAddTag: widget.onAddTag,
                      onRemoveTag: widget.onRemoveTag,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: widget.onOpen,
            icon: Icon(item.isDirectory ? Icons.folder_open : Icons.play_arrow),
            label: Text(item.isDirectory ? 'OPEN FOLDER' : 'OPEN IN PLAYER'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Double-click an item to open it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: Colors.white30),
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
                style: TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
            Expanded(
              child: _ExplorerStarRating(
                rating: annotation.rating,
                onChanged: onRatingChanged,
              ),
            ),
            TextButton(
              onPressed: annotation.rating > 0 && onRatingChanged != null
                  ? () => onRatingChanged!(0)
                  : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
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
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onDeleted: onRemoveTag == null
                      ? null
                      : () => onRemoveTag!(tag),
                ),
            ],
          )
        else
          const Text(
            'No tags',
            style: TextStyle(fontSize: 10, color: Colors.white30),
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
            hintStyle: const TextStyle(fontSize: 10, color: Colors.white30),
            contentPadding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
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
              onTap: onChanged == null ? null : () => onChanged!(value),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  value <= rating ? Icons.star : Icons.star_border,
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
      rows.add(MapEntry('Format', item.extension.toUpperCase()));
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

    rows.add(MapEntry('Modified', _formatModified(metadata.modified)));

    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
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

    String two(int number) => number.toString().padLeft(2, '0');

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
  State<_ExplorerThumbnail> createState() => _ExplorerThumbnailState();
}

class _ExplorerThumbnailState extends State<_ExplorerThumbnail> {
  Future<String?>? _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _requestThumbnail();
  }

  @override
  void didUpdateWidget(covariant _ExplorerThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path ||
        oldWidget.item.kind != widget.item.kind ||
        !identical(oldWidget.thumbnailService, widget.thumbnailService) ||
        oldWidget.active != widget.active) {
      _requestThumbnail();
    }
  }

  void _requestThumbnail() {
    if (!widget.active) {
      _thumbnailFuture = null;
      return;
    }

    _thumbnailFuture = widget.thumbnailService.supports(widget.item)
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
          loading: snapshot.connectionState == ConnectionState.waiting,
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

