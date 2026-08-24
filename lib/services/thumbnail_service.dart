// lib/services/thumbnail_service.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../models/explorer_item.dart';

typedef ThumbnailProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class ThumbnailService {
  ThumbnailService({
    Directory? cacheDirectory,
    int maxConcurrent = 2,
    ThumbnailProcessRunner? processRunner,
  })  : assert(maxConcurrent > 0),
        _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory(),
        _processRunner = processRunner ?? _runProcess,
        _permits = _ThumbnailPermitPool(maxConcurrent);

  static const int thumbnailWidth = 480;
  static const int thumbnailHeight = 270;
  static const String _cacheVersion = 'v1';

  final Directory _cacheDirectory;
  final ThumbnailProcessRunner _processRunner;
  final _ThumbnailPermitPool _permits;
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};
  bool _paused = false;

  Directory get cacheDirectory => _cacheDirectory;
  bool get paused => _paused;

  void resume() {
    _paused = false;
  }

  Future<void> pauseAndDrain() async {
    _paused = true;

    // Existing Process.run calls cannot be cancelled safely, so let the at-most
    // two active workers finish. Requests already waiting for a permit observe
    // _paused before launching ffmpeg and collapse to null immediately.
    while (_inFlight.isNotEmpty) {
      final pending = _inFlight.values.toList(growable: false);
      await Future.wait<void>(
        pending.map((future) async {
          try {
            await future;
          } catch (_) {
            // Thumbnail failure must never block the Explorer -> Player handoff.
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
    } on FileSystemException {
      return null;
    }

    if (_paused || stat.type != FileSystemEntityType.file) {
      return null;
    }

    final cachePath = _cachePathFor(
      source.absolute.path,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
    );
    final cached = File(cachePath);

    if (await _isUsableFile(cached)) {
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
        item: item,
        sourcePath: source.absolute.path,
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
    required ExplorerItem item,
    required String sourcePath,
    required String cachePath,
  }) async {
    try {
      await _cacheDirectory.create(recursive: true);
    } on FileSystemException {
      return null;
    }

    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temporaryPath = '$cachePath.$nonce.part.jpg';
    final temporary = File(temporaryPath);

    try {
      if (_paused) {
        return null;
      }

      var generated = await _runFfmpeg(
        sourcePath: sourcePath,
        outputPath: temporaryPath,
        seekSeconds: item.kind == ExplorerItemKind.video ? 1.0 : null,
      );

      if (!generated && item.kind == ExplorerItemKind.video && !_paused) {
        await _deleteIfPresent(temporary);
        generated = await _runFfmpeg(
          sourcePath: sourcePath,
          outputPath: temporaryPath,
          seekSeconds: null,
        );
      }

      if (!generated || !await _isUsableFile(temporary)) {
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
    } on ProcessException {
      await _deleteIfPresent(temporary);
      return null;
    }
  }

  Future<bool> _runFfmpeg({
    required String sourcePath,
    required String outputPath,
    required double? seekSeconds,
  }) async {
    final arguments = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
    ];

    if (seekSeconds != null) {
      arguments.addAll(<String>['-ss', seekSeconds.toStringAsFixed(3)]);
    }

    arguments.addAll(<String>[
      '-i',
      sourcePath,
      '-frames:v',
      '1',
      '-an',
      '-sn',
      '-dn',
      '-vf',
      'scale=$thumbnailWidth:$thumbnailHeight:'
          'force_original_aspect_ratio=decrease,'
          'pad=$thumbnailWidth:$thumbnailHeight:'
          '(ow-iw)/2:(oh-ih)/2:color=black',
      '-q:v',
      '3',
      outputPath,
    ]);

    final result = await _processRunner('ffmpeg', arguments);
    return result.exitCode == 0;
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

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
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
