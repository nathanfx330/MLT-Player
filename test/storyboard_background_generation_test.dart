// test/storyboard_background_generation_test.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/media_info.dart';
import 'package:mlt_player/services/storyboard_thumbnail_service.dart';
import 'package:mlt_player/ui/widgets/storyboard_view.dart';

class _ControlledStoryboardThumbnailService
    extends StoryboardThumbnailService {
  final Map<int, Completer<String?>> _completers =
      <int, Completer<String?>>{};
  final Set<int> requestedFrames = <int>{};

  @override
  void beginSource(String sourcePath) {}

  Future<String?> _request(int requestedFrame) {
    requestedFrames.add(requestedFrame);
    return _completers
        .putIfAbsent(requestedFrame, () => Completer<String?>())
        .future;
  }

  @override
  Future<String?> thumbnailAtFrame({
    required String sourcePath,
    required int requestedFrame,
  }) {
    return _request(requestedFrame);
  }

  @override
  Future<String?> prefetchAtFrame({
    required String sourcePath,
    required int requestedFrame,
  }) {
    return _request(requestedFrame);
  }

  void completeFrames(Iterable<int> frames) {
    for (final frame in frames) {
      final completer = _completers[frame];
      if (completer != null && !completer.isCompleted) {
        completer.complete(null);
      }
    }
  }
}

const _media = MediaInfo(
  path: '/tmp/storyboard-background.mov',
  width: 1920,
  height: 1080,
  displayAspect: 16 / 9,
  fps: 30,
  frames: 3600,
  durationMs: 120000,
  fileSizeBytes: 1000,
  hasAudio: true,
  isStill: false,
  streamCount: 1,
  streams: <StreamInfo>[],
  videoStreamIndex: 0,
  audioStreamIndex: -1,
  videoCodecName: 'h264',
  videoCodecLongName: 'H.264',
  audioCodecName: '',
  audioCodecLongName: '',
  videoPixelFormat: 'yuv420p',
  videoColorspace: 709,
  videoColorTrc: 1,
  videoColorRange: 'tv',
  sourceTimecode: null,
);

Widget _storyboard(_ControlledStoryboardThumbnailService service) {
  return MaterialApp(
    home: Scaffold(
      body: StoryboardView(
        media: _media,
        durationMs: _media.durationMs,
        positionMs: 0,
        thumbnailService: service,
        sourceFrameForPositionMs: (positionMs) => positionMs ~/ 1000,
        onSeek: (_) {},
        onOpenVideo: (_) {},
        bookmarkedFrames: const <int>{},
        onToggleBookmark: (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets(
    'Storyboard keeps backfilling moments without scrolling and reports progress',
    (tester) async {
      final service = _ControlledStoryboardThumbnailService();

      await tester.pumpWidget(_storyboard(service));
      await tester.pump();

      expect(find.text('0 of 12 moments processed'), findsOneWidget);

      const firstWindow = <int>[0, 10, 20, 30, 40, 50, 60, 70];
      expect(service.requestedFrames, containsAll(firstWindow));

      service.completeFrames(firstWindow);
      await tester.pump();
      await tester.pump();

      expect(find.text('8 of 12 moments processed'), findsOneWidget);

      const finalWindow = <int>[80, 90, 100, 110];
      expect(service.requestedFrames, containsAll(finalWindow));

      service.completeFrames(finalWindow);
      await tester.pump();
      await tester.pump();

      expect(find.text('12 of 12 moments processed'), findsOneWidget);
      expect(
        service.requestedFrames,
        containsAll(<int>[...firstWindow, ...finalWindow]),
      );
    },
  );

  testWidgets(
    'visible islands count immediately without derailing background progress',
    (tester) async {
      final service = _ControlledStoryboardThumbnailService();

      await tester.pumpWidget(_storyboard(service));
      await tester.pump();

      expect(find.text('0 of 12 moments processed'), findsOneWidget);

      await tester.drag(find.byType(GridView), const Offset(0, -1200));
      await tester.pump();

      final islandFrames = service.requestedFrames
          .where((frame) => frame >= 80)
          .toList()
        ..sort();
      expect(islandFrames, isNotEmpty);

      final islandFrame = islandFrames.first;
      service.completeFrames(<int>[islandFrame]);
      await tester.pump();
      await tester.pump();

      expect(find.text('1 of 12 moments processed'), findsOneWidget);

      const firstWindow = <int>[0, 10, 20, 30, 40, 50, 60, 70];
      service.completeFrames(firstWindow);
      await tester.pump();
      await tester.pump();

      expect(find.text('9 of 12 moments processed'), findsOneWidget);

      const finalWindow = <int>[80, 90, 100, 110];
      service.completeFrames(finalWindow);
      await tester.pump();
      await tester.pump();

      expect(find.text('12 of 12 moments processed'), findsOneWidget);
    },
  );
}
