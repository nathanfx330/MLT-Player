// test/bookmark_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/bookmark_service.dart';

void main() {
  group('BookmarkService', () {
    late Directory tempDirectory;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_bookmark_service_test_',
      );
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test('stores exact source frames in sorted unique order', () {
      final service = BookmarkService(configDirectory: tempDirectory);

      expect(service.add('/media/movie.mov', 120), isTrue);
      expect(service.add('/media/movie.mov', 24), isTrue);
      expect(service.add('/media/movie.mov', 120), isFalse);
      expect(service.add('/media/movie.mov', -1), isFalse);

      expect(service.framesFor('/media/movie.mov'), <int>[24, 120]);
    });

    test('toggle adds then removes one soft screenshot', () {
      final service = BookmarkService(configDirectory: tempDirectory);

      expect(service.toggle('/media/movie.mov', 42), isTrue);
      expect(service.contains('/media/movie.mov', 42), isTrue);

      expect(service.toggle('/media/movie.mov', 42), isFalse);
      expect(service.framesFor('/media/movie.mov'), isEmpty);
    });

    test('save and load round-trip per-media bookmarks', () async {
      final writer = BookmarkService(configDirectory: tempDirectory);
      writer.add('/media/a.mov', 3);
      writer.add('/media/a.mov', 100);
      writer.add('/media/b.mov', 7);
      await writer.save();

      final reader = BookmarkService(configDirectory: tempDirectory);
      await reader.load();

      expect(reader.framesFor('/media/a.mov'), <int>[3, 100]);
      expect(reader.framesFor('/media/b.mov'), <int>[7]);
    });

    test('malformed state fails open to an empty bookmark set', () async {
      await tempDirectory.create(recursive: true);
      await File('${tempDirectory.path}/bookmarks.json')
          .writeAsString('{not json');

      final service = BookmarkService(configDirectory: tempDirectory);
      await service.load();

      expect(service.framesFor('/media/movie.mov'), isEmpty);
    });
  });
}
