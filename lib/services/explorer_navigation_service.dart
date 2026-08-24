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

  final Directory _configDirectory;
  final String homePath;
  final int recentLimit;
  final int historyLimit;

  final List<String> _favorites = <String>[];
  final List<String> _recents = <String>[];
  final List<String> _history = <String>[];
  int _historyIndex = -1;
  Future<void> _writeTail = Future<void>.value();

  List<String> get favorites => List<String>.unmodifiable(_favorites);
  List<String> get recents => List<String>.unmodifiable(_recents);

  bool get canGoBack => _historyIndex > 0;
  bool get canGoForward =>
      _historyIndex >= 0 && _historyIndex < _history.length - 1;

  String? get backPath =>
      canGoBack ? _history[_historyIndex - 1] : null;
  String? get forwardPath =>
      canGoForward ? _history[_historyIndex + 1] : null;

  bool isFavorite(String path) => _favorites.contains(_normalize(path));

  void recordVisit(String path) {
    final normalized = _normalize(path);

    if (_historyIndex >= 0 &&
        _historyIndex < _history.length &&
        _history[_historyIndex] == normalized) {
      rememberRecent(normalized);
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
  }

  void commitBack() {
    if (canGoBack) {
      _historyIndex -= 1;
      rememberRecent(_history[_historyIndex]);
    }
  }

  void commitForward() {
    if (canGoForward) {
      _historyIndex += 1;
      rememberRecent(_history[_historyIndex]);
    }
  }

  void rememberRecent(String path) {
    final normalized = _normalize(path);
    _recents.remove(normalized);
    _recents.insert(0, normalized);

    if (_recents.length > recentLimit) {
      _recents.removeRange(recentLimit, _recents.length);
    }
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

      _recents
        ..clear()
        ..addAll(_readPathList(decoded['recents']).take(recentLimit));
    } catch (_) {
      // Explorer location state is convenience data. A corrupt or partially
      // written settings file must never prevent the browser from launching.
      _favorites.clear();
      _recents.clear();
    }
  }

  Future<void> save() {
    final contents = jsonEncode(<String, Object>{
      'version': 1,
      'favorites': _favorites,
      'recents': _recents,
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
