// test/explorer_navigation_service_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/explorer_navigation_service.dart';

void main() {
  group('ExplorerNavigationService', () {
    late Directory root;
    late Directory config;
    late ExplorerNavigationService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_nav_test_');
      config = Directory('${root.path}/config');
      service = ExplorerNavigationService(
        configDirectory: config,
        homePath: '${root.path}/home',
        recentLimit: 3,
        historyLimit: 6,
      );
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('history supports back, forward, and forward truncation', () {
      service.recordVisit('${root.path}/A');
      service.recordVisit('${root.path}/B');
      service.recordVisit('${root.path}/C');

      expect(service.canGoBack, isTrue);
      expect(service.backPath, Directory('${root.path}/B').absolute.path);

      service.commitBack();
      expect(service.forwardPath, Directory('${root.path}/C').absolute.path);

      service.recordVisit('${root.path}/D');
      expect(service.canGoForward, isFalse);
      expect(service.backPath, Directory('${root.path}/B').absolute.path);
    });

    test('revisiting the current folder does not duplicate history', () {
      service.recordVisit('${root.path}/A');
      service.recordVisit('${root.path}/A');

      expect(service.canGoBack, isFalse);
      expect(service.canGoForward, isFalse);
      expect(service.recents, <String>[Directory('${root.path}/A').absolute.path]);
    });

    test('favorites and recents persist across service instances', () async {
      service.toggleFavorite('${root.path}/Favorite B');
      service.toggleFavorite('${root.path}/Favorite A');
      service.recordVisit('${root.path}/One');
      service.recordVisit('${root.path}/Two');
      await service.save();

      final restored = ExplorerNavigationService(
        configDirectory: config,
        homePath: '${root.path}/home',
        recentLimit: 3,
      );
      await restored.load();

      expect(
        restored.favorites,
        <String>[
          Directory('${root.path}/Favorite A').absolute.path,
          Directory('${root.path}/Favorite B').absolute.path,
        ],
      );
      expect(
        restored.recents,
        <String>[
          Directory('${root.path}/Two').absolute.path,
          Directory('${root.path}/One').absolute.path,
        ],
      );
    });

    test('long location history persists independently of recents', () async {
      for (final name in <String>['A', 'B', 'C', 'D', 'E']) {
        service.recordVisit('${root.path}/$name');
      }
      await service.save();

      final restored = ExplorerNavigationService(
        configDirectory: config,
        homePath: '${root.path}/home',
        recentLimit: 3,
        historyLimit: 6,
      );
      await restored.load();

      expect(
        restored.recents,
        <String>[
          Directory('${root.path}/E').absolute.path,
          Directory('${root.path}/D').absolute.path,
          Directory('${root.path}/C').absolute.path,
        ],
      );
      expect(
        restored.locationHistory,
        <String>[
          Directory('${root.path}/E').absolute.path,
          Directory('${root.path}/D').absolute.path,
          Directory('${root.path}/C').absolute.path,
          Directory('${root.path}/B').absolute.path,
          Directory('${root.path}/A').absolute.path,
        ],
      );
    });

    test('clearing recents leaves long history intact', () {
      service.recordVisit('${root.path}/A');
      service.recordVisit('${root.path}/B');

      service.clearRecents();

      expect(service.recents, isEmpty);
      expect(
        service.locationHistory,
        <String>[
          Directory('${root.path}/B').absolute.path,
          Directory('${root.path}/A').absolute.path,
        ],
      );
    });

    test('reopening current folder repopulates cleared history', () {
      service.recordVisit('${root.path}/A');
      service.clearLocationHistory();

      service.recordVisit('${root.path}/A');

      expect(
        service.locationHistory,
        <String>[Directory('${root.path}/A').absolute.path],
      );
    });

    test('clearing location history leaves recents and back stack intact', () {
      service.recordVisit('${root.path}/A');
      service.recordVisit('${root.path}/B');
      service.recordVisit('${root.path}/C');

      service.clearLocationHistory();

      expect(service.locationHistory, isEmpty);
      expect(service.recents, isNotEmpty);
      expect(service.canGoBack, isTrue);
      expect(
        service.backPath,
        Directory('${root.path}/B').absolute.path,
      );
    });

    test('recent folders are unique, newest first, and capped', () {
      service.recordVisit('${root.path}/A');
      service.recordVisit('${root.path}/B');
      service.recordVisit('${root.path}/C');
      service.recordVisit('${root.path}/A');
      service.recordVisit('${root.path}/D');

      expect(
        service.recents,
        <String>[
          Directory('${root.path}/D').absolute.path,
          Directory('${root.path}/A').absolute.path,
          Directory('${root.path}/C').absolute.path,
        ],
      );
    });

    test('corrupt persisted state is ignored safely', () async {
      await config.create(recursive: true);
      await File('${config.path}/explorer_locations.json')
          .writeAsString('{ definitely not json');

      await service.load();

      expect(service.favorites, isEmpty);
      expect(service.recents, isEmpty);
    });

    test('unknown persisted fields do not disturb known location state', () async {
      await config.create(recursive: true);
      await File('${config.path}/explorer_locations.json').writeAsString(
        jsonEncode(<String, Object>{
          'version': 99,
          'favorites': <String>['${root.path}/Fav'],
          'recents': <String>['${root.path}/Recent'],
          'futureField': true,
        }),
      );

      await service.load();

      expect(service.isFavorite('${root.path}/Fav'), isTrue);
      expect(
        service.recents.single,
        Directory('${root.path}/Recent').absolute.path,
      );
    });
  });
}
