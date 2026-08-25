// lib/services/bookmark_service.dart

import 'dart:convert';
import 'dart:io';

/// Persists exact source-frame bookmarks without creating image files.
///
/// A bookmark is deliberately only a media-path + source-frame reference.
/// The Storyboard thumbnail pipeline supplies the visual preview on demand,
/// and the existing frame exporter creates a real PNG only when requested.
class BookmarkService {
  BookmarkService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  final Directory _configDirectory;
  final Map<String, List<int>> _framesByMedia = <String, List<int>>{};
  Future<void> _writeTail = Future<void>.value();

  List<int> framesFor(String mediaPath) {
    final frames = _framesByMedia[mediaPath];
    if (frames == null) {
      return const <int>[];
    }
    return List<int>.unmodifiable(frames);
  }

  bool contains(String mediaPath, int sourceFrame) {
    return _framesByMedia[mediaPath]?.contains(sourceFrame) ?? false;
  }

  bool add(String mediaPath, int sourceFrame) {
    if (mediaPath.isEmpty || sourceFrame < 0) {
      return false;
    }

    final frames = List<int>.from(_framesByMedia[mediaPath] ?? const <int>[]);
    if (frames.contains(sourceFrame)) {
      return false;
    }

    frames.add(sourceFrame);
    frames.sort();
    _framesByMedia[mediaPath] = frames;
    return true;
  }

  bool remove(String mediaPath, int sourceFrame) {
    final current = _framesByMedia[mediaPath];
    if (current == null || !current.contains(sourceFrame)) {
      return false;
    }

    final frames = List<int>.from(current)..remove(sourceFrame);
    if (frames.isEmpty) {
      _framesByMedia.remove(mediaPath);
    } else {
      _framesByMedia[mediaPath] = frames;
    }
    return true;
  }

  /// Toggles one exact source frame and returns its new bookmarked state.
  bool toggle(String mediaPath, int sourceFrame) {
    if (contains(mediaPath, sourceFrame)) {
      remove(mediaPath, sourceFrame);
      return false;
    }

    add(mediaPath, sourceFrame);
    return contains(mediaPath, sourceFrame);
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

      final media = decoded['media'];
      if (media is! Map<String, dynamic>) {
        return;
      }

      final restored = <String, List<int>>{};
      for (final entry in media.entries) {
        final rawFrames = entry.value;
        if (rawFrames is! List) {
          continue;
        }

        final frames = rawFrames
            .whereType<int>()
            .where((frame) => frame >= 0)
            .toSet()
            .toList()
          ..sort();

        if (frames.isNotEmpty) {
          restored[entry.key] = frames;
        }
      }

      _framesByMedia
        ..clear()
        ..addAll(restored);
    } catch (_) {
      // Bookmark data is convenience metadata. A malformed state file should
      // never block the player from starting.
      _framesByMedia.clear();
    }
  }

  Future<void> save() {
    final media = <String, Object>{};
    final paths = _framesByMedia.keys.toList()..sort();

    for (final path in paths) {
      media[path] = List<int>.from(_framesByMedia[path]!);
    }

    final contents = jsonEncode(<String, Object>{
      'version': 1,
      'media': media,
    });

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later save should still run after an earlier I/O failure.
      }

      await _configDirectory.create(recursive: true);
      await _stateFile.writeAsString(contents, flush: true);
    }();

    return _writeTail;
  }

  File get _stateFile => File('${_configDirectory.path}/bookmarks.json');

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
}
