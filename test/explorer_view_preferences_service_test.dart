// test/explorer_view_preferences_service_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/explorer_sort_filter_service.dart';
import 'package:mlt_player/services/explorer_view_preferences_service.dart';

void main() {
  group('ExplorerViewPreferencesService', () {
    late Directory root;
    late Directory config;
    late ExplorerViewPreferencesService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_view_prefs_test_');
      config = Directory('${root.path}/config');
      service = ExplorerViewPreferencesService(configDirectory: config);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('defaults to Standard density', () {
      expect(
        service.densityIndex,
        ExplorerViewPreferencesService.defaultDensityIndex,
      );
      expect(service.densityLabel, 'Standard');
      expect(service.thumbnailExtent, 190);
      expect(service.cardHeight, 150);
    });

    test('density index clamps to the supported five steps', () {
      service.setDensityIndex(-50);
      expect(
        service.densityIndex,
        ExplorerViewPreferencesService.minDensityIndex,
      );
      expect(service.densityLabel, 'Compact');

      service.setDensityIndex(50);
      expect(
        service.densityIndex,
        ExplorerViewPreferencesService.maxDensityIndex,
      );
      expect(service.densityLabel, 'Extra Large');
    });

    test('density changes card size and spacing together', () {
      service.setDensityIndex(0);
      final compactExtent = service.thumbnailExtent;
      final compactHeight = service.cardHeight;
      final compactSpacing = service.gridSpacing;

      service.setDensityIndex(4);

      expect(service.thumbnailExtent, greaterThan(compactExtent));
      expect(service.cardHeight, greaterThan(compactHeight));
      expect(service.gridSpacing, greaterThan(compactSpacing));
    });

    test('density persists across service instances', () async {
      service.setDensityIndex(4);
      await service.save();

      final restored = ExplorerViewPreferencesService(configDirectory: config);
      await restored.load();

      expect(restored.densityIndex, 4);
      expect(restored.densityLabel, 'Extra Large');
    });

    test('corrupt persisted state falls back to Standard safely', () async {
      await config.create(recursive: true);
      await File('${config.path}/explorer_view.json')
          .writeAsString('{ not valid json');

      service.setDensityIndex(0);
      service.setSortMode(ExplorerSortMode.size);
      service.setSortDescending(true);
      await service.load();

      expect(
        service.densityIndex,
        ExplorerViewPreferencesService.defaultDensityIndex,
      );
      expect(service.densityLabel, 'Standard');
      expect(service.sortMode, ExplorerSortMode.name);
      expect(service.sortDescending, isFalse);
    });

    test('sort defaults to Name ascending', () {
      expect(service.sortMode, ExplorerSortMode.name);
      expect(service.sortDescending, isFalse);
    });

    test('sort mode and direction persist across instances', () async {
      service.setSortMode(ExplorerSortMode.modified);
      service.setSortDescending(true);
      await service.save();

      final restored = ExplorerViewPreferencesService(configDirectory: config);
      await restored.load();

      expect(restored.sortMode, ExplorerSortMode.modified);
      expect(restored.sortDescending, isTrue);
    });

    test('legacy density-only state keeps safe sort defaults', () async {
      await config.create(recursive: true);
      await File('${config.path}/explorer_view.json').writeAsString(
        jsonEncode(<String, Object>{
          'version': 1,
          'thumbnailDensity': 4,
        }),
      );

      await service.load();

      expect(service.densityIndex, 4);
      expect(service.sortMode, ExplorerSortMode.name);
      expect(service.sortDescending, isFalse);
    });

    test('unknown persisted sort mode is ignored safely', () async {
      await config.create(recursive: true);
      await File('${config.path}/explorer_view.json').writeAsString(
        jsonEncode(<String, Object>{
          'version': 2,
          'thumbnailDensity': 1,
          'sortMode': 'not-a-real-mode',
          'sortDescending': true,
        }),
      );

      await service.load();

      expect(service.densityIndex, 1);
      expect(service.sortMode, ExplorerSortMode.name);
      expect(service.sortDescending, isTrue);
    });
  });
}
