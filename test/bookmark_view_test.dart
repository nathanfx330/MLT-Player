// test/bookmark_view_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/srt_subtitle_service.dart';
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
            subtitleTrack: null,
            positionMsForSourceFrame: (_) => 0,
            highlightCueStartMsForSourceFrame: (_) => null,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (_) {},
            onOpenTranscriptPosition: (_) {},
            onSetHighlightCueStartMs: (_, __) {},
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
            subtitleTrack: null,
            positionMsForSourceFrame: (_) => 0,
            highlightCueStartMsForSourceFrame: (_) => null,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (_) {},
            onOpenTranscriptPosition: (_) {},
            onSetHighlightCueStartMs: (_, __) {},
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


  testWidgets('bookmark opens profile with contextual transcript and seeks cue', (
    tester,
  ) async {
    final thumbnailService = _NoopThumbnailService();
    int? openedFrame;
    int? openedTranscriptPosition;

    final track = SubtitleTrack(
      path: '/tmp/source.srt',
      cues: const <SubtitleCue>[
        SubtitleCue(
          startMs: 0,
          endMs: 1000,
          text: 'Before the bookmark',
        ),
        SubtitleCue(
          startMs: 1000,
          endMs: 2000,
          text: 'Words at the bookmark',
        ),
        SubtitleCue(
          startMs: 2000,
          endMs: 3000,
          text: 'After the bookmark',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkView(
            sourcePath: '/tmp/source.mov',
            sourceFrames: const <int>[30],
            currentSourceFrame: 30,
            thumbnailService: thumbnailService,
            subtitleTrack: track,
            positionMsForSourceFrame: (_) => 1500,
            highlightCueStartMsForSourceFrame: (_) => null,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (frame) => openedFrame = frame,
            onOpenTranscriptPosition: (positionMs) =>
                openedTranscriptPosition = positionMs,
            onSetHighlightCueStartMs: (_, __) {},
            onRemoveFrame: (_) {},
            onExportFrame: (_) {},
            onExportAll: () {},
            exportEnabled: true,
          ),
        ),
      ),
    );

    await tester.pump();

    await tester.tap(find.text('frame 30'));
    await tester.pumpAndSettle();

    expect(find.text('BOOKMARK PROFILE'), findsOneWidget);
    expect(find.text('TRANSCRIPT AROUND BOOKMARK'), findsOneWidget);
    expect(find.text('Before the bookmark'), findsOneWidget);
    expect(find.text('Words at the bookmark'), findsOneWidget);
    expect(find.text('After the bookmark'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('bookmark-profile-anchor-cue'),
      ),
      findsOneWidget,
    );
    expect(openedFrame, isNull);

    await tester.tap(find.text('After the bookmark'));
    expect(openedTranscriptPosition, 2000);

    await tester.tap(find.text('OPEN IN PLAYER'));
    expect(openedFrame, 30);
  });

  testWidgets('right-click sets a different bookmark highlight line', (
    tester,
  ) async {
    final thumbnailService = _NoopThumbnailService();
    int? highlightStartMs;

    final track = SubtitleTrack(
      path: '/tmp/source.srt',
      cues: const <SubtitleCue>[
        SubtitleCue(
          startMs: 0,
          endMs: 1000,
          text: 'Before the bookmark',
        ),
        SubtitleCue(
          startMs: 1000,
          endMs: 2000,
          text: 'Words at the bookmark',
        ),
        SubtitleCue(
          startMs: 2000,
          endMs: 3000,
          text: 'Chosen highlight line',
        ),
      ],
    );

    Widget buildView() {
      return MaterialApp(
        home: Scaffold(
          body: BookmarkView(
            sourcePath: '/tmp/source.mov',
            sourceFrames: const <int>[30],
            currentSourceFrame: 30,
            thumbnailService: thumbnailService,
            subtitleTrack: track,
            positionMsForSourceFrame: (_) => 1500,
            highlightCueStartMsForSourceFrame: (_) => highlightStartMs,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (_) {},
            onOpenTranscriptPosition: (_) {},
            onSetHighlightCueStartMs: (_, cueStartMs) {
              highlightStartMs = cueStartMs;
            },
            onRemoveFrame: (_) {},
            onExportFrame: (_) {},
            onExportAll: () {},
            exportEnabled: true,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildView());
    await tester.pump();
    await tester.tap(find.text('frame 30'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>('bookmark-profile-anchor-cue'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.text('Chosen highlight line'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Set as highlight line'), findsOneWidget);

    await tester.tap(find.text('Set as highlight line'));
    await tester.pumpAndSettle();

    expect(highlightStartMs, 2000);

    await tester.pumpWidget(buildView());
    await tester.pumpAndSettle();
    await tester.tap(find.text('frame 30'));
    await tester.pumpAndSettle();

    final marker = find.byKey(
      const ValueKey<String>('bookmark-profile-anchor-cue'),
    );
    expect(marker, findsOneWidget);

    expect(
      find.descendant(
        of: marker,
        matching: find.text('Chosen highlight line'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('bookmark profile explains when no SRT is available', (
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
            subtitleTrack: null,
            positionMsForSourceFrame: (_) => 400,
            highlightCueStartMsForSourceFrame: (_) => null,
            formatFrame: (sourceFrame) => 'frame $sourceFrame',
            onAddCurrent: () {},
            onOpenFrame: (_) {},
            onOpenTranscriptPosition: (_) {},
            onSetHighlightCueStartMs: (_, __) {},
            onRemoveFrame: (_) {},
            onExportFrame: (_) {},
            onExportAll: () {},
            exportEnabled: true,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.tap(find.text('frame 12'));
    await tester.pumpAndSettle();

    expect(
      find.text('No SRT transcript is available for this media.'),
      findsOneWidget,
    );
  });
}
