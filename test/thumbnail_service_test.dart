// test/thumbnail_service_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/services/mlt_thumbnail_bridge.dart';
import 'package:mlt_player/services/thumbnail_service.dart';

ExplorerItem _video(File file) {
  return ExplorerItem.media(file, ExplorerItemKind.video);
}

MltThumbnailGenerationResult _success({int selectedFrame = 0}) {
  return MltThumbnailGenerationResult(
    succeeded: true,
    selectedFrame: selectedFrame,
    error: '',
  );
}

void main() {
  group('ThumbnailService', () {
    late Directory root;
    late Directory cache;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_thumbnail_test_');
      cache = Directory('${root.path}${Platform.pathSeparator}cache');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('generates once and reuses the persistent cache entry', () async {
      final source = File('${root.path}${Platform.pathSeparator}clip.mp4');
      await source.writeAsBytes(<int>[1, 2, 3, 4]);

      var runs = 0;
      final service = ThumbnailService(
        cacheDirectory: cache,
        generator: ({
          required sourcePath,
          required outputPath,
          required width,
          required height,
        }) async {
          runs++;
          expect(sourcePath, source.absolute.path);
          expect(width, ThumbnailService.thumbnailWidth);
          expect(height, ThumbnailService.thumbnailHeight);
          await File(outputPath).writeAsBytes(<int>[9, 8, 7]);
          return _success(selectedFrame: 42);
        },
      );

      final first = await service.thumbnailFor(_video(source));
      final secondService = ThumbnailService(
        cacheDirectory: cache,
        generator: ({
          required sourcePath,
          required outputPath,
          required width,
          required height,
        }) async {
          runs++;
          return const MltThumbnailGenerationResult(
            succeeded: false,
            selectedFrame: -1,
            error: 'cache miss',
          );
        },
      );
      final second = await secondService.thumbnailFor(_video(source));

      expect(first, isNotNull);
      expect(second, first);
      expect(await File(first!).exists(), isTrue);
      expect(runs, 1);
    });

    test('source size change creates a new cache identity', () async {
      final source = File('${root.path}${Platform.pathSeparator}clip.mov');
      await source.writeAsBytes(<int>[1, 2, 3]);

      var runs = 0;
      final service = ThumbnailService(
        cacheDirectory: cache,
        generator: ({
          required sourcePath,
          required outputPath,
          required width,
          required height,
        }) async {
          runs++;
          await File(outputPath).writeAsBytes(<int>[runs]);
          return _success(selectedFrame: runs);
        },
      );

      final first = await service.thumbnailFor(_video(source));
      await source.writeAsBytes(<int>[1, 2, 3, 4, 5, 6]);
      final second = await service.thumbnailFor(_video(source));

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second, isNot(equals(first)));
      expect(runs, 2);
    });

    test('pause drains active work and cancels queued generation', () async {
      final firstSource =
          File('${root.path}${Platform.pathSeparator}first.mp4');
      final secondSource =
          File('${root.path}${Platform.pathSeparator}second.mp4');
      await firstSource.writeAsBytes(<int>[1, 2, 3]);
      await secondSource.writeAsBytes(<int>[4, 5, 6]);

      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var runs = 0;

      final service = ThumbnailService(
        cacheDirectory: cache,
        maxConcurrent: 1,
        generator: ({
          required sourcePath,
          required outputPath,
          required width,
          required height,
        }) async {
          runs++;
          if (runs == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          await File(outputPath).writeAsBytes(<int>[runs]);
          return _success(selectedFrame: runs);
        },
      );

      final first = service.thumbnailFor(_video(firstSource));
      await firstStarted.future;

      // This request is admitted into the service but waits behind the first
      // worker's single permit.
      final second = service.thumbnailFor(_video(secondSource));

      final drain = service.pauseAndDrain();
      Timer(const Duration(milliseconds: 10), () => releaseFirst.complete());
      await drain;

      expect(await first, isNotNull);
      expect(await second, isNull);
      expect(service.paused, isTrue);
      expect(runs, 1);

      // New requests remain inert while the Player owns the foreground.
      expect(await service.thumbnailFor(_video(secondSource)), isNull);
      expect(runs, 1);

      service.resume();
      expect(await service.thumbnailFor(_video(secondSource)), isNotNull);
      expect(service.paused, isFalse);
      expect(runs, 2);
    });

    test('unsupported items never launch a thumbnail worker', () async {
      final source = File('${root.path}${Platform.pathSeparator}sound.wav');
      await source.writeAsBytes(<int>[1, 2, 3]);

      var runs = 0;
      final service = ThumbnailService(
        cacheDirectory: cache,
        generator: ({
          required sourcePath,
          required outputPath,
          required width,
          required height,
        }) async {
          runs++;
          return _success();
        },
      );

      final item = ExplorerItem.media(source, ExplorerItemKind.audio);
      final result = await service.thumbnailFor(item);

      expect(result, isNull);
      expect(runs, 0);
    });

    test('native generation failure is retained as a diagnostic', () async {
      final source = File('${root.path}${Platform.pathSeparator}broken.mp4');
      await source.writeAsBytes(<int>[1, 2, 3]);

      final service = ThumbnailService(
        cacheDirectory: cache,
        generator: ({
          required sourcePath,
          required outputPath,
          required width,
          required height,
        }) async {
          return const MltThumbnailGenerationResult(
            succeeded: false,
            selectedFrame: -1,
            error: 'MLT could not decode a representative thumbnail frame.',
          );
        },
      );

      final result = await service.thumbnailFor(_video(source));

      expect(result, isNull);
      expect(
        service.failureFor(source.absolute.path),
        'MLT could not decode a representative thumbnail frame.',
      );
    });
  });
}
