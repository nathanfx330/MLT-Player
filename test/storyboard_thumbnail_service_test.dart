// test/storyboard_thumbnail_service_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/mlt_thumbnail_bridge.dart';
import 'package:mlt_player/services/storyboard_thumbnail_service.dart';

void main() {
  late Directory temp;
  late File source;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mlt_storyboard_test_');
    source = File('${temp.path}/movie.mp4');
    await source.writeAsBytes(List<int>.filled(128, 1));
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<MltThumbnailBatchGenerationResult> writeBatch({
    required String sourcePath,
    required String outputDirectory,
    required int width,
    required int height,
    required List<int> requestedFrames,
  }) async {
    for (var index = 0; index < requestedFrames.length; index++) {
      await File('$outputDirectory/$index.jpg').writeAsBytes(
        <int>[requestedFrames[index] & 0xff, index + 1],
      );
    }

    return MltThumbnailBatchGenerationResult(
      succeeded: true,
      generatedCount: requestedFrames.length,
      error: '',
    );
  }

  test('concurrent exact frames share one native-style batch then cache', () async {
    var calls = 0;
    final batches = <List<int>>[];
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      batchGenerator: ({
        required sourcePath,
        required outputDirectory,
        required width,
        required height,
        required requestedFrames,
      }) async {
        calls += 1;
        batches.add(List<int>.from(requestedFrames));
        return writeBatch(
          sourcePath: sourcePath,
          outputDirectory: outputDirectory,
          width: width,
          height: height,
          requestedFrames: requestedFrames,
        );
      },
    );

    service.beginSource(source.path);

    final frame100Future = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 100,
    );
    final frame200Future = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 200,
    );

    final results = await Future.wait(<Future<String?>>[
      frame100Future,
      frame200Future,
    ]);

    expect(results[0], isNotNull);
    expect(results[1], isNotNull);
    expect(results[0], isNot(results[1]));
    expect(calls, 1);
    expect(batches, <List<int>>[
      <int>[100, 200],
    ]);
    expect(await File(results[0]!).length(), greaterThan(0));
    expect(await File(results[1]!).length(), greaterThan(0));

    final cached = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 100,
    );
    expect(cached, results[0]);
    expect(calls, 1);
  });

  test('duplicate concurrent frame requests are deduplicated', () async {
    var calls = 0;
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      batchGenerator: ({
        required sourcePath,
        required outputDirectory,
        required width,
        required height,
        required requestedFrames,
      }) async {
        calls += 1;
        return writeBatch(
          sourcePath: sourcePath,
          outputDirectory: outputDirectory,
          width: width,
          height: height,
          requestedFrames: requestedFrames,
        );
      },
    );

    service.beginSource(source.path);

    final first = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 250,
    );
    final second = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 250,
    );

    final results = await Future.wait(<Future<String?>>[first, second]);
    expect(results[0], isNotNull);
    expect(results[1], results[0]);
    expect(calls, 1);
  });

  test('restarting a source invalidates an active batch safely', () async {
    final started = <List<int>>[];
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      batchGenerator: ({
        required sourcePath,
        required outputDirectory,
        required width,
        required height,
        required requestedFrames,
      }) async {
        started.add(List<int>.from(requestedFrames));
        if (started.length == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }

        return writeBatch(
          sourcePath: sourcePath,
          outputDirectory: outputDirectory,
          width: width,
          height: height,
          requestedFrames: requestedFrames,
        );
      },
    );

    service.beginSource(source.path);
    final first = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 10,
    );
    final second = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 20,
    );

    await firstStarted.future;
    service.restartSource(source.path);

    expect(await first, isNull);
    expect(await second, isNull);

    releaseFirst.complete();

    final current = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 30,
    );
    expect(current, isNotNull);
    expect(started, <List<int>>[
      <int>[10, 20],
      <int>[30],
    ]);
  });

  test('outgoing view cancellation cannot kill a replacement source session', () async {
    var calls = 0;
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      batchGenerator: ({
        required sourcePath,
        required outputDirectory,
        required width,
        required height,
        required requestedFrames,
      }) async {
        calls += 1;
        return writeBatch(
          sourcePath: sourcePath,
          outputDirectory: outputDirectory,
          width: width,
          height: height,
          requestedFrames: requestedFrames,
        );
      },
    );

    service.beginSource(source.path);
    service.cancelPending();
    service.beginSource(source.path);

    final current = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 40,
    );

    expect(current, isNotNull);
    expect(calls, 1);
  });
}
