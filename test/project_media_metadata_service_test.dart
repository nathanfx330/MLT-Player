// test/project_media_metadata_service_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/project_catalog_service.dart';
import 'package:mlt_player/services/project_media_metadata_service.dart';

void main() {
  group('ProjectMediaMetadataService', () {
    late Directory root;
    late ProjectCatalogService projects;
    late ProjectMediaMetadataService metadata;
    late String defaultProjectId;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'mlt_project_media_metadata_test_',
      );

      projects = ProjectCatalogService(configDirectory: root);
      await projects.load();
      defaultProjectId = projects.activeProjectId;

      metadata = ProjectMediaMetadataService(
        configDirectory: root,
      );
      await metadata.load(defaultProjectId: defaultProjectId);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('unknown media starts empty inside each project', () {
      const path = '/tmp/clip.mp4';

      expect(metadata.ratingFor(defaultProjectId, path), 0);
      expect(metadata.tagsFor(defaultProjectId, path), isEmpty);
      expect(metadata.colorHexFor(defaultProjectId, path), isNull);
      expect(
        metadata.bookmarkFramesFor(defaultProjectId, path),
        isEmpty,
      );
    });

    test('all media metadata is isolated by project', () {
      final second = projects.createProject('Second Project');
      const path = '/tmp/clip.mp4';

      metadata.setRating(defaultProjectId, path, 5);
      metadata.setTags(
        defaultProjectId,
        path,
        <String>['Interview', 'Select'],
      );
      metadata.setColorHex(defaultProjectId, path, '#e8a33d');
      metadata.addBookmark(defaultProjectId, path, 120);

      expect(metadata.ratingFor(defaultProjectId, path), 5);
      expect(
        metadata.tagsFor(defaultProjectId, path),
        <String>['Interview', 'Select'],
      );
      expect(
        metadata.colorHexFor(defaultProjectId, path),
        '#E8A33D',
      );
      expect(
        metadata.bookmarkFramesFor(defaultProjectId, path),
        <int>[120],
      );

      expect(metadata.ratingFor(second.id, path), 0);
      expect(metadata.tagsFor(second.id, path), isEmpty);
      expect(metadata.colorHexFor(second.id, path), isNull);
      expect(metadata.bookmarkFramesFor(second.id, path), isEmpty);
    });

    test('tags normalize and colors use portable hex strings', () {
      const path = '/tmp/clip.mp4';

      metadata.setTags(
        defaultProjectId,
        path,
        <String>[
          ' interview ',
          'B-Roll',
          'INTERVIEW',
          '',
          'approved',
        ],
      );
      metadata.setColorHex(defaultProjectId, path, '#12abEF');

      expect(
        metadata.tagsFor(defaultProjectId, path),
        <String>['interview', 'B-Roll', 'approved'],
      );
      expect(
        metadata.colorHexFor(defaultProjectId, path),
        '#12ABEF',
      );

      expect(
        () => metadata.setColorHex(
          defaultProjectId,
          path,
          'orange',
        ),
        throwsArgumentError,
      );
    });

    test('rating tag and color filters combine with AND semantics', () {
      const path = '/tmp/filter.mov';

      metadata.setRating(defaultProjectId, path, 4);
      metadata.setTags(
        defaultProjectId,
        path,
        <String>['Interview'],
      );
      metadata.setColorHex(
        defaultProjectId,
        path,
        '#64B5F6',
      );

      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          minimumRating: 4,
          tag: 'interview',
          colorHex: '#64b5f6',
        ),
        isTrue,
      );
      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          minimumRating: 5,
          tag: 'interview',
          colorHex: '#64B5F6',
        ),
        isFalse,
      );
      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          minimumRating: 4,
          tag: 'interview',
          colorHex: '#E57373',
        ),
        isFalse,
      );
    });

    test('exact rating and minimum rating use distinct semantics', () {
      const path = '/tmp/rating-filter.mov';

      metadata.setRating(defaultProjectId, path, 4);

      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          exactRating: 4,
        ),
        isTrue,
      );
      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          exactRating: 5,
        ),
        isFalse,
      );
      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          minimumRating: 4,
        ),
        isTrue,
      );

      metadata.setRating(defaultProjectId, path, 5);

      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          exactRating: 4,
        ),
        isFalse,
      );
      expect(
        metadata.matchesFilters(
          defaultProjectId,
          path,
          minimumRating: 4,
        ),
        isTrue,
      );
    });

    test('bookmark frames stay sorted and unique', () {
      const path = '/tmp/movie.mov';

      expect(
        metadata.addBookmark(defaultProjectId, path, 120),
        isTrue,
      );
      expect(
        metadata.addBookmark(defaultProjectId, path, 24),
        isTrue,
      );
      expect(
        metadata.addBookmark(defaultProjectId, path, 120),
        isFalse,
      );
      expect(
        metadata.addBookmark(defaultProjectId, path, -1),
        isFalse,
      );

      expect(
        metadata.bookmarkFramesFor(defaultProjectId, path),
        <int>[24, 120],
      );

      expect(
        metadata.toggleBookmark(defaultProjectId, path, 24),
        isFalse,
      );
      expect(
        metadata.bookmarkFramesFor(defaultProjectId, path),
        <int>[120],
      );
    });

    test('save and load round-trip sparse project metadata', () async {
      final second = projects.createProject('Second Project');

      metadata.setRating(defaultProjectId, '/tmp/a.mov', 4);
      metadata.addTag(defaultProjectId, '/tmp/a.mov', 'Select');
      metadata.setColorHex(second.id, '/tmp/b.mov', '#336699');
      metadata.addBookmark(second.id, '/tmp/b.mov', 18);
      await metadata.save();

      final reader = ProjectMediaMetadataService(
        configDirectory: root,
      );
      await reader.load(defaultProjectId: defaultProjectId);

      expect(reader.ratingFor(defaultProjectId, '/tmp/a.mov'), 4);
      expect(
        reader.tagsFor(defaultProjectId, '/tmp/a.mov'),
        <String>['Select'],
      );
      expect(
        reader.colorHexFor(second.id, '/tmp/b.mov'),
        '#336699',
      );
      expect(
        reader.bookmarkFramesFor(second.id, '/tmp/b.mov'),
        <int>[18],
      );
      expect(reader.didMigrateLegacyData, isFalse);
    });

    test('legacy annotations and bookmarks migrate to Default Project',
        () async {
      const path = '/tmp/legacy.mov';

      await File('${root.path}/explorer_annotations.json').writeAsString(
        jsonEncode(
          <String, Object>{
            'version': 1,
            'assets': <String, Object>{
              path: <String, Object>{
                'rating': 5,
                'tags': <String>['Interview', 'select'],
              },
            },
          },
        ),
      );

      await File('${root.path}/bookmarks.json').writeAsString(
        jsonEncode(
          <String, Object>{
            'version': 1,
            'media': <String, Object>{
              path: <int>[90, 12, 90],
            },
          },
        ),
      );

      final migrating = ProjectMediaMetadataService(
        configDirectory: root,
      );
      await migrating.load(defaultProjectId: defaultProjectId);

      expect(migrating.didMigrateLegacyData, isTrue);
      expect(migrating.ratingFor(defaultProjectId, path), 5);
      expect(
        migrating.tagsFor(defaultProjectId, path),
        <String>['Interview', 'select'],
      );
      expect(
        migrating.bookmarkFramesFor(defaultProjectId, path),
        <int>[12, 90],
      );

      expect(
        await File('${root.path}/project_media_metadata.json').exists(),
        isTrue,
      );

      // Migration is deliberately non-destructive.
      expect(
        await File('${root.path}/explorer_annotations.json').exists(),
        isTrue,
      );
      expect(
        await File('${root.path}/bookmarks.json').exists(),
        isTrue,
      );
    });

    test('legacy data is never re-imported after new state exists', () async {
      const path = '/tmp/legacy.mov';

      metadata.setRating(defaultProjectId, path, 2);
      await metadata.save();

      await File('${root.path}/explorer_annotations.json').writeAsString(
        jsonEncode(
          <String, Object>{
            'version': 1,
            'assets': <String, Object>{
              path: <String, Object>{
                'rating': 5,
                'tags': <String>['stale'],
              },
            },
          },
        ),
      );

      final reader = ProjectMediaMetadataService(
        configDirectory: root,
      );
      await reader.load(defaultProjectId: defaultProjectId);

      expect(reader.didMigrateLegacyData, isFalse);
      expect(reader.ratingFor(defaultProjectId, path), 2);
      expect(reader.tagsFor(defaultProjectId, path), isEmpty);
    });

    test('Project dashboard summaries are project scoped and counted', () {
      metadata.setRating(defaultProjectId, '/tmp/a.mov', 5);
      metadata.setTags(
        defaultProjectId,
        '/tmp/a.mov',
        <String>['Select', 'Interview'],
      );
      metadata.setRating(defaultProjectId, '/tmp/b.mov', 4);
      metadata.setTags(
        defaultProjectId,
        '/tmp/b.mov',
        <String>['select'],
      );
      metadata.setColorHex(
        defaultProjectId,
        '/tmp/a.mov',
        '#64B5F6',
      );
      metadata.setColorHex(
        defaultProjectId,
        '/tmp/b.mov',
        '#64B5F6',
      );
      metadata.addBookmark(defaultProjectId, '/tmp/a.mov', 10);
      metadata.addBookmark(defaultProjectId, '/tmp/a.mov', 20);
      metadata.addBookmark(defaultProjectId, '/tmp/b.mov', 30);
      metadata.setRating(defaultProjectId, '/tmp/c.mov', 3);

      expect(metadata.ratedMediaCount(defaultProjectId), 3);
      expect(metadata.taggedMediaCount(defaultProjectId), 2);
      expect(metadata.colorLabeledMediaCount(defaultProjectId), 2);
      expect(metadata.bookmarkCount(defaultProjectId), 3);
      expect(metadata.bookmarkedMediaCount(defaultProjectId), 2);
      expect(
        metadata.mediaPathsForProject(defaultProjectId),
        <String>['/tmp/a.mov', '/tmp/b.mov', '/tmp/c.mov'],
      );
      expect(
        metadata.bookmarkedMediaPathsForProject(defaultProjectId),
        <String>['/tmp/a.mov', '/tmp/b.mov'],
      );
      expect(
        metadata.ratingCountsForProject(defaultProjectId),
        <int, int>{1: 0, 2: 0, 3: 1, 4: 1, 5: 1},
      );
      expect(
        metadata.tagCountsForProject(defaultProjectId),
        <String, int>{'Select': 2, 'Interview': 1},
      );
      expect(
        metadata.colorCountsForProject(defaultProjectId),
        <String, int>{'#64B5F6': 2},
      );
    });

    test('malformed new state fails open and does not revive legacy data',
        () async {
      await File('${root.path}/project_media_metadata.json')
          .writeAsString('{not json');
      await File('${root.path}/explorer_annotations.json').writeAsString(
        '{"version":1,"assets":{"/tmp/a.mov":{"rating":5}}}',
      );

      final reader = ProjectMediaMetadataService(
        configDirectory: root,
      );
      await reader.load(defaultProjectId: defaultProjectId);

      expect(reader.ratingFor(defaultProjectId, '/tmp/a.mov'), 0);
      expect(reader.didMigrateLegacyData, isFalse);
      expect(
        await File('${root.path}/explorer_annotations.json').exists(),
        isTrue,
      );
    });
  });
}
