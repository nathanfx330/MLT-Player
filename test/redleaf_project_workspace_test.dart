// test/redleaf_project_workspace_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/main.dart';
import 'package:mlt_player/models/workspace_project.dart';
import 'package:mlt_player/ui/redleaf_page.dart';

WorkspaceProject _project(String id) => WorkspaceProject.redleaf(
      instanceId: id,
      name: 'Cloud archive $id',
      serverUrl: 'http://127.0.0.1:5000',
    );

Widget _workspace(WorkspaceProject project) => MaterialApp(
      home: RedleafProjectWorkspace(
        project: project,
        active: true,
        importRequestSerial: 7,
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
      expect(browser.importRequestSerial, 7);
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
