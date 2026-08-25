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

  test('exact storyboard frame is generated once then served from cache', () async {
    var calls = 0;
    var requested = -1;
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      generator: ({
        required sourcePath,
        required outputPath,
        required width,
        required height,
        required requestedFrame,
      }) async {
        calls += 1;
        requested = requestedFrame;
        await File(outputPath).writeAsBytes(<int>[1, 2, 3, 4]);
        return MltThumbnailGenerationResult(
          succeeded: true,
          selectedFrame: requestedFrame,
          error: '',
        );
      },
    );

    service.beginSource(source.path);

    final first = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 250,
    );
    final second = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 250,
    );

    expect(first, isNotNull);
    expect(second, first);
    expect(calls, 1);
    expect(requested, 250);
    expect(await File(first!).length(), greaterThan(0));
  });

  test('different source frames receive different persistent cache entries', () async {
    var calls = 0;
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      generator: ({
        required sourcePath,
        required outputPath,
        required width,
        required height,
        required requestedFrame,
      }) async {
        calls += 1;
        await File(outputPath).writeAsBytes(<int>[requestedFrame & 0xff, 7]);
        return MltThumbnailGenerationResult(
          succeeded: true,
          selectedFrame: requestedFrame,
          error: '',
        );
      },
    );

    service.beginSource(source.path);

    final frame100 = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 100,
    );
    final frame200 = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 200,
    );

    expect(frame100, isNotNull);
    expect(frame200, isNotNull);
    expect(frame100, isNot(frame200));
    expect(calls, 2);
  });

  test('restarting a source cancels queued work from the old storyboard session', () async {
    final started = <int>[];
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final service = StoryboardThumbnailService(
      cacheDirectory: Directory('${temp.path}/cache'),
      generator: ({
        required sourcePath,
        required outputPath,
        required width,
        required height,
        required requestedFrame,
      }) async {
        started.add(requestedFrame);
        if (requestedFrame == 10) {
          firstStarted.complete();
          await releaseFirst.future;
        }
        await File(outputPath).writeAsBytes(<int>[1]);
        return MltThumbnailGenerationResult(
          succeeded: true,
          selectedFrame: requestedFrame,
          error: '',
        );
      },
    );

    service.beginSource(source.path);
    final first = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 10,
    );
    final queued = service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 20,
    );

    await firstStarted.future;
    service.restartSource(source.path);
    releaseFirst.complete();

    expect(await first, isNull);
    expect(await queued, isNull);
    expect(started, <int>[10]);

    final current = await service.thumbnailAtFrame(
      sourcePath: source.path,
      requestedFrame: 30,
    );
    expect(current, isNotNull);
    expect(started, <int>[10, 30]);
  });
}
