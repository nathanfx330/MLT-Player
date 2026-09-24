// test/bookmark_view_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/storyboard_thumbnail_service.dart';
import 'package:mlt_player/ui/widgets/bookmark_view.dart';

class _NoopThumbnailService extends StoryboardThumbnailService {
  @override
  void beginSource(String sourcePath) {}

  @override
  void cancelPending() {}

  @override
  Future<String?> thumbnailAtFrame({
    required String sourcePath,
    required int requestedFrame,
  }) async {
    return null;
  }
}

void main() {
  testWidgets('bookmarks toolbar exposes enabled bulk export action', (
    tester,
  ) async {
    final thumbnailService = _NoopThumbnailService();
    var exportAllCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkView(
            sourcePath: '/tmp/source.mov',
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
  });

  testWidgets('bulk export action disables with export controls', (
    tester,
  ) async {
    final thumbnailService = _NoopThumbnailService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkView(
            sourcePath: '/tmp/source.mov',
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
  });
}
