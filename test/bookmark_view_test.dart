// test/bookmark_view_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/mlt_thumbnail_bridge.dart';
import 'package:mlt_player/services/storyboard_thumbnail_service.dart';
import 'package:mlt_player/ui/widgets/bookmark_view.dart';

void main() {
  testWidgets('bookmarks toolbar exposes enabled bulk export action', (
    tester,
  ) async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'mlt-player-bookmark-view-test-',
    );
    addTearDown(() async {
      await tempDirectory.delete(recursive: true);
    });

    final sourceFile = File('${tempDirectory.path}/source.mov');
    await sourceFile.writeAsBytes(const <int>[0]);

    final thumbnailService = StoryboardThumbnailService(
      cacheDirectory: Directory('${tempDirectory.path}/cache'),
      generator:
          ({
            required sourcePath,
            required outputPath,
            required width,
            required height,
            required requestedFrame,
          }) async =>
              const MltThumbnailGenerationResult(
                succeeded: false,
                selectedFrame: -1,
                error: 'test thumbnail intentionally unavailable',
              ),
    );

    var exportAllCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkView(
            sourcePath: sourceFile.path,
            sourceFrames: const <int>[12, 48],
            currentSourceFrame: 12,
            thumbnailService: thumbnailService,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (_) {},
            onRemoveFrame: (_) {},
            onExportFrame: (_) {},
            onExportAll: () => exportAllCalls += 1,
            exportEnabled: true,
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('EXPORT ALL'), findsOneWidget);
    expect(find.text('2 keepers'), findsOneWidget);

    await tester.tap(find.text('EXPORT ALL'));
    expect(exportAllCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    thumbnailService.cancelPending();
    await tester.pump();
  });

  testWidgets('bulk export action disables with export controls', (
    tester,
  ) async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'mlt-player-bookmark-view-disabled-test-',
    );
    addTearDown(() async {
      await tempDirectory.delete(recursive: true);
    });

    final sourceFile = File('${tempDirectory.path}/source.mov');
    await sourceFile.writeAsBytes(const <int>[0]);

    final thumbnailService = StoryboardThumbnailService(
      cacheDirectory: Directory('${tempDirectory.path}/cache'),
      generator:
          ({
            required sourcePath,
            required outputPath,
            required width,
            required height,
            required requestedFrame,
          }) async =>
              const MltThumbnailGenerationResult(
                succeeded: false,
                selectedFrame: -1,
                error: 'test thumbnail intentionally unavailable',
              ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkView(
            sourcePath: sourceFile.path,
            sourceFrames: const <int>[12],
            currentSourceFrame: 12,
            thumbnailService: thumbnailService,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (_) {},
            onRemoveFrame: (_) {},
            onExportFrame: (_) {},
            onExportAll: () {},
            exportEnabled: false,
          ),
        ),
      ),
    );

    await tester.pump();

    final exportAllButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'EXPORT ALL'),
    );
    expect(exportAllButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    thumbnailService.cancelPending();
    await tester.pump();
  });
}
