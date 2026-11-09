// test/redleaf_linked_video_card_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/services/redleaf_media_resource_service.dart';
import 'package:mlt_player/services/redleaf_srt_service.dart';
import 'package:mlt_player/services/thumbnail_service.dart';
import 'package:mlt_player/ui/widgets/explorer_media_card.dart';
import 'package:mlt_player/ui/widgets/redleaf_linked_video_card.dart';

class _FakeMediaResolver extends RedleafMediaResourceService {
  _FakeMediaResolver(this.answer);

  final RedleafMediaResourceResolution answer;
  int calls = 0;

  @override
  Future<RedleafMediaResourceResolution> resolve(
    RedleafSrtDocument document,
  ) async {
    calls += 1;
    return answer;
  }
}

class _FakeThumbnailService extends ThumbnailService {
  int calls = 0;
  String? lastSource;

  @override
  Future<String?> thumbnailFor(ExplorerItem item) async {
    calls += 1;
    lastSource = item.path;
    return null;
  }
}

RedleafSrtDocument _document({
  String? path = '/serve_doc/my-media.rlink/interview.mp4',
  String type = 'video',
  String source = 'local',
}) {
  return RedleafSrtDocument(
    docId: 4711,
    relativePath: 'interviews/volunteer.srt',
    status: 'indexed',
    media: RedleafMediaLink(
      state: RedleafMediaLinkState.linked,
      path: path,
      type: type,
      source: source,
    ),
  );
}

Future<void> _showCard(
  WidgetTester tester, {
  required RedleafMediaResourceService resources,
  required ThumbnailService thumbnails,
  bool connected = true,
  VoidCallback? onTap,
  VoidCallback? onDoubleTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            height: 178,
            child: RedleafLinkedVideoCard(
              document: _document(),
              mediaResources: resources,
              thumbnailService: thumbnails,
              active: true,
              connectedToProject: connected,
              selected: false,
              onTap: onTap ?? () {},
              onDoubleTap: onDoubleTap ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('verified local Redleaf video uses normal Explorer card and MLT thumbnail',
      (tester) async {
    final resources = _FakeMediaResolver(
      const RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.localFileReady,
        redleafReference: '/serve_doc/my-media.rlink/interview.mp4',
        resolvedResource: '/media/archive/interview.mp4',
        message: 'Verified',
      ),
    );
    final thumbnails = _FakeThumbnailService();
    var taps = 0;

    await _showCard(
      tester,
      resources: resources,
      thumbnails: thumbnails,
      onTap: () => taps += 1,
    );

    expect(find.byType(ExplorerMediaCard), findsOneWidget);
    expect(find.text('interview.mp4'), findsOneWidget);
    expect(find.text('VIDEO · SRT #4711'), findsOneWidget);
    expect(resources.calls, 1);
    expect(thumbnails.calls, 1);
    expect(thumbnails.lastSource, '/media/archive/interview.mp4');

    await tester.tap(find.text('interview.mp4'));
    // InkWell waits for the double-tap timeout before dispatching onTap.
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1);
  });

  testWidgets('offline Redleaf video never attempts filesystem resolution or MLT',
      (tester) async {
    final resources = _FakeMediaResolver(
      const RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.localFileReady,
        redleafReference: '/serve_doc/my-media.rlink/interview.mp4',
        resolvedResource: '/media/archive/interview.mp4',
        message: 'Verified',
      ),
    );
    final thumbnails = _FakeThumbnailService();

    await _showCard(
      tester,
      connected: false,
      resources: resources,
      thumbnails: thumbnails,
    );

    expect(resources.calls, 0);
    expect(thumbnails.calls, 0);
    expect(find.text('VIDEO OFFLINE · SRT #4711'), findsOneWidget);
    expect(find.byType(ExplorerMediaCard), findsOneWidget);
  });

  testWidgets('external web media never enters native MLT thumbnail decoder',
      (tester) async {
    final resources = _FakeMediaResolver(
      const RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.webUrlCandidate,
        redleafReference: 'https://example.org/video.mp4',
        resolvedResource: 'https://example.org/video.mp4',
        message: 'Unverified web resource',
      ),
    );
    final thumbnails = _FakeThumbnailService();

    await _showCard(
      tester,
      resources: resources,
      thumbnails: thumbnails,
    );

    expect(resources.calls, 1);
    expect(thumbnails.calls, 0);
    expect(find.text('VIDEO UNAVAILABLE · SRT #4711'), findsOneWidget);
    expect(find.byType(ExplorerMediaCard), findsOneWidget);
  });
}
