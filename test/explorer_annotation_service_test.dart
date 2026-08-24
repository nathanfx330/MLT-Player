// test/explorer_annotation_service_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/explorer_annotation_service.dart';

void main() {
  group('ExplorerAnnotationService', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_annotation_test_');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('unknown assets start unrated and untagged', () {
      final service = ExplorerAnnotationService(configDirectory: root);
      final annotation = service.annotationFor('/tmp/clip.mp4');

      expect(annotation.rating, 0);
      expect(annotation.tags, isEmpty);
      expect(annotation.isEmpty, isTrue);
    });

    test('rating is clamped to the supported zero through five range', () {
      final service = ExplorerAnnotationService(configDirectory: root);

      service.setRating('/tmp/clip.mp4', 9);
      expect(service.ratingFor('/tmp/clip.mp4'), 5);

      service.setRating('/tmp/clip.mp4', -4);
      expect(service.ratingFor('/tmp/clip.mp4'), 0);
    });

    test('tags trim whitespace and deduplicate case insensitively', () {
      final service = ExplorerAnnotationService(configDirectory: root);

      service.setTags(
        '/tmp/clip.mp4',
        <String>[' interview ', 'B-Roll', 'INTERVIEW', '', 'approved'],
      );

      expect(
        service.tagsFor('/tmp/clip.mp4'),
        <String>['interview', 'B-Roll', 'approved'],
      );
    });

    test('addTag and removeTag preserve the rating', () {
      final service = ExplorerAnnotationService(configDirectory: root);
      const path = '/tmp/clip.mp4';

      service.setRating(path, 4);
      service.addTag(path, 'hero');
      service.addTag(path, 'Interview');
      service.removeTag(path, 'interview');

      expect(service.ratingFor(path), 4);
      expect(service.tagsFor(path), <String>['hero']);
    });

    test('ratings and tags persist across service instances', () async {
      const path = '/tmp/clip.mp4';
      final first = ExplorerAnnotationService(configDirectory: root);

      first.setRating(path, 5);
      first.setTags(path, <String>['approved', 'select']);
      await first.save();

      final second = ExplorerAnnotationService(configDirectory: root);
      await second.load();

      expect(second.ratingFor(path), 5);
      expect(second.tagsFor(path), <String>['approved', 'select']);
    });

    test('clearing rating and tags removes the sparse asset record', () async {
      const path = '/tmp/clip.mp4';
      final service = ExplorerAnnotationService(configDirectory: root);

      service.setRating(path, 3);
      service.addTag(path, 'temp');
      service.setRating(path, 0);
      service.setTags(path, const <String>[]);
      await service.save();

      final decoded = jsonDecode(
        await File('${root.path}/explorer_annotations.json').readAsString(),
      ) as Map<String, dynamic>;
      final assets = decoded['assets'] as Map<String, dynamic>;

      expect(assets.containsKey(path), isFalse);
    });

    test('malformed persisted data falls back to an empty catalog', () async {
      await File('${root.path}/explorer_annotations.json')
          .writeAsString('{this is not json');

      final service = ExplorerAnnotationService(configDirectory: root);
      await service.load();

      expect(service.annotationFor('/tmp/clip.mp4').isEmpty, isTrue);
    });


    test('minimum rating filter accepts ratings at or above the threshold', () {
      final service = ExplorerAnnotationService(configDirectory: root);
      const path = '/tmp/clip.mp4';

      service.setRating(path, 4);

      expect(service.matchesFilters(path, minimumRating: 3), isTrue);
      expect(service.matchesFilters(path, minimumRating: 4), isTrue);
      expect(service.matchesFilters(path, minimumRating: 5), isFalse);
    });

    test('tag filter matches tags case insensitively', () {
      final service = ExplorerAnnotationService(configDirectory: root);
      const path = '/tmp/clip.mp4';

      service.setTags(path, <String>['Interview', 'Select']);

      expect(service.matchesFilters(path, tag: 'interview'), isTrue);
      expect(service.matchesFilters(path, tag: 'SELECT'), isTrue);
      expect(service.matchesFilters(path, tag: 'b-roll'), isFalse);
    });

    test('rating and tag filters combine with AND semantics', () {
      final service = ExplorerAnnotationService(configDirectory: root);
      const path = '/tmp/clip.mp4';

      service.setRating(path, 4);
      service.setTags(path, <String>['approved']);

      expect(
        service.matchesFilters(
          path,
          minimumRating: 4,
          tag: 'approved',
        ),
        isTrue,
      );
      expect(
        service.matchesFilters(
          path,
          minimumRating: 5,
          tag: 'approved',
        ),
        isFalse,
      );
      expect(
        service.matchesFilters(
          path,
          minimumRating: 4,
          tag: 'reject',
        ),
        isFalse,
      );
    });

    test('unannotated assets match only when annotation filters are inactive', () {
      final service = ExplorerAnnotationService(configDirectory: root);
      const path = '/tmp/clip.mp4';

      expect(service.matchesFilters(path), isTrue);
      expect(service.matchesFilters(path, minimumRating: 1), isFalse);
      expect(service.matchesFilters(path, tag: 'select'), isFalse);
    });

    test('tagsForPaths returns sorted unique tags for the requested assets', () {
      final service = ExplorerAnnotationService(configDirectory: root);

      service.setTags('/tmp/a.mp4', <String>['Select', 'Interview']);
      service.setTags('/tmp/b.mp4', <String>['B-Roll', 'select']);
      service.setTags('/tmp/other.mp4', <String>['Outside']);

      expect(
        service.tagsForPaths(<String>['/tmp/a.mp4', '/tmp/b.mp4']),
        <String>['B-Roll', 'Interview', 'Select'],
      );
    });
  });
}
