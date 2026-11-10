// test/redleaf_project_workspace_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/main.dart';
import 'package:mlt_player/models/workspace_project.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_project_snapshot_service.dart';
import 'package:mlt_player/ui/redleaf_page.dart';

WorkspaceProject _project(String id) => WorkspaceProject.redleaf(
      instanceId: id,
      name: 'Cloud archive $id',
      serverUrl: 'http://127.0.0.1:5000',
    );

class _ConnectedTestRedleaf extends RedleafConnectionService {
  _ConnectedTestRedleaf(this.expectedInstance);

  final String expectedInstance;
  int inventoryRefreshes = 0;

  @override
  String get instanceId => expectedInstance;

  @override
  bool get isConnected => true;

  @override
  String get projectName => 'Connected test project';

  @override
  Future<void> load() async {}

  @override
  Future<void> refreshInventory() async {
    inventoryRefreshes++;
    throw StateError('PROJECT navigation must not start SYNC NOW');
  }
}

class _SnapshotTestService extends RedleafProjectSnapshotService {
  int loads = 0;

  @override
  Future<RedleafProjectSnapshot?> load(String instanceId) async {
    loads++;
    return RedleafProjectSnapshot(
      instanceId: instanceId,
      syncedAt: DateTime.utc(2026, 11, 9),
      documents: const [],
      catalogs: const [],
      catalogMemberships: const {},
    );
  }
}

Widget _workspace(
  WorkspaceProject project, {
  RedleafConnectionService? connection,
  RedleafProjectSnapshotService? snapshots,
}) => MaterialApp(
      home: RedleafProjectWorkspace(
        project: project,
        active: true,
        importRequestSerial: 7,
        connection: connection,
        snapshotService: snapshots,
        onRename: (_) async {},
        onOpenVerifiedMedia: (_) {},
        onOpenRedleafHandoff: (_) {},
      ),
    );

void main() {
  testWidgets(
    'Redleaf PROJECT offers thumbnails without losing its project overview',
    (tester) async {
      await tester.pumpWidget(_workspace(_project('gallery-test-one')));

      expect(find.text('PROJECT OVERVIEW'), findsOneWidget);
      expect(find.byType(RedleafPage), findsNothing);
      expect(find.text('THUMBNAILS'), findsOneWidget);

      await tester.tap(find.text('THUMBNAILS'));
      await tester.pump();

      final browser = tester.widget<RedleafPage>(find.byType(RedleafPage));
      expect(browser.initialThumbnailMode, isTrue);
      expect(browser.importRequestSerial, 0);
      expect(browser.workspaceProject?.redleafInstanceId, 'gallery-test-one');

      // The existing RedleafPage controls, search, catalog and verified
      // transcript-aware handoff are reused, not reimplemented.
      expect(browser.onOpenRedleafHandoff, isNotNull);
      expect(browser.onOpenVerifiedMedia, isNotNull);

      await tester.tap(find.text('OVERVIEW'));
      await tester.pump();

      expect(find.byType(RedleafPage), findsNothing);
      expect(find.text('PROJECT OVERVIEW'), findsOneWidget);
    },
  );

  testWidgets(
    'repeated PROJECT gallery mounts never replay an old Settings import',
    (tester) async {
      // Exercise the full Redleaf cached summary at a normal desktop width,
      // rather than the test harness' unusually narrow 800-pixel viewport.
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final connection = _ConnectedTestRedleaf('gallery-no-sync');
      final snapshots = _SnapshotTestService();

      // A Settings import already advanced the shell serial to 7. The
      // PROJECT gallery is browsing a cached snapshot on a matching live
      // Redleaf connection, exactly the conditions of the reported bug.
      await tester.pumpWidget(_workspace(
        _project('gallery-no-sync'),
        connection: connection,
        snapshots: snapshots,
      ));
      await tester.tap(find.text('THUMBNAILS'));
      await tester.pumpAndSettle();

      expect(find.byType(RedleafPage), findsOneWidget);
      expect(snapshots.loads, 1);
      expect(connection.inventoryRefreshes, 0);

      await tester.tap(find.text('OVERVIEW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('THUMBNAILS'));
      await tester.pumpAndSettle();

      expect(snapshots.loads, 2);
      expect(connection.inventoryRefreshes, 0);
    },
  );

  testWidgets('switching Redleaf projects resets the PROJECT gallery',
      (tester) async {
    await tester.pumpWidget(_workspace(_project('gallery-test-two')));
    await tester.tap(find.text('THUMBNAILS'));
    await tester.pump();
    expect(find.byType(RedleafPage), findsOneWidget);

    await tester.pumpWidget(_workspace(_project('gallery-test-three')));
    await tester.pump();

    expect(find.byType(RedleafPage), findsNothing);
    expect(find.text('PROJECT OVERVIEW'), findsOneWidget);
    expect(find.text('Cloud archive gallery-test-three'), findsOneWidget);
  });

  test('normal Redleaf Explorer still defaults to SRT TABLE', () {
    const explorer = RedleafPage(active: false);
    expect(explorer.initialThumbnailMode, isFalse);
  });
}
