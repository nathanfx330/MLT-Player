// test/explorer_sort_filter_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/services/explorer_sort_filter_service.dart';

void main() {
  group('ExplorerSortFilterService', () {
    late ExplorerSortFilterService service;
    late List<ExplorerItem> items;

    setUp(() {
      service = ExplorerSortFilterService();
      items = <ExplorerItem>[
        ExplorerItem(
          path: '/tmp/Z Folder',
          name: 'Z Folder',
          kind: ExplorerItemKind.directory,
          modified: DateTime(2026, 8, 20),
        ),
        ExplorerItem(
          path: '/tmp/a folder',
          name: 'a folder',
          kind: ExplorerItemKind.directory,
          modified: DateTime(2026, 8, 24),
        ),
        ExplorerItem(
          path: '/tmp/big.mov',
          name: 'big.mov',
          kind: ExplorerItemKind.video,
          sizeBytes: 900,
          modified: DateTime(2026, 8, 23),
        ),
        ExplorerItem(
          path: '/tmp/alpha.png',
          name: 'alpha.png',
          kind: ExplorerItemKind.image,
          sizeBytes: 100,
          modified: DateTime(2026, 8, 21),
        ),
        ExplorerItem(
          path: '/tmp/music.wav',
          name: 'music.wav',
          kind: ExplorerItemKind.audio,
          sizeBytes: 500,
          modified: DateTime(2026, 8, 22),
        ),
        ExplorerItem(
          path: '/tmp/project.mlt',
          name: 'project.mlt',
          kind: ExplorerItemKind.project,
          sizeBytes: 50,
          modified: DateTime(2026, 8, 24),
        ),
      ];
    });

    test('Name sort is case-insensitive and keeps folders first', () {
      final result = service.apply(items);

      expect(
        result.map((item) => item.name),
        <String>[
          'a folder',
          'Z Folder',
          'alpha.png',
          'big.mov',
          'music.wav',
          'project.mlt',
        ],
      );
    });

    test('descending sort still keeps the folder group above media', () {
      final result = service.apply(items, descending: true);

      expect(result.take(2).every((item) => item.isDirectory), isTrue);
      expect(result.skip(2).every((item) => !item.isDirectory), isTrue);
      expect(result.first.name, 'Z Folder');
      expect(result[2].name, 'project.mlt');
    });

    test('Size sort orders media by byte size', () {
      final result = service.apply(items, sortMode: ExplorerSortMode.size);

      expect(
        result.skip(2).map((item) => item.name),
        <String>['project.mlt', 'alpha.png', 'music.wav', 'big.mov'],
      );
    });

    test('Modified sort uses captured filesystem modification time', () {
      final result = service.apply(
        items,
        sortMode: ExplorerSortMode.modified,
        descending: true,
      );

      expect(result.take(2).map((item) => item.name), <String>['a folder', 'Z Folder']);
      expect(result[2].name, 'project.mlt');
      expect(result.last.name, 'alpha.png');
    });

    test('Type sort groups media kinds before extension/name tie breaks', () {
      final result = service.apply(items, sortMode: ExplorerSortMode.type);

      expect(
        result.skip(2).map((item) => item.kind),
        <ExplorerItemKind>[
          ExplorerItemKind.audio,
          ExplorerItemKind.image,
          ExplorerItemKind.project,
          ExplorerItemKind.video,
        ],
      );
    });

    test('filter is current-list, case-insensitive, and does not mutate input', () {
      final originalNames = items.map((item) => item.name).toList();
      final result = service.apply(items, query: 'ALP');

      expect(result.map((item) => item.name), <String>['alpha.png']);
      expect(items.map((item) => item.name), originalNames);
    });
  });
}
