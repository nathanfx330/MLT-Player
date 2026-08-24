// test/explorer_metadata_service_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/services/explorer_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExplorerMetadataService', () {
    late Directory root;
    late ExplorerMetadataService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_explorer_metadata_');
      service = ExplorerMetadataService();
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('reports file size and modification time without opening media', () async {
      final file = File('${root.path}/clip.mp4');
      await file.writeAsString('video');

      final metadata = await service.metadataFor(
        ExplorerItem.media(file, ExplorerItemKind.video),
      );

      expect(metadata.byteSize, 5);
      expect(metadata.modified.year, greaterThanOrEqualTo(2020));
      expect(metadata.pixelWidth, isNull);
      expect(metadata.pixelHeight, isNull);
    });

    test('decodes dimensions only for the selected image', () async {
      final file = File('${root.path}/still.png');
      await file.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAFklEQVR4nGP8z8Dwn4GBgYGJAQrgDAAxOwIE7x6DkQAAAABJRU5ErkJggg==',
        ),
      );

      final metadata = await service.metadataFor(
        ExplorerItem.media(file, ExplorerItemKind.image),
      );

      expect(metadata.pixelWidth, 2);
      expect(metadata.pixelHeight, 3);
      expect(metadata.hasDimensions, isTrue);
    });

    test('does not report a recursive byte size for folders', () async {
      final directory = Directory('${root.path}/folder');
      await directory.create();
      await File('${directory.path}/inside.bin').writeAsString('contents');

      final metadata = await service.metadataFor(
        ExplorerItem.directory(directory),
      );

      expect(metadata.byteSize, isNull);
      expect(metadata.hasDimensions, isFalse);
    });

    test('cache invalidates when file size changes', () async {
      final file = File('${root.path}/sound.wav');
      await file.writeAsString('a');
      final item = ExplorerItem.media(file, ExplorerItemKind.audio);

      final first = await service.metadataFor(item);
      expect(first.byteSize, 1);

      await file.writeAsString('abcd');

      final second = await service.metadataFor(item);
      expect(second.byteSize, 4);
      expect(identical(first, second), isFalse);
    });
  });
}
