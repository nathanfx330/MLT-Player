// test/redleaf_thumbnail_handoff_recovery_test.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/explorer_item.dart';
import 'package:mlt_player/models/redleaf_player_handoff.dart';
import 'package:mlt_player/models/workspace_project.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_media_resource_service.dart';
import 'package:mlt_player/services/redleaf_project_snapshot_service.dart';
import 'package:mlt_player/services/redleaf_srt_service.dart';
import 'package:mlt_player/services/redleaf_transcript_service.dart';
import 'package:mlt_player/services/srt_subtitle_service.dart';
import 'package:mlt_player/services/thumbnail_service.dart';
import 'package:mlt_player/ui/redleaf_page.dart';
import 'package:mlt_player/ui/widgets/redleaf_linked_video_card.dart';

class _ConnectedRedleaf extends RedleafConnectionService {
  @override
  bool get isConnected => true;

  @override
  String get instanceId => 'thumbnail-recovery';

  @override
  String get projectName => 'Thumbnail recovery';

  @override
  Future<void> load() async {}
}

RedleafSrtDocument _document(int id, String name) => RedleafSrtDocument(
      docId: id,
      relativePath: 'transcripts/$name.srt',
      status: 'indexed',
      media: RedleafMediaLink(
        state: RedleafMediaLinkState.linked,
        path: '/serve_doc/$name.mp4',
        type: 'video',
        source: 'local',
      ),
    );

class _Snapshots extends RedleafProjectSnapshotService {
  @override
  Future<RedleafProjectSnapshot?> load(String instanceId) async =>
      RedleafProjectSnapshot(
        instanceId: instanceId,
        syncedAt: DateTime.utc(2026, 11, 9),
        documents: <RedleafSrtDocument>[
          _document(1, 'alpha'),
          _document(2, 'beta'),
        ],
        catalogs: const [],
        catalogMemberships: const {},
      );
}

class _MediaResources extends RedleafMediaResourceService {
  bool holdBetaSelection = false;
  final Completer<RedleafMediaResourceResolution> delayedBeta =
      Completer<RedleafMediaResourceResolution>();

  RedleafMediaResourceResolution _answer(RedleafSrtDocument document) =>
      RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.localFileReady,
        redleafReference: document.media.path,
        resolvedResource: '/archive/${document.docId == 1 ? 'alpha' : 'beta'}.mp4',
      );

  @override
  Future<RedleafMediaResourceResolution> resolve(
    RedleafSrtDocument document,
  ) {
    if (document.docId == 2 && holdBetaSelection) {
      return delayedBeta.future;
    }
    return Future<RedleafMediaResourceResolution>.value(_answer(document));
  }

  void releaseBetaSelection() {
    delayedBeta.complete(_answer(_document(2, 'beta')));
  }
}

class _Transcripts extends RedleafTranscriptService {
  @override
  Future<RedleafTranscript> loadForDocument(
    RedleafSrtDocument document,
  ) async => RedleafTranscript(
        instanceId: 'thumbnail-recovery',
        docId: document.docId,
        relativePath: document.relativePath,
        track: SubtitleTrack(
          path: 'redleaf:thumbnail-recovery:document:${document.docId}',
          cues: const [],
        ),
      );
}

class _GatedThumbnails extends ThumbnailService {
  bool waiting = false;
  int resumes = 0;
  int requestsWhileRunning = 0;
  int requestsWhilePaused = 0;
  final List<Completer<void>> drains = <Completer<void>>[];

  @override
  bool get paused => waiting;

  @override
  Future<void> pauseAndDrain() {
    waiting = true;
    final drain = Completer<void>();
    drains.add(drain);
    return drain.future;
  }

  @override
  void resume() {
    resumes++;
    waiting = false;
  }

  @override
  Future<String?> thumbnailFor(ExplorerItem item) async {
    if (waiting) {
      requestsWhilePaused++;
    } else {
      requestsWhileRunning++;
    }
    return null;
  }
}

Widget _browser(
  _GatedThumbnails thumbnails, {
  bool active = true,
  ValueChanged<RedleafPlayerHandoff>? onOpen,
  _MediaResources? resources,
}) => MaterialApp(
      home: Scaffold(
        body: RedleafPage(
          key: const ValueKey('test-redleaf-browser'),
          active: active,
          workspaceProject: WorkspaceProject.redleaf(
            instanceId: 'thumbnail-recovery',
            name: 'Thumbnail recovery',
            serverUrl: 'http://127.0.0.1:5000',
          ),
          initialThumbnailMode: true,
          connection: _ConnectedRedleaf(),
          snapshotService: _Snapshots(),
          thumbnailService: thumbnails,
          mediaResourceService: resources ?? _MediaResources(),
          transcriptService: _Transcripts(),
          onOpenRedleafHandoff: onOpen ?? (_) {},
        ),
      ),
    );

Future<void> _mount(WidgetTester tester, _GatedThumbnails thumbnails,
    {ValueChanged<RedleafPlayerHandoff>? onOpen,
    _MediaResources? resources}) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
      _browser(thumbnails, onOpen: onOpen, resources: resources));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('redleaf-linked-video-grid')),
      findsOneWidget);
  expect(find.text('alpha.mp4'), findsOneWidget);
  expect(find.text('beta.mp4'), findsOneWidget);
}

Future<void> _open(WidgetTester tester, String mediaName,
    _GatedThumbnails thumbnails, int expectedDrains) async {
  // Exercise the actual Redleaf card's open callback, without introducing
  // gesture recognizer timers into thumbnail lifecycle regression tests.
  final card = tester.widget<RedleafLinkedVideoCard>(find.byWidgetPredicate(
    (widget) =>
        widget is RedleafLinkedVideoCard &&
        widget.document.media.path?.endsWith('/$mediaName') == true,
  ));
  card.onDoubleTap();
  await tester.pump();
  await tester.pump();
  expect(thumbnails.drains.length, expectedDrains);
}

void main() {
  testWidgets(
    'changing selection during a drain resumes and retries visible thumbnails',
    (tester) async {
      final thumbnails = _GatedThumbnails();
      final opened = <RedleafPlayerHandoff>[];
      await _mount(tester, thumbnails, onOpen: opened.add);

      final before = thumbnails.requestsWhileRunning;
      expect(before, greaterThanOrEqualTo(2));
      await _open(tester, 'alpha.mp4', thumbnails, 1);
      expect(thumbnails.paused, isTrue);

      // Invalidate alpha's handoff without leaving the Redleaf browser.
      await tester.tap(find.text('beta.mp4'));
      await tester.pump(const Duration(milliseconds: 400));

      thumbnails.drains[0].complete();
      await tester.pump();
      await tester.pump();

      expect(opened, isEmpty);
      expect(thumbnails.paused, isFalse);
      expect(thumbnails.resumes, 1);
      // Existing cards had futures that returned null while paused.
      // Recovery remounts them so the visible thumbnails get new requests.
      expect(thumbnails.requestsWhileRunning, greaterThan(before));
    },
  );

  testWidgets(
    'older canceled drain cannot resume while newer handoff is waiting',
    (tester) async {
      final thumbnails = _GatedThumbnails();
      final opened = <RedleafPlayerHandoff>[];
      await _mount(tester, thumbnails, onOpen: opened.add);

      await _open(tester, 'alpha.mp4', thumbnails, 1);
      await _open(tester, 'beta.mp4', thumbnails, 2);

      thumbnails.drains[0].complete();
      await tester.pump();
      expect(thumbnails.paused, isTrue);
      expect(thumbnails.resumes, 0);
      expect(opened, isEmpty);

      thumbnails.drains[1].complete();
      await tester.pump();
      expect(opened.map((handoff) => handoff.docId), <int>[2]);
      expect(thumbnails.paused, isTrue);
      expect(thumbnails.resumes, 0);
    },
  );

  testWidgets(
    'a newer grid open still resolving media prevents premature resume',
    (tester) async {
      final thumbnails = _GatedThumbnails();
      final resources = _MediaResources();
      final opened = <RedleafPlayerHandoff>[];
      await _mount(tester, thumbnails,
          onOpen: opened.add, resources: resources);

      await _open(tester, 'alpha.mp4', thumbnails, 1);

      // Beta's card was resolved during mount, but its new double-click
      // selection must now wait for a deliberately delayed media lookup.
      resources.holdBetaSelection = true;
      await _open(tester, 'beta.mp4', thumbnails, 1);

      // Alpha finishes its native drain while beta is still resolving.
      // Resuming here could admit fresh thumbnail work before beta opens.
      thumbnails.drains[0].complete();
      await tester.pump();
      expect(thumbnails.paused, isTrue);
      expect(thumbnails.resumes, 0);
      expect(opened, isEmpty);

      resources.releaseBetaSelection();
      await tester.pump();
      await tester.pump();
      expect(thumbnails.drains.length, 2);

      thumbnails.drains[1].complete();
      await tester.pump();
      expect(opened.map((handoff) => handoff.docId), <int>[2]);
      expect(thumbnails.resumes, 0);
    },
  );

  testWidgets(
    'leaving Redleaf during drain does not resume background thumbnail work',
    (tester) async {
      final thumbnails = _GatedThumbnails();
      final opened = <RedleafPlayerHandoff>[];
      await _mount(tester, thumbnails, onOpen: opened.add);

      await _open(tester, 'alpha.mp4', thumbnails, 1);
      await tester.pumpWidget(_browser(thumbnails, active: false,
          onOpen: opened.add));
      await tester.pump();
      expect(thumbnails.drains.length, 2);

      thumbnails.drains[0].complete();
      await tester.pump();
      expect(opened, isEmpty);
      expect(thumbnails.paused, isTrue);
      expect(thumbnails.resumes, 0);
      thumbnails.drains[1].complete();
    },
  );
}
