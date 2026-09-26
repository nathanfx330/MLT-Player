// test/player_settings_history_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/explorer_navigation_service.dart';
import 'package:mlt_player/services/player_settings_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/ui/widgets/player_settings_button.dart';

void main() {
  late Directory root;
  late ExplorerNavigationService navigation;
  late PlayerSettingsService settings;
  late RedleafConnectionService redleaf;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'mlt_player_settings_history_test_',
    );

    navigation = ExplorerNavigationService(
      configDirectory: Directory('${root.path}/navigation'),
      homePath: '${root.path}/home',
      recentLimit: 3,
      historyLimit: 10,
    );
    settings = PlayerSettingsService(
      configDirectory: Directory('${root.path}/settings'),
    );
    redleaf = RedleafConnectionService(
      configDirectory: Directory('${root.path}/redleaf'),
    );

    for (final name in <String>['A', 'B', 'C', 'D', 'E']) {
      navigation.recordVisit('${root.path}/$name');
    }
    await navigation.save();
  });

  tearDown(() async {
    settings.dispose();
    redleaf.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  testWidgets(
    'Settings clears short recents but keeps and opens long history',
    (tester) async {
      String? openedPath;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MltPlayerSettingsButton(
              settings: settings,
              mltVersion: '7.22.0',
              redleaf: redleaf,
              explorerNavigation: navigation,
              onOpenHistoryPath: (path) => openedPath = path,
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('CLEAR RECENT LIST'), findsOneWidget);
      expect(find.text('OPEN HISTORY (5)'), findsOneWidget);

      await tester.tap(find.text('CLEAR RECENT LIST'));
      await tester.pumpAndSettle();

      expect(navigation.recents, isEmpty);
      expect(navigation.locationHistory.length, 5);

      await tester.tap(find.text('OPEN HISTORY (5)'));
      await tester.pumpAndSettle();

      expect(find.text('Explorer History'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);

      await tester.tap(find.text('E'));
      await tester.pumpAndSettle();

      expect(
        openedPath,
        Directory('${root.path}/E').absolute.path,
      );
    },
  );

  testWidgets('History can be cleared without clearing sidebar recents', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MltPlayerSettingsButton(
            settings: settings,
            mltVersion: '7.22.0',
            redleaf: redleaf,
            explorerNavigation: navigation,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN HISTORY (5)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CLEAR HISTORY'));
    await tester.pumpAndSettle();

    expect(navigation.locationHistory, isEmpty);
    expect(navigation.recents.length, 3);
    expect(find.text('No folder history yet.'), findsOneWidget);
  });
}
