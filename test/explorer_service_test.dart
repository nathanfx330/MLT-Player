// test/explorer_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/services/explorer_service.dart';

void main() {
  group('ExplorerService', () {
    late Directory root;
    late ExplorerService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_explorer_test_');
      service = ExplorerService();

      await Directory('${root.path}/Z Folder').create();
      await Directory('${root.path}/a folder').create();
      await File('${root.path}/clip.MP4').writeAsString('video');
      await File('${root.path}/sound.wav').writeAsString('audio');
      await File('${root.path}/still.PNG').writeAsString('image');
      await File('${root.path}/project.mlt').writeAsString('project');
      await File('${root.path}/ignore.txt').writeAsString('ignore');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('lists folders first and only supported media files', () async {
      final items = await service.scanDirectory(root.path);

      expect(
        items.map((item) => item.name).toList(),
        <String>[
          'a folder',
          'Z Folder',
          'clip.MP4',
          'project.mlt',
          'sound.wav',
          'still.PNG',
        ],
      );

      expect(items[0].kind, ExplorerItemKind.directory);
      expect(items[1].kind, ExplorerItemKind.directory);
      expect(items[2].kind, ExplorerItemKind.video);
      expect(items[3].kind, ExplorerItemKind.project);
      expect(items[4].kind, ExplorerItemKind.audio);
      expect(items[5].kind, ExplorerItemKind.image);
    });

    test('scan captures lightweight stat data for sorting', () async {
      final items = await service.scanDirectory(root.path);
      final clip = items.firstWhere((item) => item.name == 'clip.MP4');
      final folder = items.firstWhere((item) => item.name == 'a folder');

      expect(clip.sizeBytes, 5);
      expect(clip.modified, isNotNull);
      expect(folder.sizeBytes, isNull);
      expect(folder.modified, isNotNull);
    });

    test('extension matching is case insensitive', () {
      expect(service.kindForPath('/tmp/A.MOV'), ExplorerItemKind.video);
      expect(service.kindForPath('/tmp/A.FLAC'), ExplorerItemKind.audio);
      expect(service.kindForPath('/tmp/A.JPEG'), ExplorerItemKind.image);
      expect(service.kindForPath('/tmp/A.XML'), ExplorerItemKind.project);
      expect(service.kindForPath('/tmp/A.TXT'), isNull);
    });
  });
}
