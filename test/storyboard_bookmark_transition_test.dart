// test/storyboard_bookmark_transition_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/media_info.dart';
import 'package:mlt_player/services/storyboard_thumbnail_service.dart';
import 'package:mlt_player/ui/widgets/bookmark_view.dart';
import 'package:mlt_player/ui/widgets/storyboard_view.dart';

class _TrackingThumbnailService extends StoryboardThumbnailService {
  int beginCalls = 0;
  int cancelCalls = 0;

  @override
  void beginSource(String sourcePath) {
    beginCalls += 1;
  }

  @override
  void cancelPending() {
    cancelCalls += 1;
  }

  @override
  Future<String?> thumbnailAtFrame({
    required String sourcePath,
    required int requestedFrame,
  }) async {
    return null;
  }
}

const _media = MediaInfo(
  path: '/tmp/source.mov',
  width: 1920,
  height: 1080,
  displayAspect: 16 / 9,
  fps: 30,
  frames: 300,
  durationMs: 10000,
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

Widget _storyboard(_TrackingThumbnailService service) {
  return MaterialApp(
    home: Scaffold(
      body: StoryboardView(
        media: _media,
        durationMs: 10000,
        positionMs: 0,
        thumbnailService: service,
        sourceFrameForPositionMs: (positionMs) => positionMs ~/ 33,
        onSeek: (_) {},
        onOpenVideo: (_) {},
        bookmarkedFrames: const <int>{},
        onToggleBookmark: (_) {},
      ),
    ),
  );
}

Widget _bookmarks(_TrackingThumbnailService service) {
  return MaterialApp(
    home: Scaffold(
      body: BookmarkView(
        sourcePath: _media.path,
        sourceFrames: const <int>[30],
        currentSourceFrame: 30,
        thumbnailService: service,
        subtitleTrack: null,
        positionMsForSourceFrame: (_) => 1000,
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
  );
}

void main() {
  testWidgets(
    'direct Storyboard and Bookmarks replacement does not cancel shared lane',
    (tester) async {
      final service = _TrackingThumbnailService();

      await tester.pumpWidget(_storyboard(service));
      await tester.pump();

      expect(service.beginCalls, 1);
      expect(service.cancelCalls, 0);

      await tester.pumpWidget(_bookmarks(service));
      await tester.pump();

      expect(service.beginCalls, 2);
      expect(service.cancelCalls, 0);

      await tester.pumpWidget(_storyboard(service));
      await tester.pump();

      expect(service.beginCalls, 3);
      expect(service.cancelCalls, 0);
    },
  );
}
