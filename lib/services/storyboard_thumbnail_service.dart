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

typedef StoryboardThumbnailBatchGenerator =
    Future<MltThumbnailBatchGenerationResult> Function({
      required String sourcePath,
      required String outputDirectory,
      required int width,
      required int height,
      required List<int> requestedFrames,
    });

class StoryboardThumbnailService {
  StoryboardThumbnailService({
    Directory? cacheDirectory,
    StoryboardThumbnailGenerator? generator,
    StoryboardThumbnailBatchGenerator? batchGenerator,
  }) : assert(generator == null || batchGenerator == null),
       _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory(),
       _batchGenerator = batchGenerator ??
           (generator == null
               ? generateMltThumbnailFrameBatch
               : _batchAdapterForSingleGenerator(generator));

  static const int thumbnailWidth = 256;
  static const int thumbnailHeight = 144;
  static const int _maxBatchSize = 8;
  static const Duration _batchPollInterval = Duration(milliseconds: 35);
  static const String _cacheVersion = 'v1-mlt-storyboard-exact-frame';

  final Directory _cacheDirectory;
  final StoryboardThumbnailBatchGenerator _batchGenerator;
  final Queue<_StoryboardThumbnailRequest> _pending =
      Queue<_StoryboardThumbnailRequest>();
  final Map<String, _StoryboardThumbnailRequest> _inFlight =
      <String, _StoryboardThumbnailRequest>{};

  String? _activeSourcePath;
  Future<_StoryboardSourceIdentity?>? _activeSourceIdentity;
  int _generation = 0;
  bool _pumpScheduled = false;
  bool _pumpRunning = false;

  Directory get cacheDirectory => _cacheDirectory;

  static StoryboardThumbnailBatchGenerator _batchAdapterForSingleGenerator(
    StoryboardThumbnailGenerator generator,
  ) {
    return ({
      required String sourcePath,
      required String outputDirectory,
      required int width,
      required int height,
      required List<int> requestedFrames,
    }) async {
      var generatedCount = 0;
      String firstError = '';

      for (var index = 0; index < requestedFrames.length; index++) {
        final result = await generator(
          sourcePath: sourcePath,
          outputPath: _join(outputDirectory, '$index.jpg'),
          width: width,
          height: height,
          requestedFrame: requestedFrames[index],
        );

        if (result.succeeded) {
          generatedCount += 1;
        } else if (firstError.isEmpty && result.error.trim().isNotEmpty) {
          firstError = result.error.trim();
        }
      }

      return MltThumbnailBatchGenerationResult(
        succeeded: true,
        generatedCount: generatedCount,
        error: firstError,
      );
    };
  }

  void beginSource(String sourcePath) {
    final absolutePath = File(sourcePath).absolute.path;

    _generation += 1;
    _activeSourcePath = absolutePath;
    _activeSourceIdentity = _readSourceIdentity(absolutePath);
    _completeInvalidatedRequests();
    _schedulePump();
  }

  void cancelPending() {
    final generation = _generation;
    final sourcePath = _activeSourcePath;

    // Storyboard and Bookmarks share this service. During a view replacement,
    // the incoming view can begin the same source in the same event turn that
    // the outgoing view disposes. Deferring cancellation prevents the old view
    // from invalidating the replacement session that was just created.
    scheduleMicrotask(() {
      if (generation != _generation || sourcePath != _activeSourcePath) {
        return;
      }

      _generation += 1;
      _activeSourcePath = null;
      _activeSourceIdentity = null;
      _completeInvalidatedRequests();
    });
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

    final absolutePath = File(sourcePath).absolute.path;
    final generation = _generation;

    if (!_isCurrent(generation, absolutePath)) {
      return null;
    }

    final identityFuture = _activeSourceIdentity;
    if (identityFuture == null) {
      return null;
    }

    final identity = await identityFuture;
    if (identity == null || !_isCurrent(generation, absolutePath)) {
      return null;
    }

    final cachePath = _cachePathFor(
      absolutePath,
      identity.fileSize,
      identity.modifiedMicros,
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
      return existing.completer.future;
    }

    final request = _StoryboardThumbnailRequest(
      key: inFlightKey,
      generation: generation,
      sourcePath: absolutePath,
      requestedFrame: requestedFrame,
      cachePath: cachePath,
    );

    _inFlight[inFlightKey] = request;
    _pending.addLast(request);
    _schedulePump();

    return request.completer.future;
  }

  void _schedulePump() {
    if (_pumpScheduled || _pumpRunning || _pending.isEmpty) {
      return;
    }

    _pumpScheduled = true;
    Timer.run(() {
      _pumpScheduled = false;
      if (!_pumpRunning && _pending.isNotEmpty) {
        unawaited(_pump());
      }
    });
  }

  Future<void> _pump() async {
    if (_pumpRunning) {
      return;
    }

    _pumpRunning = true;
    try {
      while (true) {
        _completeInvalidatedRequests();

        final batch = <_StoryboardThumbnailRequest>[];
        while (_pending.isNotEmpty && batch.length < _maxBatchSize) {
          final request = _pending.removeFirst();
          if (request.completer.isCompleted) {
            continue;
          }
          if (!_isCurrent(request.generation, request.sourcePath)) {
            _completeRequest(request, null);
            continue;
          }
          batch.add(request);
        }

        if (batch.isEmpty) {
          if (_pending.isEmpty) {
            break;
          }
          continue;
        }

        await _runBatch(batch);
      }
    } finally {
      _pumpRunning = false;
      if (_pending.isNotEmpty) {
        _schedulePump();
      }
    }
  }

  Future<void> _runBatch(List<_StoryboardThumbnailRequest> requests) async {
    final work = <_StoryboardThumbnailRequest>[];

    for (final request in requests) {
      if (request.completer.isCompleted) {
        continue;
      }
      if (!_isCurrent(request.generation, request.sourcePath)) {
        _completeRequest(request, null);
        continue;
      }

      final cached = File(request.cachePath);
      if (await _isUsableFile(cached)) {
        _completeRequest(request, request.cachePath);
      } else {
        work.add(request);
      }
    }

    if (work.isEmpty) {
      return;
    }

    final generation = work.first.generation;
    final sourcePath = work.first.sourcePath;
    if (!_isCurrent(generation, sourcePath)) {
      for (final request in work) {
        _completeRequest(request, null);
      }
      return;
    }

    try {
      await _cacheDirectory.create(recursive: true);
    } on FileSystemException {
      for (final request in work) {
        _completeRequest(request, null);
      }
      return;
    }

    if (!_isCurrent(generation, sourcePath)) {
      for (final request in work) {
        _completeRequest(request, null);
      }
      return;
    }

    final nonce = DateTime.now().microsecondsSinceEpoch;
    final batchDirectory = Directory(
      _join(_cacheDirectory.path, '.batch-$generation-$nonce'),
    );

    try {
      await batchDirectory.create(recursive: true);
    } on FileSystemException {
      for (final request in work) {
        _completeRequest(request, null);
      }
      return;
    }

    var finished = false;
    MltThumbnailBatchGenerationResult? result;
    Object? generationFailure;

    final generationFuture = () async {
      try {
        result = await _batchGenerator(
          sourcePath: sourcePath,
          outputDirectory: batchDirectory.path,
          width: thumbnailWidth,
          height: thumbnailHeight,
          requestedFrames: work
              .map((request) => request.requestedFrame)
              .toList(growable: false),
        );
      } catch (error) {
        generationFailure = error;
      } finally {
        finished = true;
      }
    }();

    while (!finished) {
      await _publishReadyBatchFiles(work, batchDirectory);
      if (!finished) {
        await Future<void>.delayed(_batchPollInterval);
      }
    }

    await generationFuture;
    await _publishReadyBatchFiles(work, batchDirectory);

    final batchResult = result;
    if (generationFailure != null) {
      stderr.writeln(
        'storyboard: $generationFailure ($sourcePath batch)',
      );
    } else if (batchResult != null && batchResult.error.trim().isNotEmpty) {
      stderr.writeln(
        'storyboard: ${batchResult.error.trim()} ($sourcePath batch)',
      );
    }

    for (final request in work) {
      if (!request.completer.isCompleted) {
        _completeRequest(request, null);
      }
    }

    await _deleteDirectoryIfPresent(batchDirectory);
  }

  Future<void> _publishReadyBatchFiles(
    List<_StoryboardThumbnailRequest> requests,
    Directory batchDirectory,
  ) async {
    for (var index = 0; index < requests.length; index++) {
      final request = requests[index];
      if (request.completer.isCompleted) {
        continue;
      }

      if (!_isCurrent(request.generation, request.sourcePath)) {
        _completeRequest(request, null);
        continue;
      }

      final cached = File(request.cachePath);
      if (await _isUsableFile(cached)) {
        _completeRequest(request, request.cachePath);
        continue;
      }

      final ready = File(_join(batchDirectory.path, '$index.jpg'));
      if (!await _isUsableFile(ready)) {
        continue;
      }

      if (!_isCurrent(request.generation, request.sourcePath)) {
        _completeRequest(request, null);
        continue;
      }

      try {
        await _deleteIfPresent(cached);
        await ready.rename(request.cachePath);
        _completeRequest(request, request.cachePath);
      } on FileSystemException {
        _completeRequest(request, null);
      }
    }
  }

  void _completeInvalidatedRequests() {
    final requests = _inFlight.values.toList(growable: false);
    for (final request in requests) {
      if (!request.completer.isCompleted &&
          !_isCurrent(request.generation, request.sourcePath)) {
        _completeRequest(request, null);
      }
    }
  }

  void _completeRequest(
    _StoryboardThumbnailRequest request,
    String? value,
  ) {
    if (request.completer.isCompleted) {
      return;
    }

    request.completer.complete(value);
    if (identical(_inFlight[request.key], request)) {
      _inFlight.remove(request.key);
    }
  }

  bool _isCurrent(int generation, String sourcePath) =>
      generation == _generation && _activeSourcePath == sourcePath;

  Future<_StoryboardSourceIdentity?> _readSourceIdentity(
    String absolutePath,
  ) async {
    try {
      final stat = await File(absolutePath).stat();
      if (stat.type != FileSystemEntityType.file) {
        return null;
      }

      return _StoryboardSourceIdentity(
        fileSize: stat.size,
        modifiedMicros: stat.modified.microsecondsSinceEpoch,
      );
    } on FileSystemException {
      return null;
    }
  }

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

  static Future<void> _deleteDirectoryIfPresent(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Storyboard temporary batch cleanup is best-effort.
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

class _StoryboardThumbnailRequest {
  _StoryboardThumbnailRequest({
    required this.key,
    required this.generation,
    required this.sourcePath,
    required this.requestedFrame,
    required this.cachePath,
  });

  final String key;
  final int generation;
  final String sourcePath;
  final int requestedFrame;
  final String cachePath;
  final Completer<String?> completer = Completer<String?>();
}

class _StoryboardSourceIdentity {
  const _StoryboardSourceIdentity({
    required this.fileSize,
    required this.modifiedMicros,
  });

  final int fileSize;
  final int modifiedMicros;
}
