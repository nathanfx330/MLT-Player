// lib/services/storyboard_thumbnail_service.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'mlt_thumbnail_bridge.dart';

typedef StoryboardThumbnailGenerator =
    Future<MltThumbnailGenerationResult> Function({
      required String sourcePath,
      required String outputPath,
      required int width,
      required int height,
      required int requestedFrame,
    });

class StoryboardThumbnailService {
  StoryboardThumbnailService({
    Directory? cacheDirectory,
    StoryboardThumbnailGenerator? generator,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory(),
       _generator = generator ?? generateMltThumbnailAtFrame;

  static const int thumbnailWidth = 256;
  static const int thumbnailHeight = 144;
  static const String _cacheVersion = 'v1-mlt-storyboard-exact-frame';

  final Directory _cacheDirectory;
  final StoryboardThumbnailGenerator _generator;
  final _StoryboardPermitPool _permits = _StoryboardPermitPool(1);
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  String? _activeSourcePath;
  int _generation = 0;

  Directory get cacheDirectory => _cacheDirectory;

  void beginSource(String sourcePath) {
    _generation += 1;
    _activeSourcePath = File(sourcePath).absolute.path;
  }

  void cancelPending() {
    _generation += 1;
    _activeSourcePath = null;
  }

  void restartSource(String sourcePath) {
    beginSource(sourcePath);
  }

  Future<String?> thumbnailAtFrame({
    required String sourcePath,
    required int requestedFrame,
  }) async {
    if (requestedFrame < 0) {
      return null;
    }

    final source = File(sourcePath);
    final absolutePath = source.absolute.path;
    final generation = _generation;

    if (_activeSourcePath != absolutePath) {
      return null;
    }

    FileStat stat;
    try {
      stat = await source.stat();
    } on FileSystemException {
      return null;
    }

    if (!_isCurrent(generation, absolutePath) ||
        stat.type != FileSystemEntityType.file) {
      return null;
    }

    final cachePath = _cachePathFor(
      absolutePath,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      requestedFrame,
    );
    final cached = File(cachePath);

    if (await _isUsableFile(cached)) {
      return cachePath;
    }

    if (!_isCurrent(generation, absolutePath)) {
      return null;
    }

    final inFlightKey = '$generation:$cachePath';
    final existing = _inFlight[inFlightKey];
    if (existing != null) {
      return existing;
    }

    final future = _permits.run<String?>(() async {
      if (!_isCurrent(generation, absolutePath)) {
        return null;
      }
      if (await _isUsableFile(cached)) {
        return cachePath;
      }
      if (!_isCurrent(generation, absolutePath)) {
        return null;
      }

      return _generateThumbnail(
        generation: generation,
        sourcePath: absolutePath,
        requestedFrame: requestedFrame,
        cachePath: cachePath,
      );
    });

    _inFlight[inFlightKey] = future;
    try {
      return await future;
    } finally {
      _inFlight.removeWhere(
        (key, value) => key == inFlightKey && identical(value, future),
      );
    }
  }

  Future<String?> _generateThumbnail({
    required int generation,
    required String sourcePath,
    required int requestedFrame,
    required String cachePath,
  }) async {
    try {
      await _cacheDirectory.create(recursive: true);
    } on FileSystemException {
      return null;
    }

    if (!_isCurrent(generation, sourcePath)) {
      return null;
    }

    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temporaryPath = '$cachePath.$nonce.part.jpg';
    final temporary = File(temporaryPath);

    try {
      final result = await _generator(
        sourcePath: sourcePath,
        outputPath: temporaryPath,
        width: thumbnailWidth,
        height: thumbnailHeight,
        requestedFrame: requestedFrame,
      );

      if (!result.succeeded || !await _isUsableFile(temporary)) {
        await _deleteIfPresent(temporary);
        if (result.error.trim().isNotEmpty) {
          stderr.writeln(
            'storyboard: ${result.error.trim()} '
            '($sourcePath @ frame $requestedFrame)',
          );
        }
        return null;
      }

      // If navigation or interval changes while the synchronous native decode
      // is running, discard the completed temporary instead of publishing a
      // result from an obsolete Storyboard session.
      if (!_isCurrent(generation, sourcePath)) {
        await _deleteIfPresent(temporary);
        return null;
      }

      final cached = File(cachePath);
      await _deleteIfPresent(cached);
      await temporary.rename(cachePath);
      return cachePath;
    } on FileSystemException {
      await _deleteIfPresent(temporary);
      return null;
    } catch (error) {
      await _deleteIfPresent(temporary);
      stderr.writeln(
        'storyboard: $error ($sourcePath @ frame $requestedFrame)',
      );
      return null;
    }
  }

  bool _isCurrent(int generation, String sourcePath) =>
      generation == _generation && _activeSourcePath == sourcePath;

  String _cachePathFor(
    String absolutePath,
    int fileSize,
    int modifiedMicros,
    int requestedFrame,
  ) {
    final identity =
        '$_cacheVersion\n'
        '$absolutePath\n'
        '$fileSize\n'
        '$modifiedMicros\n'
        '$requestedFrame\n'
        '${thumbnailWidth}x$thumbnailHeight';
    final bytes = utf8.encode(identity);

    var fnv = 0x811C9DC5;
    var djb = 5381;
    for (final byte in bytes) {
      fnv = ((fnv ^ byte) * 0x01000193) & 0xFFFFFFFF;
      djb = ((djb * 33) ^ byte) & 0xFFFFFFFF;
    }

    final key = '${fnv.toRadixString(16).padLeft(8, '0')}'
        '${djb.toRadixString(16).padLeft(8, '0')}';
    return _join(_cacheDirectory.path, '$key.jpg');
  }

  static Future<bool> _isUsableFile(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Storyboard cache cleanup is best-effort.
    }
  }

  static Directory _defaultCacheDirectory() {
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return Directory(_join(xdg, 'mlt_player/storyboard'));
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(_join(home, '.cache/mlt_player/storyboard'));
    }

    return Directory(
      _join(Directory.systemTemp.path, 'mlt_player/storyboard'),
    );
  }

  static String _join(String directory, String child) {
    final separator = Platform.pathSeparator;
    return directory.endsWith(separator)
        ? '$directory$child'
        : '$directory$separator$child';
  }
}

class _StoryboardPermitPool {
  _StoryboardPermitPool(this._capacity)
    : assert(_capacity > 0),
      _available = _capacity;

  final int _capacity;
  int _available;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_available > 0) {
      _available -= 1;
      return Future<void>.value();
    }

    final completer = Completer<void>();
    _waiters.addLast(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }

    if (_available < _capacity) {
      _available += 1;
    }
  }
}
