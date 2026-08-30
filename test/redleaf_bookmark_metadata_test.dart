// test/redleaf_bookmark_metadata_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/project_media_metadata_service.dart';

void main() {
  test('Redleaf bookmark namespace survives save and reload', () async {
    final root = await Directory.systemTemp.createTemp(
      'mlt_redleaf_bookmark_metadata_test_',
    );

    try {
      const localProjectId = 'local-project';
      const redleafProjectId = 'redleaf:instance-123';
      final media = File('${root.path}/interview.mp4');
      await media.writeAsBytes(List<int>.filled(64, 1));

      final writer = ProjectMediaMetadataService(configDirectory: root);
      await writer.load(defaultProjectId: localProjectId);

      expect(
        writer.addBookmark(redleafProjectId, media.path, 240),
        isTrue,
      );
      expect(
        writer.addBookmark(redleafProjectId, media.path, 48),
        isTrue,
      );
      await writer.save();

      final reader = ProjectMediaMetadataService(configDirectory: root);
      await reader.load(defaultProjectId: localProjectId);

      expect(
        reader.bookmarkFramesFor(redleafProjectId, media.path),
        <int>[48, 240],
      );
      expect(
        reader.bookmarkFramesFor(localProjectId, media.path),
        isEmpty,
      );
    } finally {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
  });
}
