// lib/services/explorer_navigation_service.dart

import 'dart:convert';
import 'dart:io';

class ExplorerNavigationService {
  ExplorerNavigationService({
    Directory? configDirectory,
    String? homePath,
    this.recentLimit = 8,
    this.historyLimit = 100,
  })  : assert(recentLimit > 0),
        assert(historyLimit > 0),
        _configDirectory = configDirectory ?? _defaultConfigDirectory(),
        homePath = _normalize(homePath ?? _defaultHomePath());

  static const String _defaultWorkspaceKey = '__default__';

  final Directory _configDirectory;
  final String homePath;
  final int recentLimit;
  final int historyLimit;

  final List<String> _favorites = <String>[];
  final Map<String, List<String>> _recentsByWorkspace =
      <String, List<String>>{};
  final Map<String, List<String>> _locationHistoryByWorkspace =
      <String, List<String>>{};

  // Back/Forward is deliberately session-only. It is reset when the workspace
  // changes so navigation from one workspace cannot leak into another.
  final List<String> _history = <String>[];
  int _historyIndex = -1;

  String _activeWorkspaceKey = _defaultWorkspaceKey;
  Future<void> _writeTail = Future<void>.value();

  List<String> get favorites => List<String>.unmodifiable(_favorites);
  List<String> get recents =>
      List<String>.unmodifiable(_recentsFor(_activeWorkspaceKey));
  List<String> get locationHistory =>
      List<String>.unmodifiable(_locationHistoryFor(_activeWorkspaceKey));
  String get activeWorkspaceKey => _activeWorkspaceKey;

  bool get canGoBack => _historyIndex > 0;
  bool get canGoForward =>
      _historyIndex >= 0 && _historyIndex < _history.length - 1;

  String? get backPath => canGoBack ? _history[_historyIndex - 1] : null;
  String? get forwardPath =>
      canGoForward ? _history[_historyIndex + 1] : null;

  bool isFavorite(String path) => _favorites.contains(_normalize(path));

  bool selectWorkspace(String workspaceKey) {
    final normalizedKey = workspaceKey.trim();
    if (normalizedKey.isEmpty) {
      throw ArgumentError.value(
        workspaceKey,
        'workspaceKey',
        'Explorer workspace identity cannot be empty.',
      );
    }

    if (normalizedKey == _activeWorkspaceKey) {
      return false;
    }

    // Legacy unscoped Recent/History state, or any navigation recorded before
    // WorkspaceProjectService finished loading, belongs to the first real
    // workspace selected in this session.
    if (_activeWorkspaceKey == _defaultWorkspaceKey) {
      _adoptDefaultWorkspaceState(normalizedKey);
    }

    _activeWorkspaceKey = normalizedKey;
    _history.clear();
    _historyIndex = -1;
    return true;
  }

  void recordVisit(String path) {
    final normalized = _normalize(path);

    if (_historyIndex >= 0 &&
        _historyIndex < _history.length &&
        _history[_historyIndex] == normalized) {
      rememberRecent(normalized);
      rememberLocationHistory(normalized);
      return;
    }

    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }

    _history.add(normalized);
    _historyIndex = _history.length - 1;

    if (_history.length > historyLimit) {
      final overflow = _history.length - historyLimit;
      _history.removeRange(0, overflow);
      _historyIndex -= overflow;
    }

    rememberRecent(normalized);
    rememberLocationHistory(normalized);
  }

  void commitBack() {
    if (canGoBack) {
      _historyIndex -= 1;
      final path = _history[_historyIndex];
      rememberRecent(path);
      rememberLocationHistory(path);
    }
  }

  void commitForward() {
    if (canGoForward) {
      _historyIndex += 1;
      final path = _history[_historyIndex];
      rememberRecent(path);
      rememberLocationHistory(path);
    }
  }

  void rememberRecent(String path) {
    final normalized = _normalize(path);
    final recents = _recentsFor(_activeWorkspaceKey);
    recents.remove(normalized);
    recents.insert(0, normalized);

    if (recents.length > recentLimit) {
      recents.removeRange(recentLimit, recents.length);
    }
  }

  void rememberLocationHistory(String path) {
    final normalized = _normalize(path);
    final history = _locationHistoryFor(_activeWorkspaceKey);
    history.remove(normalized);
    history.insert(0, normalized);

    if (history.length > historyLimit) {
      history.removeRange(historyLimit, history.length);
    }
  }

  void clearRecents() {
    _recentsFor(_activeWorkspaceKey).clear();
  }

  void clearLocationHistory() {
    _locationHistoryFor(_activeWorkspaceKey).clear();
  }

  void toggleFavorite(String path) {
    final normalized = _normalize(path);
    if (_favorites.remove(normalized)) {
      return;
    }
    _favorites.add(normalized);
    _favorites.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<void> load() async {
    final file = _stateFile;
    if (!await file.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      _favorites
        ..clear()
        ..addAll(_readPathList(decoded['favorites']));
      _favorites.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      _recentsByWorkspace.clear();
      _locationHistoryByWorkspace.clear();

      final scopedRecents = decoded['workspace_recents'];
      final scopedHistory = decoded['workspace_history'];
      final hasScopedNavigation =
          scopedRecents is Map<dynamic, dynamic> ||
          scopedHistory is Map<dynamic, dynamic>;

      if (hasScopedNavigation) {
        _recentsByWorkspace.addAll(
          _readWorkspacePathMap(scopedRecents, recentLimit),
        );
        _locationHistoryByWorkspace.addAll(
          _readWorkspacePathMap(scopedHistory, historyLimit),
        );
      } else {
        // Version 1 stored one global list. Keep it available under the
        // provisional scope; selectWorkspace() will move it into the first
        // actual workspace once WorkspaceProjectService is ready.
        final legacyRecents =
            _readPathList(decoded['recents']).take(recentLimit).toList();
        final legacyHistory =
            _readPathList(decoded['history']).take(historyLimit).toList();
        final targetKey = _activeWorkspaceKey;

        if (legacyRecents.isNotEmpty) {
          _recentsByWorkspace[targetKey] = legacyRecents;
        }
        if (legacyHistory.isNotEmpty) {
          _locationHistoryByWorkspace[targetKey] = legacyHistory;
        }
      }
    } catch (_) {
      // Explorer location state is convenience data. A corrupt or partially
      // written settings file must never prevent the browser from launching.
      _favorites.clear();
      _recentsByWorkspace.clear();
      _locationHistoryByWorkspace.clear();
    }
  }

  Future<void> save() {
    final contents = jsonEncode(<String, Object>{
      'version': 2,
      'favorites': _favorites,
      'workspace_recents': _writeWorkspacePathMap(_recentsByWorkspace),
      'workspace_history':
          _writeWorkspacePathMap(_locationHistoryByWorkspace),
    });

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later save should still be attempted after an earlier I/O failure.
      }

      await _configDirectory.create(recursive: true);
      await _stateFile.writeAsString(contents, flush: true);
    }();

    return _writeTail;
  }

  List<String> _recentsFor(String workspaceKey) {
    return _recentsByWorkspace.putIfAbsent(
      workspaceKey,
      () => <String>[],
    );
  }

  List<String> _locationHistoryFor(String workspaceKey) {
    return _locationHistoryByWorkspace.putIfAbsent(
      workspaceKey,
      () => <String>[],
    );
  }

  void _adoptDefaultWorkspaceState(String workspaceKey) {
    final defaultRecents = _recentsByWorkspace.remove(_defaultWorkspaceKey);
    if (defaultRecents != null &&
        defaultRecents.isNotEmpty &&
        !_recentsByWorkspace.containsKey(workspaceKey)) {
      _recentsByWorkspace[workspaceKey] = defaultRecents;
    }

    final defaultHistory =
        _locationHistoryByWorkspace.remove(_defaultWorkspaceKey);
    if (defaultHistory != null &&
        defaultHistory.isNotEmpty &&
        !_locationHistoryByWorkspace.containsKey(workspaceKey)) {
      _locationHistoryByWorkspace[workspaceKey] = defaultHistory;
    }
  }

  File get _stateFile =>
      File('${_configDirectory.path}/explorer_locations.json');

  static Iterable<String> _readPathList(Object? value) sync* {
    if (value is! List<dynamic>) {
      return;
    }

    final seen = <String>{};
    for (final entry in value) {
      if (entry is! String || entry.trim().isEmpty) {
        continue;
      }
      final normalized = _normalize(entry);
      if (seen.add(normalized)) {
        yield normalized;
      }
    }
  }

  static Map<String, List<String>> _readWorkspacePathMap(
    Object? value,
    int limit,
  ) {
    if (value is! Map<dynamic, dynamic>) {
      return <String, List<String>>{};
    }

    final result = <String, List<String>>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key.trim().isEmpty) {
        continue;
      }

      final paths = _readPathList(entry.value).take(limit).toList();
      if (paths.isNotEmpty) {
        result[key.trim()] = paths;
      }
    }
    return result;
  }

  static Map<String, List<String>> _writeWorkspacePathMap(
    Map<String, List<String>> source,
  ) {
    return <String, List<String>>{
      for (final entry in source.entries)
        if (entry.value.isNotEmpty)
          entry.key: List<String>.from(entry.value),
    };
  }

  static Directory _defaultConfigDirectory() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return Directory('${xdg.trim()}/mlt_player');
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return Directory('${home.trim()}/.config/mlt_player');
    }

    return Directory('${Directory.systemTemp.path}/mlt_player');
  }

  static String _defaultHomePath() {
    final home = Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return home.trim();
    }
    return Directory.current.path;
  }

  static String _normalize(String path) => Directory(path).absolute.path;
}
