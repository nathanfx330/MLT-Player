// test/redleaf_link_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_link_service.dart';

void main() {
  group('RedleafLinkService', () {
    late Directory root;
    late Directory target;
    late File linkFile;
    late RedleafLinkService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mlt_redleaf_link_test_');
      target = await Directory('${root.path}/external archive').create();
      await Directory('${target.path}/News/1922').create(recursive: true);

      linkFile = File('${root.path}/Archive_Drive.rlink');
      await linkFile.writeAsString(target.path);

      service = RedleafLinkService();
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('reads the Redleaf alias and absolute target directory', () async {
      final link = await service.readLink(linkFile.path);

      expect(link.aliasName, 'Archive_Drive.rlink');
      expect(link.linkPath, linkFile.absolute.path);
      expect(link.targetPath, target.absolute.path);
      expect(link.targetExists, isTrue);
    });

    test('keeps the .rlink name in the virtual address path', () async {
      final link = await service.readLink(linkFile.path);
      final nested = Directory('${target.path}/News/1922').absolute.path;

      expect(
        link.virtualPathFor(target.path),
        'Archive_Drive.rlink',
      );
      expect(
        link.virtualPathFor(nested),
        'Archive_Drive.rlink / News / 1922',
      );
      expect(link.containsPhysicalPath(nested), isTrue);
    });

    test('reports a disconnected removable-drive target', () async {
      final disconnected = File('${root.path}/Offline.rlink');
      await disconnected.writeAsString('${root.path}/not-mounted');

      final link = await service.readLink(disconnected.path);

      expect(link.aliasName, 'Offline.rlink');
      expect(link.targetExists, isFalse);
    });

    test('rejects empty link files', () async {
      final empty = File('${root.path}/Empty.rlink');
      await empty.writeAsString('   \n');

      await expectLater(
        service.readLink(empty.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('extension matching is case insensitive', () {
      expect(service.isRlinkPath('/tmp/Archive.RLINK'), isTrue);
      expect(service.isRlinkPath('/tmp/Archive.rlink'), isTrue);
      expect(service.isRlinkPath('/tmp/Archive.txt'), isFalse);
    });
  });
}
