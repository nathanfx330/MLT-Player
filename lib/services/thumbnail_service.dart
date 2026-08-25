// lib/services/thumbnail_service.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../models/explorer_item.dart';
import 'mlt_thumbnail_bridge.dart';

typedef ThumbnailGenerator = Future<MltThumbnailGenerationResult> Function({
  required String sourcePath,
  required String outputPath,
  required int width,
  required int height,
});

class ThumbnailService {
  ThumbnailService({
    Directory? cacheDirectory,
    int maxConcurrent = 1,
    ThumbnailGenerator? generator,
  })  : assert(maxConcurrent > 0),
        _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory(),
        _generator = generator ?? generateMltThumbnail,
        _permits = _ThumbnailPermitPool(maxConcurrent);

  static const int thumbnailWidth = 480;
  static const int thumbnailHeight = 270;

  // Phase 11.2 originally used an external ffmpeg CLI at a fixed one-second
  // seek. v2 is intentionally incompatible: thumbnails now come from MLT and
  // video frames are selected by the representative-frame sampler.
  static const String _cacheVersion = 'v2-mlt-representative';

  final Directory _cacheDirectory;
  final ThumbnailGenerator _generator;
  final _ThumbnailPermitPool _permits;
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};
  final Map<String, String> _failures = <String, String>{};
  bool _paused = false;

  Directory get cacheDirectory => _cacheDirectory;
  bool get paused => _paused;

  String? failureFor(String sourcePath) => _failures[sourcePath];

  void resume() {
    _paused = false;
  }

  Future<void> pauseAndDrain() async {
    _paused = true;

    // Native MLT thumbnail calls are synchronous inside a worker isolate and
    // cannot be interrupted safely mid-decode. Let the active job finish.
    // Requests still waiting for a permit observe _paused before they
    // launch and collapse to null immediately.
    while (_inFlight.isNotEmpty) {
      final pending = _inFlight.values.toList(growable: false);
      await Future.wait<void>(
        pending.map((future) async {
          try {
            await future;
          } catch (_) {
            // Thumbnail failure must never block Explorer -> Player handoff.
          }
        }),
      );
    }
  }

  bool supports(ExplorerItem item) =>
      item.kind == ExplorerItemKind.video ||
      item.kind == ExplorerItemKind.image;

  Future<String?> thumbnailFor(ExplorerItem item) async {
    if (_paused || !supports(item)) {
      return null;
    }

    final source = File(item.path);
    FileStat stat;
    try {
      stat = await source.stat();
    } on FileSystemException catch (error) {
      _recordFailure(item.path, error.message);
      return null;
    }

    if (_paused || stat.type != FileSystemEntityType.file) {
      return null;
    }

    final sourcePath = source.absolute.path;
    final cachePath = _cachePathFor(
      sourcePath,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
    );
    final cached = File(cachePath);

    if (await _isUsableFile(cached)) {
      _failures.remove(item.path);
      _failures.remove(sourcePath);
      return cachePath;
    }

    if (_paused) {
      return null;
    }

    final existing = _inFlight[cachePath];
    if (existing != null) {
      return existing;
    }

    final future = _permits.run<String?>(() async {
      if (_paused) {
        return null;
      }
      if (await _isUsableFile(cached)) {
        return cachePath;
      }
      if (_paused) {
        return null;
      }
      return _generateThumbnail(
        sourcePath: sourcePath,
        cachePath: cachePath,
      );
    });

    _inFlight[cachePath] = future;
    try {
      return await future;
    } finally {
      _inFlight.removeWhere(
        (key, value) => key == cachePath && identical(value, future),
      );
    }
  }

  Future<String?> _generateThumbnail({
    required String sourcePath,
    required String cachePath,
  }) async {
    try {
      await _cacheDirectory.create(recursive: true);
    } on FileSystemException catch (error) {
      _recordFailure(sourcePath, error.message);
      return null;
    }

    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temporaryPath = '$cachePath.$nonce.part.jpg';
    final temporary = File(temporaryPath);

    try {
      if (_paused) {
        return null;
      }

      final result = await _generator(
        sourcePath: sourcePath,
        outputPath: temporaryPath,
        width: thumbnailWidth,
        height: thumbnailHeight,
      );

      if (!result.succeeded || !await _isUsableFile(temporary)) {
        await _deleteIfPresent(temporary);
        _recordFailure(
          sourcePath,
          result.error.isEmpty
              ? 'MLT could not generate a thumbnail.'
              : result.error,
        );
        return null;
      }

      final cached = File(cachePath);
      await _deleteIfPresent(cached);
      await temporary.rename(cachePath);
      _failures.remove(sourcePath);
      return cachePath;
    } on FileSystemException catch (error) {
      await _deleteIfPresent(temporary);
      _recordFailure(sourcePath, error.message);
      return null;
    } catch (error) {
      await _deleteIfPresent(temporary);
      _recordFailure(sourcePath, error.toString());
      return null;
    }
  }

  void _recordFailure(String sourcePath, String message) {
    final normalized = message.trim().isEmpty
        ? 'MLT thumbnail generation failed.'
        : message.trim();
    _failures[sourcePath] = normalized;
    stderr.writeln('thumbnail: $normalized ($sourcePath)');
  }

  String _cachePathFor(
    String absolutePath,
    int fileSize,
    int modifiedMicros,
  ) {
    final identity = '$_cacheVersion\n$absolutePath\n$fileSize\n$modifiedMicros';
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
      // Cache cleanup is best-effort. A stale temporary file must never make
      // Explorer fail to browse or open the underlying source media.
    }
  }

  static Directory _defaultCacheDirectory() {
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return Directory(_join(xdg, 'mlt_player/thumbnails'));
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(_join(home, '.cache/mlt_player/thumbnails'));
    }

    return Directory(
      _join(Directory.systemTemp.path, 'mlt_player/thumbnails'),
    );
  }

  static String _join(String parent, String child) {
    final separator = Platform.pathSeparator;
    return parent.endsWith(separator)
        ? '$parent$child'
        : '$parent$separator$child';
  }
}

class _ThumbnailPermitPool {
  _ThumbnailPermitPool(this.maximum);

  final int maximum;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() work) async {
    await _acquire();
    try {
      return await work();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_active < maximum) {
      _active++;
      return;
    }

    final completer = Completer<void>();
    _waiters.addLast(completer);
    await completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // Transfer this occupied slot directly to the oldest waiter. Keeping
      // _active unchanged closes the race where a new caller could steal the
      // slot before the awakened waiter resumes.
      _waiters.removeFirst().complete();
      return;
    }
    _active--;
  }
}
