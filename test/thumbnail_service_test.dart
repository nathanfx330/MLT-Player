// test/thumbnail_service_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/services/thumbnail_service.dart';

ExplorerItem _video(File file) {
  return ExplorerItem.media(file, ExplorerItemKind.video);
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
        processRunner: (executable, arguments) async {
          runs++;
          expect(executable, 'ffmpeg');
          final output = File(arguments.last);
          await output.writeAsBytes(<int>[9, 8, 7]);
          return ProcessResult(1, 0, '', '');
        },
      );

      final first = await service.thumbnailFor(_video(source));
      final secondService = ThumbnailService(
        cacheDirectory: cache,
        processRunner: (executable, arguments) async {
          runs++;
          return ProcessResult(1, 1, '', 'cache miss');
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
        processRunner: (executable, arguments) async {
          runs++;
          await File(arguments.last).writeAsBytes(<int>[runs]);
          return ProcessResult(1, 0, '', '');
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
        processRunner: (executable, arguments) async {
          runs++;
          if (runs == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          await File(arguments.last).writeAsBytes(<int>[runs]);
          return ProcessResult(1, 0, '', '');
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
        processRunner: (executable, arguments) async {
          runs++;
          return ProcessResult(1, 0, '', '');
        },
      );

      final item = ExplorerItem.media(source, ExplorerItemKind.audio);
      final result = await service.thumbnailFor(item);

      expect(result, isNull);
      expect(runs, 0);
    });
  });
}
